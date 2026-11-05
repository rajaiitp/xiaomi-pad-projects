package local.hdmi.controltile;

import android.os.Build;
import android.service.quicksettings.Tile;
import android.service.quicksettings.TileService;
import android.util.Log;
import android.widget.Toast;

/** A separate Quick Settings control for keeping the screen awake while plugged in. */
public final class CaffeinateControlTileService extends TileService {
    private static final String TAG = "CaffeinateTile";
    private String failureSummary;

    @Override
    public void onTileAdded() {
        super.onTileAdded();
        refreshAsync();
    }

    @Override
    public void onStartListening() {
        super.onStartListening();
        refreshAsync();
    }

    @Override
    public void onClick() {
        super.onClick();
        final boolean locked = isLocked();
        Log.i(TAG, "onClick locked=" + locked);
        Runnable action =
                new Runnable() {
                    @Override
                    public void run() {
                        setUnavailable();
                        new Thread(
                                        new Runnable() {
                                            @Override
                                            public void run() {
                                                final RootCommand.Result result =
                                                        RootCommand.run(
                                                                RootCommand.CAFFEINATE_TOGGLE);
                                                Log.i(
                                                        TAG,
                                                        "toggle exit="
                                                                + result.status
                                                                + " output="
                                                                + result.output);
                                                getMainExecutor()
                                                        .execute(
                                                                new Runnable() {
                                                                    @Override
                                                                    public void run() {
                                                                        failureSummary =
                                                                                result.status == 0
                                                                                        ? null
                                                                                        : summarizeFailure(
                                                                                                result);
                                                                        refreshAsync();
                                                                        String message =
                                                                                result.output
                                                                                                .isEmpty()
                                                                                        ? (result.status
                                                                                                        == 0
                                                                                                ? "Caffeinate"
                                                                                                      + " toggled"
                                                                                                : "Caffeinate"
                                                                                                      + " failed")
                                                                                        : result.output;
                                                                        Toast.makeText(
                                                                                        CaffeinateControlTileService
                                                                                                .this,
                                                                                        message,
                                                                                        result.status
                                                                                                        == 0
                                                                                                ? Toast
                                                                                                        .LENGTH_SHORT
                                                                                                : Toast
                                                                                                        .LENGTH_LONG)
                                                                                .show();
                                                                    }
                                                                });
                                            }
                                        },
                                        "caffeinate-toggle")
                                .start();
                    }
                };
        if (locked) {
            unlockAndRun(action);
        } else {
            action.run();
        }
    }

    private void setUnavailable() {
        Tile tile = getQsTile();
        if (tile != null) {
            tile.setState(Tile.STATE_UNAVAILABLE);
            tile.updateTile();
        }
    }

    private void refreshAsync() {
        new Thread(
                        new Runnable() {
                            @Override
                            public void run() {
                                final boolean enabled = RootCommand.isCaffeinateEnabled();
                                getMainExecutor()
                                        .execute(
                                                new Runnable() {
                                                    @Override
                                                    public void run() {
                                                        updateTile(enabled);
                                                    }
                                                });
                            }
                        },
                        "caffeinate-state")
                .start();
    }

    private void updateTile(boolean enabled) {
        Tile tile = getQsTile();
        if (tile == null) {
            return;
        }
        tile.setState(enabled ? Tile.STATE_ACTIVE : Tile.STATE_INACTIVE);
        tile.setLabel("Caffeinate");
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            tile.setSubtitle(
                    failureSummary != null
                            ? failureSummary
                            : (enabled ? "Stay awake" : "Allow timeout"));
        }
        tile.updateTile();
    }

    private static String summarizeFailure(RootCommand.Result result) {
        String detail = result.output.trim().replace('\n', ' ');
        if (detail.isEmpty()) {
            detail = "exit " + result.status;
        }
        return detail.length() > 48 ? detail.substring(0, 45) + "..." : detail;
    }
}

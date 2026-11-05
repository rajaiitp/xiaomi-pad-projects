package local.hdmi.controltile;

import android.content.ComponentName;
import android.os.Build;
import android.os.SystemClock;
import android.service.quicksettings.Tile;
import android.service.quicksettings.TileService;
import android.util.Log;
import android.widget.Toast;

/**
 * Retains the original component name because this is the SystemUI tile route that works reliably
 * on this device. It provides the single Move HDMI tile.
 */
public final class CaffeinateTileService extends TileService {
    private static final String TAG = "MoveHdmiTile";
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
        Log.i(TAG, "working-route click locked=" + locked);
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
                                                        RootCommand.run(RootCommand.TOGGLE);
                                                Log.i(
                                                        TAG,
                                                        "working-route move-toggle exit="
                                                                + result.status
                                                                + " output="
                                                                + result.output);
                                                if (result.status == 0) {
                                                    SystemClock.sleep(300);
                                                }
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
                                                                                                ? "HDMI mode"
                                                                                                      + " changed"
                                                                                                : "Move HDMI"
                                                                                                      + " failed")
                                                                                        : result.output;
                                                                        Toast.makeText(
                                                                                        CaffeinateTileService
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
                                        "move-hdmi-toggle")
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
                                final boolean active = RootCommand.isOnHdmi();
                                getMainExecutor()
                                        .execute(
                                                new Runnable() {
                                                    @Override
                                                    public void run() {
                                                        updateTile(active);
                                                    }
                                                });
                            }
                        },
                        "move-hdmi-state")
                .start();
    }

    private void updateTile(boolean active) {
        Tile tile = getQsTile();
        if (tile == null) {
            return;
        }
        tile.setState(active ? Tile.STATE_ACTIVE : Tile.STATE_INACTIVE);
        tile.setLabel("Move HDMI");
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            tile.setSubtitle(
                    failureSummary != null
                            ? failureSummary
                            : (active ? "App on TV" : "App on tablet"));
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

    public static void requestRefresh(android.content.Context context) {
        requestListeningState(context, new ComponentName(context, CaffeinateTileService.class));
    }
}

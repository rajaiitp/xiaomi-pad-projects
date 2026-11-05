package local.reading.mode;

import android.content.ComponentName;
import android.content.Context;
import android.service.quicksettings.Tile;
import android.service.quicksettings.TileService;
import android.util.Log;
import android.widget.Toast;

public final class ReadingTileService extends TileService {
    private static final String TAG = "ReadingMode";
    private boolean working;

    @Override
    public void onStartListening() {
        super.onStartListening();
        refresh();
    }

    @Override
    public void onClick() {
        super.onClick();
        if (working) {
            return;
        }
        if (isLocked()) {
            unlockAndRun(this::toggle);
        } else {
            toggle();
        }
    }

    private void toggle() {
        if (working) {
            return;
        }
        working = true;
        render(RootClient.Mode.UNAVAILABLE, getString(R.string.applying));
        RootClient.execute(
                RootClient.Operation.TOGGLE,
                getMainExecutor(),
                result -> {
                    working = false;
                    if (result.success) {
                        render(result.mode, null);
                    } else {
                        Log.e(TAG, result.message);
                        render(RootClient.Mode.UNAVAILABLE, getString(R.string.open_setup));
                        Toast.makeText(this, result.message, Toast.LENGTH_LONG).show();
                        refresh();
                    }
                });
    }

    private void refresh() {
        RootClient.execute(
                RootClient.Operation.STATUS,
                getMainExecutor(),
                result -> {
                    if (!working) {
                        render(result.mode, result.success ? null : getString(R.string.open_setup));
                    }
                });
    }

    private void render(RootClient.Mode mode, String subtitle) {
        Tile tile = getQsTile();
        if (tile == null) {
            return;
        }
        int state;
        int detail;
        switch (mode) {
            case OFF:
                state = Tile.STATE_INACTIVE;
                detail = R.string.mode_off;
                break;
            case ON:
                state = Tile.STATE_ACTIVE;
                detail = R.string.mode_on;
                break;
            case RECOVERY:
                state = Tile.STATE_ACTIVE;
                detail = R.string.mode_recovery;
                break;
            case UNAVAILABLE:
                state = Tile.STATE_UNAVAILABLE;
                detail = R.string.open_setup;
                break;
            default:
                throw new IllegalStateException("Unknown Reading Mode state: " + mode);
        }
        tile.setState(state);
        tile.setLabel(getString(R.string.app_name));
        tile.setSubtitle(subtitle == null ? getString(detail) : subtitle);
        tile.setContentDescription(getString(R.string.tile_description, tile.getSubtitle()));
        tile.updateTile();
    }

    static void requestRefresh(Context context) {
        requestListeningState(context, new ComponentName(context, ReadingTileService.class));
    }
}

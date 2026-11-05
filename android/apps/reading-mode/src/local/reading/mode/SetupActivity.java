package local.reading.mode;

import android.app.Activity;
import android.app.StatusBarManager;
import android.content.ComponentName;
import android.graphics.drawable.Icon;
import android.os.Bundle;
import android.view.Gravity;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;

public final class SetupActivity extends Activity {
    private TextView status;
    private Button rootButton;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        int padding = Math.round(24 * getResources().getDisplayMetrics().density);
        LinearLayout layout = new LinearLayout(this);
        layout.setOrientation(LinearLayout.VERTICAL);
        layout.setGravity(Gravity.CENTER);
        layout.setPadding(padding, padding, padding, padding);

        TextView instructions = new TextView(this);
        instructions.setText(R.string.instructions);
        instructions.setTextSize(18);
        instructions.setGravity(Gravity.CENTER);
        layout.addView(instructions);

        status = new TextView(this);
        status.setText(R.string.not_checked);
        status.setGravity(Gravity.CENTER);
        status.setPadding(0, padding, 0, padding);
        layout.addView(status);

        rootButton = new Button(this);
        rootButton.setText(R.string.root_button);
        rootButton.setOnClickListener(view -> checkRoot());
        layout.addView(rootButton);

        Button addButton = new Button(this);
        addButton.setText(R.string.add_tile);
        addButton.setOnClickListener(view -> addTile());
        layout.addView(addButton);
        setContentView(layout);
    }

    private void checkRoot() {
        rootButton.setEnabled(false);
        status.setText(R.string.checking);
        RootClient.execute(
                RootClient.Operation.CHECK,
                getMainExecutor(),
                result -> {
                    if (isDestroyed()) {
                        return;
                    }
                    if (!result.success) {
                        rootButton.setEnabled(true);
                        status.setText(getString(R.string.failure, result.message));
                        return;
                    }
                    RootClient.execute(
                            RootClient.Operation.STATUS,
                            getMainExecutor(),
                            state -> {
                                if (isDestroyed()) {
                                    return;
                                }
                                rootButton.setEnabled(true);
                                status.setText(
                                        state.success
                                                ? getString(R.string.ready, state.message)
                                                : getString(R.string.failure, state.message));
                                ReadingTileService.requestRefresh(this);
                            });
                });
    }

    private void addTile() {
        StatusBarManager manager = getSystemService(StatusBarManager.class);
        if (manager == null) {
            status.setText(R.string.add_unavailable);
            return;
        }
        manager.requestAddTileService(
                new ComponentName(this, ReadingTileService.class),
                getString(R.string.app_name),
                Icon.createWithResource(this, R.drawable.ic_reading),
                getMainExecutor(),
                result -> {
                    if (result == StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ADDED
                            || result
                                    == StatusBarManager
                                            .TILE_ADD_REQUEST_RESULT_TILE_ALREADY_ADDED) {
                        status.setText(R.string.tile_added);
                    } else {
                        status.setText(R.string.add_unavailable);
                    }
                });
    }
}

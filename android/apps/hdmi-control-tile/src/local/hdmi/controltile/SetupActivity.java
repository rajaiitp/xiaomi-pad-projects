package local.hdmi.controltile;

import android.app.Activity;
import android.os.Bundle;
import android.view.Gravity;
import android.view.View;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.widget.Toast;

public final class SetupActivity extends Activity {
    private TextView statusView;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        LinearLayout layout = new LinearLayout(this);
        layout.setOrientation(LinearLayout.VERTICAL);
        layout.setGravity(Gravity.CENTER);
        int padding = (int) (32 * getResources().getDisplayMetrics().density);
        layout.setPadding(padding, padding, padding, padding);

        statusView = new TextView(this);
        statusView.setText("Grant root access once, then use the Move HDMI Quick Settings tile.");
        statusView.setGravity(Gravity.CENTER);
        statusView.setTextSize(18);
        layout.addView(
                statusView,
                new LinearLayout.LayoutParams(
                        LinearLayout.LayoutParams.MATCH_PARENT,
                        LinearLayout.LayoutParams.WRAP_CONTENT));

        Button button = new Button(this);
        button.setText("Grant root access");
        LinearLayout.LayoutParams buttonParams =
                new LinearLayout.LayoutParams(
                        LinearLayout.LayoutParams.WRAP_CONTENT,
                        LinearLayout.LayoutParams.WRAP_CONTENT);
        buttonParams.topMargin = padding;
        layout.addView(button, buttonParams);
        button.setOnClickListener(
                new View.OnClickListener() {
                    @Override
                    public void onClick(View view) {
                        requestRoot();
                    }
                });

        setContentView(layout);
        requestRoot();
    }

    private void requestRoot() {
        statusView.setText("Waiting for root permission…");
        new Thread(
                        new Runnable() {
                            @Override
                            public void run() {
                                final RootCommand.Result result =
                                        RootCommand.run(RootCommand.ROOT_CHECK);
                                runOnUiThread(
                                        new Runnable() {
                                            @Override
                                            public void run() {
                                                if (result.status == 0) {
                                                    statusView.setText(
                                                            "Ready. The Move HDMI tile sends the"
                                                                    + " current app to the TV.");
                                                    CaffeinateTileService.requestRefresh(
                                                            SetupActivity.this);
                                                    Toast.makeText(
                                                                    SetupActivity.this,
                                                                    "Move HDMI is ready",
                                                                    Toast.LENGTH_SHORT)
                                                            .show();
                                                } else {
                                                    statusView.setText(
                                                            "Root access failed: " + result.output);
                                                }
                                            }
                                        });
                            }
                        },
                        "hdmi-control-root-setup")
                .start();
    }
}

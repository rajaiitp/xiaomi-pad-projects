package local.power.mode;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.util.Log;

import java.io.IOException;
import java.util.concurrent.TimeUnit;

public final class BootReceiver extends BroadcastReceiver {
    private static final String TAG = "OfflineStandby";
    private static final long START_TIMEOUT_SECONDS = 10;

    @Override
    public void onReceive(Context context, Intent intent) {
        String action = intent.getAction();
        if (!Intent.ACTION_BOOT_COMPLETED.equals(action)
                && !Intent.ACTION_LOCKED_BOOT_COMPLETED.equals(action)
                && !Intent.ACTION_MY_PACKAGE_REPLACED.equals(action)) return;
        if (Maintenance.active(context)) return;
        try {
            context.startForegroundService(
                    new Intent(context, StandbyService.class).setAction(StandbyService.RECONCILE));
        } catch (IllegalStateException error) {
            Log.w(
                    TAG,
                    "Framework denied background startup; using the provisioned root launcher",
                    error);
            PendingResult pending = goAsync();
            new Thread(
                            () -> {
                                try {
                                    RootChannel.startService(
                                            System.nanoTime()
                                                    + TimeUnit.SECONDS.toNanos(
                                                            START_TIMEOUT_SECONDS));
                                } catch (IOException failure) {
                                    Log.e(TAG, "Automatic startup failed", failure);
                                } finally {
                                    pending.finish();
                                }
                            },
                            "sleep-mode-startup")
                    .start();
        }
    }
}

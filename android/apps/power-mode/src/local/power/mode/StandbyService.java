package local.power.mode;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.ServiceInfo;
import android.hardware.display.DisplayManager;
import android.net.Uri;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.PowerManager;
import android.provider.Settings;
import android.util.Log;
import android.view.Display;

import java.io.IOException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;

public final class StandbyService extends Service {
    static final String RECONCILE = RootChannel.START_ACTION;
    private static final String MAINTENANCE_START = "allow_maintenance";
    private static final String CHANNEL = "sleep-mode";
    private static final String TAG = "OfflineStandby";
    private static final int NOTIFICATION_ID = 1;
    private static final int MAX_ATTEMPTS = 2;
    private static final long TRANSITION_TIMEOUT_SECONDS = 45;
    private static final long WAKE_LOCK_TIMEOUT_MILLIS = 60000;
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private final Handler main = new Handler(Looper.getMainLooper());
    private final AtomicBoolean pending = new AtomicBoolean();
    private volatile boolean maintenanceStartAllowed;
    private RootChannel root;
    private PowerManager.WakeLock transition;
    private volatile boolean destroyed;
    private volatile long generation;
    private final BroadcastReceiver events =
            new BroadcastReceiver() {
                @Override
                public void onReceive(Context context, Intent intent) {
                    reconcile();
                }
            };
    private final DisplayManager.DisplayListener displays =
            new DisplayManager.DisplayListener() {
                @Override
                public void onDisplayAdded(int id) {
                    reconcile();
                }

                @Override
                public void onDisplayRemoved(int id) {
                    reconcile();
                }

                @Override
                public void onDisplayChanged(int id) {
                    if (id != Display.DEFAULT_DISPLAY) reconcile();
                }
            };

    @Override
    public void onCreate() {
        super.onCreate();
        NotificationManager notifications = getSystemService(NotificationManager.class);
        notifications.createNotificationChannel(
                new NotificationChannel(
                        CHANNEL,
                        getString(R.string.channel_name),
                        NotificationManager.IMPORTANCE_LOW));
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
            startForeground(
                    NOTIFICATION_ID,
                    notification(R.string.starting),
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE);
        else startForeground(NOTIFICATION_ID, notification(R.string.starting));
        transition =
                getSystemService(PowerManager.class)
                        .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "power-mode:transition");
        transition.setReferenceCounted(false);
        IntentFilter filter = new IntentFilter();
        filter.addAction(Intent.ACTION_SCREEN_ON);
        filter.addAction(Intent.ACTION_SCREEN_OFF);
        filter.addAction(Intent.ACTION_POWER_CONNECTED);
        filter.addAction(Intent.ACTION_POWER_DISCONNECTED);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU)
            registerReceiver(events, filter, Context.RECEIVER_NOT_EXPORTED);
        else registerReceiver(events, filter);
        getSystemService(DisplayManager.class).registerDisplayListener(displays, main);
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        boolean bootstrap = intent != null && intent.getBooleanExtra(MAINTENANCE_START, false);
        if ((Maintenance.active(this) && !bootstrap)
                || (intent != null && !RECONCILE.equals(intent.getAction()))) {
            stopSelf(startId);
            return START_NOT_STICKY;
        }
        maintenanceStartAllowed = bootstrap;
        reconcile();
        return START_STICKY;
    }

    private void reconcile() {
        if (!destroyed && pending.compareAndSet(false, true))
            worker.execute(
                    () -> {
                        pending.set(false);
                        run();
                    });
    }

    private RootChannel channel(long deadline) throws IOException {
        if (root == null) {
            long current = ++generation;
            root =
                    new RootChannel(
                            () ->
                                    main.post(
                                            () -> {
                                                if (!destroyed && generation == current)
                                                    reconcile();
                                            }),
                            deadline);
        }
        root.setDeadline(deadline);
        return root;
    }

    private RootChannel.Mode reconcileRoot(long deadline) throws IOException {
        for (int attempt = 0; attempt < MAX_ATTEMPTS; attempt++) {
            try {
                return channel(deadline).execute(RootChannel.Command.RECONCILE);
            } catch (IOException error) {
                Log.e(TAG, "Controller failed", error);
                closeRoot(deadline);
                RootChannel.recover(deadline);
                if (attempt == MAX_ATTEMPTS - 1) throw error;
            }
        }
        throw new IOException("Recovery attempts exhausted");
    }

    private void run() {
        if (destroyed) return;
        if (Maintenance.active(this) && !maintenanceStartAllowed) return;
        long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(TRANSITION_TIMEOUT_SECONDS);
        transition.acquire(WAKE_LOCK_TIMEOUT_MILLIS);
        try {
            RootChannel.Mode mode = reconcileRoot(deadline);
            Log.i(TAG, "Sleep mode state: " + mode);
            main.post(
                    () -> {
                        if (destroyed) return;
                        getSystemService(NotificationManager.class)
                                .notify(NOTIFICATION_ID, notification(label(mode)));
                        if (mode == RootChannel.Mode.OFF) stopSelf();
                    });
        } catch (IOException error) {
            Log.e(TAG, "Sleep mode unavailable; verify recovery", error);
            main.post(
                    () -> {
                        if (!destroyed)
                            getSystemService(NotificationManager.class)
                                    .notify(NOTIFICATION_ID, notification(R.string.error));
                    });
        } finally {
            if (transition.isHeld()) transition.release();
        }
    }

    private void closeRoot(long deadline) {
        generation++;
        if (root == null) return;
        RootChannel old = root;
        root = null;
        old.setDeadline(deadline);
        try {
            old.close();
        } catch (IOException error) {
            Log.e(TAG, "Broker cleanup failed", error);
        }
    }

    private static int label(RootChannel.Mode mode) {
        switch (mode) {
            case OFF:
                return R.string.off;
            case ARMED:
                return R.string.armed;
            case SLEEPING:
                return R.string.sleeping;
            case STOPPED:
                return R.string.stopped;
            case RECOVERY:
                return R.string.recovery;
            case INVALID:
                return R.string.error;
            default:
                throw new IllegalStateException("Unknown Sleep mode state");
        }
    }

    private Notification notification(int text) {
        Intent details =
                new Intent(
                        Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                        Uri.fromParts("package", getPackageName(), null));
        PendingIntent setup =
                PendingIntent.getActivity(
                        this,
                        0,
                        details,
                        PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        return new Notification.Builder(this, CHANNEL)
                .setSmallIcon(R.drawable.ic_standby)
                .setContentTitle(getString(R.string.app_name))
                .setContentText(getString(text))
                .setContentIntent(setup)
                .setOngoing(true)
                .build();
    }

    @Override
    public void onDestroy() {
        destroyed = true;
        unregisterReceiver(events);
        getSystemService(DisplayManager.class).unregisterDisplayListener(displays);
        worker.execute(
                () ->
                        closeRoot(
                                System.nanoTime()
                                        + TimeUnit.SECONDS.toNanos(TRANSITION_TIMEOUT_SECONDS)));
        worker.shutdown();
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }
}

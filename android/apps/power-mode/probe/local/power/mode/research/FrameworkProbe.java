package local.power.mode.research;

import android.os.Build;

import dalvik.system.PathClassLoader;

import java.io.IOException;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.Arrays;
import java.util.HashSet;
import java.util.Set;

public final class FrameworkProbe {
    private static final Set<String> METHODS =
            new HashSet<>(
                    Arrays.asList(
                            "startProcessLocked",
                            "handleProcessStartedLocked",
                            "isProcStartValidLocked",
                            "forceFreezeAppAsyncLSP",
                            "unfreezeAppLSP",
                            "freezeAppAsyncInternalLSP",
                            "useFreezer",
                            "unfreezeProcess",
                            "freezeProcess",
                            "freezeBinder",
                            "setFreezeSticky",
                            "isFreezeSticky",
                            "isFrozen",
                            "shouldNotFreeze",
                            "getUid",
                            "getPid",
                            "getPkgList",
                            "attachApplicationLocked",
                            "systemReady",
                            "getProcessRecordLocked",
                            "enqueueBroadcastLocked",
                            "forceDelayBroadcastDelivery",
                            "setQueueProcessDeferredLocked"));
    private static final Set<String> FIELDS =
            new HashSet<>(
                    Arrays.asList(
                            "uid",
                            "info",
                            "mOptRecord",
                            "mService",
                            "mProcessList",
                            "mContext",
                            "mCachedAppOptimizer",
                            "mProcLock",
                            "mFreezerLock",
                            "mBroadcastQueue"));

    private FrameworkProbe() {}

    public static void main(String[] arguments) throws Exception {
        if (arguments.length != 1 || Integer.parseInt(arguments[0]) <= 0) {
            throw new IllegalArgumentException("Expected the system_server PID");
        }
        System.out.println("probe_schema=1");
        System.out.println("sdk=" + Build.VERSION.SDK_INT);
        System.out.println("build=" + Build.DISPLAY);
        Object service =
                Class.forName("android.app.ActivityManager")
                        .getDeclaredMethod("getService")
                        .invoke(null);
        for (String query : new String[] {"isAppFreezerSupported", "isAppFreezerEnabled"}) {
            System.out.println(query + "=" + service.getClass().getMethod(query).invoke(service));
        }
        ClassLoader loader =
                new PathClassLoader(
                        systemServerClassPath(arguments[0]), ClassLoader.getSystemClassLoader());
        for (String name :
                new String[] {
                    "ProcessList",
                    "ProcessRecord",
                    "CachedAppOptimizer",
                    "ProcessCachedOptimizerRecord",
                    "ActivityManagerService",
                    "BroadcastQueue",
                    "BroadcastQueueModernImpl",
                    "BroadcastProcessQueue",
                    "Freezer"
                }) {
            inspect(loader, "com.android.server.am." + name);
        }
    }

    private static String systemServerClassPath(String pid) throws IOException {
        String environment =
                new String(
                        Files.readAllBytes(Paths.get("/proc", pid, "environ")),
                        StandardCharsets.UTF_8);
        StringBuilder result = new StringBuilder();
        for (String entry : environment.split("\0")) {
            if (entry.startsWith("SYSTEMSERVERCLASSPATH=")
                    || entry.startsWith("STANDALONE_SYSTEMSERVER_JARS=")) {
                String value = entry.substring(entry.indexOf('=') + 1);
                if (!value.isEmpty()) {
                    if (result.length() != 0) result.append(':');
                    result.append(value);
                }
            }
        }
        if (result.length() == 0) throw new IOException("System-server classpath unavailable");
        return result.toString();
    }

    private static void inspect(ClassLoader loader, String name) {
        System.out.println("CLASS " + name);
        Class<?> type;
        try {
            type = Class.forName(name, false, loader);
        } catch (LinkageError | ReflectiveOperationException error) {
            System.out.println("UNRESOLVED " + error);
            return;
        }
        try {
            for (Method method : type.getDeclaredMethods()) {
                if (METHODS.contains(method.getName()))
                    System.out.println(method.toGenericString());
            }
        } catch (LinkageError error) {
            System.out.println("UNRESOLVED_METHODS " + error);
        }
        try {
            for (Class<?> parent = type; parent != null; parent = parent.getSuperclass()) {
                for (Field field : parent.getDeclaredFields()) {
                    if (FIELDS.contains(field.getName()))
                        System.out.println(field.toGenericString());
                }
            }
        } catch (LinkageError error) {
            System.out.println("UNRESOLVED_FIELDS " + error);
        }
    }
}

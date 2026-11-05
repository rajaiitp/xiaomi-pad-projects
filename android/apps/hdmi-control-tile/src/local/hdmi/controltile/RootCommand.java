package local.hdmi.controltile;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStreamReader;
import java.util.concurrent.TimeUnit;

final class RootCommand {
    // Magisk grants a tile app a root mount namespace that cannot execute
    // Termux-private files under /data/data. Keep this canonical root copy
    // beside the other /data/adb tablet services.
    private static final String DISPATCHER = "/data/adb/tablet-playback";
    private static final long TIMEOUT_SECONDS = 20;

    static final String TOGGLE = dispatch("move-toggle");
    static final String STATE = dispatch("move-state");
    static final String ROOT_CHECK =
            "test \"$(id -u)\" = 0 && test -x " + quote(DISPATCHER) + " && echo ready";
    static final String CAFFEINATE_TOGGLE =
            "current=$(settings get global stay_on_while_plugged_in 2>/dev/null); "
                    + "case \"$current\" in "
                    + "0|null|'') svc power stayon true && echo 'Caffeinate enabled' ;; "
                    + "*) svc power stayon false && echo 'Caffeinate disabled' ;; "
                    + "esac";

    private RootCommand() {}

    private static String dispatch(String action) {
        return "test -x "
                + quote(DISPATCHER)
                + " || { echo 'Tablet dispatcher is not installed'; exit 1; }; "
                + "printf '%s\\n%s\\n' "
                + quote(action)
                + " '' | "
                + quote(DISPATCHER);
    }

    private static String quote(String value) {
        return "'" + value.replace("'", "'\\''") + "'";
    }

    static boolean isOnHdmi() {
        Result result = run(STATE);
        return result.status == 0 && "hdmi".equals(result.output.trim());
    }

    static boolean isCaffeinateEnabled() {
        Result result = run("settings get global stay_on_while_plugged_in");
        String value = result.output.trim();
        return result.status == 0
                && !value.isEmpty()
                && !"0".equals(value)
                && !"null".equals(value);
    }

    static synchronized Result run(String command) {
        Process process = null;
        Thread outputReader = null;
        StringBuffer output = new StringBuffer();
        try {
            process = new ProcessBuilder("su", "-c", command).redirectErrorStream(true).start();
            final Process runningProcess = process;
            outputReader =
                    new Thread(
                            new Runnable() {
                                @Override
                                public void run() {
                                    try (BufferedReader reader =
                                            new BufferedReader(
                                                    new InputStreamReader(
                                                            runningProcess.getInputStream()))) {
                                        String line;
                                        while ((line = reader.readLine()) != null) {
                                            if (output.length() > 0) {
                                                output.append('\n');
                                            }
                                            output.append(line);
                                        }
                                    } catch (IOException ignored) {
                                        // Process teardown closes the pipe when a command times
                                        // out.
                                    }
                                }
                            },
                            "move-hdmi-root-output");
            outputReader.start();

            if (!process.waitFor(TIMEOUT_SECONDS, TimeUnit.SECONDS)) {
                process.destroy();
                if (!process.waitFor(1, TimeUnit.SECONDS)) {
                    process.destroyForcibly();
                    process.waitFor(1, TimeUnit.SECONDS);
                }
                outputReader.join(1000);
                return new Result(124, "Root command timed out");
            }
            outputReader.join(1000);
            return new Result(process.exitValue(), output.toString());
        } catch (Exception error) {
            if (process != null) {
                process.destroyForcibly();
            }
            if (outputReader != null) {
                try {
                    outputReader.join(1000);
                } catch (InterruptedException interrupted) {
                    Thread.currentThread().interrupt();
                }
            }
            return new Result(
                    1, error.getMessage() == null ? error.toString() : error.getMessage());
        }
    }

    static final class Result {
        final int status;
        final String output;

        Result(int status, String output) {
            this.status = status;
            this.output = output;
        }
    }
}

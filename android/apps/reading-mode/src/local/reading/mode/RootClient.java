package local.reading.mode;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.Executor;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

final class RootClient {
    private static final String CONTROLLER = "/data/adb/reading-mode-control";
    private static final long TIMEOUT_SECONDS = 60;
    private static final int OUTPUT_LIMIT = 8192;
    private static final long READER_TIMEOUT_MILLIS = 1000;
    private static final ExecutorService WORKER = Executors.newSingleThreadExecutor();

    enum Operation {
        INVALID(""),
        CHECK("check"),
        STATUS("status"),
        TOGGLE("toggle");

        final String argument;

        Operation(String argument) {
            this.argument = argument;
        }
    }

    enum Mode {
        UNAVAILABLE,
        OFF,
        ON,
        RECOVERY
    }

    interface Callback {
        void complete(Result result);
    }

    static final class Result {
        final boolean success;
        final Mode mode;
        final String message;

        Result(boolean success, Mode mode, String message) {
            this.success = success;
            this.mode = mode;
            this.message = message;
        }
    }

    private RootClient() {}

    static void execute(Operation operation, Executor callbackExecutor, Callback callback) {
        if (operation == Operation.INVALID) {
            throw new IllegalArgumentException("Invalid Reading Mode operation");
        }
        WORKER.execute(
                () -> {
                    Result result = run(operation);
                    callbackExecutor.execute(() -> callback.complete(result));
                });
    }

    private static Result run(Operation operation) {
        Process process = null;
        Thread reader = null;
        StringBuffer output = new StringBuffer();
        try {
            process =
                    new ProcessBuilder("su", "-c", CONTROLLER + " " + operation.argument)
                            .redirectErrorStream(true)
                            .start();
            process.getOutputStream().close();
            Process running = process;
            reader =
                    new Thread(
                            () -> {
                                try (BufferedReader stream =
                                        new BufferedReader(
                                                new InputStreamReader(
                                                        running.getInputStream(),
                                                        StandardCharsets.UTF_8))) {
                                    String line;
                                    while ((line = stream.readLine()) != null) {
                                        if (output.length() < OUTPUT_LIMIT) {
                                            if (output.length() > 0) {
                                                output.append('\n');
                                            }
                                            output.append(
                                                    line,
                                                    0,
                                                    Math.min(
                                                            line.length(),
                                                            OUTPUT_LIMIT - output.length()));
                                        }
                                    }
                                } catch (IOException error) {
                                    if (output.length() == 0) {
                                        output.append(error.toString());
                                    }
                                }
                            },
                            "reading-mode-output");
            reader.start();
            if (!process.waitFor(TIMEOUT_SECONDS, TimeUnit.SECONDS)) {
                return failure("Root operation timed out. Check the tile state before retrying.");
            }
            reader.join(READER_TIMEOUT_MILLIS);
            String message = output.toString().trim();
            if (process.exitValue() != 0 || reader.isAlive()) {
                return failure(message.isEmpty() ? "Root operation failed" : message);
            }
            if (operation == Operation.CHECK) {
                return "ready".equals(message)
                        ? new Result(true, Mode.UNAVAILABLE, message)
                        : failure("Unexpected controller response: " + message);
            }
            switch (message) {
                case "off":
                    return new Result(true, Mode.OFF, message);
                case "on":
                    return new Result(true, Mode.ON, message);
                case "recovery":
                    return new Result(true, Mode.RECOVERY, message);
                default:
                    return failure("Unexpected controller response: " + message);
            }
        } catch (InterruptedException error) {
            Thread.currentThread().interrupt();
            return failure("Root operation interrupted. Check the tile state before retrying.");
        } catch (IOException error) {
            return failure(error.toString());
        } finally {
            if (process != null) {
                process.destroyForcibly();
            }
            if (reader != null && reader.isAlive()) {
                reader.interrupt();
            }
        }
    }

    private static Result failure(String message) {
        return new Result(false, Mode.UNAVAILABLE, message);
    }
}

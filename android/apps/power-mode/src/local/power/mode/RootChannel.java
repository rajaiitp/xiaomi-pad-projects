package local.power.mode;

import java.io.BufferedReader;
import java.io.Closeable;
import java.io.IOException;
import java.io.InputStreamReader;
import java.io.OutputStreamWriter;
import java.io.Writer;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;

final class RootChannel implements Closeable {
    static final String CONTROLLER = "/data/adb/power-mode-control";
    static final String START_ACTION = "local.power.mode.RECONCILE";
    private static final String START_SERVICE =
            "am start-foreground-service --user 0 -n local.power.mode/.StandbyService -a "
                    + START_ACTION;
    private static final long COMMAND_TIMEOUT_SECONDS = 60;
    private static final int QUEUE_LIMIT = 8;
    private static final int MAX_LINE = 128;
    private static final String END = "<closed>";
    private final Process process;
    private final Writer input;
    private final ArrayBlockingQueue<String> output = new ArrayBlockingQueue<>(QUEUE_LIMIT);
    private final AtomicBoolean ready = new AtomicBoolean();
    private final AtomicBoolean closing = new AtomicBoolean();
    private volatile long deadline = Long.MAX_VALUE;

    enum Mode {
        INVALID,
        OFF,
        ARMED,
        SLEEPING,
        STOPPED,
        RECOVERY;

        static Mode parse(String text) throws IOException {
            switch (text) {
                case "off":
                    return OFF;
                case "armed":
                    return ARMED;
                case "sleeping":
                    return SLEEPING;
                case "stopped":
                    return STOPPED;
                case "recovery":
                    return RECOVERY;
                default:
                    throw new IOException("Controller response: " + text);
            }
        }
    }

    enum Command {
        INVALID(""),
        ENABLE("enable"),
        DISABLE("disable"),
        RECONCILE("reconcile"),
        STATUS("status");
        final String argument;

        Command(String argument) {
            this.argument = argument;
        }
    }

    RootChannel(Runnable disconnected, long deadline) throws IOException {
        this(
                new ProcessBuilder("su", "-c", CONTROLLER + " broker").start(),
                disconnected,
                deadline);
    }

    RootChannel(Process process) throws IOException {
        this(process, () -> {}, Long.MAX_VALUE);
    }

    RootChannel(Process process, Runnable disconnected, long deadline) throws IOException {
        this.process = process;
        this.deadline = deadline;
        input = new OutputStreamWriter(process.getOutputStream(), StandardCharsets.UTF_8);
        Thread reader =
                new Thread(
                        () -> {
                            try (BufferedReader stream =
                                    new BufferedReader(
                                            new InputStreamReader(
                                                    process.getInputStream(),
                                                    StandardCharsets.UTF_8))) {
                                StringBuilder line = new StringBuilder();
                                int character;
                                while ((character = stream.read()) != -1) {
                                    if (character == '\n') {
                                        if (!output.offer(line.toString())) break;
                                        line.setLength(0);
                                    } else {
                                        if (line.length() == MAX_LINE) break;
                                        line.append((char) character);
                                    }
                                }
                            } catch (IOException ignored) {
                                // A waiting command observes END; idle disconnects trigger
                                // recovery.
                            } finally {
                                output.offer(END);
                                if (ready.get() && !closing.get()) disconnected.run();
                            }
                        },
                        "sleep-mode-root-output");
        Thread errors =
                new Thread(
                        () -> {
                            try (InputStreamReader stream =
                                    new InputStreamReader(
                                            process.getErrorStream(), StandardCharsets.UTF_8)) {
                                char[] buffer = new char[MAX_LINE];
                                int count;
                                int logged = 0;
                                while ((count = stream.read(buffer)) != -1) {
                                    if (logged++ < QUEUE_LIMIT)
                                        System.err.print(new String(buffer, 0, count));
                                }
                            } catch (IOException ignored) {
                                // Closing the controller also closes stderr.
                            }
                        },
                        "sleep-mode-root-errors");
        reader.start();
        errors.start();
        try {
            if (!"ready".equals(receive()))
                throw new IOException("Root controller did not become ready");
            ready.set(true);
        } catch (IOException error) {
            try {
                close();
            } catch (IOException cleanup) {
                error.addSuppressed(cleanup);
            }
            throw error;
        }
    }

    void setDeadline(long value) {
        deadline = value;
    }

    Mode execute(Command command) throws IOException {
        if (command == Command.INVALID) throw new IllegalArgumentException("Invalid command");
        remaining(deadline);
        input.write(command.argument + "\n");
        input.flush();
        return Mode.parse(receive());
    }

    private static long remaining(long deadline) throws IOException {
        long timeout = TimeUnit.SECONDS.toNanos(COMMAND_TIMEOUT_SECONDS);
        if (deadline != Long.MAX_VALUE) timeout = Math.min(timeout, deadline - System.nanoTime());
        if (timeout <= 0) throw new IOException("Transition deadline exceeded");
        return timeout;
    }

    private String receive() throws IOException {
        try {
            String line = output.poll(remaining(deadline), TimeUnit.NANOSECONDS);
            if (line == null || END.equals(line))
                throw new IOException("Root controller disconnected or timed out");
            return line;
        } catch (InterruptedException error) {
            Thread.currentThread().interrupt();
            throw new IOException("Root operation interrupted", error);
        }
    }

    static void startService(long deadline) throws IOException {
        Process child = new ProcessBuilder("su", "-c", START_SERVICE).start();
        try {
            child.getOutputStream().close();
            if (!child.waitFor(remaining(deadline), TimeUnit.NANOSECONDS) || child.exitValue() != 0)
                throw new IOException("Root service startup failed or timed out");
        } catch (InterruptedException error) {
            Thread.currentThread().interrupt();
            throw new IOException("Root service startup interrupted", error);
        } finally {
            child.destroy();
        }
    }

    static Mode recover(long deadline) throws IOException {
        Process child = new ProcessBuilder("su", "-c", CONTROLLER + " recover").start();
        try {
            child.getOutputStream().close();
            if (!child.waitFor(remaining(deadline), TimeUnit.NANOSECONDS) || child.exitValue() != 0)
                throw new IOException("Root recovery failed or timed out");
            try (BufferedReader stream =
                    new BufferedReader(
                            new InputStreamReader(
                                    child.getInputStream(), StandardCharsets.UTF_8))) {
                String line = stream.readLine();
                if (line == null || stream.readLine() != null)
                    throw new IOException("Recovery was not confirmed");
                Mode mode = Mode.parse(line);
                if (mode != Mode.OFF && mode != Mode.STOPPED)
                    throw new IOException("Recovery remains incomplete: " + mode);
                return mode;
            }
        } catch (InterruptedException error) {
            Thread.currentThread().interrupt();
            throw new IOException("Root recovery interrupted", error);
        } finally {
            child.destroy();
        }
    }

    @Override
    public void close() throws IOException {
        closing.set(true);
        IOException failure = null;
        try {
            input.close();
        } catch (IOException error) {
            failure = error;
        }
        try {
            if (!process.waitFor(remaining(deadline), TimeUnit.NANOSECONDS))
                throw new IOException("Restoration timed out; snapshot retained");
            if (process.exitValue() != 0)
                throw new IOException("Root restoration failed; snapshot retained");
        } catch (InterruptedException error) {
            Thread.currentThread().interrupt();
            failure = new IOException("Restoration interrupted", error);
        } catch (IOException error) {
            if (failure == null) failure = error;
            else failure.addSuppressed(error);
        } finally {
            process.destroy();
        }
        if (failure != null) throw failure;
    }
}

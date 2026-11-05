package local.power.mode;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

public final class RootChannelTest {
    private RootChannelTest() {}

    public static void main(String[] args) throws Exception {
        Path restored = Files.createTempFile("standby-restored-", ".state");
        try {
            String script =
                    "printf 'ready\\n"
                            + "'; while IFS= read -r op; do case $op in enable) printf 'sleeping\\n"
                            + "';; disable) printf 'off\\n"
                            + "';; reconcile|status) printf 'armed\\n"
                            + "';; esac; done; printf 'restored' > \"$1\"";
            Process process =
                    new ProcessBuilder("sh", "-c", script, "broker", restored.toString()).start();
            try (RootChannel root = new RootChannel(process)) {
                require(root.execute(RootChannel.Command.ENABLE) == RootChannel.Mode.SLEEPING);
                for (int index = 0; index < 20; index++)
                    require(root.execute(RootChannel.Command.RECONCILE) == RootChannel.Mode.ARMED);
                require(root.execute(RootChannel.Command.DISABLE) == RootChannel.Mode.OFF);
                try {
                    root.execute(RootChannel.Command.INVALID);
                    throw new AssertionError("Invalid command accepted");
                } catch (IllegalArgumentException expected) {
                    require(process.isAlive());
                }
            }
            require(
                    new String(Files.readAllBytes(restored), StandardCharsets.UTF_8)
                            .equals("restored"));
            try (RootChannel root =
                    new RootChannel(
                            new ProcessBuilder(
                                            "sh",
                                            "-c",
                                            "printf 'ready\\n'; read -r op; printf 'unknown\\n'")
                                    .start())) {
                try {
                    root.execute(RootChannel.Command.STATUS);
                    throw new AssertionError("Unknown response accepted");
                } catch (IOException expected) {
                    require(expected.getMessage().contains("response"));
                }
            }
            try (RootChannel root =
                    new RootChannel(
                            new ProcessBuilder("sh", "-c", "printf 'ready\\n'; read -r op")
                                    .start())) {
                try {
                    root.execute(RootChannel.Command.STATUS);
                    throw new AssertionError("Disconnect accepted");
                } catch (IOException expected) {
                    require(expected.getMessage().contains("disconnected"));
                }
            }
            CountDownLatch disconnected = new CountDownLatch(1);
            Process idle = new ProcessBuilder("sh", "-c", "printf 'ready\\n'; read -r op").start();
            RootChannel idleChannel =
                    new RootChannel(idle, disconnected::countDown, Long.MAX_VALUE);
            idle.destroy();
            require(disconnected.await(2, TimeUnit.SECONDS));
            try {
                idleChannel.close();
            } catch (IOException expected) {
                require(!idle.isAlive());
            }
            CountDownLatch intentional = new CountDownLatch(1);
            try (RootChannel ignored =
                    new RootChannel(
                            new ProcessBuilder(
                                            "sh",
                                            "-c",
                                            "printf 'ready\\n'; while read -r op; do :; done")
                                    .start(),
                            intentional::countDown,
                            Long.MAX_VALUE)) {
                require(ignored != null);
            }
            require(!intentional.await(100, TimeUnit.MILLISECONDS));
            Process stalled = new ProcessBuilder("sh", "-c", "exec sleep 2").start();
            try {
                new RootChannel(
                        stalled, () -> {}, System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(50));
                throw new AssertionError("Handshake deadline ignored");
            } catch (IOException expected) {
                require(stalled.waitFor(2, TimeUnit.SECONDS));
            }
            System.out.println(
                    "Root channel protocol, ordering, EOF recovery, deadlines, and failure tests"
                            + " passed");
        } finally {
            Files.deleteIfExists(restored);
        }
    }

    private static void require(boolean value) {
        if (!value) throw new AssertionError("Root channel test failed");
    }
}

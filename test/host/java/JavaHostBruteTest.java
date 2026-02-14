import io.github.ivere27.synurang.PluginHost;
import io.github.ivere27.synurang.PluginStream;
import io.github.ivere27.synurang.ProcessHost;
import io.github.ivere27.synurang.SynurangChannel;

import io.grpc.CallOptions;
import io.grpc.Channel;
import io.grpc.ClientCall;
import io.grpc.ManagedChannel;
import io.grpc.ManagedChannelBuilder;
import io.grpc.Metadata;
import io.grpc.MethodDescriptor;
import io.grpc.Status;
import io.grpc.StatusRuntimeException;
import io.grpc.stub.ClientCalls;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.time.Duration;
import java.util.ArrayList;
import java.util.Iterator;
import java.util.List;
import java.util.Locale;
import java.util.Random;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicLong;

public class JavaHostBruteTest {
    private static final MethodDescriptor.Marshaller<byte[]> BYTE_MARSHALLER =
            new MethodDescriptor.Marshaller<byte[]>() {
                @Override
                public InputStream stream(byte[] value) {
                    return new ByteArrayInputStream(value);
                }

                @Override
                public byte[] parse(InputStream is) {
                    try {
                        ByteArrayOutputStream baos = new ByteArrayOutputStream();
                        byte[] buf = new byte[4096];
                        int n;
                        while ((n = is.read(buf)) != -1) {
                            baos.write(buf, 0, n);
                        }
                        return baos.toByteArray();
                    } catch (Exception e) {
                        throw new RuntimeException(e);
                    }
                }
            };

    private static final MethodDescriptor<byte[], byte[]> MD_UNARY = methodDesc(
            MethodDescriptor.MethodType.UNARY,
            "example.v1.GoGreeterService/Bar");
    private static final MethodDescriptor<byte[], byte[]> MD_SERVER = methodDesc(
            MethodDescriptor.MethodType.SERVER_STREAMING,
            "example.v1.GoGreeterService/BarServerStream");
    private static final MethodDescriptor<byte[], byte[]> MD_CLIENT = methodDesc(
            MethodDescriptor.MethodType.CLIENT_STREAMING,
            "example.v1.GoGreeterService/BarClientStream");
    private static final MethodDescriptor<byte[], byte[]> MD_BIDI = methodDesc(
            MethodDescriptor.MethodType.BIDI_STREAMING,
            "example.v1.GoGreeterService/BarBidiStream");

    private static MethodDescriptor<byte[], byte[]> methodDesc(
            MethodDescriptor.MethodType type, String fullName) {
        return MethodDescriptor.<byte[], byte[]>newBuilder()
                .setType(type)
                .setFullMethodName(fullName)
                .setRequestMarshaller(BYTE_MARSHALLER)
                .setResponseMarshaller(BYTE_MARSHALLER)
                .build();
    }

    private static final class BruteResult {
        long ops;
        long expected;
        long unexpected;
    }

    private static final class ResourceSnapshot {
        int fdCount;
        long rssBytes;
        boolean hasFd;
        boolean hasRss;
    }

    private static final class PluginSpec {
        final String name;
        final String path;

        PluginSpec(String name, String path) {
            this.name = name;
            this.path = path;
        }
    }

    public static void main(String[] args) throws Exception {
        if (!"1".equals(System.getenv("SYNURANG_BRUTE"))) {
            System.out.println("SKIP: set SYNURANG_BRUTE=1 to run Java brute-force test");
            return;
        }

        Duration totalDuration = envDuration("SYNURANG_BRUTE_DURATION", Duration.ofMinutes(1));
        Duration processPhase = envDuration("SYNURANG_BRUTE_PHASE", Duration.ofSeconds(20));
        int workers = Math.max(1, envInt("SYNURANG_BRUTE_WORKERS", 4));
        int maxFdDelta = envInt("SYNURANG_BRUTE_MAX_FD_DELTA", 48);
        int maxRssMbDelta = envInt("SYNURANG_BRUTE_MAX_RSS_MB_DELTA", 256);
        String mode = envMode();
        boolean runPlugin = "all".equals(mode) || "ffi".equals(mode);
        boolean runProcess = "all".equals(mode) || "process".equals(mode);
        if (!runPlugin && !runProcess) {
            throw new RuntimeException("invalid SYNURANG_BRUTE_MODE=" + mode + " (expected all|ffi|process)");
        }

        System.out.println("═══════════════════════════════════════════════════════════════");
        System.out.println("  Java Host Brute-Force Chaos Test");
        System.out.println("  duration=" + totalDuration + " workers=" + workers
                + " max_fd_delta=" + maxFdDelta
                + " max_rss_mb_delta=" + maxRssMbDelta
                + " mode=" + mode);
        System.out.println("═══════════════════════════════════════════════════════════════");

        ResourceSnapshot baseline = captureResources();

        BruteResult pluginRes = new BruteResult();
        BruteResult processRes = new BruteResult();
        if (runPlugin) {
            pluginRes = runPluginBrute(totalDuration, workers);
        }
        if (runProcess) {
            processRes = runProcessBrute(totalDuration, processPhase, workers);
        }

        // Allow daemon threads to terminate and JVM to settle before measuring RSS.
        // Go runtime native memory is only partially reclaimable on dlclose, so
        // we do our best to shrink the JVM heap contribution.
        System.gc();
        Thread.sleep(2000);
        System.gc();
        Thread.sleep(1000);

        ResourceSnapshot finalRes = captureResources();
        assertNoResourceLeak(baseline, finalRes, maxFdDelta, maxRssMbDelta);

        long totalOps = pluginRes.ops + processRes.ops;
        long totalExpected = pluginRes.expected + processRes.expected;
        long totalUnexpected = pluginRes.unexpected + processRes.unexpected;

        System.out.println();
        System.out.println("═══════════════════════════════════════════════════════════════");
        System.out.println("  Aggregate Results:");
        System.out.println("    ops:               " + totalOps);
        System.out.println("    expected_errors:   " + totalExpected);
        System.out.println("    unexpected_errors: " + totalUnexpected);
        if (baseline.hasFd && finalRes.hasFd) {
            System.out.println("    fd_delta:          " + (finalRes.fdCount - baseline.fdCount));
        }
        if (baseline.hasRss && finalRes.hasRss) {
            System.out.println("    rss_delta_mb:      " + ((finalRes.rssBytes - baseline.rssBytes) / (1024 * 1024)));
        }
        System.out.println("═══════════════════════════════════════════════════════════════");

        if (totalUnexpected > 0) {
            throw new RuntimeException("unexpected errors observed: " + totalUnexpected);
        }
        if (totalOps == 0) {
            throw new RuntimeException("zero successful operations");
        }
        System.out.println("PASS");
    }

    private static BruteResult runPluginBrute(Duration duration, int workers) throws Exception {
        List<PluginSpec> specs = new ArrayList<>();
        specs.add(new PluginSpec("Go", resolvePath("bin/libplugin_go.so")));
        specs.add(new PluginSpec("C++", resolvePath("bin/libplugin_cpp.so")));
        specs.add(new PluginSpec("Rust", resolvePath("bin/libplugin_rust.so")));

        for (PluginSpec spec : specs) {
            if (!new File(spec.path).exists()) {
                throw new RuntimeException("plugin not found: " + spec.path + " (run `make build_plugin_all`)");
            }
        }

        Duration perPlugin = Duration.ofMillis(Math.max(1, duration.toMillis() / specs.size()));
        BruteResult out = new BruteResult();

        int idx = 0;
        for (PluginSpec spec : specs) {
            idx++;
            System.out.println();
            System.out.println("▶ Plugin phase: " + spec.name + " (" + spec.path + ")");
            try (PluginHost plugin = PluginHost.load(spec.path)) {
                Channel ch = SynurangChannel.create(plugin, "GoGreeterService");
                BruteResult phase = runChannelPhase(ch, perPlugin, workers, idx * 101L, "plugin:" + spec.name);
                out.ops += phase.ops;
                out.expected += phase.expected;
                out.unexpected += phase.unexpected;
                if (phase.unexpected > 0) {
                    throw new RuntimeException("plugin phase " + spec.name + " had " + phase.unexpected + " unexpected errors");
                }
            }
        }
        return out;
    }

    private static BruteResult runProcessBrute(Duration totalDuration, Duration phaseDuration, int workers) throws Exception {
        String child = resolvePath(exeName("bin/process_child_tcp"));
        if (!new File(child).exists()) {
            throw new RuntimeException("process child not found: " + child + " (run `make build_process_tcp_child`)");
        }

        BruteResult out = new BruteResult();
        long start = System.nanoTime();
        long deadline = start + totalDuration.toNanos();
        int round = 0;

        while (System.nanoTime() < deadline) {
            round++;
            long remainingNanos = deadline - System.nanoTime();
            if (remainingNanos <= TimeUnit.SECONDS.toNanos(1)) {
                break;
            }
            Duration phase = phaseDuration;
            if (remainingNanos < phaseDuration.toNanos()) {
                phase = Duration.ofNanos(remainingNanos);
            }

            System.out.println();
            System.out.println("▶ Process phase round " + round + ": " + child);
            ProcessHost proc = null;
            ManagedChannel managed = null;
            try {
                proc = ProcessHost.start(child);
                Channel ch;
                if (proc.isSocketpairMode()) {
                    ch = (Channel) proc.channel();
                } else {
                    managed = ManagedChannelBuilder.forTarget(proc.target())
                            .usePlaintext()
                            .build();
                    ch = managed;
                }
                BruteResult phaseRes = runChannelPhase(ch, phase, workers, round * 917L, "process");
                out.ops += phaseRes.ops;
                out.expected += phaseRes.expected;
                out.unexpected += phaseRes.unexpected;
                if (phaseRes.unexpected > 0) {
                    throw new RuntimeException("process round " + round + " had " + phaseRes.unexpected + " unexpected errors");
                }
            } finally {
                if (managed != null) {
                    managed.shutdownNow();
                    managed.awaitTermination(3, TimeUnit.SECONDS);
                }
                if (proc != null) {
                    proc.close();
                }
            }
        }
        return out;
    }

    private static BruteResult runChannelPhase(
            Channel channel,
            Duration duration,
            int workers,
            long seedBase,
            String label) throws Exception {
        AtomicLong ops = new AtomicLong();
        AtomicLong expected = new AtomicLong();
        AtomicLong unexpected = new AtomicLong();
        AtomicBoolean stop = new AtomicBoolean(false);
        long deadline = System.nanoTime() + duration.toNanos();

        ExecutorService pool = Executors.newFixedThreadPool(workers);
        for (int w = 0; w < workers; w++) {
            final int workerId = w;
            pool.submit(() -> {
                Random rnd = new Random(System.nanoTime() ^ (workerId * 100103L) ^ (seedBase * 9973L));
                while (!stop.get() && System.nanoTime() < deadline) {
                    try {
                        runRandomOp(channel, rnd, workerId);
                        ops.incrementAndGet();
                    } catch (Throwable t) {
                        if (isExpectedError(t)) {
                            expected.incrementAndGet();
                        } else {
                            long prev = unexpected.incrementAndGet();
                            if (prev <= 5) {
                                System.err.println("  UNEXPECTED [" + label + " worker " + workerId + "]: " + t);
                            }
                            stop.set(true);
                            return;
                        }
                    }
                    try {
                        Thread.sleep(1L + rnd.nextInt(5));
                    } catch (InterruptedException e) {
                        Thread.currentThread().interrupt();
                        return;
                    }
                }
            });
        }

        pool.shutdown();
        pool.awaitTermination(duration.toMillis() + 10_000, TimeUnit.MILLISECONDS);

        BruteResult result = new BruteResult();
        result.ops = ops.get();
        result.expected = expected.get();
        result.unexpected = unexpected.get();
        System.out.println("  [" + label + "] ops=" + result.ops
                + " expected_errs=" + result.expected
                + " unexpected_errs=" + result.unexpected);
        return result;
    }

    private static void runRandomOp(Channel channel, Random rnd, int workerId) throws Exception {
        int x = rnd.nextInt(100);
        if (x < 40) {
            opUnary(channel, rnd, workerId);
        } else if (x < 62) {
            opServerStream(channel, rnd, workerId);
        } else if (x < 78) {
            opClientStream(channel, rnd, workerId);
        } else if (x < 88) {
            opBidi(channel, rnd, workerId);
        } else {
            runChaos(channel, rnd, workerId);
        }
    }

    private static CallOptions withTimeout(Random rnd) {
        int n = rnd.nextInt(100);
        long ms;
        if (n < 15) {
            ms = 2 + rnd.nextInt(4);
        } else if (n < 65) {
            ms = 20 + rnd.nextInt(80);
        } else {
            ms = 100 + rnd.nextInt(350);
        }
        return CallOptions.DEFAULT.withDeadlineAfter(ms, TimeUnit.MILLISECONDS);
    }

    private static void opUnary(Channel channel, Random rnd, int workerId) {
        String marker = "u-" + workerId + "-" + rnd.nextInt(Integer.MAX_VALUE);
        byte[] req = makeHelloRequest(marker);
        byte[] resp = ClientCalls.blockingUnaryCall(channel, MD_UNARY, withTimeout(rnd), req);
        String msg = extractMessage(resp);
        if (msg.isEmpty() || msg.startsWith("<") || !msg.contains(marker)) {
            throw new RuntimeException("unary mismatch");
        }
    }

    private static void opServerStream(Channel channel, Random rnd, int workerId) {
        String marker = "ss-" + workerId + "-" + rnd.nextInt(Integer.MAX_VALUE);
        Iterator<byte[]> iter = ClientCalls.blockingServerStreamingCall(
                channel, MD_SERVER, withTimeout(rnd), makeHelloRequest(marker));
        int received = 0;
        while (iter.hasNext()) {
            String msg = extractMessage(iter.next());
            if (msg.isEmpty() || msg.startsWith("<")) {
                throw new RuntimeException("server-stream parse failure");
            }
            received++;
        }
        if (received == 0) {
            throw new RuntimeException("server-stream returned zero messages");
        }
    }

    private static void opClientStream(Channel channel, Random rnd, int workerId) throws Exception {
        final byte[][] result = new byte[1][];
        final Status[] status = new Status[1];
        final CountDownLatch latch = new CountDownLatch(1);

        ClientCall<byte[], byte[]> call = channel.newCall(MD_CLIENT, withTimeout(rnd));
        call.start(new ClientCall.Listener<byte[]>() {
            @Override
            public void onMessage(byte[] message) {
                result[0] = message;
            }

            @Override
            public void onClose(Status st, Metadata trailers) {
                status[0] = st;
                latch.countDown();
            }
        }, new Metadata());
        call.request(2);

        int count = 1 + rnd.nextInt(20);
        for (int i = 0; i < count; i++) {
            call.sendMessage(makeHelloRequest("cs-" + workerId + "-" + i + "-" + rnd.nextInt(Integer.MAX_VALUE)));
        }
        call.halfClose();

        if (!latch.await(10, TimeUnit.SECONDS)) {
            throw new RuntimeException("client-stream timeout");
        }
        if (!status[0].isOk()) {
            throw status[0].asRuntimeException();
        }
        String msg = extractMessage(result[0]);
        if (msg.isEmpty() || msg.startsWith("<")) {
            throw new RuntimeException("client-stream parse failure");
        }
    }

    private static void opBidi(Channel channel, Random rnd, int workerId) throws Exception {
        final List<byte[]> received = new ArrayList<>();
        final Status[] status = new Status[1];
        final CountDownLatch latch = new CountDownLatch(1);

        ClientCall<byte[], byte[]> call = channel.newCall(MD_BIDI, withTimeout(rnd));
        call.start(new ClientCall.Listener<byte[]>() {
            @Override
            public void onMessage(byte[] message) {
                received.add(message);
                call.request(1);
            }

            @Override
            public void onClose(Status st, Metadata trailers) {
                status[0] = st;
                latch.countDown();
            }
        }, new Metadata());
        call.request(1);

        int count = 1 + rnd.nextInt(12);
        for (int i = 0; i < count; i++) {
            call.sendMessage(makeHelloRequest("bs-" + workerId + "-" + i + "-" + rnd.nextInt(Integer.MAX_VALUE)));
        }
        call.halfClose();

        if (!latch.await(10, TimeUnit.SECONDS)) {
            throw new RuntimeException("bidi timeout");
        }
        if (!status[0].isOk()) {
            throw status[0].asRuntimeException();
        }
        if (received.isEmpty()) {
            throw new RuntimeException("bidi returned zero responses");
        }
    }

    private static void runChaos(Channel channel, Random rnd, int workerId) throws Exception {
        int x = rnd.nextInt(100);
        if (x < 25) {
            try {
                ClientCalls.blockingUnaryCall(
                        channel,
                        MD_UNARY,
                        CallOptions.DEFAULT.withDeadlineAfter(1, TimeUnit.MILLISECONDS),
                        makeHelloRequest("chaos-immediate-cancel"));
            } catch (Exception ignored) {
                // expected sometimes
            }
            return;
        }
        if (x < 50) {
            try {
                opClientStream(channel, rnd, workerId);
            } catch (Exception ignored) {
                // expected sometimes
            }
            return;
        }
        if (x < 75) {
            int size = 64 * 1024 + rnd.nextInt(192 * 1024);
            byte[] req = makeHelloRequestWithLanguage("boundary", repeat('B', size));
            ClientCalls.blockingUnaryCall(
                    channel,
                    MD_UNARY,
                    CallOptions.DEFAULT.withDeadlineAfter(1500, TimeUnit.MILLISECONDS),
                    req);
            return;
        }
        if (x < 90) {
            opServerStream(channel, rnd, workerId);
            return;
        }
        opUnary(channel, rnd, workerId);
    }

    private static boolean isExpectedError(Throwable t) {
        if (t == null) return false;
        if (t instanceof StatusRuntimeException) {
            Status.Code code = ((StatusRuntimeException) t).getStatus().getCode();
            if (code == Status.Code.CANCELLED
                    || code == Status.Code.DEADLINE_EXCEEDED
                    || code == Status.Code.UNAVAILABLE
                    || code == Status.Code.ABORTED) {
                return true;
            }
        }
        String msg = t.toString().toLowerCase(Locale.ROOT);
        return msg.contains("deadline")
                || msg.contains("cancel")
                || msg.contains("transport is closing")
                || msg.contains("connection closing")
                || msg.contains("broken pipe")
                || msg.contains("socket closed")
                || msg.contains("eof");
    }

    private static byte[] makeHelloRequest(String name) {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        byte[] bytes = name.getBytes(StandardCharsets.UTF_8);
        out.write(0x0a);
        writeVarint(bytes.length, out);
        out.write(bytes, 0, bytes.length);
        return out.toByteArray();
    }

    private static byte[] makeHelloRequestWithLanguage(String name, String language) {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        byte[] nameBytes = name.getBytes(StandardCharsets.UTF_8);
        if (nameBytes.length > 0) {
            out.write(0x0a);
            writeVarint(nameBytes.length, out);
            out.write(nameBytes, 0, nameBytes.length);
        }
        byte[] langBytes = language.getBytes(StandardCharsets.UTF_8);
        if (langBytes.length > 0) {
            out.write(0x12);
            writeVarint(langBytes.length, out);
            out.write(langBytes, 0, langBytes.length);
        }
        return out.toByteArray();
    }

    private static String extractMessage(byte[] data) {
        if (data == null || data.length < 2 || data[0] != 0x0a) {
            return "<parse error>";
        }
        int idx = 1;
        long len = 0;
        int shift = 0;
        while (idx < data.length) {
            int b = data[idx++] & 0xff;
            len |= (long) (b & 0x7f) << shift;
            if ((b & 0x80) == 0) break;
            shift += 7;
            if (shift > 35) return "<varint overflow>";
        }
        if (idx + len > data.length || len < 0) {
            return "<truncated>";
        }
        return new String(data, idx, (int) len, StandardCharsets.UTF_8);
    }

    private static void writeVarint(int value, ByteArrayOutputStream out) {
        int n = value;
        while (n >= 0x80) {
            out.write((n & 0x7f) | 0x80);
            n >>>= 7;
        }
        out.write(n & 0x7f);
    }

    private static String repeat(char c, int count) {
        StringBuilder sb = new StringBuilder(count);
        for (int i = 0; i < count; i++) sb.append(c);
        return sb.toString();
    }

    private static Duration envDuration(String key, Duration fallback) {
        String raw = System.getenv(key);
        if (raw == null || raw.trim().isEmpty()) return fallback;
        String s = raw.trim().toLowerCase(Locale.ROOT);
        try {
            if (s.endsWith("ms")) return Duration.ofMillis(Long.parseLong(s.substring(0, s.length() - 2)));
            if (s.endsWith("s")) return Duration.ofSeconds(Long.parseLong(s.substring(0, s.length() - 1)));
            if (s.endsWith("m")) return Duration.ofMinutes(Long.parseLong(s.substring(0, s.length() - 1)));
            return Duration.ofSeconds(Long.parseLong(s));
        } catch (Exception e) {
            throw new RuntimeException("invalid duration " + key + "=" + raw, e);
        }
    }

    private static int envInt(String key, int fallback) {
        String raw = System.getenv(key);
        if (raw == null || raw.trim().isEmpty()) return fallback;
        try {
            return Integer.parseInt(raw.trim());
        } catch (Exception e) {
            return fallback;
        }
    }

    private static String envMode() {
        String raw = System.getenv("SYNURANG_BRUTE_MODE");
        if (raw == null || raw.trim().isEmpty()) return "all";
        String mode = raw.trim().toLowerCase(Locale.ROOT);
        if ("plugin".equals(mode)) return "ffi";
        if ("tcp".equals(mode)) return "process";
        return mode;
    }

    private static String exeName(String base) {
        boolean windows = System.getProperty("os.name", "").toLowerCase(Locale.ROOT).contains("win");
        return windows ? base + ".exe" : base;
    }

    private static String resolvePath(String rel) {
        File f = new File(rel);
        if (f.isAbsolute()) return f.getPath();
        File dir = new File(System.getProperty("user.dir"));
        while (true) {
            File candidate = new File(dir, rel);
            if (candidate.exists()) return candidate.getPath();
            if (new File(dir, "go.mod").exists()) return candidate.getPath();
            File parent = dir.getParentFile();
            if (parent == null || parent.equals(dir)) break;
            dir = parent;
        }
        return new File(System.getProperty("user.dir"), rel).getPath();
    }

    private static ResourceSnapshot captureResources() {
        ResourceSnapshot s = new ResourceSnapshot();
        s.fdCount = -1;
        s.rssBytes = -1;
        s.hasFd = false;
        s.hasRss = false;

        try {
            if (Files.isDirectory(Paths.get("/proc/self/fd"))) {
                s.fdCount = (int) Files.list(Paths.get("/proc/self/fd")).count();
                s.hasFd = true;
            }
        } catch (Exception ignored) {
        }

        try {
            if (Files.exists(Paths.get("/proc/self/statm"))) {
                String statm = new String(Files.readAllBytes(Paths.get("/proc/self/statm")), StandardCharsets.UTF_8).trim();
                String[] fields = statm.split("\\s+");
                if (fields.length >= 2) {
                    long pages = Long.parseLong(fields[1]);
                    long pageSize = 4096L;
                    s.rssBytes = pages * pageSize;
                    s.hasRss = true;
                }
            }
        } catch (Exception ignored) {
        }
        return s;
    }

    private static void assertNoResourceLeak(
            ResourceSnapshot baseline,
            ResourceSnapshot finalRes,
            int maxFdDelta,
            int maxRssMbDelta) {
        if (baseline.hasFd && finalRes.hasFd) {
            int delta = finalRes.fdCount - baseline.fdCount;
            if (delta > maxFdDelta) {
                throw new RuntimeException(
                        "fd leak suspected: baseline=" + baseline.fdCount
                                + " final=" + finalRes.fdCount
                                + " delta=" + delta
                                + " allowed=" + maxFdDelta);
            }
        }
        if (baseline.hasRss && finalRes.hasRss) {
            long deltaMb = (finalRes.rssBytes - baseline.rssBytes) / (1024 * 1024);
            if (deltaMb > maxRssMbDelta) {
                throw new RuntimeException(
                        "rss leak suspected: baseline_mb=" + (baseline.rssBytes / (1024 * 1024))
                                + " final_mb=" + (finalRes.rssBytes / (1024 * 1024))
                                + " delta_mb=" + deltaMb
                                + " allowed_mb=" + maxRssMbDelta);
            }
        }
    }
}

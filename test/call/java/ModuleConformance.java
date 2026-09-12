import io.github.ivere27.synurang.FfiError;
import io.github.ivere27.synurang.ModuleCall;
import io.github.ivere27.synurang.ModuleHost;
import java.io.ByteArrayOutputStream;
import java.time.Duration;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.TimeUnit;

public final class ModuleConformance {
    static String path(String method) { return "/synurang.test.Calls/" + method; }
    static byte[] value(long number) {
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        if (number == 0) return bytes.toByteArray();
        bytes.write(8);
        while ((number & ~127L) != 0) { bytes.write(((int)number & 127) | 128); number >>>= 7; }
        bytes.write((int)number);
        return bytes.toByteArray();
    }
    static <T> T await(CompletableFuture<T> future) throws Exception { return future.get(5, TimeUnit.SECONDS); }
    static void same(byte[] actual, byte[] expected) {
        if (!Arrays.equals(actual, expected)) throw new AssertionError(Arrays.toString(actual) + " != " + Arrays.toString(expected));
    }
    static FfiError error(int code, CompletableFuture<?> future) throws Exception {
        try { await(future); throw new AssertionError("Expected status " + code); }
        catch (ExecutionException error) {
            Throwable cause = error.getCause();
            while (cause instanceof java.util.concurrent.CompletionException && cause.getCause() != null) cause = cause.getCause();
            if (!(cause instanceof FfiError) || ((FfiError)cause).getGrpcCode() != code) throw error;
            return (FfiError)cause;
        }
    }
    static void run(String module) throws Exception {
        try (ModuleHost host = ModuleHost.load(module); ModuleHost other = ModuleHost.load(module)) {
            same(await(host.unary(path("Unary"), value(0))), value(0));
            same(await(other.unary(path("Unary"), value(42))), value(42));
            List<CompletableFuture<byte[]>> concurrent = new ArrayList<>();
            for (int i = 0; i < 50; ++i) concurrent.add(host.unary(path("Unary"), value(i)));
            for (int i = 0; i < concurrent.size(); ++i) same(await(concurrent.get(i)), value(i));
            try (ModuleCall call = host.open(path("Server"), false, true)) {
                await(call.send(value(1000))); await(call.halfClose());
                for (int i = 0; i < 1000; ++i) same(await(call.receive()), value(i));
                if (await(call.receive()) != null) throw new AssertionError("Expected EOF");
            }
            try (ModuleCall call = host.open(path("Client"), true, false)) {
                for (int i = 0; i < 1000; ++i) await(call.send(value(1)));
                await(call.halfClose()); same(await(call.result()), value(1000));
            }
            try (ModuleCall call = host.open(path("Bidi"), true, true)) {
                for (int i = 0; i < 40; ++i) { await(call.send(value(i))); same(await(call.receive()), value(i)); }
                await(call.halfClose());
                if (await(call.receive()) != null) throw new AssertionError("Expected EOF");
            }
            FfiError failure = error(7, host.unary(path("Fail"), value(0)));
            if (failure.getCode() != 42 || failure.getPayload() == null) throw new AssertionError("Lost error detail");
            error(7, host.unary(path("Unary"), value(-1)));
            error(12, host.unary(path("Missing"), value(0)));
            error(4, host.unary(path("Wait"), value(0), Duration.ofMillis(20)));
            ModuleCall waiting = host.open(path("Wait"), false, false);
            await(waiting.send(value(0))); await(waiting.halfClose());
            CompletableFuture<byte[]> response = waiting.receive();
            waiting.cancel(); error(1, response);
            CompletableFuture<byte[]> cancelled = host.unary(path("Wait"), value(0));
            cancelled.cancel(false);
            if (!cancelled.isCancelled()) throw new AssertionError("Future not cancelled");
        }
        ModuleHost host = ModuleHost.load(module);
        CompletableFuture<byte[]> waiting = host.unary(path("Wait"), value(0));
        await(host.closeAsync()); error(1, waiting);
        System.out.println("Java module conformance: " + module);
    }
    static void releasedCalls(String module) throws Exception {
        Path marker = Files.createTempFile("synurang-release-", ".txt");
        try (ModuleHost host = ModuleHost.load(module)) {
            List<ModuleCall> calls = new ArrayList<>();
            for (int i = 0; i < 96; ++i) {
                ModuleCall call = host.open("/test.Release/Watch", false, true);
                calls.add(call);
                await(call.send(marker.toString().getBytes(StandardCharsets.UTF_8)));
                same(await(call.receive()), new byte[0]);
            }
            for (ModuleCall call : calls) call.close();
            long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(2);
            while (true) {
                byte[] data = Files.readAllBytes(marker);
                int cancelled = 0, destroyed = 0;
                for (byte event : data) { if (event == 'C') ++cancelled; if (event == 'D') ++destroyed; }
                if (cancelled == calls.size() && destroyed == calls.size()) break;
                if (System.nanoTime() > deadline) throw new AssertionError("Release cleanup stopped before host close");
                Thread.sleep(1);
            }
        } finally { Files.deleteIfExists(marker); }
        System.out.println("Java release drains without another call or host close");
    }
    public static void main(String[] args) throws Exception {
        String releaseModule = System.getenv("SYNURANG_TEST_RELEASE_MODULE");
        if (releaseModule != null) releasedCalls(releaseModule);
        for (String module : args) run(module);
    }
}

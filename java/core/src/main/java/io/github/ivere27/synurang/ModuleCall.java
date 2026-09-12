package io.github.ivere27.synurang;

import java.time.Duration;
import java.util.ArrayDeque;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ScheduledFuture;
import java.util.concurrent.TimeUnit;

/**
 * Asynchronous call supporting all RPC cardinalities. Await send before sending
 * again when applying backpressure. At most 16 pending sends and one receive
 * are accepted; responses remain in the module until receive is requested.
 */
public final class ModuleCall implements AutoCloseable {
    final ModuleHost host;
    long handle;
    private final boolean timed;
    private final long started = System.nanoTime();
    private final long timeoutNanos;
    private final ArrayDeque<Write> writes = new ArrayDeque<>();
    private CompletableFuture<byte[]> receiver;
    private CompletableFuture<Void> halfClose;
    private final CompletableFuture<Void> status = new CompletableFuture<>();
    private boolean halfClosed, finished;
    private boolean requestClosed;
    private byte[] buffered;
    private Throwable terminalError;
    private ScheduledFuture<?> deadlineTask;

    ModuleCall(ModuleHost host, Duration timeout) {
        this.host = host;
        timed = timeout != null;
        long nanos;
        try { nanos = timed ? timeout.toNanos() : Long.MAX_VALUE; }
        catch (ArithmeticException overflow) { nanos = Long.MAX_VALUE; }
        timeoutNanos = nanos;
        status.whenComplete((value, error) -> { if (status.isCancelled()) cancel(); });
    }

    long remainingMillis() {
        if (!timed) return -1L;
        long remaining = timeoutNanos - (System.nanoTime() - started);
        return remaining <= 0 ? 0 : 1 + (remaining - 1) / 1000000;
    }
    void armDeadline() {
        if (timed) deadlineTask = host.loop.schedule(this::pump, remainingMillis(), TimeUnit.MILLISECONDS);
    }

    /** Completes on terminal RPC status; successful completion follows EOF. */
    public CompletableFuture<Void> status() { return status; }

    public CompletableFuture<Void> send(byte[] bytes) {
        byte[] copy = bytes.clone();
        CompletableFuture<Void> result = cancellable();
        host.execute(() -> {
            if (requestClosed) {
                host.complete(result, null, new RequestClosedException());
            } else if (finished || halfClose != null || halfClosed) {
                host.complete(result, null, terminalError != null ? terminalError : new FfiError("Request side is closed", 0, 9));
            } else if (writes.size() >= 16) {
                host.complete(result, null, new FfiError("Await send before queuing more requests", 0, 8));
            } else {
                writes.addLast(new Write(copy, result));
                pump();
            }
        }, result);
        return result;
    }

    public CompletableFuture<Void> halfClose() {
        CompletableFuture<Void> result = cancellable();
        host.execute(() -> {
            if (finished) host.complete(result, null, terminalError);
            else if (halfClosed || requestClosed) host.complete(result, null, null);
            else if (halfClose != null) halfClose.whenComplete((value, error) -> host.complete(result, null, error));
            else { halfClose = result; pump(); }
        }, result);
        return result;
    }

    /** Empty bytes represent a message. Null represents successful EOF. */
    public CompletableFuture<byte[]> receive() {
        CompletableFuture<byte[]> result = cancellable();
        host.execute(() -> {
            if (finished) host.complete(result, null, terminalError);
            else if (receiver != null) host.complete(result, null, new IllegalStateException("Only one receive may be pending"));
            else { receiver = result; pump(); }
        }, result);
        return result;
    }

    /** A unary response is published only after the terminal status succeeds. */
    public CompletableFuture<byte[]> result() {
        CompletableFuture<byte[]> result = receive().thenCompose(first -> {
            if (first == null) {
                CompletableFuture<byte[]> missing = new CompletableFuture<>();
                missing.completeExceptionally(new FfiError("Missing unary response", 0, 13));
                return missing;
            }
            return receive().thenApply(second -> {
                if (second != null) throw new java.util.concurrent.CompletionException(new FfiError("Multiple unary responses", 0, 13));
                return first;
            });
        });
        result.whenComplete((value, error) -> { if (error != null) close(); });
        return result;
    }

    public void cancel() { cancel(1); }

    public void cancel(int code) {
        if (code < 1 || code > 16) throw new IllegalArgumentException("Status must be 1..16");
        host.execute(() -> {
            if (!finished && handle != 0) ModuleJni.cancel(host.handle, handle, code);
            fail(new FfiError(code == 4 ? "Deadline exceeded" : "Call cancelled", 0, code));
        }, status);
    }

    private <T> CompletableFuture<T> cancellable() {
        CompletableFuture<T> future = new CompletableFuture<>();
        future.whenComplete((value, error) -> { if (future.isCancelled()) cancel(); });
        return future;
    }

    void pump() {
        if (finished || handle == 0) return;
        try {
            if (timed && remainingMillis() == 0) {
                ModuleJni.cancel(host.handle, handle, 4);
                fail(new FfiError("Deadline exceeded", 0, 4));
                return;
            }
            for (int budget = 0; budget < 16 && !writes.isEmpty(); ++budget) {
                Write write = writes.peekFirst();
                int result = ModuleJni.send(host.handle, handle, write.data);
                if (result == -4) break;
                if (result != 0) { readFailure("send", result); break; }
                writes.removeFirst();
                host.complete(write.result, null, null);
            }
            if (finished) return;
            if (halfClose != null && writes.isEmpty() && !halfClosed && !requestClosed) {
                int result = ModuleJni.halfClose(host.handle, handle);
                if (result != 0) { readFailure("half-close", result); return; }
                halfClosed = true;
                host.complete(halfClose, null, null);
            }
            if (receiver != null) {
                if (buffered != null) {
                    CompletableFuture<byte[]> pending = receiver;
                    byte[] message = buffered;
                    receiver = null;
                    buffered = null;
                    host.complete(pending, message, null);
                    return;
                }
                ModuleJni.Read read = ModuleJni.receive(host.handle, handle);
                if (read.status != 0) { fail(new FfiError("Receive failed: " + read.status, 0, 13)); return; }
                if (read.kind == 1) {
                    CompletableFuture<byte[]> pending = receiver;
                    receiver = null;
                    host.complete(pending, read.data, null);
                } else if (read.kind == 2) {
                    finish(read.code == 0 ? null : error(read));
                } else if (read.kind != 0) fail(new FfiError("Invalid module read kind", 0, 13));
            }
        } catch (Throwable error) { fail(error); }
    }

    private static FfiError error(ModuleJni.Read read) {
        FfiError parsed = FfiError.fromPayload(read.data);
        return new FfiError(parsed.getMessage(), parsed.getCode(), read.code, read.data, null);
    }

    private void readFailure(String operation, int code) {
        ModuleJni.Read read = ModuleJni.receive(host.handle, handle);
        if (read.status != 0) { fail(new FfiError("Receive failed: " + read.status, 0, 13)); return; }
        if (read.kind == 2 && read.code != 0) { fail(error(read)); return; }
        if (code == -3) {
            if (read.kind == 1) buffered = read.data;
            requestClosed = true;
            while (!writes.isEmpty()) host.complete(writes.removeFirst().result, null, new RequestClosedException());
            if (halfClose != null && !halfClosed) host.complete(halfClose, null, null);
            if (read.kind == 2) finish(null);
            return;
        }
        fail(new FfiError(operation + " failed: " + code, 0, 13));
    }

    void fail(Throwable error) { finish(error); }

    private void finish(Throwable error) {
        if (finished) return;
        finished = true;
        if (deadlineTask != null) deadlineTask.cancel(false);
        terminalError = error;
        buffered = null;
        if (handle != 0) {
            ModuleJni.release(host.handle, handle);
            handle = 0;
        }
        host.calls.remove(this);
        Throwable sendError = error != null ? error : new FfiError("Call finished before send", 0, 9);
        while (!writes.isEmpty()) host.complete(writes.removeFirst().result, null, sendError);
        if (halfClose != null && !halfClosed) host.complete(halfClose, null, error);
        if (receiver != null) { host.complete(receiver, null, error); receiver = null; }
        host.complete(status, null, error);
    }

    @Override public void close() { cancel(); }

    private static final class Write {
        final byte[] data;
        final CompletableFuture<Void> result;
        Write(byte[] data, CompletableFuture<Void> result) { this.data = data; this.result = result; }
    }
}

package io.github.ivere27.synurang;

import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.Set;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.Executor;
import java.util.concurrent.Executors;
import java.util.concurrent.ForkJoinPool;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * One native module instance, usable from Java and Kotlin. JNI entries never
 * wait. A single scheduler serializes entry and polls bounded work; application
 * continuations run on the supplied executor. Close after the final call.
 *
 * <p>The core uses CompletableFuture and has no gRPC or coroutine dependency.
 * Kotlin applications can await these futures using their coroutine adapter.
 */
public final class ModuleHost implements AutoCloseable {
    final ScheduledExecutorService loop;
    final Executor completions;
    final Set<ModuleCall> calls = new HashSet<>();
    long handle;
    volatile boolean closing;
    private final CompletableFuture<Void> closed = new CompletableFuture<>();
    private final AtomicBoolean scheduled = new AtomicBoolean();

    private ModuleHost(long handle, Executor completions) {
        this.handle = handle;
        this.completions = completions;
        loop = Executors.newSingleThreadScheduledExecutor(task -> {
            Thread thread = new Thread(task, "synurang-module");
            thread.setDaemon(true);
            return thread;
        });
        ModuleJni.setWakeup(handle, this);
    }

    public static ModuleHost load(String path) {
        return load(path, "Synurang_GetApi", ForkJoinPool.commonPool());
    }

    public static ModuleHost load(String path, String symbol, Executor completions) {
        if (completions == null) throw new NullPointerException("completions");
        long handle = ModuleJni.load(path.getBytes(StandardCharsets.UTF_8), symbol.getBytes(StandardCharsets.UTF_8));
        if (handle == 0) throw new IllegalStateException("Could not create module instance");
        return new ModuleHost(handle, completions);
    }

    public ModuleCall open(String method, boolean requestStream, boolean responseStream) {
        return open(method, requestStream, responseStream, null);
    }

    /** Timeout is relative to this invocation, including scheduler delay. */
    public ModuleCall open(String method, boolean requestStream, boolean responseStream, Duration timeout) {
        if (method == null || !method.startsWith("/") || method.indexOf('\0') >= 0)
            throw new IllegalArgumentException("Expected /package.Service/Method");
        if (timeout != null && timeout.isNegative()) throw new IllegalArgumentException("Negative timeout");
        ModuleCall call = new ModuleCall(this, timeout);
        execute(() -> {
            if (closing) { call.fail(new FfiError("Module is closed", 0, 1)); return; }
            calls.add(call);
            try {
                call.handle = ModuleJni.open(handle, method.getBytes(StandardCharsets.UTF_8),
                    requestStream, responseStream, call.remainingMillis());
                if (call.handle == 0) call.fail(new FfiError("Could not open call", 0, 13));
                else call.armDeadline();
            } catch (Throwable error) { call.fail(error); }
        }, call.status());
        return call;
    }

    public CompletableFuture<byte[]> unary(String method, byte[] request) {
        return unary(method, request, null);
    }

    public CompletableFuture<byte[]> unary(String method, byte[] request, Duration timeout) {
        ModuleCall call = open(method, false, false, timeout);
        CompletableFuture<byte[]> result = call.send(request).thenCompose(ignored -> call.halfClose())
            .thenCompose(ignored -> call.result());
        result.whenComplete((value, error) -> { if (error != null) call.close(); });
        return result;
    }

    <T> void complete(CompletableFuture<T> future, T value, Throwable error) {
        Runnable completion = () -> {
            if (error == null) future.complete(value); else future.completeExceptionally(error);
        };
        try { completions.execute(completion); }
        catch (RejectedExecutionException rejected) { ForkJoinPool.commonPool().execute(completion); }
    }

    void execute(Runnable work, CompletableFuture<?> failure) {
        try { loop.execute(() -> { try { work.run(); } finally { wakeup(); } }); }
        catch (RejectedExecutionException error) { complete(failure, null, new FfiError("Module is closed", 0, 1)); }
    }

    // Called by JNI on any producer thread. Only enqueue; never enter JNI here.
    private void wakeup() {
        if (!scheduled.compareAndSet(false, true)) return;
        try { loop.execute(() -> { scheduled.set(false); tick(); }); }
        catch (RejectedExecutionException closed) { scheduled.set(false); }
    }

    private void tick() {
        if (handle == 0) return;
        try {
            if (closing) for (ModuleCall call : new ArrayList<>(calls))
                call.fail(new FfiError("Module is closed", 0, 1));
            ModuleJni.poll(handle, 64);
            for (ModuleCall call : new ArrayList<>(calls)) call.pump();
            if (closing) {
                int status = ModuleJni.destroy(handle);
                if (status == 0) {
                    handle = 0;
                    loop.shutdown();
                    complete(closed, null, null);
                } else if (status != 3) {
                    complete(closed, null, new FfiError("Module destroy failed: " + status, 0, 13));
                }
            }
            if (handle != 0 && ModuleJni.hasWork(handle)) wakeup();
        } catch (Throwable error) {
            for (ModuleCall call : new ArrayList<>(calls)) call.fail(error);
            if (closing) complete(closed, null, error);
        }
    }

    /** Cancels active calls and waits asynchronously for producer cleanup. */
    public synchronized CompletableFuture<Void> closeAsync() {
        if (!closing) {
            closing = true;
            execute(() -> {
                for (ModuleCall call : new ArrayList<>(calls))
                    call.fail(new FfiError("Module is closed", 0, 1));
            }, closed);
        }
        return closed;
    }

    /** Blocking convenience for try-with-resources. */
    @Override public void close() { closeAsync().join(); }
}

package io.github.ivere27.synurang;

import io.grpc.CallOptions;
import io.grpc.ClientCall;
import io.grpc.Metadata;
import io.grpc.MethodDescriptor;
import io.grpc.Status;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.time.Duration;
import java.util.ArrayDeque;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.CompletionException;
import java.util.concurrent.Executor;
import java.util.concurrent.ForkJoinPool;
import java.util.concurrent.TimeUnit;

/** One buffered response allows observing EOF without consuming a demand permit. */
final class ModuleClientCall<Request, Response> extends ClientCall<Request, Response> {
    private final ModuleHost host;
    private final MethodDescriptor<Request, Response> method;
    private final CallOptions options;
    private final SerialExecutor callbacks;
    private Listener<Response> listener;
    private ModuleCall call;
    private CompletableFuture<Void> writes = CompletableFuture.completedFuture(null);
    private long demand;
    private int pendingWrites;
    private boolean started, closed, halfClosed, reading;
    private byte[] buffered;
    private Status earlyCancellation;

    ModuleClientCall(ModuleHost host, MethodDescriptor<Request, Response> method, CallOptions options) {
        this.host = host; this.method = method; this.options = options;
        callbacks = new SerialExecutor(options.getExecutor() != null ? options.getExecutor() : ForkJoinPool.commonPool());
    }

    @Override public synchronized void start(Listener<Response> listener, Metadata headers) {
        if (started) throw new IllegalStateException("Call already started");
        started = true;
        this.listener = listener;
        if (earlyCancellation != null) { finish(earlyCancellation, null); return; }
        if (options.getCredentials() != null) {
            finish(Status.UNIMPLEMENTED.withDescription("Module calls do not use network credentials"), null);
            return;
        }
        if (!headers.keys().isEmpty()) {
            finish(Status.UNIMPLEMENTED.withDescription("Module ABI does not carry request metadata"), null);
            return;
        }
        MethodDescriptor.MethodType kind = method.getType();
        boolean requestStream = kind == MethodDescriptor.MethodType.CLIENT_STREAMING || kind == MethodDescriptor.MethodType.BIDI_STREAMING;
        boolean responseStream = kind == MethodDescriptor.MethodType.SERVER_STREAMING || kind == MethodDescriptor.MethodType.BIDI_STREAMING;
        Duration timeout = options.getDeadline() == null ? null
            : Duration.ofNanos(Math.max(0, options.getDeadline().timeRemaining(TimeUnit.NANOSECONDS)));
        try {
            call = host.open("/" + method.getFullMethodName(), requestStream, responseStream, timeout);
            call.status().whenComplete((ignored, error) -> { if (error != null) fail(error); });
            callbacks.execute(() -> listener.onHeaders(new Metadata()));
            callbacks.execute(() -> { if (isReady()) listener.onReady(); });
            read();
        } catch (Throwable error) { fail(error); }
    }

    @Override public synchronized void request(int count) {
        if (count <= 0) throw new IllegalArgumentException("Positive request count required");
        demand = Math.min(Long.MAX_VALUE - count, demand) + count;
        deliverBuffered();
    }

    @Override public synchronized void sendMessage(Request message) {
        if (!started) throw new IllegalStateException("Call not started");
        if (closed) return;
        if (halfClosed) throw new IllegalStateException("Request side is closed");
        if (pendingWrites >= 16) { finish(Status.RESOURCE_EXHAUSTED.withDescription("Wait for onReady before sending more messages"), null); return; }
        final byte[] data;
        try (InputStream source = method.getRequestMarshaller().stream(message)) {
            ByteArrayOutputStream output = new ByteArrayOutputStream();
            byte[] buffer = new byte[4096];
            for (int n; (n = source.read(buffer)) != -1;) output.write(buffer, 0, n);
            data = output.toByteArray();
        } catch (Exception error) { fail(error); return; }
        ++pendingWrites;
        writes = writes.thenCompose(ignored -> call.send(data));
        writes.whenComplete((ignored, error) -> {
            synchronized (this) {
                --pendingWrites;
                if (error != null) fail(error);
                else if (!closed) callbacks.execute(() -> { if (isReady()) listener.onReady(); });
            }
        });
    }

    @Override public synchronized boolean isReady() { return started && !closed && !halfClosed && pendingWrites < 16; }

    @Override public synchronized void halfClose() {
        if (!started) throw new IllegalStateException("Call not started");
        if (closed || halfClosed) return;
        halfClosed = true;
        writes = writes.thenCompose(ignored -> call.halfClose());
        writes.whenComplete((ignored, error) -> { if (error != null) fail(error); });
    }

    @Override public synchronized void cancel(String message, Throwable cause) {
        Status status = Status.CANCELLED.withDescription(message).withCause(cause);
        if (!started) earlyCancellation = status;
        else finish(status, null);
    }

    private synchronized void read() {
        if (closed || call == null || reading || buffered != null) return;
        reading = true;
        call.receive().whenComplete((data, error) -> {
            synchronized (this) {
                reading = false;
                if (closed) return;
                if (error != null) { fail(error); return; }
                if (data == null) { finish(Status.OK, null); return; }
                buffered = data;
                deliverBuffered();
            }
        });
    }

    private void deliverBuffered() {
        if (closed || buffered == null || demand == 0) return;
        byte[] data = buffered;
        buffered = null;
        --demand;
        callbacks.execute(() -> {
            try { listener.onMessage(method.getResponseMarshaller().parse(new ByteArrayInputStream(data))); }
            catch (Throwable error) { fail(error); return; }
            // Only the listener's return permits another message to leave the
            // module, so a slow callback cannot build an unbounded Java queue.
            read();
        });
    }

    private synchronized void fail(Throwable error) {
        while (error instanceof CompletionException && error.getCause() != null) error = error.getCause();
        if (error instanceof RequestClosedException) {
            // Request-side EOF leaves prefetched output and the receive path
            // alive. The final RPC status is delivered by receive/status.
            halfClosed = true;
            return;
        }
        if (error instanceof FfiError) {
            FfiError ffi = (FfiError)error;
            finish(Status.fromCodeValue(ffi.getGrpcCode()).withDescription(ffi.getMessage()).withCause(ffi), ffi.getPayload());
        } else finish(Status.INTERNAL.withDescription(error.getMessage()).withCause(error), null);
    }

    private void finish(Status status, byte[] payload) {
        if (closed) return;
        closed = true;
        buffered = null;
        if (call != null) call.close();
        Metadata trailers = new Metadata();
        if (payload != null && payload.length != 0)
            trailers.put(Metadata.Key.of("synurang-error-bin", Metadata.BINARY_BYTE_MARSHALLER), payload);
        callbacks.execute(() -> listener.onClose(status, trailers));
    }

    private static final class SerialExecutor implements Executor {
        private final Executor delegate;
        private final ArrayDeque<Runnable> queue = new ArrayDeque<>();
        private boolean running;
        SerialExecutor(Executor delegate) { this.delegate = delegate; }
        @Override public synchronized void execute(Runnable task) {
            queue.addLast(task);
            if (!running) { running = true; delegate.execute(this::drain); }
        }
        private void drain() {
            while (true) {
                Runnable task;
                synchronized (this) {
                    task = queue.pollFirst();
                    if (task == null) { running = false; return; }
                }
                try { task.run(); } catch (Throwable ignored) { /* listener exception must not strand later close */ }
            }
        }
    }
}

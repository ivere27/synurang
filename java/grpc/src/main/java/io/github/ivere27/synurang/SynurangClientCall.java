package io.github.ivere27.synurang;

import io.grpc.CallOptions;
import io.grpc.ClientCall;
import io.grpc.Metadata;
import io.grpc.MethodDescriptor;
import io.grpc.MethodDescriptor.MethodType;
import io.grpc.Status;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.util.concurrent.Executor;
import java.util.concurrent.Semaphore;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * Package-private {@link ClientCall} implementation that routes RPCs through
 * the Synurang plugin C ABI. Handles all four gRPC call types.
 *
 * <p>Flow control is implemented via a {@link Semaphore}: {@link #request(int)}
 * releases permits, and the recv thread acquires a permit before each recv.
 * This correctly supports both blocking stubs (which use ThreadlessExecutor
 * and call request(1) per message) and async stubs.
 *
 * <p>Listener callbacks are delivered via {@link CallOptions#getExecutor()}
 * when set (critical for blocking stubs which use ThreadlessExecutor internally),
 * or directly on the worker thread otherwise.
 */
class SynurangClientCall<ReqT, RespT> extends ClientCall<ReqT, RespT> {
    private final PluginHost host;
    private final String serviceName;
    private final MethodDescriptor<ReqT, RespT> method;
    private final CallOptions callOptions;

    private Listener<RespT> listener;
    private final AtomicBoolean cancelled = new AtomicBoolean(false);
    private final AtomicBoolean closeSent = new AtomicBoolean(false);
    private final AtomicBoolean closeDelivered = new AtomicBoolean(false);
    private final Semaphore semaphore = new Semaphore(0);

    // For UNARY/SERVER_STREAMING: buffer the single request
    private byte[] bufferedRequest;

    // For CLIENT_STREAMING/BIDI_STREAMING: the open stream
    private volatile PluginStream stream;

    SynurangClientCall(PluginHost host, String serviceName,
                       MethodDescriptor<ReqT, RespT> method, CallOptions callOptions) {
        this.host = host;
        this.serviceName = serviceName;
        this.method = method;
        this.callOptions = callOptions;
    }

    @Override
    public void start(Listener<RespT> responseListener, Metadata headers) {
        this.listener = responseListener;

        MethodType type = method.getType();
        if (type == MethodType.CLIENT_STREAMING || type == MethodType.BIDI_STREAMING) {
            try {
                stream = host.openStream(serviceName, "/" + method.getFullMethodName());
                startRecvThread();
            } catch (PluginError e) {
                deliverClose(Status.INTERNAL.withDescription(e.getMessage()), new Metadata());
            }
        }
    }

    @Override
    public void request(int numMessages) {
        semaphore.release(numMessages);
    }

    @Override
    public void sendMessage(ReqT message) {
        if (cancelled.get()) return;

        byte[] data = serialize(message);

        MethodType type = method.getType();
        if (type == MethodType.UNARY || type == MethodType.SERVER_STREAMING) {
            bufferedRequest = data;
        } else {
            // CLIENT_STREAMING or BIDI_STREAMING
            if (stream != null) {
                try {
                    stream.send(data);
                } catch (PluginError e) {
                    if (!cancelled.get()) {
                        cancelled.set(true);
                        if (stream != null) stream.close();
                        deliverClose(Status.INTERNAL.withDescription(e.getMessage()), new Metadata());
                    }
                }
            }
        }
    }

    @Override
    public void halfClose() {
        if (closeSent.getAndSet(true)) return;

        MethodType type = method.getType();

        if (type == MethodType.UNARY) {
            Thread t = new Thread(() -> {
                try {
                    byte[] resp = host.invoke(serviceName,
                            "/" + method.getFullMethodName(), bufferedRequest);
                    if (cancelled.get()) return;

                    deliver(() -> listener.onHeaders(new Metadata()));

                    semaphore.acquire();
                    if (cancelled.get()) return;

                    RespT msg = deserialize(resp);
                    deliver(() -> listener.onMessage(msg));
                    deliverClose(Status.OK, new Metadata());
                } catch (PluginError e) {
                    if (!cancelled.get()) {
                        deliverClose(Status.INTERNAL.withDescription(e.getMessage()), new Metadata());
                    }
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                    if (!cancelled.get()) {
                        deliverClose(Status.CANCELLED, new Metadata());
                    }
                }
            }, "synurang-unary");
            t.setDaemon(true);
            t.start();
        } else if (type == MethodType.SERVER_STREAMING) {
            Thread t = new Thread(() -> {
                PluginStream s = null;
                try {
                    s = host.openStream(serviceName, "/" + method.getFullMethodName());
                    this.stream = s;
                    s.send(bufferedRequest);
                    s.closeSend();

                    if (cancelled.get()) { s.close(); return; }

                    deliver(() -> listener.onHeaders(new Metadata()));
                    recvLoop(s);
                } catch (PluginError e) {
                    if (s != null) s.close();
                    if (!cancelled.get()) {
                        deliverClose(Status.INTERNAL.withDescription(e.getMessage()), new Metadata());
                    }
                }
            }, "synurang-server-stream");
            t.setDaemon(true);
            t.start();
        } else {
            // CLIENT_STREAMING or BIDI_STREAMING
            if (stream != null) {
                stream.closeSend();
            }
        }
    }

    @Override
    public void cancel(String message, Throwable cause) {
        if (cancelled.compareAndSet(false, true)) {
            semaphore.release(); // unblock any waiting recv thread
            if (stream != null) {
                stream.close();
            }
            deliverClose(Status.CANCELLED.withDescription(message), new Metadata());
        }
    }

    // -------------------------------------------------------------------------
    // Internal
    // -------------------------------------------------------------------------

    private void startRecvThread() {
        Thread t = new Thread(() -> {
            deliver(() -> listener.onHeaders(new Metadata()));
            recvLoop(stream);
        }, "synurang-recv");
        t.setDaemon(true);
        t.start();
    }

    private void recvLoop(PluginStream s) {
        try {
            while (!cancelled.get()) {
                semaphore.acquire();
                if (cancelled.get()) break;

                byte[] data;
                try {
                    data = s.recv();
                } catch (PluginError e) {
                    s.close();
                    if (!cancelled.get()) {
                        deliverClose(Status.INTERNAL.withDescription(e.getMessage()), new Metadata());
                    }
                    return;
                }

                if (cancelled.get()) break;

                if (data == null) {
                    // EOF
                    s.close();
                    deliverClose(Status.OK, new Metadata());
                    return;
                }

                RespT msg = deserialize(data);
                if (!cancelled.get()) {
                    deliver(() -> listener.onMessage(msg));
                }
            }
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            s.close();
            if (!cancelled.get()) {
                deliverClose(Status.CANCELLED, new Metadata());
            }
        }
    }

    private byte[] serialize(ReqT message) {
        InputStream is = method.getRequestMarshaller().stream(message);
        try {
            ByteArrayOutputStream baos = new ByteArrayOutputStream();
            byte[] buf = new byte[4096];
            int n;
            while ((n = is.read(buf)) != -1) {
                baos.write(buf, 0, n);
            }
            return baos.toByteArray();
        } catch (Exception e) {
            throw new RuntimeException("Failed to serialize request", e);
        }
    }

    private RespT deserialize(byte[] data) {
        return method.getResponseMarshaller().parse(new ByteArrayInputStream(data));
    }

    private void deliverClose(Status status, Metadata trailers) {
        if (closeDelivered.compareAndSet(false, true)) {
            deliver(() -> listener.onClose(status, trailers));
        }
    }

    private void deliver(Runnable task) {
        Executor executor = callOptions.getExecutor();
        if (executor != null) {
            executor.execute(task);
        } else {
            task.run();
        }
    }
}

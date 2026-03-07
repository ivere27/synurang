package io.github.ivere27.synurang;

/**
 * A stream handle for streaming RPCs with a Synurang plugin.
 * <p>
 * Supports send, recv, closeSend, and close operations.
 * The recv() method returns null on EOF.
 */
public class PluginStream implements AutoCloseable {
    private final PluginHost host;
    private final long handle;
    private final PluginHost.StreamFuncs funcs;
    private final java.util.concurrent.atomic.AtomicBoolean closed = new java.util.concurrent.atomic.AtomicBoolean(false);

    PluginStream(PluginHost host, long handle, PluginHost.StreamFuncs funcs) {
        this.host = host;
        this.handle = handle;
        this.funcs = funcs;
    }

    /**
     * Send data to the stream.
     *
     * @param data serialized protobuf message
     * @throws FfiError on send failure
     */
    public void send(byte[] data) throws FfiError {
        if (closed.get()) throw new FfiError.ClosedError();

        int result = SynurangJni.nativeStreamSend(funcs.send, handle, data);
        if (result != 0) {
            throw new FfiError("Stream send failed with code " + result);
        }
    }

    /**
     * Receive data from the stream.
     *
     * @return protobuf response bytes, or null on EOF
     * @throws FfiError on error
     */
    public byte[] recv() throws FfiError {
        if (closed.get()) throw new FfiError.ClosedError();

        return SynurangJni.nativeStreamRecv(funcs.recv, host.getFreePtr(), handle);
    }

    /**
     * Close the send side of the stream.
     * The stream can still receive data after this.
     */
    public void closeSend() {
        if (!closed.get()) {
            SynurangJni.nativeStreamCloseSend(funcs.closeSend, handle);
        }
    }

    /**
     * Close the stream completely. Thread-safe via CAS.
     */
    @Override
    public void close() {
        if (closed.compareAndSet(false, true)) {
            SynurangJni.nativeStreamClose(funcs.close, handle);
        }
    }
}

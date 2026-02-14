package io.github.ivere27.synurang;

/**
 * A stream handle for streaming RPCs with a Synurang plugin.
 * <p>
 * Supports send, recv, closeSend, and close operations.
 * The recv() method returns null on EOF.
 * <p>
 * Response format: [status:1byte][payload...]
 * status=0: success, payload is protobuf
 * status=1: error, payload is error message
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
     * @throws PluginError on send failure
     */
    public void send(byte[] data) throws PluginError {
        if (closed.get()) throw new PluginError.ClosedError();

        int result = SynurangJni.nativeStreamSend(funcs.send, handle, data);
        if (result != 0) {
            throw new PluginError("Stream send failed with code " + result);
        }
    }

    /**
     * Receive data from the stream.
     * <p>
     * The status byte is checked and stripped. Returns the protobuf payload.
     *
     * @return protobuf response bytes (status byte stripped), or null on EOF
     * @throws PluginError on error
     */
    public byte[] recv() throws PluginError {
        if (closed.get()) throw new PluginError.ClosedError();

        byte[] result = SynurangJni.nativeStreamRecv(funcs.recv, host.getFreePtr(), handle);

        // null means EOF
        if (result == null) {
            return null;
        }

        if (result.length == 0) {
            throw new PluginError("Empty stream response");
        }

        // Check status byte
        if (result[0] == 1) {
            throw new PluginError(new String(result, 1, result.length - 1));
        }

        // Strip status byte
        byte[] payload = new byte[result.length - 1];
        System.arraycopy(result, 1, payload, 0, payload.length);
        return payload;
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

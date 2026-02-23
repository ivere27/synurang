package io.github.ivere27.synurang;

import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * Loads and communicates with Synurang plugins (Go/C++/Rust shared libraries).
 * <p>
 * Thread-safe. Caches symbol lookups in ConcurrentHashMap.
 * <p>
 * Usage:
 * <pre>
 *   try (PluginHost plugin = PluginHost.load("./libmyplugin.so")) {
 *       byte[] resp = plugin.invoke("MyService", "/pkg.MyService/Method", requestBytes);
 *   }
 * </pre>
 */
public class PluginHost implements AutoCloseable {
    private final long handle;
    private final long freePtr;
    private final AtomicBoolean closed = new AtomicBoolean(false);

    // Cached function pointers: serviceName -> pointer
    private final ConcurrentHashMap<String, Long> invokers = new ConcurrentHashMap<>();
    private final ConcurrentHashMap<String, Long> streamOpeners = new ConcurrentHashMap<>();

    // Global stream function pointers (lazily resolved)
    private volatile StreamFuncs streamFuncs;

    static final class StreamFuncs {
        final long send;
        final long recv;
        final long closeSend;
        final long close;

        StreamFuncs(long send, long recv, long closeSend, long close) {
            this.send = send;
            this.recv = recv;
            this.closeSend = closeSend;
            this.close = close;
        }
    }

    private PluginHost(long handle, long freePtr) {
        this.handle = handle;
        this.freePtr = freePtr;
    }

    /**
     * Load a plugin from the given shared library path.
     *
     * @param path path to .so/.dylib/.dll file
     * @return loaded plugin host
     * @throws PluginError if loading fails or Synurang_Free symbol is missing
     */
    public static PluginHost load(String path) throws PluginError {
        long handle = SynurangJni.nativeOpen(path);
        if (handle == 0) {
            throw new PluginError("Failed to load plugin: " + path);
        }

        long freePtr = SynurangJni.nativeLookupSymbol(handle, "Synurang_Free");
        if (freePtr == 0) {
            SynurangJni.nativeClose(handle);
            throw new PluginError("Plugin missing Synurang_Free symbol: " + path);
        }

        return new PluginHost(handle, freePtr);
    }

    /**
     * Invoke a unary RPC method on a service.
     * <p>
     * Response format from plugin: [status:1byte][payload...]
     * status=0: success, payload is protobuf response
     * status=1: error, payload is error message
     *
     * @param serviceName the service name (e.g., "GoGreeterService")
     * @param method      the full gRPC method path (e.g., "/pkg.Service/Method")
     * @param data        the serialized protobuf request
     * @return the protobuf response bytes (status byte stripped)
     * @throws PluginError on error
     */
    public byte[] invoke(String serviceName, String method, byte[] data) throws PluginError {
        ensureOpen();

        long invokePtr = getInvoker(serviceName);
        byte[] result = SynurangJni.nativeInvoke(invokePtr, freePtr, method, data);

        if (result == null || result.length == 0) {
            throw new PluginError("Empty response from plugin for " + method);
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
     * Open a streaming RPC to a service.
     *
     * @param serviceName the service name
     * @param method      the full gRPC method path
     * @return a stream handle for send/recv operations
     * @throws PluginError on error
     */
    public PluginStream openStream(String serviceName, String method) throws PluginError {
        ensureOpen();

        StreamFuncs sf = ensureStreamFuncs();
        long openPtr = getStreamOpener(serviceName);

        long streamHandle = SynurangJni.nativeStreamOpen(openPtr, method);
        if (streamHandle == 0) {
            throw new PluginError("Failed to open stream for " + method);
        }

        return new PluginStream(this, streamHandle, sf);
    }

    @Override
    public void close() {
        if (closed.compareAndSet(false, true)) {
            SynurangJni.nativeClose(handle);
        }
    }

    // -------------------------------------------------------------------------
    // Internal
    // -------------------------------------------------------------------------

    private void ensureOpen() throws PluginError.ClosedError {
        if (closed.get()) {
            throw new PluginError.ClosedError();
        }
    }

    private long getInvoker(String serviceName) throws PluginError {
        Long cached = invokers.get(serviceName);
        if (cached != null) return cached;

        String symName = "Synurang_Invoke_" + serviceName;
        long ptr = SynurangJni.nativeLookupSymbol(handle, symName);
        if (ptr == 0) {
            throw new PluginError("Service not found: " + serviceName + " (missing " + symName + ")");
        }

        invokers.put(serviceName, ptr);
        return ptr;
    }

    private long getStreamOpener(String serviceName) throws PluginError {
        Long cached = streamOpeners.get(serviceName);
        if (cached != null) return cached;

        String symName = "Synurang_Stream_" + serviceName + "_Open";
        long ptr = SynurangJni.nativeLookupSymbol(handle, symName);
        if (ptr == 0) {
            throw new PluginError("Streaming not supported for " + serviceName + " (missing " + symName + ")");
        }

        streamOpeners.put(serviceName, ptr);
        return ptr;
    }

    private StreamFuncs ensureStreamFuncs() throws PluginError {
        StreamFuncs sf = streamFuncs;
        if (sf != null) return sf;

        synchronized (this) {
            sf = streamFuncs;
            if (sf != null) return sf;

            long send = SynurangJni.nativeLookupSymbol(handle, "Synurang_Stream_Send");
            long recv = SynurangJni.nativeLookupSymbol(handle, "Synurang_Stream_Recv");
            long closeSend = SynurangJni.nativeLookupSymbol(handle, "Synurang_Stream_CloseSend");
            long close = SynurangJni.nativeLookupSymbol(handle, "Synurang_Stream_Close");

            if (send == 0 || recv == 0 || closeSend == 0 || close == 0) {
                throw new PluginError("Incomplete streaming support in plugin");
            }

            sf = new StreamFuncs(send, recv, closeSend, close);
            streamFuncs = sf;
            return sf;
        }
    }

    long getFreePtr() {
        return freePtr;
    }

    /**
     * Get the native memory address of a direct {@link java.nio.Buffer}.
     * <p>
     * Uses JNI {@code GetDirectBufferAddress} — works reliably on all Android API
     * levels and JVMs, unlike reflection on {@code Buffer.address}.
     *
     * @param buffer a direct ByteBuffer (e.g., from Camera2 Image planes)
     * @return the native pointer address
     * @throws PluginError if the buffer is not a direct buffer
     */
    public static long getDirectBufferAddress(java.nio.Buffer buffer) throws PluginError {
        return SynurangJni.nativeGetDirectBufferAddress(buffer);
    }
}

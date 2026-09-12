package io.github.ivere27.synurang;

/** New module ABI only; the portable loader owns the module's buffer allocator. */
final class ModuleJni {
    static { NativeLibLoader.load(); }
    private ModuleJni() {}
    static native long load(byte[] path, byte[] symbol);
    static native void setWakeup(long host, ModuleHost callback);
    static native long open(long host, byte[] method, boolean requestStream,
                            boolean responseStream, long timeoutMillis);
    static native int send(long host, long call, byte[] data);
    static native int halfClose(long host, long call);
    static native Read receive(long host, long call);
    static native int cancel(long host, long call, int code);
    static native void release(long host, long call);
    static native void poll(long host, int budget);
    static native boolean hasWork(long host);
    static native int destroy(long host);

    static final class Read {
        final int status, kind, code;
        final byte[] data;
        Read(int status, int kind, int code, byte[] data) {
            this.status = status; this.kind = kind; this.code = code; this.data = data;
        }
    }
}

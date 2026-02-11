package io.github.ivere27.synurang;

/**
 * JNI native method declarations for Synurang plugin loading, invocation,
 * and process host (socketpair + fork/exec).
 * <p>
 * These methods are implemented in synurang_jni.c.
 */
class SynurangJni {
    static {
        System.loadLibrary("synurang_jni");
    }

    // =========================================================================
    // Plugin loading
    // =========================================================================

    static native long nativeOpen(String path);
    static native void nativeClose(long handle);
    static native long nativeLookupSymbol(long handle, String name);

    // =========================================================================
    // Unary RPC — response format: [status:1byte][payload...]
    // =========================================================================

    static native byte[] nativeInvoke(long invokePtr, long freePtr, String method, byte[] data) throws PluginError;

    // =========================================================================
    // Streaming
    // =========================================================================

    static native long nativeStreamOpen(long openPtr, String method);
    static native int nativeStreamSend(long sendPtr, long handle, byte[] data) throws PluginError;
    // Returns null on EOF, throws on error
    static native byte[] nativeStreamRecv(long recvPtr, long freePtr, long handle) throws PluginError;
    static native void nativeStreamCloseSend(long closeSendPtr, long handle);
    static native void nativeStreamClose(long closePtr, long handle);

    // =========================================================================
    // Process host — socketpair + fork/exec
    // =========================================================================

    /** Creates a Unix socketpair. Returns int[2] = {parentFd, childFd}. */
    static native int[] nativeSocketpair() throws PluginError;

    /**
     * Fork + exec a child process with the given socketpair fd.
     * <p>
     * Child: dup2(childFd, 3), close fds > 3, set SYNURANG_IPC=3, execve.
     * Parent: closes childFd, returns child pid.
     *
     * @return child pid
     */
    static native int nativeForkExec(String executable, String[] args, int childFd) throws PluginError;

    /** Send a signal to a process. */
    static native void nativeKill(int pid, int signal);

    /** Wait for process to exit. Returns exit code or -1. */
    static native int nativeWaitPid(int pid);

    /** Check if process is still alive (kill(pid, 0)). */
    static native boolean nativeIsAlive(int pid);

    // =========================================================================
    // Raw fd I/O — for SocketPairSocket
    // =========================================================================

    /**
     * Read from a file descriptor.
     * @return bytes read, 0 on EOF
     * @throws java.net.SocketTimeoutException on timeout
     */
    static native int nativeReadFd(int fd, byte[] buf, int offset, int len) throws PluginError;

    /** Write all bytes to a file descriptor. */
    static native void nativeWriteFd(int fd, byte[] buf, int offset, int len) throws PluginError;

    /** Close a file descriptor. */
    static native void nativeCloseFd(int fd);

    /** Shutdown a socket fd (how: 0=SHUT_RD, 1=SHUT_WR, 2=SHUT_RDWR). */
    static native void nativeShutdownFd(int fd, int how);

    /** Set SO_RCVTIMEO on a socket fd. */
    static native void nativeSetSoTimeout(int fd, int timeoutMs);

    /** Get SO_RCVTIMEO on a socket fd. */
    static native int nativeGetSoTimeout(int fd);

    /** Get SO_RCVBUF size. */
    static native int nativeGetRecvBufSize(int fd);

    /** Get SO_SNDBUF size. */
    static native int nativeGetSendBufSize(int fd);

    /** Set SO_RCVBUF size. */
    static native void nativeSetRecvBufSize(int fd, int size);

    /** Set SO_SNDBUF size. */
    static native void nativeSetSendBufSize(int fd, int size);

    // =========================================================================
    // Direct buffer address
    // =========================================================================

    /** Get the native address of a direct ByteBuffer (JNI GetDirectBufferAddress). */
    static native long nativeGetDirectBufferAddress(Object buffer) throws PluginError;
}

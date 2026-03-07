package io.github.ivere27.synurang;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.Socket;
import java.net.SocketAddress;
import java.net.SocketException;
import java.nio.channels.SocketChannel;

/**
 * A {@link Socket} backed by a pre-connected socketpair file descriptor.
 * <p>
 * Follows the same pattern as grpc-java's UdsSocket: extends Socket, delegates
 * I/O to the underlying fd via JNI, and lies to OkHttp about TCP-specific
 * properties (e.g., {@link #getTcpNoDelay()} returns true).
 * <p>
 * The socket is already connected at construction time (socketpair creates
 * a pair of connected sockets), so {@link #connect} is a no-op.
 */
@SuppressWarnings("UnsynchronizedOverridesSynchronized")
class SocketPairSocket extends Socket {

    private final int fd;
    private volatile boolean closed = false;
    private volatile boolean inputShutdown = false;
    private volatile boolean outputShutdown = false;

    SocketPairSocket(int fd) {
        this.fd = fd;
    }

    @Override
    public void connect(SocketAddress endpoint) throws IOException {
        // Already connected via socketpair — no-op.
    }

    @Override
    public void connect(SocketAddress endpoint, int timeout) throws IOException {
        // Already connected via socketpair — no-op.
    }

    @Override
    public void bind(SocketAddress bindpoint) {
        // no-op
    }

    @Override
    public InputStream getInputStream() throws IOException {
        if (closed) throw new SocketException("Socket closed");
        return new SocketPairInputStream();
    }

    @Override
    public OutputStream getOutputStream() throws IOException {
        if (closed) throw new SocketException("Socket closed");
        return new SocketPairOutputStream();
    }

    @Override
    public synchronized void close() throws IOException {
        if (closed) return;
        closed = true;
        if (!inputShutdown) {
            try { SynurangJni.nativeShutdownFd(fd, 0); } catch (Exception e) { /* ignore */ }
            inputShutdown = true;
        }
        if (!outputShutdown) {
            try { SynurangJni.nativeShutdownFd(fd, 1); } catch (Exception e) { /* ignore */ }
            outputShutdown = true;
        }
        SynurangJni.nativeCloseFd(fd);
    }

    // =========================================================================
    // Socket state
    // =========================================================================

    @Override public boolean isConnected() { return !closed; }
    @Override public boolean isBound() { return true; }
    @Override public synchronized boolean isClosed() { return closed; }
    @Override public synchronized boolean isInputShutdown() { return inputShutdown; }
    @Override public synchronized boolean isOutputShutdown() { return outputShutdown; }

    @Override
    public synchronized void shutdownInput() throws IOException {
        SynurangJni.nativeShutdownFd(fd, 0);
        inputShutdown = true;
    }

    @Override
    public synchronized void shutdownOutput() throws IOException {
        SynurangJni.nativeShutdownFd(fd, 1);
        outputShutdown = true;
    }

    // =========================================================================
    // Socket options — delegate to setsockopt/getsockopt via JNI
    // =========================================================================

    @Override
    public void setSoTimeout(int timeout) throws SocketException {
        SynurangJni.nativeSetSoTimeout(fd, timeout);
    }

    @Override
    public int getSoTimeout() throws SocketException {
        return SynurangJni.nativeGetSoTimeout(fd);
    }

    @Override
    public void setReceiveBufferSize(int size) throws SocketException {
        SynurangJni.nativeSetRecvBufSize(fd, size);
    }

    @Override
    public int getReceiveBufferSize() throws SocketException {
        return SynurangJni.nativeGetRecvBufSize(fd);
    }

    @Override
    public void setSendBufferSize(int size) throws SocketException {
        SynurangJni.nativeSetSendBufSize(fd, size);
    }

    @Override
    public int getSendBufferSize() throws SocketException {
        return SynurangJni.nativeGetSendBufSize(fd);
    }

    // TCP no-delay: lie to OkHttp — UDS has no Nagle algorithm
    @Override public void setTcpNoDelay(boolean on) { /* no-op */ }
    @Override public boolean getTcpNoDelay() { return true; }

    @Override public int getSoLinger() { return -1; }
    @Override public void setSoLinger(boolean on, int linger) { /* no-op */ }

    // =========================================================================
    // Unsupported IP-specific operations
    // =========================================================================

    @Override public SocketChannel getChannel() { throw new UnsupportedOperationException(); }
    @Override public InetAddress getInetAddress() { throw new UnsupportedOperationException(); }
    @Override public InetAddress getLocalAddress() { throw new UnsupportedOperationException(); }
    @Override public int getPort() { throw new UnsupportedOperationException(); }
    @Override public int getLocalPort() { throw new UnsupportedOperationException(); }
    @Override public boolean getKeepAlive() { throw new UnsupportedOperationException(); }
    @Override public void setKeepAlive(boolean on) { throw new UnsupportedOperationException(); }
    @Override public boolean getOOBInline() { throw new UnsupportedOperationException(); }
    @Override public void setOOBInline(boolean on) { throw new UnsupportedOperationException(); }
    @Override public boolean getReuseAddress() { throw new UnsupportedOperationException(); }
    @Override public void setReuseAddress(boolean on) { throw new UnsupportedOperationException(); }
    @Override public int getTrafficClass() { throw new UnsupportedOperationException(); }
    @Override public void setTrafficClass(int tc) { throw new UnsupportedOperationException(); }
    @Override public void sendUrgentData(int data) { throw new UnsupportedOperationException(); }
    @Override public void setPerformancePreferences(int connectionTime, int latency, int bandwidth) { throw new UnsupportedOperationException(); }

    @Override
    public SocketAddress getLocalSocketAddress() { return new SocketAddress() {}; }

    @Override
    public SocketAddress getRemoteSocketAddress() { return new SocketAddress() {}; }

    // =========================================================================
    // Inner streams — delegate to JNI read/write
    // =========================================================================

    private class SocketPairInputStream extends InputStream {
        @Override
        public int read() throws IOException {
            byte[] buf = new byte[1];
            int n = read(buf, 0, 1);
            return n <= 0 ? -1 : (buf[0] & 0xFF);
        }

        @Override
        public int read(byte[] b, int off, int len) throws IOException {
            if (closed) throw new SocketException("Socket closed");
            if (len == 0) return 0;
            try {
                int n = SynurangJni.nativeReadFd(fd, b, off, len);
                return n == 0 ? -1 : n;  // 0 from read() = EOF = -1 in Java
            } catch (FfiError e) {
                throw new IOException(e.getMessage(), e);
            }
        }

        @Override
        public int available() { return 0; }

        @Override
        public void close() throws IOException {
            SocketPairSocket.this.close();
        }
    }

    private class SocketPairOutputStream extends OutputStream {
        @Override
        public void write(int b) throws IOException {
            write(new byte[]{(byte) b}, 0, 1);
        }

        @Override
        public void write(byte[] b, int off, int len) throws IOException {
            if (closed) throw new SocketException("Socket closed");
            if (len == 0) return;
            try {
                SynurangJni.nativeWriteFd(fd, b, off, len);
            } catch (FfiError e) {
                throw new IOException(e.getMessage(), e);
            }
        }

        @Override
        public void flush() { /* no-op for sockets */ }

        @Override
        public void close() throws IOException {
            SocketPairSocket.this.close();
        }
    }
}

package io.github.ivere27.synurang;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStreamReader;
import java.net.Socket;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.TimeUnit;
import javax.net.SocketFactory;

/**
 * Spawns a child process and communicates via gRPC over IPC.
 * <p>
 * On Unix (with OkHttp on classpath): uses socketpair — no TCP, no network exposure.
 * The child receives fd 3 with {@code SYNURANG_IPC=3}.
 * <p>
 * Fallback (Windows, or OkHttp missing): uses TCP loopback.
 * The child prints {@code SYNURANG_PORT:<port>} to stdout.
 * <p>
 * Usage:
 * <pre>
 *   try (ProcessHost proc = ProcessHost.start("./my-server")) {
 *       // Socketpair mode (preferred) — returns a channel directly
 *       Object channel = proc.channel();
 *
 *       // TCP fallback — use with ManagedChannelBuilder.forTarget(proc.target())
 *       // String target = proc.target();
 *   }
 * </pre>
 */
public class ProcessHost implements AutoCloseable {
    private static final long STARTUP_TIMEOUT_MS = 30_000;

    // Socketpair mode fields
    private final int childPid;
    private final int parentFd;

    // TCP fallback mode fields
    private final Process process;
    private final String target;

    // Lazy-created gRPC channel (socketpair mode)
    private volatile Object managedChannel;

    private ProcessHost(int pid, int parentFd) {
        this.childPid = pid;
        this.parentFd = parentFd;
        this.process = null;
        this.target = null;
    }

    private ProcessHost(Process process, String target) {
        this.childPid = -1;
        this.parentFd = -1;
        this.process = process;
        this.target = target;
    }

    /**
     * Start a child process.
     * Uses socketpair on Unix (if OkHttp is available), TCP loopback otherwise.
     *
     * @param executable the executable path
     * @param args       additional arguments
     * @return a ProcessHost wrapping the child
     * @throws IOException if starting fails
     */
    public static ProcessHost start(String executable, String... args) throws IOException {
        // Try socketpair mode on Unix
        if (!isWindows() && hasOkHttp()) {
            return startSocketpair(executable, args);
        }
        // Fallback to TCP
        return startTcp(executable, args);
    }

    /**
     * Get a gRPC channel connected to the child process via socketpair.
     * <p>
     * Uses {@code OkHttpChannelBuilder} via reflection to inject a
     * {@link SocketPairSocket} wrapping the socketpair fd.
     * <p>
     * The returned object is an {@code io.grpc.ManagedChannel}.
     * Cast it or use it with grpc-java APIs.
     *
     * @return a ManagedChannel connected via socketpair IPC
     * @throws UnsupportedOperationException if started in TCP fallback mode
     */
    public Object channel() {
        if (parentFd < 0) {
            throw new UnsupportedOperationException(
                "channel() is only available in socketpair mode. Use target() for TCP mode.");
        }
        if (managedChannel == null) {
            synchronized (this) {
                if (managedChannel == null) {
                    managedChannel = createOkHttpChannel(parentFd);
                }
            }
        }
        return managedChannel;
    }

    /**
     * Get the gRPC target address (e.g., "127.0.0.1:50051").
     * Only available in TCP fallback mode.
     *
     * @throws UnsupportedOperationException if started in socketpair mode
     */
    public String target() {
        if (target == null) {
            throw new UnsupportedOperationException(
                "target() is only available in TCP mode. Use channel() for socketpair mode.");
        }
        return target;
    }

    /**
     * Get the child process ID (socketpair mode) or -1 (TCP mode).
     */
    public int getPid() {
        return childPid;
    }

    /**
     * Check if this ProcessHost is using socketpair IPC (vs TCP fallback).
     */
    public boolean isSocketpairMode() {
        return parentFd >= 0;
    }

    public void terminate() {
        shutdownChannel();
        if (childPid > 0) {
            SynurangJni.nativeKill(childPid, 15); // SIGTERM
        } else if (process != null) {
            process.destroy();
        }
    }

    public int waitFor() throws InterruptedException {
        if (childPid > 0) {
            return SynurangJni.nativeWaitPid(childPid);
        } else if (process != null) {
            return process.waitFor();
        }
        return -1;
    }

    public boolean waitFor(long timeout, TimeUnit unit) throws InterruptedException {
        if (childPid > 0) {
            // Poll with sleep — JNI waitpid is blocking, so use isAlive loop
            long deadlineMs = System.currentTimeMillis() + unit.toMillis(timeout);
            while (System.currentTimeMillis() < deadlineMs) {
                if (!SynurangJni.nativeIsAlive(childPid)) return true;
                Thread.sleep(50);
            }
            return !SynurangJni.nativeIsAlive(childPid);
        } else if (process != null) {
            return process.waitFor(timeout, unit);
        }
        return true;
    }

    public boolean isRunning() {
        if (childPid > 0) {
            return SynurangJni.nativeIsAlive(childPid);
        } else if (process != null) {
            return process.isAlive();
        }
        return false;
    }

    @Override
    public void close() {
        terminate();
        try {
            if (!waitFor(5, TimeUnit.SECONDS)) {
                if (childPid > 0) {
                    SynurangJni.nativeKill(childPid, 9); // SIGKILL
                    SynurangJni.nativeWaitPid(childPid);
                } else if (process != null) {
                    process.destroyForcibly();
                }
            }
        } catch (InterruptedException e) {
            if (childPid > 0) {
                SynurangJni.nativeKill(childPid, 9);
            } else if (process != null) {
                process.destroyForcibly();
            }
            Thread.currentThread().interrupt();
        }
        // Close the socketpair fd if channel() was never called
        if (parentFd >= 0 && managedChannel == null) {
            SynurangJni.nativeCloseFd(parentFd);
        }
    }

    // =========================================================================
    // Socketpair mode
    // =========================================================================

    private static ProcessHost startSocketpair(String executable, String[] args) throws IOException {
        try {
            int[] fds = SynurangJni.nativeSocketpair();
            int parentFd = fds[0];
            int childFd = fds[1];

            String[] childArgs = args != null ? args : new String[0];
            int pid = SynurangJni.nativeForkExec(executable, childArgs, childFd);
            // nativeForkExec closes childFd in parent

            return new ProcessHost(pid, parentFd);
        } catch (PluginError e) {
            throw new IOException("Failed to start child process via socketpair", e);
        }
    }

    /**
     * Create an OkHttp-based gRPC channel using a SocketPairSocket.
     * Uses reflection to avoid compile-time dependency on grpc-okhttp.
     */
    private static Object createOkHttpChannel(int fd) {
        try {
            Class<?> builderClass = Class.forName("io.grpc.okhttp.OkHttpChannelBuilder");

            // OkHttpChannelBuilder.forTarget("dns:///localhost", InsecureChannelCredentials.create())
            Class<?> credsClass = Class.forName("io.grpc.InsecureChannelCredentials");
            Object creds = credsClass.getMethod("create").invoke(null);
            Class<?> channelCredsClass = Class.forName("io.grpc.ChannelCredentials");

            Object builder = builderClass.getMethod("forTarget", String.class, channelCredsClass)
                .invoke(null, "dns:///127.0.0.1", creds);

            // builder.socketFactory(new SocketPairSocketFactory(fd))
            SocketFactory factory = new SocketPairSocketFactory(fd);
            builderClass.getMethod("socketFactory", SocketFactory.class)
                .invoke(builder, factory);

            // builder.build()
            return builderClass.getMethod("build").invoke(builder);
        } catch (Exception e) {
            throw new RuntimeException("Failed to create OkHttp channel for socketpair", e);
        }
    }

    private void shutdownChannel() {
        Object ch = managedChannel;
        if (ch != null) {
            try {
                ch.getClass().getMethod("shutdownNow").invoke(ch);
            } catch (Exception e) {
                // ignore
            }
        }
    }

    // =========================================================================
    // TCP fallback mode
    // =========================================================================

    private static ProcessHost startTcp(String executable, String[] args) throws IOException {
        List<String> command = new ArrayList<>();
        command.add(executable);
        if (args != null) {
            for (String arg : args) command.add(arg);
        }

        ProcessBuilder pb = new ProcessBuilder(command);
        pb.environment().put("SYNURANG_IPC", "tcp");
        pb.redirectErrorStream(false);

        Process process = pb.start();

        BufferedReader reader = new BufferedReader(new InputStreamReader(process.getInputStream()));
        String target = null;

        long deadline = System.currentTimeMillis() + STARTUP_TIMEOUT_MS;
        while (System.currentTimeMillis() < deadline) {
            if (!process.isAlive()) {
                throw new IOException("Child process exited before reporting port");
            }
            try {
                if (reader.ready()) {
                    String line = reader.readLine();
                    if (line != null && line.startsWith("SYNURANG_PORT:")) {
                        int port = Integer.parseInt(line.substring("SYNURANG_PORT:".length()).trim());
                        target = "127.0.0.1:" + port;
                        break;
                    }
                } else {
                    Thread.sleep(50);
                }
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                process.destroyForcibly();
                throw new IOException("Interrupted while waiting for child process", e);
            }
        }

        if (target == null) {
            process.destroyForcibly();
            throw new IOException("Child process did not report port within timeout");
        }

        return new ProcessHost(process, target);
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    private static boolean isWindows() {
        return System.getProperty("os.name", "").toLowerCase().contains("win");
    }

    private static boolean hasOkHttp() {
        try {
            Class.forName("io.grpc.okhttp.OkHttpChannelBuilder");
            return true;
        } catch (ClassNotFoundException e) {
            return false;
        }
    }

    // =========================================================================
    // SocketPairSocketFactory — one-shot factory for OkHttp
    // =========================================================================

    private static class SocketPairSocketFactory extends SocketFactory {
        private final int fd;
        private volatile boolean used = false;

        SocketPairSocketFactory(int fd) {
            this.fd = fd;
        }

        @Override
        public Socket createSocket() {
            if (used) {
                throw new IllegalStateException("SocketPairSocketFactory is single-use (fd already wrapped)");
            }
            used = true;
            return new SocketPairSocket(fd);
        }

        @Override
        public Socket createSocket(String host, int port) throws IOException {
            Socket s = createSocket();
            s.connect(null);
            return s;
        }

        @Override
        public Socket createSocket(String host, int port, java.net.InetAddress localHost, int localPort) throws IOException {
            return createSocket(host, port);
        }

        @Override
        public Socket createSocket(java.net.InetAddress host, int port) throws IOException {
            Socket s = createSocket();
            s.connect(null);
            return s;
        }

        @Override
        public Socket createSocket(java.net.InetAddress address, int port, java.net.InetAddress localAddress, int localPort) throws IOException {
            return createSocket(address, port);
        }
    }
}

using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Net.Http;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using Grpc.Net.Client;
using Microsoft.Win32.SafeHandles;

namespace Synurang;

/// <summary>
/// Spawns a child process and communicates via gRPC over IPC.
/// On Unix: defaults to TCP loopback for runtime safety.
/// Set SYNURANG_PROCESS_IPC=socketpair to opt into socketpair mode.
/// Unix startup automatically falls back across transports on startup failure.
/// In socketpair mode, the child receives fd 3 with SYNURANG_IPC=3.
/// In TCP mode, the child prints SYNURANG_PORT:&lt;port&gt; to stdout.
/// </summary>
public class ProcessHost : IDisposable
{
    private const int StartupTimeoutMs = 30_000;
    private const string UnixIpcModeEnv = "SYNURANG_PROCESS_IPC";

    // Socketpair mode
    private readonly int _childPid;
    private readonly int _parentFd;

    // TCP / Named pipe mode
    private readonly Process? _process;
    private readonly string? _target;
    private readonly bool _isNamedPipe;

    // Shared
    private volatile GrpcChannel? _channel;
    private volatile bool _disposed;

    private ProcessHost(int childPid, int parentFd)
    {
        _childPid = childPid;
        _parentFd = parentFd;
        _process = null;
        _target = null;
    }

    private ProcessHost(Process process, string target, bool isNamedPipe = false)
    {
        _childPid = -1;
        _parentFd = -1;
        _process = process;
        _target = target;
        _isNamedPipe = isNamedPipe;
    }

    /// <summary>
    /// Start a child process.
    /// Windows: named pipe preferred (.NET 5.0+), TCP loopback fallback.
    /// Unix: TCP preferred, socketpair fallback (.NET 5.0+).
    /// Set SYNURANG_PROCESS_IPC=tcp to force TCP on all platforms.
    /// Set SYNURANG_PROCESS_IPC=pipe to prefer named pipes (Windows).
    /// Set SYNURANG_PROCESS_IPC=socketpair to prefer socketpair (Unix).
    /// </summary>
    public static ProcessHost Start(string executable, params string[] args)
    {
        string mode = (Environment.GetEnvironmentVariable(UnixIpcModeEnv) ?? "")
            .Trim()
            .ToLowerInvariant();

        if (mode == "tcp")
        {
            if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
                return StartTcp(executable, args);
            return StartTcpUnix(executable, args);
        }

        if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
        {
#if NET5_0_OR_GREATER
            try { return StartNamedPipe(executable, args); }
            catch { return StartTcp(executable, args); }
#else
            return StartTcp(executable, args);
#endif
        }

#if NET5_0_OR_GREATER
        if (mode == "socketpair")
        {
            try { return StartSocketpair(executable, args); }
            catch { return StartTcpUnix(executable, args); }
        }

        // Default Unix path: prefer TCP, then fallback to socketpair.
        try { return StartTcpUnix(executable, args); }
        catch { return StartSocketpair(executable, args); }
#else
        return StartTcpUnix(executable, args);
#endif
    }

    /// <summary>
    /// Start a child process using TCP loopback (cross-platform).
    /// </summary>
    public static ProcessHost StartTcp(string executable, params string[] args)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = executable,
            RedirectStandardOutput = true,
            UseShellExecute = false,
            CreateNoWindow = true,
        };
        startInfo.Environment["SYNURANG_IPC"] = "tcp";
        if (args != null)
        {
            foreach (var arg in args)
                startInfo.ArgumentList.Add(arg);
        }

        var process = Process.Start(startInfo)
            ?? throw new FfiError("Failed to start process: " + executable);

        // Read stdout for SYNURANG_PORT:<port>
        var reader = process.StandardOutput;
        var readTask = Task.Run(() =>
        {
            string? line;
            while ((line = reader.ReadLine()) != null)
            {
                if (line.StartsWith("SYNURANG_PORT:"))
                    return line;
            }
            return (string?)null;
        });

        if (!readTask.Wait(StartupTimeoutMs))
        {
            KillProcessQuietly(process, entireProcessTree: false);
            throw new FfiError("Child process did not report port within timeout");
        }

        if (readTask.IsFaulted)
        {
            KillProcessQuietly(process, entireProcessTree: false);
            string message = readTask.Exception?.GetBaseException().Message ?? "unknown error";
            throw new FfiError("Failed to read child stdout: " + message);
        }

        string? portLine = readTask.Result;
        if (portLine == null)
        {
            KillProcessQuietly(process, entireProcessTree: false);
            throw new FfiError("Child process exited before reporting port");
        }

        string portText = portLine["SYNURANG_PORT:".Length..].Trim();
        if (!int.TryParse(portText, out int port) || port <= 0 || port > 65535)
        {
            KillProcessQuietly(process, entireProcessTree: false);
            throw new FfiError("Child reported invalid port: " + portText);
        }
        string target = $"http://127.0.0.1:{port}";

        return new ProcessHost(process, target);
    }

    private static ProcessHost StartTcpUnix(string executable, params string[] args)
    {
        // Prefer a dedicated TCP child binary when available.
        string tcpExecutable = ResolveTcpExecutable(executable);
        if (tcpExecutable != executable)
        {
            try
            {
                return StartTcp(tcpExecutable, args);
            }
            catch
            {
                // Fall back to the original executable.
            }
        }
        return StartTcp(executable, args);
    }

    private static string ResolveTcpExecutable(string executable)
    {
        string candidate = executable + "_tcp";
        return File.Exists(candidate) ? candidate : executable;
    }

    /// <summary>
    /// Get a GrpcChannel connected to the child process.
    /// Socketpair mode: channel over the socketpair fd.
    /// TCP mode: channel to the loopback address.
    /// </summary>
    public GrpcChannel Channel
    {
        get
        {
            if (_channel != null) return _channel;
            lock (this)
            {
                if (_channel != null) return _channel;
#if NET5_0_OR_GREATER
                _channel = IsSocketpairMode ? CreateSocketpairChannel()
                         : _isNamedPipe ? CreateNamedPipeChannel()
                         : CreateTcpChannel();
#else
                _channel = CreateTcpChannel();
#endif
                return _channel;
            }
        }
    }

    /// <summary>
    /// Get the gRPC target address (TCP mode only), e.g. "http://127.0.0.1:50051".
    /// </summary>
    public string? Target => _target;

    /// <summary>
    /// Whether this host uses socketpair IPC (Unix).
    /// </summary>
    public bool IsSocketpairMode => _parentFd >= 0;

    /// <summary>
    /// Whether this host uses named pipe IPC (Windows).
    /// </summary>
    public bool IsNamedPipeMode => _isNamedPipe;

    /// <summary>
    /// Get the child process ID.
    /// </summary>
    public int Pid => _childPid > 0 ? _childPid : (_process?.Id ?? -1);

    /// <summary>
    /// Check if the child process is still running.
    /// </summary>
    public bool IsRunning
    {
        get
        {
            if (_childPid > 0)
                return Libc.kill(_childPid, 0) == 0;
            return _process?.HasExited == false;
        }
    }

    public void Terminate()
    {
        ShutdownChannel();
        if (_childPid > 0)
            Libc.kill(_childPid, Libc.SIGTERM);
        else if (_process != null)
            KillProcessQuietly(_process, entireProcessTree: false);
    }

    public int WaitForExit()
    {
        if (_childPid > 0)
        {
            Libc.waitpid(_childPid, out int status, 0);
            // WIFEXITED + WEXITSTATUS
            if ((status & 0x7f) == 0)
                return (status >> 8) & 0xff;
            return -1;
        }
        _process?.WaitForExit();
        return _process?.ExitCode ?? -1;
    }

    public bool WaitForExit(TimeSpan timeout)
    {
        if (_childPid > 0)
        {
            var deadline = DateTime.UtcNow + timeout;
            while (DateTime.UtcNow < deadline)
            {
                if (!IsRunning) return true;
                Thread.Sleep(50);
            }
            return !IsRunning;
        }
        return _process?.WaitForExit((int)timeout.TotalMilliseconds) ?? true;
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;

        Terminate();
        if (!WaitForExit(TimeSpan.FromSeconds(5)))
        {
            // Force kill
            if (_childPid > 0)
            {
                Libc.kill(_childPid, Libc.SIGKILL);
                Libc.waitpid(_childPid, out _, 0);
            }
            else
            {
                if (_process != null)
                    KillProcessQuietly(_process, entireProcessTree: true);
            }
        }

        // Close socketpair fd if channel was never created
        if (_parentFd >= 0 && _channel == null)
            Libc.close(_parentFd);

        _process?.Dispose();
    }

    // =========================================================================
    // Socketpair mode (Unix, .NET 5.0+)
    // =========================================================================

#if NET5_0_OR_GREATER
    private static ProcessHost StartSocketpair(string executable, string[] args)
    {
        int[] fds = new int[2];
        if (Libc.socketpair(Libc.AF_UNIX, Libc.SOCK_STREAM, 0, fds) != 0)
            throw new FfiError("socketpair() failed");

        int parentFd = fds[0];
        int childFd = fds[1];

        try
        {
            int pid = ForkExec(executable, args, childFd, parentFd);
            // ForkExec closes childFd in the parent
            return new ProcessHost(pid, parentFd);
        }
        catch
        {
            Libc.close(parentFd);
            throw;
        }
    }

    /// <summary>
    /// Fork and exec a child process with the socketpair fd duped to fd 3.
    /// Closes childFd in the parent after fork.
    /// </summary>
    private static int ForkExec(string executable, string[] args, int childFd, int parentFd)
    {
        // Pre-allocate all native memory BEFORE fork
        IntPtr execPath = IntPtr.Zero;
        IntPtr argv = IntPtr.Zero;
        IntPtr envp = IntPtr.Zero;
        var allocatedPtrs = new List<IntPtr>();

        // Warm up close_range availability check (resolves P/Invoke symbol)
        Libc.EnsureCloseRangeChecked();

        try
        {
            execPath = NativeLoader.StringToCoTaskMemUTF8(executable);

            // Build argv: [executable, args..., NULL]
            int argc = args?.Length ?? 0;
            argv = Marshal.AllocCoTaskMem(IntPtr.Size * (argc + 2));
            Marshal.WriteIntPtr(argv, 0, execPath);
            for (int i = 0; i < argc; i++)
            {
                var argPtr = NativeLoader.StringToCoTaskMemUTF8(args![i]);
                allocatedPtrs.Add(argPtr);
                Marshal.WriteIntPtr(argv, (i + 1) * IntPtr.Size, argPtr);
            }
            Marshal.WriteIntPtr(argv, (argc + 1) * IntPtr.Size, IntPtr.Zero);

            // Build envp: current env with SYNURANG_IPC=3
            var envVars = Environment.GetEnvironmentVariables();
            envVars["SYNURANG_IPC"] = "3";
            int envCount = envVars.Count;
            envp = Marshal.AllocCoTaskMem(IntPtr.Size * (envCount + 1));
            int ei = 0;
            foreach (DictionaryEntry entry in envVars)
            {
                var envStr = NativeLoader.StringToCoTaskMemUTF8($"{entry.Key}={entry.Value}");
                allocatedPtrs.Add(envStr);
                Marshal.WriteIntPtr(envp, ei * IntPtr.Size, envStr);
                ei++;
            }
            Marshal.WriteIntPtr(envp, ei * IntPtr.Size, IntPtr.Zero);

            // Fork
            int pid = Libc.fork();
            if (pid < 0)
            {
                Libc.close(childFd);
                throw new FfiError("fork() failed");
            }

            if (pid == 0)
            {
                // ==== CHILD PROCESS ====
                // Only async-signal-safe operations from here.
                // P/Invoke function pointers are cached pre-fork.

                if (childFd != 3)
                {
                    Libc.dup2(childFd, 3);
                    Libc.close(childFd);
                }
                Libc.close(parentFd);

                // Close all fds > 3
                Libc.CloseFromFd(4);

                // Replace process image
                Libc.execve(execPath, argv, envp);
                Libc._exit(127); // exec failed
            }

            // ==== PARENT ====
            Libc.close(childFd);
            return pid;
        }
        finally
        {
            // Free native memory in parent (child has COW copy)
            if (execPath != IntPtr.Zero) Marshal.FreeCoTaskMem(execPath);
            if (argv != IntPtr.Zero) Marshal.FreeCoTaskMem(argv);
            if (envp != IntPtr.Zero) Marshal.FreeCoTaskMem(envp);
            foreach (var ptr in allocatedPtrs)
                Marshal.FreeCoTaskMem(ptr);
        }
    }

    private GrpcChannel CreateSocketpairChannel()
    {
        SafeSocketHandle? safeHandle = null;
        Socket? socket = null;
        NetworkStream? stream = null;
        try
        {
            safeHandle = new SafeSocketHandle(new IntPtr(_parentFd), ownsHandle: true);
            socket = new Socket(safeHandle);
            stream = new NetworkStream(socket, ownsSocket: true);

            bool used = false;
            var handler = new SocketsHttpHandler
            {
                ConnectCallback = (_, _) =>
                {
                    if (used)
                        throw new InvalidOperationException(
                            "Socketpair connection lost, cannot reconnect");
                    used = true;
                    return new ValueTask<Stream>(stream);
                },
                EnableMultipleHttp2Connections = false,
            };

            var channel = GrpcChannel.ForAddress("http://localhost", new GrpcChannelOptions
            {
                HttpHandler = handler,
                DisposeHttpClient = true,
            });

            // Transfer ownership — fd is now managed by the channel's handler chain
            safeHandle = null;
            socket = null;
            stream = null;
            return channel;
        }
        catch
        {
            stream?.Dispose();
            if (stream == null) socket?.Dispose();
            if (socket == null) safeHandle?.Dispose();
            throw;
        }
    }

    // =========================================================================
    // Named pipe mode (Windows, .NET 5.0+)
    // =========================================================================

    /// <summary>
    /// Start a child process using named pipe IPC (Windows).
    /// Sets SYNURANG_IPC=pipe:&lt;name&gt; for the child.
    /// Accepts either SYNURANG_PIPE:&lt;name&gt; (named pipe) or
    /// SYNURANG_PORT:&lt;port&gt; (TCP fallback) from child stdout.
    /// </summary>
    private static ProcessHost StartNamedPipe(string executable, string[] args)
    {
        string pipeName = "synurang-" + Guid.NewGuid().ToString("N");

        var startInfo = new ProcessStartInfo
        {
            FileName = executable,
            RedirectStandardOutput = true,
            UseShellExecute = false,
            CreateNoWindow = true,
        };
        startInfo.Environment["SYNURANG_IPC"] = $"pipe:{pipeName}";
        if (args != null)
        {
            foreach (var arg in args)
                startInfo.ArgumentList.Add(arg);
        }

        var process = Process.Start(startInfo)
            ?? throw new FfiError("Failed to start process: " + executable);

        // Read stdout for SYNURANG_PIPE:<name> or SYNURANG_PORT:<port>
        var reader = process.StandardOutput;
        var readTask = Task.Run(() =>
        {
            string? line;
            while ((line = reader.ReadLine()) != null)
            {
                if (line.StartsWith("SYNURANG_PIPE:") || line.StartsWith("SYNURANG_PORT:"))
                    return line;
            }
            return (string?)null;
        });

        if (!readTask.Wait(StartupTimeoutMs))
        {
            KillProcessQuietly(process, entireProcessTree: false);
            throw new FfiError("Child process did not report pipe/port within timeout");
        }

        if (readTask.IsFaulted)
        {
            KillProcessQuietly(process, entireProcessTree: false);
            string message = readTask.Exception?.GetBaseException().Message ?? "unknown error";
            throw new FfiError("Failed to read child stdout: " + message);
        }

        string? resultLine = readTask.Result;
        if (resultLine == null)
        {
            KillProcessQuietly(process, entireProcessTree: false);
            throw new FfiError("Child process exited before reporting pipe/port");
        }

        if (resultLine.StartsWith("SYNURANG_PIPE:"))
        {
            string actualPipeName = resultLine["SYNURANG_PIPE:".Length..].Trim();
            return new ProcessHost(process, actualPipeName, isNamedPipe: true);
        }

        // Child fell back to TCP — handle SYNURANG_PORT:<port>
        string portText = resultLine["SYNURANG_PORT:".Length..].Trim();
        if (!int.TryParse(portText, out int port) || port <= 0 || port > 65535)
        {
            KillProcessQuietly(process, entireProcessTree: false);
            throw new FfiError("Child reported invalid port: " + portText);
        }
        return new ProcessHost(process, $"http://127.0.0.1:{port}");
    }

    private GrpcChannel CreateNamedPipeChannel()
    {
        string pipeName = _target!;
        var handler = new SocketsHttpHandler
        {
            ConnectCallback = async (_, ct) =>
            {
                var client = new NamedPipeClientStream(
                    serverName: ".",
                    pipeName: pipeName,
                    direction: PipeDirection.InOut,
                    options: PipeOptions.WriteThrough | PipeOptions.Asynchronous);
                try
                {
                    await client.ConnectAsync(ct).ConfigureAwait(false);
                    return client;
                }
                catch
                {
                    client.Dispose();
                    throw;
                }
            }
        };

        return GrpcChannel.ForAddress("http://localhost", new GrpcChannelOptions
        {
            HttpHandler = handler,
            DisposeHttpClient = true,
        });
    }
#endif

    // =========================================================================
    // TCP mode
    // =========================================================================

    private GrpcChannel CreateTcpChannel()
    {
        var handler = new SocketsHttpHandler
        {
            PooledConnectionIdleTimeout = TimeSpan.FromSeconds(1),
#if NET5_0_OR_GREATER
            EnableMultipleHttp2Connections = false,
#endif
        };
        return GrpcChannel.ForAddress(_target!, new GrpcChannelOptions
        {
            HttpHandler = handler,
            DisposeHttpClient = true,
        });
    }

    // =========================================================================
    // Shared
    // =========================================================================

    private void ShutdownChannel()
    {
        var ch = _channel;
        if (ch != null)
        {
            try { ch.ShutdownAsync().Wait(TimeSpan.FromSeconds(3)); } catch { /* ignore */ }
            ch.Dispose();
        }
    }

    private static void KillProcessQuietly(Process process, bool entireProcessTree)
    {
        try
        {
            if (!process.HasExited)
#if NET5_0_OR_GREATER
                process.Kill(entireProcessTree);
#else
                process.Kill();
#endif
        }
        catch (InvalidOperationException)
        {
            // Process has already exited.
        }
        catch
        {
            // Best effort.
        }

        try
        {
            process.WaitForExit(1000);
        }
        catch
        {
            // Ignore timeout/failure during teardown.
        }
    }

    // =========================================================================
    // libc P/Invoke (Unix)
    // =========================================================================

    internal static class Libc
    {
        public const int AF_UNIX = 1;
        public const int SOCK_STREAM = 1;
        public const int SIGTERM = 15;
        public const int SIGKILL = 9;

        [DllImport("libc", SetLastError = true)]
        public static extern int socketpair(int domain, int type, int protocol, int[] sv);

        [DllImport("libc", SetLastError = true)]
        public static extern int fork();

        [DllImport("libc", SetLastError = true)]
        public static extern int dup2(int oldfd, int newfd);

        [DllImport("libc", SetLastError = true)]
        public static extern int close(int fd);

        [DllImport("libc", SetLastError = true)]
        public static extern int execve(IntPtr pathname, IntPtr argv, IntPtr envp);

        [DllImport("libc")]
        public static extern void _exit(int status);

        [DllImport("libc", SetLastError = true)]
        public static extern int kill(int pid, int sig);

        [DllImport("libc", SetLastError = true)]
        public static extern int waitpid(int pid, out int status, int options);

        [DllImport("libc", SetLastError = true)]
        private static extern long sysconf(int name);
        private const int _SC_OPEN_MAX = 4;

        // close_range (glibc 2.34+)
        [DllImport("libc", SetLastError = true, EntryPoint = "close_range")]
        private static extern int close_range_native(uint first, uint last, int flags);

        private static bool? _hasCloseRange;
        private static int _maxFd = 1024;
        private const int EINVAL = 22;
        private const int ENOSYS = 38;

        /// <summary>
        /// Pre-fork: resolve close_range symbol so the P/Invoke cache is warm.
        /// </summary>
        public static void EnsureCloseRangeChecked()
        {
            if (_hasCloseRange.HasValue) return;
            try
            {
                // Invalid range is a no-op for fd state and tells us if the syscall exists.
                int rc = close_range_native(1, 0, 0);
                if (rc == 0)
                {
                    _hasCloseRange = true;
                }
                else
                {
                    int errno = Marshal.GetLastWin32Error();
                    _hasCloseRange = errno != ENOSYS;
                }
            }
            catch (EntryPointNotFoundException)
            {
                _hasCloseRange = false;
            }
            // Also warm up the close() P/Invoke
            close(-1); // EBADF, but resolves the symbol

            // Cache max fd from sysconf (async-signal-safe value, read before fork)
            try
            {
                long maxFd = sysconf(_SC_OPEN_MAX);
                if (maxFd > 0) _maxFd = (int)Math.Min(maxFd, 65536);
            }
            catch { /* sysconf unavailable, keep default */ }
        }

        /// <summary>
        /// Close all fds >= fromFd. Safe to call after fork.
        /// </summary>
        public static void CloseFromFd(int fromFd)
        {
            if (_hasCloseRange == true)
            {
                if (close_range_native((uint)fromFd, uint.MaxValue, 0) == 0)
                    return;

                int errno = Marshal.GetLastWin32Error();
                if (errno == ENOSYS || errno == EINVAL)
                    _hasCloseRange = false;
            }
            // Fallback: close individually up to cached max fd
            int maxFd = _maxFd;
            for (int fd = fromFd; fd < maxFd; fd++)
                close(fd);
        }
    }
}

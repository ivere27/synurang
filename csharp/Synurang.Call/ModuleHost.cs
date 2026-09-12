using System.Runtime.InteropServices;
using System.Diagnostics;

namespace Synurang;

public sealed class ModuleRpcException : Exception
{
    public int Code { get; }
    public byte[] Details { get; }
    public ModuleRpcException(int code, string message, byte[]? details = null) : base(message)
    { Code = code; Details = details ?? Array.Empty<byte>(); }
}

public sealed record ModuleCallOptions(CancellationToken CancellationToken = default, TimeSpan? Timeout = null);

/// <summary>The peer stopped accepting requests; responses and final status remain readable.</summary>
public sealed class ModuleRequestClosedException : InvalidOperationException
{
    public ModuleRequestClosedException() : base("RPC request side is closed") { }
}

public interface IModuleCall : IAsyncDisposable
{
    Task SendAsync(byte[] message, CancellationToken cancellationToken = default);
    Task HalfCloseAsync(CancellationToken cancellationToken = default);
    Task<byte[]?> ReceiveAsync(CancellationToken cancellationToken = default);
    void Cancel(int code = 1);
}

public interface IModuleTransport
{
    IModuleCall Open(string path, bool requestStream, bool responseStream, ModuleCallOptions? options = null);
}

/// <summary>Serialized, nonblocking native module instance. Dispose asynchronously
/// to keep its library loaded until all producer work has finished.</summary>
public sealed class ModuleHost : IModuleTransport, IAsyncDisposable
{
    internal readonly object Sync = new();
    internal IntPtr Handle;
    private readonly HashSet<ModuleCall> _calls = new();
    private bool _closing;
    private Task? _closeTask;
    private int _scheduled;
    private readonly Native.Wakeup _wakeup;
    private GCHandle _wakeupRoot;
    private TaskCompletionSource _changed = NewChange();
    private Exception? _failure;
    private static TaskCompletionSource NewChange() => new(TaskCreationOptions.RunContinuationsAsynchronously);
    private ModuleHost(IntPtr handle) {
        Handle = handle;
        _wakeup = _ => Wake();
        _wakeupRoot = GCHandle.Alloc(_wakeup);
        Native.SetWakeup(handle, _wakeup, IntPtr.Zero);
    }

    private void Wake() {
        if (Interlocked.Exchange(ref _scheduled, 1) == 0)
            ThreadPool.QueueUserWorkItem(_ => Drain());
    }
    private void Drain() {
        lock (Sync) {
            Interlocked.Exchange(ref _scheduled, 0);
            if (Handle == IntPtr.Zero) return;
            var changed = _changed;
            _changed = NewChange();
            try {
                Native.Poll(Handle, 64);
                if (Native.HasWork(Handle) != 0) Wake();
            } catch (Exception error) { _failure ??= error; }
            changed.TrySetResult();
        }
    }

    public static ModuleHost Load(string path, string symbol = "Synurang_GetApi")
    {
        var handle = Native.Load(path, symbol, IntPtr.Zero);
        if (handle == IntPtr.Zero)
            throw new InvalidOperationException(Marshal.PtrToStringUTF8(Native.Error()));
        return new ModuleHost(handle);
    }

    /// <summary>The application owns the linked API table and its code for this host's lifetime.</summary>
    public static ModuleHost Linked(IntPtr api)
    {
        var handle = Native.Linked(api, IntPtr.Zero);
        if (handle == IntPtr.Zero)
            throw new InvalidOperationException(Marshal.PtrToStringUTF8(Native.Error()));
        return new ModuleHost(handle);
    }

    public IModuleCall Open(string path, bool requestStream, bool responseStream, ModuleCallOptions? options = null)
    {
        options ??= new();
        if (options.Timeout is { } timeout && timeout < TimeSpan.Zero) throw new ArgumentOutOfRangeException(nameof(options));
        lock (Sync)
        {
            if (_closing) throw new ModuleRpcException(14, "Module is closed");
            var native = new Native.Options {
                Size = (uint)Marshal.SizeOf<Native.Options>(), RequestStream = requestStream ? 1u : 0u,
                ResponseStream = responseStream ? 1u : 0u,
                TimeoutMs = options.Timeout is { } t ? (ulong)Math.Ceiling(t.TotalMilliseconds) : ulong.MaxValue,
            };
            var id = Native.Open(Handle, path, ref native);
            if (id == 0) throw new ModuleRpcException(13, "Module could not open call");
            var call = new ModuleCall(this, id, options);
            _calls.Add(call);
            return call;
        }
    }

    private void Remove(ModuleCall call) { _calls.Remove(call); }

    public ValueTask DisposeAsync()
    {
        lock (Sync)
        {
            if (_closeTask != null) return new(_closeTask);
            _closing = true;
            foreach (var call in _calls.ToArray()) call.CloseLocked();
            _closeTask = CloseCoreAsync();
            return new(_closeTask);
        }
    }

    private async Task CloseCoreAsync()
    {
        while (true)
        {
            Task changed;
            lock (Sync)
            {
                changed = _changed.Task;
                var status = Native.Destroy(Handle);
                if (status == 0) {
                    Handle = IntPtr.Zero;
                    _changed.TrySetResult();
                    GC.KeepAlive(_wakeup);
                    _wakeupRoot.Free();
                    return;
                }
                if (status != 3) throw new ModuleRpcException(13, $"Module shutdown failed: {status}");
                if (Native.HasWork(Handle) != 0) Wake();
            }
            await changed.ConfigureAwait(false);
        }
    }

    internal static class Native
    {
        private const string Library = "synurang_module_host";
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] internal delegate void Wakeup(IntPtr data);
        [DllImport(Library, EntryPoint="synurang_host_set_wakeup", CallingConvention=CallingConvention.Cdecl)] internal static extern void SetWakeup(IntPtr host, Wakeup callback, IntPtr data);
        [DllImport(Library, EntryPoint="synurang_host_has_work", CallingConvention=CallingConvention.Cdecl)] internal static extern int HasWork(IntPtr host);
        [StructLayout(LayoutKind.Sequential)] internal struct Options {
            internal uint Size, RequestStream, ResponseStream, Reserved;
            internal ulong TimeoutMs;
        }
        [StructLayout(LayoutKind.Sequential)] internal struct Result {
            internal uint Kind; internal int Code; internal IntPtr Data; internal uint Size;
        }
        [DllImport(Library, EntryPoint="synurang_host_load", CallingConvention=CallingConvention.Cdecl)]
        internal static extern IntPtr Load([MarshalAs(UnmanagedType.LPUTF8Str)] string path, [MarshalAs(UnmanagedType.LPUTF8Str)] string symbol, IntPtr options);
        [DllImport(Library, EntryPoint="synurang_host_linked", CallingConvention=CallingConvention.Cdecl)] internal static extern IntPtr Linked(IntPtr api, IntPtr options);
        [DllImport(Library, EntryPoint="synurang_host_error", CallingConvention=CallingConvention.Cdecl)] internal static extern IntPtr Error();
        [DllImport(Library, EntryPoint="synurang_host_open", CallingConvention=CallingConvention.Cdecl)] internal static extern ulong Open(IntPtr host, [MarshalAs(UnmanagedType.LPUTF8Str)] string path, ref Options options);
        [DllImport(Library, EntryPoint="synurang_host_send", CallingConvention=CallingConvention.Cdecl)] internal static extern int Send(IntPtr host, ulong call, byte[] data, uint size);
        [DllImport(Library, EntryPoint="synurang_host_half_close", CallingConvention=CallingConvention.Cdecl)] internal static extern int HalfClose(IntPtr host, ulong call);
        [DllImport(Library, EntryPoint="synurang_host_receive", CallingConvention=CallingConvention.Cdecl)] internal static extern int Receive(IntPtr host, ulong call, out Result result);
        [DllImport(Library, EntryPoint="synurang_host_cancel", CallingConvention=CallingConvention.Cdecl)] internal static extern int Cancel(IntPtr host, ulong call, int code);
        [DllImport(Library, EntryPoint="synurang_host_release", CallingConvention=CallingConvention.Cdecl)] internal static extern void Release(IntPtr host, ulong call);
        [DllImport(Library, EntryPoint="synurang_host_free", CallingConvention=CallingConvention.Cdecl)] internal static extern void Free(IntPtr host, IntPtr data);
        [DllImport(Library, EntryPoint="synurang_host_poll", CallingConvention=CallingConvention.Cdecl)] internal static extern uint Poll(IntPtr host, uint budget);
        [DllImport(Library, EntryPoint="synurang_host_destroy", CallingConvention=CallingConvention.Cdecl)] internal static extern int Destroy(IntPtr host);
    }

    private sealed class ModuleCall : IModuleCall
    {
        private readonly ModuleHost _host;
        private readonly ulong _id;
        private readonly SemaphoreSlim _sender = new(1), _receiver = new(1);
        private readonly CancellationTokenRegistration _registration;
        private readonly Timer? _timer;
        private readonly long _started = Stopwatch.GetTimestamp();
        private readonly TimeSpan? _timeout;
        private bool _released, _finished;
        private ModuleRpcException? _error;
        private byte[]? _pending;
        internal ModuleCall(ModuleHost host, ulong id, ModuleCallOptions options)
        {
            _host = host; _id = id;
            _timeout = options.Timeout;
            _registration = options.CancellationToken.Register(() => Cancel());
            if (options.Timeout is { } timeout)
                _timer = new Timer(_ => DeadlineTick(), null, TimerDelay(timeout), Timeout.InfiniteTimeSpan);
        }

        private static TimeSpan TimerDelay(TimeSpan remaining) => remaining > TimeSpan.FromDays(1) ? TimeSpan.FromDays(1) : remaining;
        private void DeadlineTick()
        {
            lock (_host.Sync)
            {
                if (_released || _finished || _timeout == null) return;
                var remaining = _timeout.Value - Stopwatch.GetElapsedTime(_started);
                if (remaining <= TimeSpan.Zero) Cancel(4);
                else _timer?.Change(TimerDelay(remaining), Timeout.InfiniteTimeSpan);
            }
        }

        public void Cancel(int code = 1)
        {
            if (code < 1 || code > 16) throw new ArgumentOutOfRangeException(nameof(code));
            lock (_host.Sync)
            {
                if (_released || _finished) return;
                _error ??= new ModuleRpcException(code, code == 4 ? "Deadline exceeded" : "Call cancelled");
                Native.Cancel(_host.Handle, _id, code);
                _host.Wake();
            }
        }

        private void Check(CancellationToken token)
        {
            if (token.IsCancellationRequested) Cancel();
            if (_error != null) throw _error;
            if (_host._failure != null) throw _host._failure;
            if (_released) throw new ModuleRpcException(1, "Call closed");
        }

        private async Task Enter(SemaphoreSlim gate, CancellationToken token)
        {
            try { await gate.WaitAsync(token).ConfigureAwait(false); }
            catch (OperationCanceledException) { Cancel(); throw new ModuleRpcException(1, "Call cancelled"); }
        }

        private void ThrowClosedInput(int status)
        {
            // Peek once to preserve a terminal error, keeping any response for
            // the receiver. A rejected write must never drain a response stream.
            if (_pending == null && !_finished && _error == null)
                _pending = ReadLocked(out _);
            if (_error != null) throw _error;
            throw new ModuleRequestClosedException();
        }

        private byte[]? ReadLocked(out bool pending)
        {
            pending = false;
            if (_pending != null)
            {
                var response = _pending;
                _pending = null;
                return response;
            }
            var status = Native.Receive(_host.Handle, _id, out var result);
            byte[] data;
            try
            {
                data = new byte[checked((int)result.Size)];
                if (data.Length != 0) Marshal.Copy(result.Data, data, 0, data.Length);
            }
            finally { if (result.Data != IntPtr.Zero) Native.Free(_host.Handle, result.Data); }
            if (status != 0) throw new ModuleRpcException(13, $"Module receive failed: {status}");
            if (result.Kind == 0) { pending = true; return null; }
            if (result.Kind == 1) return data;
            if (result.Kind != 2) throw new ModuleRpcException(13, "Invalid module read kind");
            _finished = true;
            if (result.Code != 0) { _error = new ModuleRpcException(result.Code, $"RPC failed ({result.Code})", data); throw _error; }
            return null;
        }

        public async Task SendAsync(byte[] message, CancellationToken cancellationToken = default)
        {
            ArgumentNullException.ThrowIfNull(message);
            await Enter(_sender, cancellationToken).ConfigureAwait(false);
            using var registration = cancellationToken.Register(() => Cancel());
            try
            {
                while (true)
                {
                    Task changed;
                    lock (_host.Sync)
                    {
                        changed = _host._changed.Task;
                        Check(cancellationToken);
                        var status = Native.Send(_host.Handle, _id, message, checked((uint)message.Length));
                        if (status == 0) return;
                        if (status != -4 && status != 3)
                        {
                            // A terminal RPC error takes precedence over a closed input queue.
                            ThrowClosedInput(status);
                        }
                    }
                    await changed.ConfigureAwait(false);
                }
            }
            finally { _sender.Release(); }
        }

        public async Task HalfCloseAsync(CancellationToken cancellationToken = default)
        {
            await Enter(_sender, cancellationToken).ConfigureAwait(false);
            try
            {
                lock (_host.Sync)
                {
                    Check(cancellationToken);
                    var status = Native.HalfClose(_host.Handle, _id);
                    if (status != 0) ThrowClosedInput(status);
                }
            }
            finally { _sender.Release(); }
        }

        public async Task<byte[]?> ReceiveAsync(CancellationToken cancellationToken = default)
        {
            await Enter(_receiver, cancellationToken).ConfigureAwait(false);
            using var registration = cancellationToken.Register(() => Cancel());
            try
            {
                while (true)
                {
                    Task changed;
                    lock (_host.Sync)
                    {
                        changed = _host._changed.Task;
                        Check(cancellationToken);
                        if (_finished) return null;
                        var data = ReadLocked(out bool pending);
                        if (!pending) return data;
                    }
                    await changed.ConfigureAwait(false);
                }
            }
            finally { _receiver.Release(); }
        }

        internal void CloseLocked()
        {
            if (_released) return;
            if (!_finished) { _error ??= new ModuleRpcException(1, "Call closed"); Native.Cancel(_host.Handle, _id, 1); }
            Native.Release(_host.Handle, _id);
            _host.Wake();
            _released = true;
            _timer?.Dispose();
            _registration.Unregister();
            _host.Remove(this);
        }
        public ValueTask DisposeAsync() { lock (_host.Sync) CloseLocked(); return ValueTask.CompletedTask; }
    }
}

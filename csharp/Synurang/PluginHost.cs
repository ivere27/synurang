using System;
using System.Collections.Concurrent;
using System.Runtime.InteropServices;
using System.Threading;

namespace Synurang;

/// <summary>
/// Loads and communicates with Synurang plugins (Go/C++/Rust shared libraries).
/// Thread-safe. Caches symbol lookups.
/// No native C bridge required — uses NativeLibrary + Marshal directly.
/// </summary>
public class PluginHost : IDisposable
{
    private readonly IntPtr _handle;
    private readonly FreeDelegate _free;
    private readonly ManualResetEventSlim _noActiveCalls = new(initialState: true);
    private readonly object _disposeLock = new();
    private readonly ConcurrentDictionary<ulong, PluginStream> _openStreams = new();
    private int _activeCalls;
    private volatile bool _disposeRequested;
    private volatile bool _disposed;

    private readonly ConcurrentDictionary<string, InvokeDelegate> _invokers = new();
    private readonly ConcurrentDictionary<string, StreamOpenDelegate> _streamOpeners = new();

    private volatile StreamFuncs? _streamFuncs;

    internal sealed class StreamFuncs
    {
        public readonly StreamSendDelegate Send;
        public readonly StreamRecvDelegate Recv;
        public readonly StreamCloseSendDelegate CloseSend;
        public readonly StreamCloseDelegate Close;

        public StreamFuncs(StreamSendDelegate send, StreamRecvDelegate recv,
                           StreamCloseSendDelegate closeSend, StreamCloseDelegate close)
        {
            Send = send;
            Recv = recv;
            CloseSend = closeSend;
            Close = close;
        }
    }

    private PluginHost(IntPtr handle, FreeDelegate free)
    {
        _handle = handle;
        _free = free;
    }

    /// <summary>
    /// Load a plugin from the given shared library path.
    /// </summary>
    public static PluginHost Load(string path)
    {
        IntPtr handle = NativeLoader.LoadLibrary(path);

        IntPtr freeSym = NativeLoader.GetExport(handle, "Synurang_Free");
        var free = NativeLoader.GetDelegate<FreeDelegate>(freeSym);

        return new PluginHost(handle, free);
    }

    /// <summary>
    /// Invoke a unary RPC method on a service.
    /// Success returns raw protobuf bytes. Negative respLen carries a serialized FfiError payload.
    /// </summary>
    public byte[] Invoke(string serviceName, string method, byte[] data)
    {
        ThrowIfDisposed();
        if (!TryEnterNativeCall(allowDuringDisposal: false))
            throw new PluginClosedError();

        IntPtr methodPtr = IntPtr.Zero;
        IntPtr dataPtr = IntPtr.Zero;
        try
        {
            var invoke = GetInvoker(serviceName);
            methodPtr = NativeLoader.StringToCoTaskMemUTF8(method);
            if (data.Length > 0)
                dataPtr = Marshal.AllocCoTaskMem(data.Length);

            if (data.Length > 0)
                Marshal.Copy(data, 0, dataPtr, data.Length);

            IntPtr resultPtr = invoke(methodPtr, dataPtr, data.Length, out int respLen);
            if (resultPtr == IntPtr.Zero)
            {
                if (respLen == 0)
                    return new byte[0];
                throw new FfiError($"Plugin returned null for {method}");
            }

            try
            {
                int copyLen = respLen < 0 ? -respLen : respLen;
                byte[] payload = new byte[copyLen];
                if (copyLen > 0)
                {
                    Marshal.Copy(resultPtr, payload, 0, copyLen);
                }

                if (respLen < 0)
                    throw FfiError.FromPayload(payload);

                return payload;
            }
            finally
            {
                _free(resultPtr);
            }
        }
        finally
        {
            if (methodPtr != IntPtr.Zero)
                Marshal.FreeCoTaskMem(methodPtr);
            if (dataPtr != IntPtr.Zero)
                Marshal.FreeCoTaskMem(dataPtr);
            ExitNativeCall();
        }
    }

    /// <summary>
    /// Open a streaming RPC to a service.
    /// </summary>
    public PluginStream OpenStream(string serviceName, string method)
    {
        ThrowIfDisposed();
        if (!TryEnterNativeCall(allowDuringDisposal: false))
            throw new PluginClosedError();

        IntPtr methodPtr = IntPtr.Zero;
        try
        {
            var sf = EnsureStreamFuncs();
            var open = GetStreamOpener(serviceName);
            methodPtr = NativeLoader.StringToCoTaskMemUTF8(method);
            ulong streamHandle = open(methodPtr);
            if (streamHandle == 0)
                throw new FfiError($"Failed to open stream for {method}");

            var stream = new PluginStream(this, streamHandle, sf);
            _openStreams[streamHandle] = stream;
            return stream;
        }
        finally
        {
            if (methodPtr != IntPtr.Zero)
                Marshal.FreeCoTaskMem(methodPtr);
            ExitNativeCall();
        }
    }

    public void Dispose()
    {
        lock (_disposeLock)
        {
            if (_disposeRequested || _disposed)
                return;
            _disposeRequested = true;
        }

        foreach (PluginStream stream in _openStreams.Values)
        {
            try
            {
                stream.DisposeFromHost();
            }
            catch
            {
                // Best-effort close during teardown.
            }
        }

        _noActiveCalls.Wait();

        lock (_disposeLock)
        {
            if (_disposed)
                return;
            NativeLoader.FreeLibrary(_handle);
            _disposed = true;
        }
    }

    internal void FreeNative(IntPtr ptr)
    {
        if (ptr != IntPtr.Zero)
            _free(ptr);
    }

    internal bool TryEnterNativeCall(bool allowDuringDisposal)
    {
        while (true)
        {
            if (_disposed)
                return false;
            if (!allowDuringDisposal && _disposeRequested)
                return false;

            int current = NativeLoader.VolatileRead(ref _activeCalls);
            if (Interlocked.CompareExchange(ref _activeCalls, current + 1, current) != current)
                continue;

            _noActiveCalls.Reset();

            if (_disposed || (!allowDuringDisposal && _disposeRequested))
            {
                ExitNativeCall();
                return false;
            }

            return true;
        }
    }

    internal void ExitNativeCall()
    {
        int remaining = Interlocked.Decrement(ref _activeCalls);
        if (remaining <= 0)
        {
            if (remaining < 0)
                Interlocked.Exchange(ref _activeCalls, 0);
            _noActiveCalls.Set();
        }
    }

    internal void UnregisterStream(ulong handle)
    {
        _openStreams.TryRemove(handle, out _);
    }

    private void ThrowIfDisposed()
    {
        if (_disposeRequested || _disposed)
            throw new PluginClosedError();
    }

    private InvokeDelegate GetInvoker(string serviceName)
    {
        return _invokers.GetOrAdd(serviceName, name =>
        {
            string symName = "Synurang_Invoke_" + name;
            IntPtr sym = NativeLoader.GetExport(_handle, symName);
            return NativeLoader.GetDelegate<InvokeDelegate>(sym);
        });
    }

    private StreamOpenDelegate GetStreamOpener(string serviceName)
    {
        return _streamOpeners.GetOrAdd(serviceName, name =>
        {
            string symName = "Synurang_Stream_" + name + "_Open";
            IntPtr sym = NativeLoader.GetExport(_handle, symName);
            return NativeLoader.GetDelegate<StreamOpenDelegate>(sym);
        });
    }

    private StreamFuncs EnsureStreamFuncs()
    {
        if (_streamFuncs != null) return _streamFuncs;

        lock (this)
        {
            if (_streamFuncs != null) return _streamFuncs;

            var send = NativeLoader.GetDelegate<StreamSendDelegate>(
                NativeLoader.GetExport(_handle, "Synurang_Stream_Send"));
            var recv = NativeLoader.GetDelegate<StreamRecvDelegate>(
                NativeLoader.GetExport(_handle, "Synurang_Stream_Recv"));
            var closeSend = NativeLoader.GetDelegate<StreamCloseSendDelegate>(
                NativeLoader.GetExport(_handle, "Synurang_Stream_CloseSend"));
            var close = NativeLoader.GetDelegate<StreamCloseDelegate>(
                NativeLoader.GetExport(_handle, "Synurang_Stream_Close"));

            _streamFuncs = new StreamFuncs(send, recv, closeSend, close);
            return _streamFuncs;
        }
    }
}

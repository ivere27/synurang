using System;
using System.Runtime.InteropServices;
using System.Threading;

namespace Synurang;

/// <summary>
/// A stream handle for streaming RPCs with a Synurang plugin.
/// Supports Send, Recv, CloseSend, and Dispose operations.
/// Recv() returns null on EOF.
/// </summary>
public class PluginStream : IDisposable
{
    private readonly PluginHost _host;
    private readonly ulong _handle;
    private readonly PluginHost.StreamFuncs _funcs;
    private int _disposed;

    internal PluginStream(PluginHost host, ulong handle, PluginHost.StreamFuncs funcs)
    {
        _host = host;
        _handle = handle;
        _funcs = funcs;
    }

    /// <summary>
    /// Send data to the stream.
    /// </summary>
    public void Send(byte[] data)
    {
        ThrowIfClosed();
        if (!_host.TryEnterNativeCall(allowDuringDisposal: false))
            throw new PluginClosedError();

        IntPtr dataPtr = data.Length > 0 ? Marshal.AllocCoTaskMem(data.Length) : IntPtr.Zero;
        try
        {
            if (data.Length > 0)
                Marshal.Copy(data, 0, dataPtr, data.Length);
            int result = _funcs.Send(_handle, dataPtr, data.Length);
            if (result != 0)
                throw new FfiError("Stream send failed with code " + result);
        }
        finally
        {
            if (dataPtr != IntPtr.Zero)
                Marshal.FreeCoTaskMem(dataPtr);
            _host.ExitNativeCall();
        }
    }

    /// <summary>
    /// Receive data from the stream.
    /// Returns raw protobuf response bytes, or null on EOF.
    /// </summary>
    public byte[]? Recv()
    {
        ThrowIfClosed();
        if (!_host.TryEnterNativeCall(allowDuringDisposal: false))
            throw new PluginClosedError();

        try
        {
            IntPtr resultPtr = _funcs.Recv(_handle, out int respLen, out int status);

            if (status == 1)
            {
                _host.FreeNative(resultPtr);
                return null;
            }

            if (status < 0)
            {
                if (resultPtr != IntPtr.Zero && respLen > 0)
                {
                    try
                    {
                        byte[] errBytes = new byte[respLen];
                        Marshal.Copy(resultPtr, errBytes, 0, respLen);
                        throw FfiError.FromPayload(errBytes);
                    }
                    finally
                    {
                        _host.FreeNative(resultPtr);
                    }
                }

                _host.FreeNative(resultPtr);
                throw new FfiError("Stream recv failed with status " + status);
            }

            if (status != 0)
            {
                _host.FreeNative(resultPtr);
                throw new FfiError("Stream recv failed with status " + status);
            }

            try
            {
                if (resultPtr == IntPtr.Zero)
                {
                    if (respLen == 0)
                        return Array.Empty<byte>();
                    throw new FfiError("Plugin returned null for stream recv");
                }

                byte[] payload = new byte[respLen];
                if (payload.Length > 0)
                    Marshal.Copy(resultPtr, payload, 0, payload.Length);
                return payload;
            }
            finally
            {
                _host.FreeNative(resultPtr);
            }
        }
        finally
        {
            _host.ExitNativeCall();
        }
    }

    /// <summary>
    /// Close the send side of the stream.
    /// The stream can still receive data after this.
    /// </summary>
    public void CloseSend()
    {
        ThrowIfClosed();
        if (!_host.TryEnterNativeCall(allowDuringDisposal: false))
            throw new PluginClosedError();

        try
        {
            _funcs.CloseSend(_handle);
        }
        finally
        {
            _host.ExitNativeCall();
        }
    }

    public void Dispose()
    {
        CloseInternal(allowDuringDisposal: true);
    }

    internal void DisposeFromHost()
    {
        CloseInternal(allowDuringDisposal: true);
    }

    private void CloseInternal(bool allowDuringDisposal)
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0)
            return;

        try
        {
            if (_host.TryEnterNativeCall(allowDuringDisposal))
            {
                try
                {
                    _funcs.Close(_handle);
                }
                finally
                {
                    _host.ExitNativeCall();
                }
            }
        }
        finally
        {
            _host.UnregisterStream(_handle);
        }
    }

    private void ThrowIfClosed()
    {
        if (NativeLoader.VolatileRead(ref _disposed) != 0)
            throw new PluginClosedError();
    }
}

using System;
using System.Runtime.InteropServices;
using System.Text;
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
                throw new PluginError("Stream send failed with code " + result);
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
    /// Returns protobuf response bytes (status byte stripped), or null on EOF.
    /// </summary>
    public byte[]? Recv()
    {
        ThrowIfClosed();
        if (!_host.TryEnterNativeCall(allowDuringDisposal: false))
            throw new PluginClosedError();

        try
        {
            IntPtr resultPtr = _funcs.Recv(_handle, out int respLen, out int status);

            // Stream-level status: 0=data, 1=EOF, 2+=error
            if (status == 1)
            {
                _host.FreeNative(resultPtr);
                return null;
            }

            if (status >= 2)
            {
                if (resultPtr != IntPtr.Zero && respLen > 0)
                {
                    try
                    {
                        byte[] errBytes = new byte[respLen];
                        Marshal.Copy(resultPtr, errBytes, 0, respLen);
                        throw new PluginError(Encoding.UTF8.GetString(errBytes));
                    }
                    finally
                    {
                        _host.FreeNative(resultPtr);
                    }
                }

                _host.FreeNative(resultPtr);
                throw new PluginError("Stream recv failed with status " + status);
            }

            // status == 0: data
            if (resultPtr == IntPtr.Zero)
                throw new PluginError("Empty stream response");

            try
            {
                if (respLen <= 0)
                    throw new PluginError("Empty stream response");

                // Check response status byte: 0=success, 1=error
                byte responseStatus = Marshal.ReadByte(resultPtr);
                if (responseStatus == 1)
                {
                    int errLen = respLen - 1;
                    byte[] errBytes = new byte[errLen];
                    if (errLen > 0)
                        Marshal.Copy(IntPtr.Add(resultPtr, 1), errBytes, 0, errLen);
                    throw new PluginError(Encoding.UTF8.GetString(errBytes));
                }

                // Success: copy payload (skip status byte)
                byte[] payload = new byte[respLen - 1];
                if (payload.Length > 0)
                    Marshal.Copy(IntPtr.Add(resultPtr, 1), payload, 0, payload.Length);
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

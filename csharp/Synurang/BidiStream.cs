using System;
using System.Collections.Generic;

namespace Synurang;

/// <summary>
/// A bidirectional stream helper for generated code.
/// Provides Send() for outgoing messages and Responses() for incoming messages.
/// </summary>
public class BidiStream<TReq, TResp> : IDisposable
{
    private readonly PluginStream _stream;
    private readonly Func<TReq, byte[]> _serializer;
    private readonly Func<byte[], TResp> _deserializer;
    private volatile bool _disposed;

    public BidiStream(PluginStream stream, Func<TReq, byte[]> serializer, Func<byte[], TResp> deserializer)
    {
        _stream = stream;
        _serializer = serializer;
        _deserializer = deserializer;
    }

    /// <summary>
    /// Send a request message.
    /// </summary>
    public void Send(TReq request)
    {
        _stream.Send(_serializer(request));
    }

    /// <summary>
    /// Close the send side. Call this after sending all requests.
    /// </summary>
    public void CloseSend()
    {
        _stream.CloseSend();
    }

    /// <summary>
    /// Returns a blocking enumerable over response messages.
    /// </summary>
    public IEnumerable<TResp> Responses()
    {
        while (true)
        {
            byte[]? data = _stream.Recv();
            if (data == null) yield break;
            yield return _deserializer(data);
        }
    }

    public void Dispose()
    {
        if (!_disposed)
        {
            _disposed = true;
            _stream.Dispose();
        }
    }
}

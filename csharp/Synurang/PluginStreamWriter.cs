using System;
using System.Threading;
using System.Threading.Tasks;
using Grpc.Core;

namespace Synurang;

/// <summary>
/// IClientStreamWriter implementation that writes to a PluginStream.
/// Used by SynurangCallInvoker for client-streaming and bidi RPCs.
/// </summary>
internal class PluginStreamWriter<T> : IClientStreamWriter<T>
{
    private readonly PluginStream _stream;
    private readonly Func<T, byte[]> _serializer;
    private readonly CancellationToken _callCancellationToken;
    private readonly Action<Exception> _onError;
    private readonly Func<Exception, Exception> _exceptionMapper;

    public PluginStreamWriter(
        PluginStream stream,
        Func<T, byte[]> serializer,
        CancellationToken callCancellationToken,
        Action<Exception> onError,
        Func<Exception, Exception> exceptionMapper)
    {
        _stream = stream;
        _serializer = serializer;
        _callCancellationToken = callCancellationToken;
        _onError = onError;
        _exceptionMapper = exceptionMapper;
    }

    public WriteOptions? WriteOptions { get; set; }

    public Task WriteAsync(T message)
    {
        if (_callCancellationToken.IsCancellationRequested)
        {
            Exception mapped = _exceptionMapper(new OperationCanceledException(_callCancellationToken));
            _onError(mapped);
            return Task.FromException(mapped);
        }

        try
        {
            _stream.Send(_serializer(message));
            return Task.CompletedTask;
        }
        catch (Exception ex)
        {
            Exception mapped = _exceptionMapper(ex);
            _onError(mapped);
            return Task.FromException(mapped);
        }
    }

    public Task CompleteAsync()
    {
        if (_callCancellationToken.IsCancellationRequested)
        {
            Exception mapped = _exceptionMapper(new OperationCanceledException(_callCancellationToken));
            _onError(mapped);
            return Task.FromException(mapped);
        }

        try
        {
            _stream.CloseSend();
            return Task.CompletedTask;
        }
        catch (Exception ex)
        {
            Exception mapped = _exceptionMapper(ex);
            _onError(mapped);
            return Task.FromException(mapped);
        }
    }
}

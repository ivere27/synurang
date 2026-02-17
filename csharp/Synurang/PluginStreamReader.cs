using System;
using System.Threading;
using System.Threading.Tasks;
using Grpc.Core;

namespace Synurang;

/// <summary>
/// IAsyncStreamReader implementation that reads from a PluginStream.
/// Used by SynurangCallInvoker for server-streaming and bidi RPCs.
/// </summary>
internal class PluginStreamReader<T> : IAsyncStreamReader<T>
{
    private readonly PluginStream _stream;
    private readonly Func<byte[], T> _deserializer;
    private readonly CancellationToken _callCancellationToken;
    private readonly Action _onCompleted;
    private readonly Action<Exception> _onError;
    private readonly Func<Exception, Exception> _exceptionMapper;
    private int _done;
    private T? _current;

    public PluginStreamReader(
        PluginStream stream,
        Func<byte[], T> deserializer,
        CancellationToken callCancellationToken,
        Action onCompleted,
        Action<Exception> onError,
        Func<Exception, Exception> exceptionMapper)
    {
        _stream = stream;
        _deserializer = deserializer;
        _callCancellationToken = callCancellationToken;
        _onCompleted = onCompleted;
        _onError = onError;
        _exceptionMapper = exceptionMapper;
    }

    public T Current => _current!;

    public Task<bool> MoveNext(CancellationToken cancellationToken)
    {
        if (cancellationToken.IsCancellationRequested)
            return Task.FromCanceled<bool>(cancellationToken);

        if (_callCancellationToken.IsCancellationRequested)
        {
            Exception mapped = _exceptionMapper(new OperationCanceledException(_callCancellationToken));
            FailOnce(mapped);
            return Task.FromException<bool>(mapped);
        }

        try
        {
            byte[]? data = _stream.Recv();
            if (data == null)
            {
                CompleteOnce();
                return Task.FromResult(false);
            }

            _current = _deserializer(data);
            return Task.FromResult(true);
        }
        catch (Exception ex)
        {
            Exception mapped = _exceptionMapper(ex);
            FailOnce(mapped);
            return Task.FromException<bool>(mapped);
        }
    }

    private void CompleteOnce()
    {
        if (Interlocked.CompareExchange(ref _done, 1, 0) == 0)
            _onCompleted();
    }

    private void FailOnce(Exception ex)
    {
        if (Interlocked.CompareExchange(ref _done, 1, 0) == 0)
            _onError(ex);
    }
}

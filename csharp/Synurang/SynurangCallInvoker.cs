using System;
using System.Threading;
using System.Threading.Tasks;
using Grpc.Core;

namespace Synurang;

/// <summary>
/// Drop-in gRPC CallInvoker backed by a Synurang plugin (shared library).
/// Enables using standard protoc-gen-grpc-csharp generated stubs over FFI transport.
/// All four RPC types are supported.
///
/// Usage:
///   var plugin = PluginHost.Load("./libplugin.so");
///   var invoker = new SynurangCallInvoker(plugin, "GoGreeterService");
///   var client = new Greeter.GreeterClient(invoker);
///   var reply = await client.SayHelloAsync(request);
/// </summary>
public class SynurangCallInvoker : CallInvoker
{
    private readonly PluginHost _host;
    private readonly string _serviceName;

    private sealed class CallState
    {
        private readonly object _lock = new();
        private bool _completed;
        private Status _status = new(StatusCode.Unknown, "Call has not completed.");
        private Metadata _trailers = new();

        public Status Status
        {
            get
            {
                lock (_lock)
                    return _status;
            }
        }

        public Metadata Trailers
        {
            get
            {
                lock (_lock)
                    return _trailers;
            }
        }

        public void TryComplete(Status status, Metadata? trailers = null)
        {
            lock (_lock)
            {
                if (_completed)
                    return;

                _completed = true;
                _status = status;
                _trailers = trailers ?? new Metadata();
            }
        }
    }

    public SynurangCallInvoker(PluginHost host, string serviceName)
    {
        _host = host;
        _serviceName = serviceName;
    }

    public override TResponse BlockingUnaryCall<TRequest, TResponse>(
        Method<TRequest, TResponse> method, string? host, CallOptions options, TRequest request)
    {
        using var cts = CreateCallCancellationSource(options);
        CancellationToken callToken = cts?.Token ?? options.CancellationToken;

        try
        {
            ThrowIfCancelled(options, callToken);
            byte[] reqData = method.RequestMarshaller.Serializer(request);
            byte[] respData = _host.Invoke(_serviceName, method.FullName, reqData);
            ThrowIfCancelled(options, callToken);
            return method.ResponseMarshaller.Deserializer(respData);
        }
        catch (Exception ex)
        {
            throw MapException(ex, options, callToken);
        }
    }

    public override AsyncUnaryCall<TResponse> AsyncUnaryCall<TRequest, TResponse>(
        Method<TRequest, TResponse> method, string? host, CallOptions options, TRequest request)
    {
        var state = new CallState();
        var cts = CreateCallCancellationSource(options);
        CancellationToken callToken = cts?.Token ?? options.CancellationToken;

        var responseTask = Task.Run(() =>
        {
            try
            {
                ThrowIfCancelled(options, callToken);
                byte[] reqData = method.RequestMarshaller.Serializer(request);
                byte[] respData = _host.Invoke(_serviceName, method.FullName, reqData);
                ThrowIfCancelled(options, callToken);
                TResponse response = method.ResponseMarshaller.Deserializer(respData);
                state.TryComplete(Status.DefaultSuccess);
                return response;
            }
            catch (Exception ex)
            {
                RpcException mapped = MapException(ex, options, callToken);
                state.TryComplete(mapped.Status);
                throw mapped;
            }
        });

        return new AsyncUnaryCall<TResponse>(
            responseTask,
            Task.FromResult(new Metadata()),
            () => state.Status,
            () => state.Trailers,
            () =>
            {
                cts?.Cancel();
                state.TryComplete(CancellationStatus(options));
                cts?.Dispose();
            });
    }

    public override AsyncServerStreamingCall<TResponse> AsyncServerStreamingCall<TRequest, TResponse>(
        Method<TRequest, TResponse> method, string? host, CallOptions options, TRequest request)
    {
        var state = new CallState();
        var cts = CreateCallCancellationSource(options);
        CancellationToken callToken = cts?.Token ?? options.CancellationToken;

        PluginStream stream;
        try
        {
            ThrowIfCancelled(options, callToken);
            stream = _host.OpenStream(_serviceName, method.FullName);
            stream.Send(method.RequestMarshaller.Serializer(request));
            stream.CloseSend();
        }
        catch (Exception ex)
        {
            cts?.Dispose();
            throw MapException(ex, options, callToken);
        }

        CancellationTokenRegistration cancellationRegistration =
            RegisterCallCancellation(callToken, stream, state, options);

        var reader = new PluginStreamReader<TResponse>(
            stream,
            method.ResponseMarshaller.Deserializer,
            callToken,
            onCompleted: () => state.TryComplete(Status.DefaultSuccess),
            onError: ex =>
            {
                RpcException mapped = MapException(ex, options, callToken);
                state.TryComplete(mapped.Status);
            },
            exceptionMapper: ex => MapException(ex, options, callToken));

        return new AsyncServerStreamingCall<TResponse>(
            reader,
            Task.FromResult(new Metadata()),
            () => state.Status,
            () => state.Trailers,
            () =>
            {
                cancellationRegistration.Dispose();
                cts?.Cancel();
                state.TryComplete(CancellationStatus(options));
                try { stream.Dispose(); } catch { /* ignore */ }
                cts?.Dispose();
            });
    }

    public override AsyncClientStreamingCall<TRequest, TResponse> AsyncClientStreamingCall<TRequest, TResponse>(
        Method<TRequest, TResponse> method, string? host, CallOptions options)
    {
        var state = new CallState();
        var cts = CreateCallCancellationSource(options);
        CancellationToken callToken = cts?.Token ?? options.CancellationToken;

        PluginStream stream;
        try
        {
            ThrowIfCancelled(options, callToken);
            stream = _host.OpenStream(_serviceName, method.FullName);
        }
        catch (Exception ex)
        {
            cts?.Dispose();
            throw MapException(ex, options, callToken);
        }

        CancellationTokenRegistration cancellationRegistration =
            RegisterCallCancellation(callToken, stream, state, options);

        var writer = new PluginStreamWriter<TRequest>(
            stream,
            method.RequestMarshaller.Serializer,
            callToken,
            onError: ex =>
            {
                RpcException mapped = MapException(ex, options, callToken);
                state.TryComplete(mapped.Status);
            },
            exceptionMapper: ex => MapException(ex, options, callToken));

        // The response task blocks on Recv until the server responds
        // (which happens after the client calls CompleteAsync / CloseSend).
        var responseTask = Task.Run(() =>
        {
            try
            {
                ThrowIfCancelled(options, callToken);
                byte[]? data = stream.Recv();
                if (data == null)
                    throw new RpcException(new Status(StatusCode.Internal, "No response from client streaming RPC"));

                ThrowIfCancelled(options, callToken);
                TResponse response = method.ResponseMarshaller.Deserializer(data);
                state.TryComplete(Status.DefaultSuccess);
                return response;
            }
            catch (Exception ex)
            {
                RpcException mapped = MapException(ex, options, callToken);
                state.TryComplete(mapped.Status);
                throw mapped;
            }
        });

        return new AsyncClientStreamingCall<TRequest, TResponse>(
            writer,
            responseTask,
            Task.FromResult(new Metadata()),
            () => state.Status,
            () => state.Trailers,
            () =>
            {
                cancellationRegistration.Dispose();
                cts?.Cancel();
                state.TryComplete(CancellationStatus(options));
                try { stream.Dispose(); } catch { /* ignore */ }
                cts?.Dispose();
            });
    }

    public override AsyncDuplexStreamingCall<TRequest, TResponse> AsyncDuplexStreamingCall<TRequest, TResponse>(
        Method<TRequest, TResponse> method, string? host, CallOptions options)
    {
        var state = new CallState();
        var cts = CreateCallCancellationSource(options);
        CancellationToken callToken = cts?.Token ?? options.CancellationToken;

        PluginStream stream;
        try
        {
            ThrowIfCancelled(options, callToken);
            stream = _host.OpenStream(_serviceName, method.FullName);
        }
        catch (Exception ex)
        {
            cts?.Dispose();
            throw MapException(ex, options, callToken);
        }

        CancellationTokenRegistration cancellationRegistration =
            RegisterCallCancellation(callToken, stream, state, options);

        var writer = new PluginStreamWriter<TRequest>(
            stream,
            method.RequestMarshaller.Serializer,
            callToken,
            onError: ex =>
            {
                RpcException mapped = MapException(ex, options, callToken);
                state.TryComplete(mapped.Status);
            },
            exceptionMapper: ex => MapException(ex, options, callToken));

        var reader = new PluginStreamReader<TResponse>(
            stream,
            method.ResponseMarshaller.Deserializer,
            callToken,
            onCompleted: () => state.TryComplete(Status.DefaultSuccess),
            onError: ex =>
            {
                RpcException mapped = MapException(ex, options, callToken);
                state.TryComplete(mapped.Status);
            },
            exceptionMapper: ex => MapException(ex, options, callToken));

        return new AsyncDuplexStreamingCall<TRequest, TResponse>(
            writer,
            reader,
            Task.FromResult(new Metadata()),
            () => state.Status,
            () => state.Trailers,
            () =>
            {
                cancellationRegistration.Dispose();
                cts?.Cancel();
                state.TryComplete(CancellationStatus(options));
                try { stream.Dispose(); } catch { /* ignore */ }
                cts?.Dispose();
            });
    }

    private static CancellationTokenRegistration RegisterCallCancellation(
        CancellationToken callToken,
        PluginStream stream,
        CallState state,
        CallOptions options)
    {
        if (!callToken.CanBeCanceled)
            return default;

        return callToken.Register(() =>
        {
            state.TryComplete(CancellationStatus(options));
            try { stream.Dispose(); } catch { /* ignore */ }
        });
    }

    private sealed class CompositeCancellationSource : IDisposable
    {
        private readonly CancellationTokenSource _primary;
        private readonly CancellationTokenSource? _deadline;

        public CompositeCancellationSource(CancellationTokenSource primary, CancellationTokenSource? deadline)
        {
            _primary = primary;
            _deadline = deadline;
        }

        public CancellationToken Token => _primary.Token;
        public void Cancel() => _primary.Cancel();

        public void Dispose()
        {
            _primary.Dispose();
            _deadline?.Dispose();
        }
    }

    private static CompositeCancellationSource? CreateCallCancellationSource(CallOptions options)
    {
        CancellationTokenSource? deadlineCts = null;
        if (options.Deadline is DateTime deadline)
        {
            TimeSpan due = deadline - DateTime.UtcNow;
            deadlineCts = due <= TimeSpan.Zero
                ? new CancellationTokenSource(0)
                : new CancellationTokenSource(due);
        }

        if (deadlineCts != null && options.CancellationToken.CanBeCanceled)
        {
            var linked = CancellationTokenSource.CreateLinkedTokenSource(
                options.CancellationToken,
                deadlineCts.Token);
            return new CompositeCancellationSource(linked, deadlineCts);
        }

        if (deadlineCts != null)
            return new CompositeCancellationSource(deadlineCts, null);

        if (options.CancellationToken.CanBeCanceled)
            return new CompositeCancellationSource(
                CancellationTokenSource.CreateLinkedTokenSource(options.CancellationToken), null);

        return null;
    }

    private static void ThrowIfCancelled(CallOptions options, CancellationToken callToken)
    {
        if (options.Deadline is DateTime deadline && DateTime.UtcNow >= deadline)
            throw new RpcException(new Status(StatusCode.DeadlineExceeded, "Deadline exceeded"));

        if (callToken.IsCancellationRequested)
            throw new RpcException(CancellationStatus(options));
    }

    private static Status CancellationStatus(CallOptions options)
    {
        if (options.Deadline is DateTime deadline && DateTime.UtcNow >= deadline)
            return new Status(StatusCode.DeadlineExceeded, "Deadline exceeded");
        return new Status(StatusCode.Cancelled, "Call cancelled");
    }

    private static RpcException MapException(
        Exception ex,
        CallOptions options,
        CancellationToken callToken)
    {
        if (ex is RpcException rpcEx)
            return rpcEx;

        if (callToken.IsCancellationRequested || ex is OperationCanceledException)
            return new RpcException(CancellationStatus(options));

        if (ex is PluginError pluginError)
            return new RpcException(new Status(StatusCode.Internal, pluginError.Message));

        return new RpcException(new Status(StatusCode.Unknown, ex.Message));
    }
}

using Grpc.Core;

namespace Synurang;

/// <summary>Optional gRPC generated-client adapter. The core module package has no gRPC dependency.</summary>
public sealed class ModuleCallInvoker : CallInvoker
{
    private readonly IModuleTransport _transport;
    public ModuleCallInvoker(IModuleTransport transport) { _transport = transport; }

    private sealed class State
    {
        internal readonly IModuleCall Call;
        private readonly object _sync = new();
        private Status? _status;
        private Metadata _trailers = new();
        internal State(IModuleCall call) { Call = call; }
        internal Status Status { get { lock (_sync) return _status ?? throw new InvalidOperationException("Call has not finished"); } }
        internal Metadata Trailers { get { lock (_sync) { _ = Status; return _trailers; } } }
        internal void Complete() { lock (_sync) _status ??= Grpc.Core.Status.DefaultSuccess; }
        internal RpcException Fail(Exception error)
        {
            var status = error is ModuleRpcException rpc ? new Status((StatusCode)rpc.Code, rpc.Message) :
                error is OperationCanceledException ? new Status(StatusCode.Cancelled, "Call cancelled") :
                new Status(StatusCode.Internal, error.Message);
            var trailers = new Metadata();
            if (error is ModuleRpcException { Details.Length: > 0 } details)
                trailers.Add("synurang-error-bin", details.Details);
            lock (_sync) { _status ??= status; _trailers = trailers; }
            return new RpcException(status, trailers);
        }
        internal void Dispose() { Call.Cancel(); _ = Call.DisposeAsync(); }
    }

    private State Open<TRequest, TResponse>(Method<TRequest, TResponse> method, CallOptions options)
        where TRequest : class where TResponse : class
    {
        TimeSpan? timeout = options.Deadline is { } deadline ? deadline.ToUniversalTime() - DateTime.UtcNow : null;
        if (timeout < TimeSpan.Zero) timeout = TimeSpan.Zero;
        return new State(_transport.Open(method.FullName,
            method.Type is MethodType.ClientStreaming or MethodType.DuplexStreaming,
            method.Type is MethodType.ServerStreaming or MethodType.DuplexStreaming,
            new ModuleCallOptions(options.CancellationToken, timeout)));
    }

    private static async Task<TResponse> One<TRequest, TResponse>(State state, Method<TRequest, TResponse> method,
        TRequest? request = null) where TRequest : class where TResponse : class
    {
        try
        {
            if (request != null)
            {
                await state.Call.SendAsync(method.RequestMarshaller.Serializer(request)).ConfigureAwait(false);
                await state.Call.HalfCloseAsync().ConfigureAwait(false);
            }
            var data = await state.Call.ReceiveAsync().ConfigureAwait(false);
            if (data == null || await state.Call.ReceiveAsync().ConfigureAwait(false) != null)
                throw new ModuleRpcException(13, "Invalid unary response count");
            var response = method.ResponseMarshaller.Deserializer(data);
            state.Complete();
            return response;
        }
        catch (Exception error) { throw state.Fail(error); }
        finally { await state.Call.DisposeAsync().ConfigureAwait(false); }
    }

    public override TResponse BlockingUnaryCall<TRequest, TResponse>(Method<TRequest, TResponse> method,
        string? host, CallOptions options, TRequest request) => AsyncUnaryCall(method, host, options, request).ResponseAsync.GetAwaiter().GetResult();

    public override AsyncUnaryCall<TResponse> AsyncUnaryCall<TRequest, TResponse>(Method<TRequest, TResponse> method,
        string? host, CallOptions options, TRequest request)
    {
        var state = Open(method, options);
        return new(One(state, method, request), Task.FromResult(new Metadata()), () => state.Status, () => state.Trailers, state.Dispose);
    }

    private sealed class Writer<T> : IClientStreamWriter<T>
    {
        private readonly State _state;
        private readonly Func<T, byte[]> _encode;
        public WriteOptions? WriteOptions { get; set; }
        internal Writer(State state, Func<T, byte[]> encode) { _state = state; _encode = encode; }
        public async Task WriteAsync(T message)
        { try { await _state.Call.SendAsync(_encode(message)).ConfigureAwait(false); } catch (ModuleRequestClosedException) { throw; } catch (Exception e) { throw _state.Fail(e); } }
        public async Task CompleteAsync()
        { try { await _state.Call.HalfCloseAsync().ConfigureAwait(false); } catch (ModuleRequestClosedException) { throw; } catch (Exception e) { throw _state.Fail(e); } }
    }

    private sealed class Reader<T> : IAsyncStreamReader<T>
    {
        private readonly State _state;
        private readonly Func<byte[], T> _decode;
        private readonly Task _started;
        public T Current { get; private set; } = default!;
        internal Reader(State state, Func<byte[], T> decode, Task? started = null)
        { _state = state; _decode = decode; _started = started ?? Task.CompletedTask; }
        public async Task<bool> MoveNext(CancellationToken token)
        {
            try
            {
                await _started.ConfigureAwait(false);
                var data = await _state.Call.ReceiveAsync(token).ConfigureAwait(false);
                if (data == null) { _state.Complete(); await _state.Call.DisposeAsync().ConfigureAwait(false); return false; }
                Current = _decode(data); return true;
            }
            catch (Exception e) { await _state.Call.DisposeAsync().ConfigureAwait(false); throw _state.Fail(e); }
        }
    }

    public override AsyncServerStreamingCall<TResponse> AsyncServerStreamingCall<TRequest, TResponse>(Method<TRequest, TResponse> method,
        string? host, CallOptions options, TRequest request)
    {
        var state = Open(method, options);
        async Task Start()
        {
            await state.Call.SendAsync(method.RequestMarshaller.Serializer(request)).ConfigureAwait(false);
            await state.Call.HalfCloseAsync().ConfigureAwait(false);
        }
        return new(new Reader<TResponse>(state, method.ResponseMarshaller.Deserializer, Start()), Task.FromResult(new Metadata()),
            () => state.Status, () => state.Trailers, state.Dispose);
    }

    public override AsyncClientStreamingCall<TRequest, TResponse> AsyncClientStreamingCall<TRequest, TResponse>(Method<TRequest, TResponse> method,
        string? host, CallOptions options)
    {
        var state = Open(method, options);
        return new(new Writer<TRequest>(state, method.RequestMarshaller.Serializer), One(state, method), Task.FromResult(new Metadata()),
            () => state.Status, () => state.Trailers, state.Dispose);
    }

    public override AsyncDuplexStreamingCall<TRequest, TResponse> AsyncDuplexStreamingCall<TRequest, TResponse>(Method<TRequest, TResponse> method,
        string? host, CallOptions options)
    {
        var state = Open(method, options);
        return new(new Writer<TRequest>(state, method.RequestMarshaller.Serializer), new Reader<TResponse>(state, method.ResponseMarshaller.Deserializer),
            Task.FromResult(new Metadata()), () => state.Status, () => state.Trailers, state.Dispose);
    }
}

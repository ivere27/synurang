using Grpc.Core;
using Synurang;

static class Test
{
    private const string Prefix = "/synurang.test.Calls/";
    private static byte[] Encode(int value)
    {
        if (value == 0) return Array.Empty<byte>();
        var bytes = new List<byte> { 8 };
        ulong n = unchecked((ulong)(long)value);
        while (n >= 128) { bytes.Add((byte)((n & 127) | 128)); n >>= 7; }
        bytes.Add((byte)n);
        return bytes.ToArray();
    }
    private static int Decode(byte[] data)
    {
        if (data.Length == 0) return 0;
        if (data[0] != 8) throw new Exception("Invalid Value protobuf");
        ulong n = 0; int shift = 0;
        foreach (var b in data.Skip(1)) { n |= (ulong)(b & 127) << shift; if (b < 128) return unchecked((int)n); shift += 7; }
        throw new Exception("Invalid Value protobuf");
    }
    private static void Equal<T>(T actual, T expected)
    { if (!EqualityComparer<T>.Default.Equals(actual, expected)) throw new Exception($"Expected {expected}, got {actual}"); }
    private static async Task Fails(Task task, int code, bool details = false)
    {
        try { await task; }
        catch (ModuleRpcException error) { Equal(error.Code, code); if (details && error.Details.Length == 0) throw new Exception("Missing error details"); return; }
        throw new Exception($"Expected status {code}");
    }
    private static Task<int> Unary(IModuleTransport host, int value, string method = "Unary", ModuleCallOptions? options = null) =>
        ModuleClient.UnaryAsync(host, Prefix + method, value, Encode, Decode, options);
    private static async IAsyncEnumerable<int> Inputs(int count)
    { for (int i = 0; i < count; ++i) { yield return i; await Task.CompletedTask; } }

    public static async Task Main(string[] args)
    {
        await ReleaseBacklog();
        if (args.Length == 0) throw new ArgumentException("Pass native module paths");
        foreach (var path in args)
        {
            await using var host = ModuleHost.Load(path);
            await using var other = ModuleHost.Load(path);
            Equal(await Unary(host, 0), 0);
            Equal(await Unary(host, 42), 42);
#if GENERATED_CONFORMANCE
            await Generated(host);
#endif
            int count = 0;
            await foreach (var value in ModuleClient.ServerStreamAsync(host, Prefix + "Server", 50, Encode, Decode)) Equal(value, count++);
            Equal(count, 50);
            Equal(await ModuleClient.ClientStreamAsync(host, Prefix + "Client", Inputs(50), Encode, Decode), 1225);
            await EarlyCompletion(host);
            await using (var call = host.Open(Prefix + "Bidi", true, true))
            {
                for (int n = 0; n < 30; ++n)
                {
                    await call.SendAsync(Encode(n));
                    Equal(Decode((await call.ReceiveAsync())!), n); // Before half-close.
                }
                async Task Send()
                { for (int n = 0; n < 500; ++n) await call.SendAsync(Encode(n)); await call.HalfCloseAsync(); }
                async Task Receive()
                { for (int n = 0; n < 500; ++n) Equal(Decode((await call.ReceiveAsync())!), n); Equal(await call.ReceiveAsync(), null); }
                await Task.WhenAll(Send(), Receive());
            }
            var results = await Task.WhenAll(Enumerable.Range(0, 25).Select(n => Unary(host, n)));
            for (int n = 0; n < results.Length; ++n) Equal(results[n], n);
            Equal(await Unary(other, 123), 123);
            await Fails(Unary(host, 0, "Fail"), 7, true);
            await Fails(Unary(host, -1), 7, true); // A message followed by an error must reject unary.
            await using (var unknown = host.Open("/unknown.Service/Method", false, false)) await Fails(unknown.ReceiveAsync(), 12);
            using var cancellation = new CancellationTokenSource();
            var waiting = Unary(host, 0, "Wait", new(cancellation.Token));
            cancellation.CancelAfter(10);
            await Fails(waiting, 1);
            await Fails(Unary(host, 0, "Wait", new(Timeout: TimeSpan.FromMilliseconds(20))), 4);
            await Fails(Unary(host, 0, "Wait", new(Timeout: TimeSpan.Zero)), 4);
            await Fails(Unary(host, 0, "Wait", new(cancellation.Token)), 1);
            await foreach (var value in ModuleClient.ServerStreamAsync(host, Prefix + "Server", 10000, Encode, Decode)) { Equal(value, 0); break; }
            await Grpc(host);
            var pending = Fails(Unary(host, 0, "Wait"), 1);
            await Task.Delay(5);
            await host.DisposeAsync();
            await pending;
            await Fails(Unary(host, 0), 14);
            Equal(await Unary(other, 9), 9);
            Console.WriteLine($"C# module + gRPC conformance passed: {path}");
        }
    }

    private sealed record Box(int Value);

    private static async Task ReleaseBacklog() {
        var module = Environment.GetEnvironmentVariable("SYNURANG_TEST_RELEASE_MODULE");
        if (module == null) return;
        var marker = Path.GetTempFileName();
        try {
            await using var host = ModuleHost.Load(module);
            await using var target = host.Open("/test.Release/Watch", false, true);
            await target.SendAsync(System.Text.Encoding.UTF8.GetBytes(marker));
            Equal((await target.ReceiveAsync())!.Length, 0);
            var peers = Enumerable.Range(0, 512).Select(_ => host.Open("/test.Release/Watch", false, true)).ToArray();
            await target.DisposeAsync();
            var started = System.Diagnostics.Stopwatch.StartNew();
            while (File.ReadAllText(marker) != "CD" && started.Elapsed < TimeSpan.FromSeconds(2)) await Task.Delay(5);
            Equal(File.ReadAllText(marker), "CD");
            await host.DisposeAsync();
            foreach (var peer in peers) await peer.DisposeAsync();
            Console.WriteLine("C# release drains through a ready queue backlog");
        } finally { File.Delete(marker); }
    }
    private sealed class SuspendedInput : IAsyncEnumerable<int>, IAsyncEnumerator<int>
    {
        private readonly TaskCompletionSource<bool> _next = new(TaskCreationOptions.RunContinuationsAsynchronously);
        private bool _first = true;
        public bool Disposed { get; private set; }
        public int Current => -2;
        public IAsyncEnumerator<int> GetAsyncEnumerator(CancellationToken token = default) => this;
        public ValueTask<bool> MoveNextAsync()
        { if (_first) { _first = false; return ValueTask.FromResult(true); } return new(_next.Task); }
        public ValueTask DisposeAsync() { Disposed = true; _next.TrySetResult(false); return ValueTask.CompletedTask; }
    }
    private static async Task EarlyCompletion(ModuleHost host)
    {
        async IAsyncEnumerable<int> Many()
        { yield return -2; for (int n = 0; n < 100; ++n) { yield return n; await Task.CompletedTask; } }
        Equal(await ModuleClient.ClientStreamAsync(host, Prefix + "Client", Many(), Encode, Decode).WaitAsync(TimeSpan.FromSeconds(2)), 42);
        var suspended = new SuspendedInput();
        Equal(await ModuleClient.ClientStreamAsync(host, Prefix + "Client", suspended, Encode, Decode).WaitAsync(TimeSpan.FromSeconds(2)), 42);
        for (int n = 0; n < 100 && !suspended.Disposed; ++n) await Task.Delay(1);
        Equal(suspended.Disposed, true);
        await using var stream = host.Open(Prefix + "Server", false, true);
        await stream.SendAsync(Encode(100)); await stream.HalfCloseAsync();
        try { await stream.SendAsync(Encode(0)); throw new Exception("Expected closed request side"); }
        catch (ModuleRequestClosedException) { }
        for (int n = 0; n < 100; ++n) Equal(Decode((await stream.ReceiveAsync())!), n);
        Equal(await stream.ReceiveAsync(), null);
    }
#if GENERATED_CONFORMANCE
    private static async Task Generated(ModuleHost host)
    {
        var client = new Synurang.Test.CallsClient(host);
        Equal((await client.UnaryAsync(new Synurang.Test.Value { Value_ = 42 })).Value_, 42);
        int count = 0;
        await foreach (var value in client.Server(new Synurang.Test.Value { Value_ = 50 })) Equal(value.Value_, count++);
        Equal(count, 50);
        async IAsyncEnumerable<Synurang.Test.Value> Requests()
        { for (int n = 0; n < 50; ++n) { yield return new Synurang.Test.Value { Value_ = n }; await Task.CompletedTask; } }
        Equal((await client.ClientAsync(Requests())).Value_, 1225);
        await using var bidi = client.Bidi();
        await using var responses = bidi.ReadAllAsync().GetAsyncEnumerator();
        for (int n = 0; n < 30; ++n)
        {
            await bidi.SendAsync(new Synurang.Test.Value { Value_ = n });
            Equal(await responses.MoveNextAsync(), true);
            Equal(responses.Current.Value_, n);
        }
        await bidi.HalfCloseAsync();
        Equal(await responses.MoveNextAsync(), false);
    }
#endif
    private static async Task Grpc(ModuleHost host)
    {
        var invoker = new ModuleCallInvoker(host);
        var codec = Marshallers.Create<Box>(box => Encode(box.Value), bytes => new Box(Decode(bytes)));
        Method<Box, Box> Method(string name, MethodType type) => new(type, "synurang.test.Calls", name, codec, codec);
        using (var unary = invoker.AsyncUnaryCall(Method("Unary", MethodType.Unary), null, default, new Box(42)))
        { Equal((await unary.ResponseAsync).Value, 42); Equal(unary.GetStatus().StatusCode, StatusCode.OK); }
        using (var server = invoker.AsyncServerStreamingCall(Method("Server", MethodType.ServerStreaming), null, default, new Box(50)))
        {
            int n = 0;
            while (await server.ResponseStream.MoveNext(default)) Equal(server.ResponseStream.Current.Value, n++);
            Equal(n, 50); Equal(server.GetStatus().StatusCode, StatusCode.OK);
        }
        using (var client = invoker.AsyncClientStreamingCall(Method("Client", MethodType.ClientStreaming), null, default))
        {
            for (int n = 0; n < 50; ++n) await client.RequestStream.WriteAsync(new Box(n));
            await client.RequestStream.CompleteAsync();
            Equal((await client.ResponseAsync).Value, 1225);
        }
        using (var bidi = invoker.AsyncDuplexStreamingCall(Method("Bidi", MethodType.DuplexStreaming), null, default))
        {
            for (int n = 0; n < 30; ++n)
            {
                await bidi.RequestStream.WriteAsync(new Box(n));
                Equal(await bidi.ResponseStream.MoveNext(default), true);
                Equal(bidi.ResponseStream.Current.Value, n);
            }
            await bidi.RequestStream.CompleteAsync();
            Equal(await bidi.ResponseStream.MoveNext(default), false);
        }
        using (var fail = invoker.AsyncUnaryCall(Method("Fail", MethodType.Unary), null, default, new Box(0)))
        {
            try { await fail.ResponseAsync; throw new Exception("Expected gRPC permission denied"); }
            catch (RpcException error) { Equal(error.StatusCode, StatusCode.PermissionDenied); Equal(error.Trailers.GetValueBytes("synurang-error-bin")!.Length > 0, true); }
        }
        using (var wait = invoker.AsyncUnaryCall(Method("Wait", MethodType.Unary), null,
                   new CallOptions(deadline: DateTime.UtcNow.AddMilliseconds(20)), new Box(0)))
        {
            try { await wait.ResponseAsync; throw new Exception("Expected gRPC deadline"); }
            catch (RpcException error) { Equal(error.StatusCode, StatusCode.DeadlineExceeded); }
        }
    }
}

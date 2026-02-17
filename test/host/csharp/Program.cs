// C# Host Test
//
// Tests C# parent loading Go/C++/Rust plugins and invoking all 4 RPC types.
// Follows the same pattern as test/host/java/JavaHostTest.java.
//
// Build:
//   dotnet build test/host/csharp/
//
// Run (from repo root):
//   dotnet run --project test/host/csharp/

using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Grpc.Core;
using Synurang;

// =============================================================================
// Proto Helpers (manual serialization, same as C++/Java/Rust tests)
// =============================================================================

static byte[] MakeHelloRequest(string name)
{
    // HelloRequest { name = value } — field 1, wire type 2 (length-delimited)
    byte[] nameBytes = Encoding.UTF8.GetBytes(name);
    byte[] data = new byte[2 + nameBytes.Length];
    data[0] = 0x0a;
    data[1] = (byte)nameBytes.Length;
    Buffer.BlockCopy(nameBytes, 0, data, 2, nameBytes.Length);
    return data;
}

static string ExtractMessage(byte[] data)
{
    // HelloResponse { message = 1 } — field 1, wire type 2
    if (data == null || data.Length < 2 || data[0] != 0x0a)
        return "<parse error>";
    int len = data[1] & 0xFF;
    if (data.Length < 2 + len)
        return "<truncated>";
    return Encoding.UTF8.GetString(data, 2, len);
}

// =============================================================================
// gRPC CallInvoker Helpers (raw byte[] marshaller for testing without protobuf)
// =============================================================================

var byteMarshaller = new Marshaller<byte[]>(
    serializer: data => data,
    deserializer: data => data
);

Method<byte[], byte[]> MakeMethod(MethodType type, string fullName)
{
    // Method ctor takes (type, serviceName, methodName, ...) — split "Svc/Method"
    int idx = fullName.LastIndexOf('/');
    string serviceName = fullName[..idx];
    string methodName = fullName[(idx + 1)..];
    return new Method<byte[], byte[]>(type, serviceName, methodName, byteMarshaller, byteMarshaller);
}

bool IsRpcStatus(Exception ex, StatusCode code)
{
    if (ex is AggregateException agg && agg.InnerException != null)
        ex = agg.InnerException;
    return ex is RpcException rpc && rpc.StatusCode == code;
}

// =============================================================================
// Test Runner
// =============================================================================

int passed = 0;
int failed = 0;
int skipped = 0;
bool ffiOnly = Array.Exists(args, static a => a == "--ffi-only");

if (ffiOnly)
{
    Console.WriteLine("===============================================================");
    Console.WriteLine("  C# FFI API Test (No gRPC - all 4 RPC types)");
    Console.WriteLine("===============================================================");

    TestPlugin("bin/libplugin_go.so", "Go");
}
else
{
    Console.WriteLine("===============================================================");
    Console.WriteLine("  C# Host Test (All 4 RPC Types x 3 Plugin Languages)");
    Console.WriteLine("===============================================================");

    TestPlugin("bin/libplugin_go.so", "Go");
    TestPlugin("bin/libplugin_cpp.so", "C++");
    TestPlugin("bin/libplugin_rust.so", "Rust");

    TestCallInvokerPlugin("bin/libplugin_go.so", "Go");
    TestCallInvokerPlugin("bin/libplugin_cpp.so", "C++");
    TestCallInvokerPlugin("bin/libplugin_rust.so", "Rust");

    TestProcessMode();
}

Console.WriteLine("\n===============================================================");
Console.WriteLine(ffiOnly ? "  C# FFI API Test Complete" : "  C# Host Test Complete");
Console.WriteLine($"  Passed: {passed}  Failed: {failed}  Skipped: {skipped}");
Console.WriteLine("===============================================================");

return failed > 0 ? 1 : 0;

// =============================================================================
// Plugin Host Tests (direct FFI)
// =============================================================================

void TestPlugin(string path, string name)
{
    Console.WriteLine($"\n> Testing {name} plugin: {path}");

    if (!File.Exists(path))
    {
        Console.WriteLine("  ! SKIP: Plugin not found");
        skipped++;
        return;
    }

    try
    {
        using var plugin = PluginHost.Load(path);

        // Test 1: Unary RPC
        Console.Write("  [1/4] Unary RPC... ");
        try
        {
            byte[] req = MakeHelloRequest("CSharpHost");
            byte[] resp = plugin.Invoke(
                "GoGreeterService",
                "/example.v1.GoGreeterService/Bar",
                req);
            Console.WriteLine("OK " + ExtractMessage(resp));
            passed++;
        }
        catch (Exception e)
        {
            Console.WriteLine("FAIL " + e.Message);
            failed++;
        }

        // Test 2: Server Streaming
        Console.Write("  [2/4] Server Streaming... ");
        try
        {
            using var stream = plugin.OpenStream(
                "GoGreeterService",
                "/example.v1.GoGreeterService/BarServerStream");
            stream.Send(MakeHelloRequest("StreamTest"));
            stream.CloseSend();

            int count = 0;
            while (true)
            {
                byte[]? data = stream.Recv();
                if (data == null) break;
                count++;
            }
            Console.WriteLine($"OK received {count} messages");
            passed++;
        }
        catch (Exception e)
        {
            Console.WriteLine("FAIL " + e.Message);
            failed++;
        }

        // Test 3: Client Streaming
        Console.Write("  [3/4] Client Streaming... ");
        try
        {
            using var stream = plugin.OpenStream(
                "GoGreeterService",
                "/example.v1.GoGreeterService/BarClientStream");
            for (int i = 0; i < 3; i++)
                stream.Send(MakeHelloRequest($"Msg{i}"));
            stream.CloseSend();

            byte[]? resp = stream.Recv();
            Console.WriteLine("OK " + ExtractMessage(resp!));
            passed++;
        }
        catch (Exception e)
        {
            Console.WriteLine("FAIL " + e.Message);
            failed++;
        }

        // Test 4: Bidirectional Streaming
        Console.Write("  [4/4] Bidi Streaming... ");
        try
        {
            using var stream = plugin.OpenStream(
                "GoGreeterService",
                "/example.v1.GoGreeterService/BarBidiStream");

            for (int i = 0; i < 3; i++)
                stream.Send(MakeHelloRequest($"Ping{i}"));
            stream.CloseSend();

            int count = 0;
            while (true)
            {
                byte[]? data = stream.Recv();
                if (data == null) break;
                count++;
            }
            Console.WriteLine($"OK echoed {count} messages");
            passed++;
        }
        catch (Exception e)
        {
            Console.WriteLine("FAIL " + e.Message);
            failed++;
        }
    }
    catch (Exception e)
    {
        Console.WriteLine("  FAIL " + e.Message);
        failed++;
    }
}

// =============================================================================
// SynurangCallInvoker Tests (gRPC drop-in replacement)
// =============================================================================

void TestCallInvokerPlugin(string path, string name)
{
    Console.WriteLine($"\n> Testing {name} plugin via SynurangCallInvoker: {path}");

    if (!File.Exists(path))
    {
        Console.WriteLine("  ! SKIP: Plugin not found");
        skipped++;
        return;
    }

    try
    {
        using var plugin = PluginHost.Load(path);
        var invoker = new SynurangCallInvoker(plugin, "GoGreeterService");

        // Test 1: Blocking Unary
        Console.Write("  [1/7] CallInvoker Unary... ");
        try
        {
            var method = MakeMethod(MethodType.Unary, "example.v1.GoGreeterService/Bar");
            byte[] resp = invoker.BlockingUnaryCall(method, null, new CallOptions(),
                MakeHelloRequest("InvokerUnary"));
            Console.WriteLine("OK " + ExtractMessage(resp));
            passed++;
        }
        catch (Exception e)
        {
            Console.WriteLine("FAIL " + e.Message);
            failed++;
        }

        // Test 2: Async Unary
        Console.Write("  [2/7] CallInvoker Async Unary... ");
        try
        {
            var method = MakeMethod(MethodType.Unary, "example.v1.GoGreeterService/Bar");
            using var call = invoker.AsyncUnaryCall(method, null, new CallOptions(),
                MakeHelloRequest("AsyncInvoker"));
            byte[] resp = call.ResponseAsync.Result;
            Console.WriteLine("OK " + ExtractMessage(resp));
            passed++;
        }
        catch (Exception e)
        {
            Console.WriteLine("FAIL " + e.Message);
            failed++;
        }

        // Test 3: Server Streaming
        Console.Write("  [3/7] CallInvoker Server Streaming... ");
        try
        {
            var method = MakeMethod(MethodType.ServerStreaming,
                "example.v1.GoGreeterService/BarServerStream");
            using var call = invoker.AsyncServerStreamingCall(method, null, new CallOptions(),
                MakeHelloRequest("InvokerStream"));
            int count = 0;
            while (call.ResponseStream.MoveNext(CancellationToken.None).Result)
                count++;
            Console.WriteLine($"OK received {count} messages");
            passed++;
        }
        catch (Exception e)
        {
            Console.WriteLine("FAIL " + e.Message);
            failed++;
        }

        // Test 4: Client Streaming
        Console.Write("  [4/7] CallInvoker Client Streaming... ");
        try
        {
            var method = MakeMethod(MethodType.ClientStreaming,
                "example.v1.GoGreeterService/BarClientStream");
            using var call = invoker.AsyncClientStreamingCall<byte[], byte[]>(method, null,
                new CallOptions());
            for (int i = 0; i < 3; i++)
                call.RequestStream.WriteAsync(MakeHelloRequest($"CMsg{i}")).Wait();
            call.RequestStream.CompleteAsync().Wait();
            byte[] resp = call.ResponseAsync.Result;
            Console.WriteLine("OK " + ExtractMessage(resp));
            passed++;
        }
        catch (Exception e)
        {
            Console.WriteLine("FAIL " + e.Message);
            failed++;
        }

        // Test 5: Bidi Streaming
        Console.Write("  [5/7] CallInvoker Bidi Streaming... ");
        try
        {
            var method = MakeMethod(MethodType.DuplexStreaming,
                "example.v1.GoGreeterService/BarBidiStream");
            using var call = invoker.AsyncDuplexStreamingCall<byte[], byte[]>(method, null,
                new CallOptions());
            for (int i = 0; i < 3; i++)
                call.RequestStream.WriteAsync(MakeHelloRequest($"BidiMsg{i}")).Wait();
            call.RequestStream.CompleteAsync().Wait();
            int count = 0;
            while (call.ResponseStream.MoveNext(CancellationToken.None).Result)
                count++;
            Console.WriteLine($"OK echoed {count} messages");
            passed++;
        }
        catch (Exception e)
        {
            Console.WriteLine("FAIL " + e.Message);
            failed++;
        }

        // Test 6: Pre-cancelled unary call should return CANCELLED
        Console.Write("  [6/7] CallInvoker Cancelled Unary... ");
        try
        {
            var method = MakeMethod(MethodType.Unary, "example.v1.GoGreeterService/Bar");
            using var cts = new CancellationTokenSource();
            cts.Cancel();
            try
            {
                _ = invoker.BlockingUnaryCall(method, null, new CallOptions(cancellationToken: cts.Token),
                    MakeHelloRequest("Cancelled"));
                Console.WriteLine("FAIL expected CANCELLED");
                failed++;
            }
            catch (Exception ex) when (IsRpcStatus(ex, StatusCode.Cancelled))
            {
                Console.WriteLine("OK cancelled");
                passed++;
            }
        }
        catch (Exception e)
        {
            Console.WriteLine("FAIL " + e.Message);
            failed++;
        }

        // Test 7: Expired deadline should return DEADLINE_EXCEEDED
        Console.Write("  [7/7] CallInvoker Deadline Unary... ");
        try
        {
            var method = MakeMethod(MethodType.Unary, "example.v1.GoGreeterService/Bar");
            try
            {
                _ = invoker.BlockingUnaryCall(method, null,
                    new CallOptions(deadline: DateTime.UtcNow.AddMilliseconds(-1)),
                    MakeHelloRequest("Deadline"));
                Console.WriteLine("FAIL expected DEADLINE_EXCEEDED");
                failed++;
            }
            catch (Exception ex) when (IsRpcStatus(ex, StatusCode.DeadlineExceeded))
            {
                Console.WriteLine("OK deadline exceeded");
                passed++;
            }
        }
        catch (Exception e)
        {
            Console.WriteLine("FAIL " + e.Message);
            failed++;
        }
    }
    catch (Exception e)
    {
        Console.WriteLine("  FAIL " + e.Message);
        failed++;
    }
}

// =============================================================================
// Process Mode Test
// =============================================================================

void TestProcessMode()
{
    Console.WriteLine("\n> Testing Process Mode");

    string executable = "bin/process_child";
    if (!File.Exists(executable))
    {
        Console.WriteLine("  ! SKIP: Process server not found: " + executable);
        skipped++;
        return;
    }

    try
    {
        using var proc = ProcessHost.Start(executable);
        if (proc.IsSocketpairMode)
            Console.WriteLine($"  Process started (socketpair mode, pid={proc.Pid})");
        else
            Console.WriteLine($"  Process started, target: {proc.Target}");

        Console.WriteLine("  [1/2] OK Process mode startup OK");
        passed++;

        if (proc.IsSocketpairMode)
        {
            Console.WriteLine("  [2/2] SKIP Health RPC check in socketpair mode");
            skipped++;
        }
        else
        {
            Console.Write("  [2/2] Health RPC over process channel... ");
            var invoker = proc.Channel.CreateCallInvoker();
            var method = MakeMethod(MethodType.Unary, "grpc.health.v1.Health/Check");
            byte[] resp = invoker.BlockingUnaryCall(
                method,
                null,
                new CallOptions(deadline: DateTime.UtcNow.AddSeconds(3)),
                Array.Empty<byte>());

            if (resp.Length >= 2 && resp[0] == 0x08 && resp[1] == 0x01)
            {
                Console.WriteLine("OK SERVING");
                passed++;
            }
            else
            {
                Console.WriteLine("FAIL unexpected health response");
                failed++;
            }
        }
    }
    catch (Exception e)
    {
        Console.WriteLine("  FAIL " + e.Message);
        failed++;
    }
}

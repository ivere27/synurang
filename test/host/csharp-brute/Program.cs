// C# Host Brute-Force Chaos Test
//
// Randomized stress test for C# host loading Go/C++/Rust plugins and
// TCP process children. Follows the same pattern as JavaHostBruteTest.java.
//
// Requires: SYNURANG_BRUTE=1
//
// Build:
//   dotnet build test/host/csharp-brute/
//
// Run (from repo root):
//   SYNURANG_BRUTE=1 dotnet run --project test/host/csharp-brute/

using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Grpc.Core;
using Synurang;

if (Environment.GetEnvironmentVariable("SYNURANG_BRUTE") != "1")
{
    Console.WriteLine("SKIP: set SYNURANG_BRUTE=1 to run C# brute-force test");
    return 0;
}

TimeSpan totalDuration = EnvDuration("SYNURANG_BRUTE_DURATION", TimeSpan.FromMinutes(1));
TimeSpan phaseDuration = EnvDuration("SYNURANG_BRUTE_PHASE", TimeSpan.FromSeconds(20));
int workers = Math.Max(1, EnvInt("SYNURANG_BRUTE_WORKERS", 4));
// .NET runtime's thread pool, epoll handles, and async infrastructure use more
// FDs than native runtimes. 128 accommodates this overhead with headroom.
int maxFdDelta = EnvInt("SYNURANG_BRUTE_MAX_FD_DELTA", 128);
int maxRssMbDelta = EnvInt("SYNURANG_BRUTE_MAX_RSS_MB_DELTA", 256);
string mode = EnvMode();
bool runPlugin = mode is "all" or "ffi";
bool runProcess = mode is "all" or "process";

if (!runPlugin && !runProcess)
{
    Console.Error.WriteLine($"invalid SYNURANG_BRUTE_MODE={mode} (expected all|ffi|process)");
    return 1;
}

Console.WriteLine("===============================================================");
Console.WriteLine("  C# Host Brute-Force Chaos Test");
Console.WriteLine($"  duration={totalDuration} workers={workers}"
    + $" max_fd_delta={maxFdDelta} max_rss_mb_delta={maxRssMbDelta}"
    + $" mode={mode}");
Console.WriteLine("===============================================================");

var baseline = CaptureResources();
var pluginRes = new BruteResult();
var processRes = new BruteResult();

if (runPlugin)
    pluginRes = RunPluginBrute(totalDuration, workers);
if (runProcess)
    processRes = RunProcessBrute(totalDuration, phaseDuration, workers);

// Let GC settle before measuring final resources.
// .NET's SocketsHttpHandler may defer connection cleanup to finalizers.
GC.Collect();
GC.WaitForPendingFinalizers();
GC.Collect();
Thread.Sleep(3000);
GC.Collect();
GC.WaitForPendingFinalizers();
Thread.Sleep(2000);

var finalRes = CaptureResources();
AssertNoResourceLeak(baseline, finalRes, maxFdDelta, maxRssMbDelta);

long totalOps = pluginRes.Ops + processRes.Ops;
long totalExpected = pluginRes.Expected + processRes.Expected;
long totalUnexpected = pluginRes.Unexpected + processRes.Unexpected;

Console.WriteLine();
Console.WriteLine("===============================================================");
Console.WriteLine("  Aggregate Results:");
Console.WriteLine($"    ops:               {totalOps}");
Console.WriteLine($"    expected_errors:   {totalExpected}");
Console.WriteLine($"    unexpected_errors: {totalUnexpected}");
if (baseline.HasFd && finalRes.HasFd)
    Console.WriteLine($"    fd_delta:          {finalRes.FdCount - baseline.FdCount}");
if (baseline.HasRss && finalRes.HasRss)
    Console.WriteLine($"    rss_delta_mb:      {(finalRes.RssBytes - baseline.RssBytes) / (1024 * 1024)}");
Console.WriteLine("===============================================================");

if (totalUnexpected > 0)
{
    Console.Error.WriteLine($"FAIL: unexpected errors observed: {totalUnexpected}");
    return 1;
}
if (totalOps == 0)
{
    Console.Error.WriteLine("FAIL: zero successful operations");
    return 1;
}
Console.WriteLine("PASS");
return 0;

// =============================================================================
// Proto Helpers
// =============================================================================

static byte[] MakeHelloRequest(string name)
{
    byte[] nameBytes = Encoding.UTF8.GetBytes(name);
    using var ms = new MemoryStream();
    ms.WriteByte(0x0a);
    WriteVarint(nameBytes.Length, ms);
    ms.Write(nameBytes, 0, nameBytes.Length);
    return ms.ToArray();
}

static byte[] MakeHelloRequestWithLanguage(string name, string language)
{
    using var ms = new MemoryStream();
    byte[] nameBytes = Encoding.UTF8.GetBytes(name);
    if (nameBytes.Length > 0)
    {
        ms.WriteByte(0x0a);
        WriteVarint(nameBytes.Length, ms);
        ms.Write(nameBytes, 0, nameBytes.Length);
    }
    byte[] langBytes = Encoding.UTF8.GetBytes(language);
    if (langBytes.Length > 0)
    {
        ms.WriteByte(0x12);
        WriteVarint(langBytes.Length, ms);
        ms.Write(langBytes, 0, langBytes.Length);
    }
    return ms.ToArray();
}

static string ExtractMessage(byte[] data)
{
    if (data == null || data.Length < 2 || data[0] != 0x0a)
        return "<parse error>";
    int idx = 1;
    long len = 0;
    int shift = 0;
    while (idx < data.Length)
    {
        int b = data[idx++] & 0xff;
        len |= (long)(b & 0x7f) << shift;
        if ((b & 0x80) == 0) break;
        shift += 7;
        if (shift > 35) return "<varint overflow>";
    }
    if (idx + len > data.Length || len < 0)
        return "<truncated>";
    return Encoding.UTF8.GetString(data, idx, (int)len);
}

static void WriteVarint(int value, Stream s)
{
    int n = value;
    while (n >= 0x80)
    {
        s.WriteByte((byte)((n & 0x7f) | 0x80));
        n >>= 7;
    }
    s.WriteByte((byte)(n & 0x7f));
}

// =============================================================================
// gRPC Helpers (see Rpc static class at bottom of file for method descriptors)
// =============================================================================

// =============================================================================
// Plugin Phase
// =============================================================================

BruteResult RunPluginBrute(TimeSpan duration, int numWorkers)
{
    var specs = new (string Name, string Path)[]
    {
        ("Go", ResolvePath("bin/libplugin_go.so")),
        ("C++", ResolvePath("bin/libplugin_cpp.so")),
        ("Rust", ResolvePath("bin/libplugin_rust.so")),
    };

    foreach (var spec in specs)
    {
        if (!File.Exists(spec.Path))
            throw new Exception($"plugin not found: {spec.Path} (run `make build_plugin_all`)");
    }

    var perPlugin = TimeSpan.FromMilliseconds(Math.Max(1, duration.TotalMilliseconds / specs.Length));
    var result = new BruteResult();

    for (int i = 0; i < specs.Length; i++)
    {
        var spec = specs[i];
        Console.WriteLine();
        Console.WriteLine($">> Plugin phase: {spec.Name} ({spec.Path})");
        using var plugin = PluginHost.Load(spec.Path);
        var invoker = new SynurangCallInvoker(plugin, "GoGreeterService");
        var phase = RunPhase(invoker, perPlugin, numWorkers, (i + 1) * 101L, $"plugin:{spec.Name}");
        result.Ops += phase.Ops;
        result.Expected += phase.Expected;
        result.Unexpected += phase.Unexpected;
        if (phase.Unexpected > 0)
            throw new Exception($"plugin phase {spec.Name} had {phase.Unexpected} unexpected errors");
    }
    return result;
}

// =============================================================================
// Process Phase
// =============================================================================

BruteResult RunProcessBrute(TimeSpan totalDur, TimeSpan phaseDur, int numWorkers)
{
    string child = ResolvePath("bin/process_child_tcp");
    if (!File.Exists(child))
        throw new Exception($"process child not found: {child} (run `make build_process_tcp_child`)");

    var result = new BruteResult();
    var deadline = DateTime.UtcNow + totalDur;
    int round = 0;

    while (DateTime.UtcNow < deadline)
    {
        round++;
        var remaining = deadline - DateTime.UtcNow;
        if (remaining <= TimeSpan.FromSeconds(1)) break;
        var phase = remaining < phaseDur ? remaining : phaseDur;

        Console.WriteLine();
        Console.WriteLine($">> Process phase round {round}: {child}");
        var proc = ProcessHost.Start(child);
        try
        {
            var invoker = proc.Channel.CreateCallInvoker();
            var phaseRes = RunPhase(invoker, phase, numWorkers, round * 917L, "process");
            result.Ops += phaseRes.Ops;
            result.Expected += phaseRes.Expected;
            result.Unexpected += phaseRes.Unexpected;
            if (phaseRes.Unexpected > 0)
                throw new Exception($"process round {round} had {phaseRes.Unexpected} unexpected errors");
        }
        finally
        {
            proc.Dispose();
            GC.Collect();
            GC.WaitForPendingFinalizers();
            GC.Collect();
        }
    }
    return result;
}

// =============================================================================
// Phase Runner (shared by plugin and process)
// =============================================================================

BruteResult RunPhase(CallInvoker invoker, TimeSpan duration, int numWorkers, long seedBase, string label)
{
    long ops = 0;
    long expected = 0;
    long unexpected = 0;
    int stop = 0;
    var deadline = DateTime.UtcNow + duration;

    var tasks = new Task[numWorkers];
    for (int w = 0; w < numWorkers; w++)
    {
        int workerId = w;
        tasks[w] = Task.Run(() =>
        {
            var rnd = new Random((int)(DateTime.UtcNow.Ticks ^ (workerId * 100103L) ^ (seedBase * 9973L)));
            while (Volatile.Read(ref stop) == 0 && DateTime.UtcNow < deadline)
            {
                try
                {
                    RunRandomOp(invoker, rnd, workerId);
                    Interlocked.Increment(ref ops);
                }
                catch (Exception t)
                {
                    if (IsExpectedError(t))
                    {
                        Interlocked.Increment(ref expected);
                    }
                    else
                    {
                        long prev = Interlocked.Increment(ref unexpected);
                        if (prev <= 5)
                            Console.Error.WriteLine($"  UNEXPECTED [{label} worker {workerId}]: {t}");
                        Volatile.Write(ref stop, 1);
                        return;
                    }
                }

                try { Thread.Sleep(1 + rnd.Next(5)); } catch { return; }
            }
        });
    }

    Task.WaitAll(tasks, (int)duration.TotalMilliseconds + 10_000);

    var result = new BruteResult
    {
        Ops = Interlocked.Read(ref ops),
        Expected = Interlocked.Read(ref expected),
        Unexpected = Interlocked.Read(ref unexpected),
    };
    Console.WriteLine($"  [{label}] ops={result.Ops} expected_errs={result.Expected} unexpected_errs={result.Unexpected}");
    return result;
}

// =============================================================================
// Random Operations
// =============================================================================

static void RunRandomOp(CallInvoker invoker, Random rnd, int workerId)
{
    int x = rnd.Next(100);
    if (x < 40) OpUnary(invoker, rnd, workerId);
    else if (x < 62) OpServerStream(invoker, rnd, workerId);
    else if (x < 78) OpClientStream(invoker, rnd, workerId);
    else if (x < 88) OpBidi(invoker, rnd, workerId);
    else RunChaos(invoker, rnd, workerId);
}

static CallOptions WithTimeout(Random rnd)
{
    int n = rnd.Next(100);
    int ms;
    if (n < 15) ms = 2 + rnd.Next(4);
    else if (n < 65) ms = 20 + rnd.Next(80);
    else ms = 100 + rnd.Next(350);
    return new CallOptions(deadline: DateTime.UtcNow.AddMilliseconds(ms));
}

static void OpUnary(CallInvoker invoker, Random rnd, int workerId)
{
    string marker = $"u-{workerId}-{rnd.Next(int.MaxValue)}";
    byte[] resp = invoker.BlockingUnaryCall(Rpc.MdUnary, null, WithTimeout(rnd), MakeHelloRequest(marker));
    string msg = ExtractMessage(resp);
    if (msg.Length == 0 || msg.StartsWith('<') || !msg.Contains(marker))
        throw new Exception("unary mismatch");
}

static void OpServerStream(CallInvoker invoker, Random rnd, int workerId)
{
    string marker = $"ss-{workerId}-{rnd.Next(int.MaxValue)}";
    using var call = invoker.AsyncServerStreamingCall(Rpc.MdServer, null, WithTimeout(rnd), MakeHelloRequest(marker));
    int received = 0;
    while (call.ResponseStream.MoveNext(CancellationToken.None).Result)
    {
        string msg = ExtractMessage(call.ResponseStream.Current);
        if (msg.Length == 0 || msg.StartsWith('<'))
            throw new Exception("server-stream parse failure");
        received++;
    }
    if (received == 0)
        throw new Exception("server-stream returned zero messages");
}

static void OpClientStream(CallInvoker invoker, Random rnd, int workerId)
{
    using var call = invoker.AsyncClientStreamingCall<byte[], byte[]>(Rpc.MdClient, null, WithTimeout(rnd));
    int count = 1 + rnd.Next(20);
    for (int i = 0; i < count; i++)
        call.RequestStream.WriteAsync(MakeHelloRequest($"cs-{workerId}-{i}-{rnd.Next(int.MaxValue)}")).Wait();
    call.RequestStream.CompleteAsync().Wait();
    byte[] resp = call.ResponseAsync.Result;
    string msg = ExtractMessage(resp);
    if (msg.Length == 0 || msg.StartsWith('<'))
        throw new Exception("client-stream parse failure");
}

static void OpBidi(CallInvoker invoker, Random rnd, int workerId)
{
    using var call = invoker.AsyncDuplexStreamingCall<byte[], byte[]>(Rpc.MdBidi, null, WithTimeout(rnd));
    int count = 1 + rnd.Next(12);
    for (int i = 0; i < count; i++)
        call.RequestStream.WriteAsync(MakeHelloRequest($"bs-{workerId}-{i}-{rnd.Next(int.MaxValue)}")).Wait();
    call.RequestStream.CompleteAsync().Wait();

    int received = 0;
    while (call.ResponseStream.MoveNext(CancellationToken.None).Result)
        received++;
    if (received == 0)
        throw new Exception("bidi returned zero responses");
}

static void RunChaos(CallInvoker invoker, Random rnd, int workerId)
{
    int x = rnd.Next(100);
    if (x < 25)
    {
        // Immediate-cancel: 1ms deadline
        try
        {
            invoker.BlockingUnaryCall(Rpc.MdUnary, null,
                new CallOptions(deadline: DateTime.UtcNow.AddMilliseconds(1)),
                MakeHelloRequest("chaos-immediate-cancel"));
        }
        catch { /* expected */ }
        return;
    }
    if (x < 50)
    {
        try { OpClientStream(invoker, rnd, workerId); }
        catch { /* expected */ }
        return;
    }
    if (x < 75)
    {
        // Large payload
        int size = 64 * 1024 + rnd.Next(192 * 1024);
        byte[] req = MakeHelloRequestWithLanguage("boundary", new string('B', size));
        invoker.BlockingUnaryCall(Rpc.MdUnary, null,
            new CallOptions(deadline: DateTime.UtcNow.AddMilliseconds(1500)),
            req);
        return;
    }
    if (x < 90)
    {
        OpServerStream(invoker, rnd, workerId);
        return;
    }
    OpUnary(invoker, rnd, workerId);
}

// =============================================================================
// Error Classification
// =============================================================================

static bool IsExpectedError(Exception t)
{
    if (t is AggregateException agg && agg.InnerException != null)
        t = agg.InnerException;

    if (t is RpcException rpc)
    {
        var code = rpc.StatusCode;
        if (code is StatusCode.Cancelled or StatusCode.DeadlineExceeded
            or StatusCode.Unavailable or StatusCode.Aborted)
            return true;
    }

    string msg = t.ToString().ToLowerInvariant();
    return msg.Contains("deadline")
        || msg.Contains("cancel")
        || msg.Contains("transport is closing")
        || msg.Contains("connection closing")
        || msg.Contains("broken pipe")
        || msg.Contains("socket closed")
        || msg.Contains("eof")
        || msg.Contains("plugin is closed")
        || msg.Contains("no response from client streaming")
        || msg.Contains("returned zero responses")
        || msg.Contains("returned zero messages");
}

// =============================================================================
// Resource Monitoring
// =============================================================================

static ResourceSnapshot CaptureResources()
{
    var s = new ResourceSnapshot();
    try
    {
        if (Directory.Exists("/proc/self/fd"))
        {
            s.FdCount = Directory.GetFiles("/proc/self/fd").Length;
            s.HasFd = true;
        }
    }
    catch { }

    try
    {
        if (File.Exists("/proc/self/statm"))
        {
            string statm = File.ReadAllText("/proc/self/statm").Trim();
            string[] fields = statm.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (fields.Length >= 2 && long.TryParse(fields[1], out long pages))
            {
                s.RssBytes = pages * 4096L;
                s.HasRss = true;
            }
        }
    }
    catch { }
    return s;
}

static void AssertNoResourceLeak(ResourceSnapshot baselineSnap, ResourceSnapshot finalSnap, int maxFd, int maxRssMb)
{
    if (baselineSnap.HasFd && finalSnap.HasFd)
    {
        int delta = finalSnap.FdCount - baselineSnap.FdCount;
        if (delta > maxFd)
            throw new Exception($"fd leak suspected: baseline={baselineSnap.FdCount} final={finalSnap.FdCount} delta={delta} allowed={maxFd}");
    }
    if (baselineSnap.HasRss && finalSnap.HasRss)
    {
        long deltaMb = (finalSnap.RssBytes - baselineSnap.RssBytes) / (1024 * 1024);
        if (deltaMb > maxRssMb)
            throw new Exception($"rss leak suspected: baseline_mb={baselineSnap.RssBytes / (1024 * 1024)} final_mb={finalSnap.RssBytes / (1024 * 1024)} delta_mb={deltaMb} allowed_mb={maxRssMb}");
    }
}

// =============================================================================
// Environment Helpers
// =============================================================================

static TimeSpan EnvDuration(string key, TimeSpan fallback)
{
    string? raw = Environment.GetEnvironmentVariable(key);
    if (string.IsNullOrWhiteSpace(raw)) return fallback;
    string s = raw.Trim().ToLowerInvariant();
    if (s.EndsWith("ms") && long.TryParse(s[..^2], out long ms)) return TimeSpan.FromMilliseconds(ms);
    if (s.EndsWith("s") && long.TryParse(s[..^1], out long sec)) return TimeSpan.FromSeconds(sec);
    if (s.EndsWith("m") && long.TryParse(s[..^1], out long min)) return TimeSpan.FromMinutes(min);
    if (long.TryParse(s, out long secFallback)) return TimeSpan.FromSeconds(secFallback);
    throw new Exception($"invalid duration {key}={raw}");
}

static int EnvInt(string key, int fallback)
{
    string? raw = Environment.GetEnvironmentVariable(key);
    if (string.IsNullOrWhiteSpace(raw)) return fallback;
    return int.TryParse(raw.Trim(), out int val) ? val : fallback;
}

static string EnvMode()
{
    string? raw = Environment.GetEnvironmentVariable("SYNURANG_BRUTE_MODE");
    if (string.IsNullOrWhiteSpace(raw)) return "all";
    string m = raw.Trim().ToLowerInvariant();
    if (m == "plugin") return "ffi";
    if (m == "tcp") return "process";
    return m;
}

static string ResolvePath(string rel)
{
    if (Path.IsPathRooted(rel)) return rel;
    string dir = Directory.GetCurrentDirectory();
    while (true)
    {
        string candidate = Path.Combine(dir, rel);
        if (File.Exists(candidate)) return candidate;
        if (File.Exists(Path.Combine(dir, "go.mod"))) return candidate;
        string? parent = Directory.GetParent(dir)?.FullName;
        if (parent == null || parent == dir) break;
        dir = parent;
    }
    return Path.Combine(Directory.GetCurrentDirectory(), rel);
}

// =============================================================================
// Types
// =============================================================================

class BruteResult
{
    public long Ops;
    public long Expected;
    public long Unexpected;
}

class ResourceSnapshot
{
    public int FdCount;
    public long RssBytes;
    public bool HasFd;
    public bool HasRss;
}

static class Rpc
{
    static readonly Marshaller<byte[]> M = new(
        serializer: data => data,
        deserializer: data => data);

    public static readonly Method<byte[], byte[]> MdUnary = Make(MethodType.Unary, "example.v1.GoGreeterService/Bar");
    public static readonly Method<byte[], byte[]> MdServer = Make(MethodType.ServerStreaming, "example.v1.GoGreeterService/BarServerStream");
    public static readonly Method<byte[], byte[]> MdClient = Make(MethodType.ClientStreaming, "example.v1.GoGreeterService/BarClientStream");
    public static readonly Method<byte[], byte[]> MdBidi = Make(MethodType.DuplexStreaming, "example.v1.GoGreeterService/BarBidiStream");

    static Method<byte[], byte[]> Make(MethodType type, string fullName)
    {
        int idx = fullName.LastIndexOf('/');
        return new Method<byte[], byte[]>(type, fullName[..idx], fullName[(idx + 1)..], M, M);
    }
}

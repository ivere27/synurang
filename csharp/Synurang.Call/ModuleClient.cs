using System.Runtime.CompilerServices;

namespace Synurang;

public static class ModuleClient
{
    public static async Task<TResponse> UnaryAsync<TRequest, TResponse>(IModuleTransport transport, string path,
        TRequest request, Func<TRequest, byte[]> encode, Func<byte[], TResponse> decode, ModuleCallOptions? options = null)
    {
        await using var call = transport.Open(path, false, false, options);
        await call.SendAsync(encode(request)).ConfigureAwait(false);
        await call.HalfCloseAsync().ConfigureAwait(false);
        return await OneAsync(call, decode).ConfigureAwait(false);
    }

    internal static async Task<T> OneAsync<T>(IModuleCall call, Func<byte[], T> decode)
    {
        var data = await call.ReceiveAsync().ConfigureAwait(false);
        if (data == null) throw new ModuleRpcException(13, "Missing unary response");
        // An initial response is not success until the terminal status arrives.
        if (await call.ReceiveAsync().ConfigureAwait(false) != null)
            throw new ModuleRpcException(13, "Multiple unary responses");
        return decode(data);
    }

    public static async IAsyncEnumerable<TResponse> ServerStreamAsync<TRequest, TResponse>(IModuleTransport transport,
        string path, TRequest request, Func<TRequest, byte[]> encode, Func<byte[], TResponse> decode,
        ModuleCallOptions? options = null, [EnumeratorCancellation] CancellationToken cancellationToken = default)
    {
        await using var call = transport.Open(path, false, true, options);
        await call.SendAsync(encode(request), cancellationToken).ConfigureAwait(false);
        await call.HalfCloseAsync(cancellationToken).ConfigureAwait(false);
        while (await call.ReceiveAsync(cancellationToken).ConfigureAwait(false) is { } data) yield return decode(data);
    }

    public static async Task<TResponse> ClientStreamAsync<TRequest, TResponse>(IModuleTransport transport, string path,
        IAsyncEnumerable<TRequest> requests, Func<TRequest, byte[]> encode, Func<byte[], TResponse> decode,
        ModuleCallOptions? options = null)
    {
        await using var call = transport.Open(path, true, false, options);
        using var inputCancellation = CancellationTokenSource.CreateLinkedTokenSource(options?.CancellationToken ?? default);
        var stopping = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var receiving = OneAsync(call, decode);
        var sending = SendInputs(call, requests, encode, inputCancellation.Token, stopping.Task);
        try
        {
            if (await Task.WhenAny(receiving, sending).ConfigureAwait(false) == sending)
                await sending.ConfigureAwait(false);
            return await receiving.ConfigureAwait(false);
        }
        finally
        {
            stopping.TrySetResult();
            inputCancellation.Cancel();
            Observe(sending);
            Observe(receiving);
        }
    }

    private static void Observe(Task task) => _ = task.ContinueWith(
        completed => { _ = completed.Exception; }, CancellationToken.None,
        TaskContinuationOptions.OnlyOnFaulted | TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);

    private static async Task SendInputs<T>(IModuleCall call, IAsyncEnumerable<T> requests, Func<T, byte[]> encode,
        CancellationToken cancellation, Task stopping)
    {
        var iterator = requests.GetAsyncEnumerator(cancellation);
        Task<bool>? pending = null;
        try
        {
            while (!stopping.IsCompleted)
            {
                pending = iterator.MoveNextAsync().AsTask();
                if (await Task.WhenAny(pending, stopping).ConfigureAwait(false) == stopping) return;
                if (!await pending.ConfigureAwait(false)) break;
                pending = null;
                await call.SendAsync(encode(iterator.Current)).ConfigureAwait(false);
            }
            if (!stopping.IsCompleted) await call.HalfCloseAsync().ConfigureAwait(false);
        }
        catch (ModuleRequestClosedException) { /* The receive task owns final status. */ }
        finally
        {
            // A generic input iterator can ignore cancellation. Do not keep the
            // RPC waiting for it; dispose once its outstanding next completes.
            Observe(RetireInput(iterator, pending));
        }
    }

    private static async Task RetireInput<T>(IAsyncEnumerator<T> iterator, Task<bool>? pending)
    {
        try { await iterator.DisposeAsync().ConfigureAwait(false); }
        catch (NotSupportedException) when (pending != null)
        {
            // Compiler-generated iterators reject DisposeAsync during MoveNext.
            // Custom iterators may instead use disposal to wake that MoveNext.
            try { await pending.ConfigureAwait(false); } catch { }
            await iterator.DisposeAsync().ConfigureAwait(false);
        }
    }

    public static ModuleDuplex<TRequest, TResponse> Duplex<TRequest, TResponse>(IModuleTransport transport, string path,
        Func<TRequest, byte[]> encode, Func<byte[], TResponse> decode, ModuleCallOptions? options = null) =>
        new(transport.Open(path, true, true, options), encode, decode);
}

public sealed class ModuleDuplex<TRequest, TResponse> : IAsyncDisposable
{
    private readonly IModuleCall _call;
    private readonly Func<TRequest, byte[]> _encode;
    private readonly Func<byte[], TResponse> _decode;
    public ModuleDuplex(IModuleCall call, Func<TRequest, byte[]> encode, Func<byte[], TResponse> decode)
    { _call = call; _encode = encode; _decode = decode; }
    public Task SendAsync(TRequest request, CancellationToken token = default) => _call.SendAsync(_encode(request), token);
    public Task HalfCloseAsync(CancellationToken token = default) => _call.HalfCloseAsync(token);
    public async IAsyncEnumerable<TResponse> ReadAllAsync([EnumeratorCancellation] CancellationToken token = default)
    {
        try { while (await _call.ReceiveAsync(token).ConfigureAwait(false) is { } data) yield return _decode(data); }
        finally { await _call.DisposeAsync().ConfigureAwait(false); }
    }
    public void Cancel() => _call.Cancel();
    public ValueTask DisposeAsync() => _call.DisposeAsync();
}

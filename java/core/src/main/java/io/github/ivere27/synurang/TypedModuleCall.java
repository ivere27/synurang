package io.github.ivere27.synurang;

import java.util.concurrent.CompletableFuture;
import java.util.concurrent.CompletionException;
import java.util.function.Function;

/** Typed send/receive surface used by generated clients for every stream kind. */
public final class TypedModuleCall<Request, Response> implements AutoCloseable {
    @FunctionalInterface public interface Decoder<T> { T decode(byte[] data) throws Exception; }
    private final ModuleCall call;
    private final Function<Request, byte[]> encoder;
    private final Decoder<Response> decoder;
    public TypedModuleCall(ModuleCall call, Function<Request, byte[]> encoder, Decoder<Response> decoder) {
        this.call = call; this.encoder = encoder; this.decoder = decoder;
    }
    public CompletableFuture<Void> send(Request request) { return call.send(encoder.apply(request)); }
    public CompletableFuture<Void> halfClose() { return call.halfClose(); }
    public CompletableFuture<Response> receive() { return ModuleFutures.map(call.receive(), this::decode); }
    public CompletableFuture<Response> result() { return ModuleFutures.map(call.result(), this::decode); }
    public CompletableFuture<Void> status() { return call.status(); }
    private Response decode(byte[] data) {
        if (data == null) return null;
        try { return decoder.decode(data); }
        catch (Exception error) { call.close(); throw new CompletionException(error); }
    }
    public void cancel() { call.cancel(); }
    @Override public void close() { call.close(); }
}

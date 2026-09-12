package io.github.ivere27.synurang;

import java.util.concurrent.CompletableFuture;

/** Future conversion that preserves cancellation of the underlying RPC. */
public final class ModuleFutures {
    private ModuleFutures() {}
    @FunctionalInterface public interface Mapper<Input, Output> { Output apply(Input input) throws Exception; }
    public static <Input, Output> CompletableFuture<Output> map(
            CompletableFuture<Input> source, Mapper<Input, Output> mapper) {
        CompletableFuture<Output> result = new CompletableFuture<>();
        source.whenComplete((value, error) -> {
            if (error != null) result.completeExceptionally(error);
            else {
                try { result.complete(mapper.apply(value)); }
                catch (Exception failure) { result.completeExceptionally(failure); }
            }
        });
        result.whenComplete((value, error) -> { if (result.isCancelled()) source.cancel(false); });
        return result;
    }
}

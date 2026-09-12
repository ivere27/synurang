package io.github.ivere27.synurang;

import io.grpc.CallOptions;
import io.grpc.Channel;
import io.grpc.ClientCall;
import io.grpc.MethodDescriptor;

/** gRPC stubs over the module call ABI. The full method path selects the service. */
public final class ModuleChannel extends Channel {
    private final ModuleHost host;
    public ModuleChannel(ModuleHost host) { this.host = host; }
    @Override public <Request, Response> ClientCall<Request, Response> newCall(
            MethodDescriptor<Request, Response> method, CallOptions options) {
        return new ModuleClientCall<>(host, method, options);
    }
    @Override public String authority() { return "synurang"; }
}

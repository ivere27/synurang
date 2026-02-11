package io.github.ivere27.synurang;

import io.grpc.CallOptions;
import io.grpc.Channel;
import io.grpc.ClientCall;
import io.grpc.MethodDescriptor;

/**
 * Drop-in grpc-java {@link Channel} backed by a Synurang plugin (shared library).
 * <p>
 * Enables using standard protoc-gen-grpc-java generated stubs over FFI transport
 * with zero custom codegen. All four RPC types are supported.
 * <p>
 * Usage:
 * <pre>
 *   PluginHost plugin = PluginHost.load("./libplugin.so");
 *   Channel channel = SynurangChannel.create(plugin, "GoGreeterService");
 *
 *   // Standard protoc-gen-grpc-java stubs
 *   GreeterGrpc.GreeterBlockingStub stub = GreeterGrpc.newBlockingStub(channel);
 *   HelloReply reply = stub.sayHello(request);
 * </pre>
 */
public class SynurangChannel extends Channel {
    private final PluginHost host;
    private final String serviceName;

    private SynurangChannel(PluginHost host, String serviceName) {
        this.host = host;
        this.serviceName = serviceName;
    }

    /**
     * Create a channel for the given plugin and service.
     *
     * @param host        loaded plugin
     * @param serviceName the service name matching Synurang_Invoke_&lt;ServiceName&gt;
     * @return a grpc-java Channel backed by FFI
     */
    public static SynurangChannel create(PluginHost host, String serviceName) {
        return new SynurangChannel(host, serviceName);
    }

    @Override
    public <ReqT, RespT> ClientCall<ReqT, RespT> newCall(
            MethodDescriptor<ReqT, RespT> method, CallOptions callOptions) {
        return new SynurangClientCall<>(host, serviceName, method, callOptions);
    }

    @Override
    public String authority() {
        return "synurang-plugin://" + serviceName;
    }
}

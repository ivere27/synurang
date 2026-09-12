import io.github.ivere27.synurang.ModuleCall;
import io.github.ivere27.synurang.ModuleHost;
import io.github.ivere27.synurang.ModuleChannel;
import io.github.ivere27.synurang.RequestClosedException;
import io.grpc.CallOptions;
import io.grpc.ClientCall;
import io.grpc.Metadata;
import io.grpc.MethodDescriptor;
import java.time.Duration;
import java.util.concurrent.ExecutionException;

public final class EarlyModuleConformance {
    public static void main(String[] args) throws Exception {
        try (ModuleHost host = ModuleHost.load(args[0])) {
            for (String method : new String[]{"Client", "Fail"}) {
                try (ModuleCall call = host.open("/early.Service/" + method, true, false, Duration.ofSeconds(2))) {
                    ModuleConformance.await(call.send(ModuleConformance.value(42)));
                    Thread.sleep(30);
                    try {
                        ModuleConformance.await(call.send(ModuleConformance.value(43)));
                        throw new AssertionError("Expected request-side EOF");
                    } catch (ExecutionException expected) {
                        if (!(expected.getCause() instanceof RequestClosedException)) throw expected;
                    }
                    ModuleConformance.await(call.halfClose());
                    if (method.equals("Client")) ModuleConformance.same(ModuleConformance.await(call.result()), ModuleConformance.value(42));
                    else ModuleConformance.error(7, call.result());
                }
            }
            ModuleChannel channel = new ModuleChannel(host);
            ClientCall<byte[], byte[]> stream = GrpcModuleConformance.call(channel, "Client", MethodDescriptor.MethodType.CLIENT_STREAMING, CallOptions.DEFAULT);
            GrpcModuleConformance.Listener listener = new GrpcModuleConformance.Listener();
            stream.start(listener, new Metadata());
            // No response demand yet: native completion must survive a later
            // rejected send and only publish the reply after request(1).
            stream.sendMessage(ModuleConformance.value(42));
            Thread.sleep(30);
            stream.sendMessage(ModuleConformance.value(43));
            Thread.sleep(30);
            stream.request(1);
            listener.ended(0);
            if (listener.messages.size() != 1) throw new AssertionError("Lost early gRPC response");
            ModuleConformance.same(listener.messages.get(0), ModuleConformance.value(42));
        }
        System.out.println("Java request EOF preserves early response and terminal error");
    }
}

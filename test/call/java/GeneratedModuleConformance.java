import io.github.ivere27.synurang.ModuleHost;
import io.github.ivere27.synurang.TypedModuleCall;
import synurang.test.CallsClient;
import synurang.test.Conformance.Value;

public final class GeneratedModuleConformance {
    public static void main(String[] args) throws Exception {
        for (String module : args) {
            try (ModuleHost host = ModuleHost.load(module)) {
                CallsClient client = new CallsClient(host);
                if (ModuleConformance.await(client.Unary(Value.newBuilder().setValue(42).build())).getValue() != 42)
                    throw new AssertionError("Generated unary");
                try (TypedModuleCall<Value, Value> call = client.Server()) {
                    ModuleConformance.await(call.send(Value.newBuilder().setValue(50).build()));
                    ModuleConformance.await(call.halfClose());
                    for (int i = 0; i < 50; ++i)
                        if (ModuleConformance.await(call.receive()).getValue() != i) throw new AssertionError("Generated server");
                    if (ModuleConformance.await(call.receive()) != null) throw new AssertionError("Generated server EOF");
                }
                try (TypedModuleCall<Value, Value> call = client.Client()) {
                    ModuleConformance.await(call.send(Value.newBuilder().setValue(3).build()));
                    ModuleConformance.await(call.send(Value.newBuilder().setValue(4).build()));
                    ModuleConformance.await(call.halfClose());
                    if (ModuleConformance.await(call.result()).getValue() != 7) throw new AssertionError("Generated client");
                }
                try (TypedModuleCall<Value, Value> call = client.Bidi()) {
                    ModuleConformance.await(call.send(Value.getDefaultInstance()));
                    if (ModuleConformance.await(call.receive()).getValue() != 0) throw new AssertionError("Generated bidi");
                    ModuleConformance.await(call.halfClose());
                    if (ModuleConformance.await(call.receive()) != null) throw new AssertionError("Generated bidi EOF");
                }
            }
            System.out.println("Java generated client conformance: " + module);
        }
    }
}

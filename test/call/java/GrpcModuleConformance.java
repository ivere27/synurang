import io.github.ivere27.synurang.ModuleChannel;
import io.github.ivere27.synurang.ModuleHost;
import io.grpc.CallOptions;
import io.grpc.ClientCall;
import io.grpc.Metadata;
import io.grpc.MethodDescriptor;
import io.grpc.Status;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.Semaphore;
import java.util.concurrent.TimeUnit;

public final class GrpcModuleConformance {
    static final MethodDescriptor.Marshaller<byte[]> BYTES = new MethodDescriptor.Marshaller<byte[]>() {
        public InputStream stream(byte[] value) { return new ByteArrayInputStream(value); }
        public byte[] parse(InputStream stream) {
            try {
                ByteArrayOutputStream result = new ByteArrayOutputStream();
                for (int n; (n = stream.read()) != -1;) result.write(n);
                return result.toByteArray();
            } catch (Exception error) { throw new RuntimeException(error); }
        }
    };
    static ClientCall<byte[], byte[]> call(ModuleChannel channel, String name, MethodDescriptor.MethodType type, CallOptions options) {
        return channel.newCall(MethodDescriptor.<byte[], byte[]>newBuilder().setType(type)
            .setFullMethodName("synurang.test.Calls/" + name)
            .setRequestMarshaller(BYTES).setResponseMarshaller(BYTES).build(), options);
    }
    static final class Listener extends ClientCall.Listener<byte[]> {
        final List<byte[]> messages = new ArrayList<>();
        final Semaphore readable = new Semaphore(0);
        final CompletableFuture<Status> status = new CompletableFuture<>();
        Metadata trailers;
        public synchronized void onMessage(byte[] value) { messages.add(value); readable.release(); }
        public synchronized void onClose(Status value, Metadata trailers) { this.trailers = trailers; status.complete(value); }
        void message() throws Exception { if (!readable.tryAcquire(5, TimeUnit.SECONDS)) throw new AssertionError("Missing message"); }
        void ended(int code) throws Exception {
            Status value = status.get(5, TimeUnit.SECONDS);
            if (value.getCode().value() != code) throw new AssertionError(value.toString());
        }
    }
    static void run(String module) throws Exception {
        try (ModuleHost host = ModuleHost.load(module)) {
            ModuleChannel channel = new ModuleChannel(host);
            ClientCall<byte[], byte[]> unary = call(channel, "Unary", MethodDescriptor.MethodType.UNARY, CallOptions.DEFAULT);
            Listener one = new Listener(); unary.start(one, new Metadata()); unary.request(1);
            unary.sendMessage(new byte[0]); unary.halfClose(); one.ended(0);
            if (one.messages.size() != 1 || one.messages.get(0).length != 0) throw new AssertionError("Empty unary payload lost");

            ClientCall<byte[], byte[]> server = call(channel, "Server", MethodDescriptor.MethodType.SERVER_STREAMING, CallOptions.DEFAULT);
            Listener many = new Listener(); server.start(many, new Metadata()); server.sendMessage(ModuleConformance.value(64)); server.halfClose();
            Thread.sleep(10);
            if (!many.messages.isEmpty()) throw new AssertionError("Response without demand");
            server.request(64); many.ended(0);
            if (many.messages.size() != 64) throw new AssertionError("Missing server messages");
            for (int i = 0; i < 64; ++i) ModuleConformance.same(many.messages.get(i), ModuleConformance.value(i));

            ClientCall<byte[], byte[]> client = call(channel, "Client", MethodDescriptor.MethodType.CLIENT_STREAMING, CallOptions.DEFAULT);
            Listener sum = new Listener(); client.start(sum, new Metadata()); client.request(1);
            for (int i = 0; i < 10; ++i) client.sendMessage(ModuleConformance.value(1));
            client.halfClose(); sum.ended(0);
            ModuleConformance.same(sum.messages.get(0), ModuleConformance.value(10));

            ClientCall<byte[], byte[]> bidi = call(channel, "Bidi", MethodDescriptor.MethodType.BIDI_STREAMING, CallOptions.DEFAULT);
            Listener echo = new Listener(); bidi.start(echo, new Metadata());
            for (int i = 0; i < 40; ++i) {
                bidi.request(1); bidi.sendMessage(ModuleConformance.value(i)); echo.message();
                ModuleConformance.same(echo.messages.get(i), ModuleConformance.value(i));
            }
            bidi.halfClose(); echo.ended(0);

            for (String name : new String[]{"Fail", "Missing", "Wait"}) {
                CallOptions options = name.equals("Wait") ? CallOptions.DEFAULT.withDeadlineAfter(20, TimeUnit.MILLISECONDS) : CallOptions.DEFAULT;
                ClientCall<byte[], byte[]> failed = call(channel, name, MethodDescriptor.MethodType.UNARY, options);
                Listener failure = new Listener(); failed.start(failure, new Metadata()); failed.request(1);
                failed.sendMessage(new byte[0]); failed.halfClose(); failure.ended(name.equals("Fail") ? 7 : name.equals("Missing") ? 12 : 4);
                if (name.equals("Fail") && failure.trailers.get(Metadata.Key.of("synurang-error-bin", Metadata.BINARY_BYTE_MARSHALLER)) == null)
                    throw new AssertionError("Missing structured error");
            }
            ClientCall<byte[], byte[]> waiting = call(channel, "Wait", MethodDescriptor.MethodType.UNARY, CallOptions.DEFAULT);
            Listener cancelled = new Listener(); waiting.start(cancelled, new Metadata()); waiting.sendMessage(new byte[0]); waiting.halfClose();
            waiting.cancel("test", null); cancelled.ended(1);
        }
        System.out.println("Java gRPC module conformance: " + module);
    }
    public static void main(String[] args) throws Exception { for (String module : args) run(module); }
}

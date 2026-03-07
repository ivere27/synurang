// Java Host Test
//
// Tests Java parent loading Go/C++/Rust plugins and invoking all 4 RPC types.
// Follows the same pattern as test/host/cpp/main.cpp.
//
// Build:
//   # Build synurang_jni native library
//   cd java/core/src/main/c && cmake -B build && cmake --build build
//   # Build Java host library
//   make build_java
//   # Compile test
//   javac -cp build/java/libs/java.jar:java/libs/* test/host/java/JavaHostTest.java
//
// Run:
//   java -Djava.library.path=java/core/src/main/c/build \
//        -cp build/java/libs/java.jar:java/libs/*:test/host/java \
//        JavaHostTest

import io.github.ivere27.synurang.PluginHost;
import io.github.ivere27.synurang.PluginStream;
import io.github.ivere27.synurang.FfiError;
import io.github.ivere27.synurang.SynurangChannel;

import io.grpc.CallOptions;
import io.grpc.ClientCall;
import io.grpc.Metadata;
import io.grpc.MethodDescriptor;
import io.grpc.Status;
import io.grpc.stub.ClientCalls;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Iterator;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

public class JavaHostTest {
    static final String ERROR_TRIGGER_NAME = "trigger_error";

    // =========================================================================
    // Proto Helpers (manual serialization, same as C++ test)
    // =========================================================================

    /** Serialize HelloRequest { name = value } */
    static byte[] makeHelloRequest(String name) {
        byte[] nameBytes = name.getBytes(StandardCharsets.UTF_8);
        byte[] data = new byte[2 + nameBytes.length];
        data[0] = 0x0a;  // field 1, wire type 2 (length-delimited)
        data[1] = (byte) nameBytes.length;
        System.arraycopy(nameBytes, 0, data, 2, nameBytes.length);
        return data;
    }

    /** Extract message field from HelloResponse { message = 1 } */
    static String extractMessage(byte[] data) {
        if (data == null || data.length < 2 || data[0] != 0x0a) {
            return "<parse error>";
        }
        int len = data[1] & 0xFF;
        if (data.length < 2 + len) {
            return "<truncated>";
        }
        return new String(data, 2, len, StandardCharsets.UTF_8);
    }

    // =========================================================================
    // gRPC Channel Helpers (raw byte[] marshaller for testing without protobuf)
    // =========================================================================

    static final MethodDescriptor.Marshaller<byte[]> BYTE_MARSHALLER =
            new MethodDescriptor.Marshaller<byte[]>() {
                @Override
                public InputStream stream(byte[] value) {
                    return new ByteArrayInputStream(value);
                }

                @Override
                public byte[] parse(InputStream is) {
                    try {
                        ByteArrayOutputStream baos = new ByteArrayOutputStream();
                        byte[] buf = new byte[4096];
                        int n;
                        while ((n = is.read(buf)) != -1) {
                            baos.write(buf, 0, n);
                        }
                        return baos.toByteArray();
                    } catch (Exception e) {
                        throw new RuntimeException(e);
                    }
                }
            };

    static MethodDescriptor<byte[], byte[]> methodDesc(MethodDescriptor.MethodType type, String fullName) {
        return MethodDescriptor.<byte[], byte[]>newBuilder()
                .setType(type)
                .setFullMethodName(fullName)
                .setRequestMarshaller(BYTE_MARSHALLER)
                .setResponseMarshaller(BYTE_MARSHALLER)
                .build();
    }

    // =========================================================================
    // Test Runner
    // =========================================================================

    static int passed = 0;
    static int failed = 0;
    static int skipped = 0;

    static final class ExpectedFfiError {
        final String message;
        final int code;
        final int grpcCode;

        ExpectedFfiError(String message, int code, int grpcCode) {
            this.message = message;
            this.code = code;
            this.grpcCode = grpcCode;
        }
    }

    static ExpectedFfiError expectedFfiError(String pluginName, String rpcKind) {
        switch (pluginName) {
            case "Go":
                switch (rpcKind) {
                    case "unary":
                        return new ExpectedFfiError("go unary ffi error", 4101, 10);
                    case "server":
                        return new ExpectedFfiError("go server stream ffi error", 4102, 10);
                    case "client":
                        return new ExpectedFfiError("go client stream ffi error", 4103, 10);
                    case "bidi":
                        return new ExpectedFfiError("go bidi stream ffi error", 4104, 10);
                    default:
                        break;
                }
                break;
            case "C++":
                switch (rpcKind) {
                    case "unary":
                        return new ExpectedFfiError("cpp unary ffi error", 4201, 10);
                    case "server":
                        return new ExpectedFfiError("cpp server stream ffi error", 4202, 10);
                    case "client":
                        return new ExpectedFfiError("cpp client stream ffi error", 4203, 10);
                    case "bidi":
                        return new ExpectedFfiError("cpp bidi stream ffi error", 4204, 10);
                    default:
                        break;
                }
                break;
            case "Rust":
                switch (rpcKind) {
                    case "unary":
                        return new ExpectedFfiError("rust unary ffi error", 4301, 10);
                    case "server":
                        return new ExpectedFfiError("rust server stream ffi error", 4302, 10);
                    case "client":
                        return new ExpectedFfiError("rust client stream ffi error", 4303, 10);
                    case "bidi":
                        return new ExpectedFfiError("rust bidi stream ffi error", 4304, 10);
                    default:
                        break;
                }
                break;
            default:
                break;
        }
        throw new IllegalArgumentException("unknown plugin/rpc expectation: " + pluginName + "/" + rpcKind);
    }

    static void assertFfiError(String label, FfiError error, ExpectedFfiError expected) throws Exception {
        if (!expected.message.equals(error.getMessage())) {
            throw new Exception(label + " message mismatch: expected=" + expected.message + " got=" + error.getMessage());
        }
        if (error.getCode() != expected.code) {
            throw new Exception(label + " code mismatch: expected=" + expected.code + " got=" + error.getCode());
        }
        if (error.getGrpcCode() != expected.grpcCode) {
            throw new Exception(label + " grpcCode mismatch: expected=" + expected.grpcCode + " got=" + error.getGrpcCode());
        }
    }

    static void testStructuredFfiErrors(PluginHost plugin, String pluginName) throws Exception {
        ExpectedFfiError unaryExpected = expectedFfiError(pluginName, "unary");
        try {
            plugin.invoke(
                    "GoGreeterService",
                    "/example.v1.GoGreeterService/Bar",
                    makeHelloRequest(ERROR_TRIGGER_NAME)
            );
            throw new Exception("unary expected FfiError");
        } catch (FfiError e) {
            assertFfiError("unary", e, unaryExpected);
        }

        ExpectedFfiError serverExpected = expectedFfiError(pluginName, "server");
        PluginStream serverStream = plugin.openStream(
                "GoGreeterService",
                "/example.v1.GoGreeterService/BarServerStream"
        );
        try {
            serverStream.send(makeHelloRequest(ERROR_TRIGGER_NAME));
            serverStream.closeSend();
            byte[] data = serverStream.recv();
            throw new Exception("server-stream expected FfiError, got " + (data == null ? "EOF" : "data"));
        } catch (FfiError e) {
            assertFfiError("server-stream", e, serverExpected);
        } finally {
            serverStream.close();
        }

        ExpectedFfiError clientExpected = expectedFfiError(pluginName, "client");
        PluginStream clientStream = plugin.openStream(
                "GoGreeterService",
                "/example.v1.GoGreeterService/BarClientStream"
        );
        try {
            clientStream.send(makeHelloRequest(ERROR_TRIGGER_NAME));
            clientStream.closeSend();
            byte[] data = clientStream.recv();
            throw new Exception("client-stream expected FfiError, got " + (data == null ? "EOF" : "data"));
        } catch (FfiError e) {
            assertFfiError("client-stream", e, clientExpected);
        } finally {
            clientStream.close();
        }

        ExpectedFfiError bidiExpected = expectedFfiError(pluginName, "bidi");
        PluginStream bidiStream = plugin.openStream(
                "GoGreeterService",
                "/example.v1.GoGreeterService/BarBidiStream"
        );
        try {
            bidiStream.send(makeHelloRequest(ERROR_TRIGGER_NAME));
            bidiStream.closeSend();
            byte[] data = bidiStream.recv();
            throw new Exception("bidi expected FfiError, got " + (data == null ? "EOF" : "data"));
        } catch (FfiError e) {
            assertFfiError("bidi", e, bidiExpected);
        } finally {
            bidiStream.close();
        }
    }

    static void testPlugin(String path, String name) {
        System.out.println("\n\u25b6 Testing " + name + " plugin: " + path);

        if (!new File(path).exists()) {
            System.out.println("  \u26a0 SKIP: Plugin not found");
            skipped++;
            return;
        }

        try {
            PluginHost plugin = PluginHost.load(path);

            // Test 1: Unary RPC
            System.out.print("  [1/4] Unary RPC... ");
            try {
                byte[] req = makeHelloRequest("JavaHost");
                byte[] resp = plugin.invoke(
                    "GoGreeterService",
                    "/example.v1.GoGreeterService/Bar",
                    req
                );
                System.out.println("\u2713 " + extractMessage(resp));
                passed++;
            } catch (Exception e) {
                System.out.println("\u2717 " + e.getMessage());
                failed++;
            }

            // Test 2: Server Streaming
            System.out.print("  [2/4] Server Streaming... ");
            try {
                PluginStream stream = plugin.openStream(
                    "GoGreeterService",
                    "/example.v1.GoGreeterService/BarServerStream"
                );
                stream.send(makeHelloRequest("StreamTest"));
                stream.closeSend();

                int count = 0;
                while (true) {
                    byte[] data = stream.recv();
                    if (data == null) break;
                    count++;
                }
                stream.close();
                System.out.println("\u2713 received " + count + " messages");
                passed++;
            } catch (Exception e) {
                System.out.println("\u2717 " + e.getMessage());
                failed++;
            }

            // Test 3: Client Streaming
            System.out.print("  [3/4] Client Streaming... ");
            try {
                PluginStream stream = plugin.openStream(
                    "GoGreeterService",
                    "/example.v1.GoGreeterService/BarClientStream"
                );
                for (int i = 0; i < 3; i++) {
                    stream.send(makeHelloRequest("Msg" + i));
                }
                stream.closeSend();

                byte[] resp = stream.recv();
                stream.close();
                System.out.println("\u2713 " + extractMessage(resp));
                passed++;
            } catch (Exception e) {
                System.out.println("\u2717 " + e.getMessage());
                failed++;
            }

            // Test 4: Bidirectional Streaming
            System.out.print("  [4/4] Bidi Streaming... ");
            try {
                PluginStream stream = plugin.openStream(
                    "GoGreeterService",
                    "/example.v1.GoGreeterService/BarBidiStream"
                );

                for (int i = 0; i < 3; i++) {
                    stream.send(makeHelloRequest("Ping" + i));
                }
                stream.closeSend();

                int count = 0;
                while (true) {
                    byte[] data = stream.recv();
                    if (data == null) break;
                    count++;
                }
                stream.close();
                System.out.println("\u2713 echoed " + count + " messages");
                passed++;
            } catch (Exception e) {
                System.out.println("\u2717 " + e.getMessage());
                failed++;
            }

            // Test 5: Structured FFI errors on all 4 RPC types
            System.out.print("  [5/5] Structured FFI Errors... ");
            try {
                testStructuredFfiErrors(plugin, name);
                System.out.println("\u2713 unary/server/client/bidi");
                passed++;
            } catch (Exception e) {
                System.out.println("\u2717 " + e.getMessage());
                failed++;
            }

            plugin.close();
        } catch (Exception e) {
            System.out.println("  \u2717 Failed: " + e.getMessage());
            failed++;
        }
    }

    static void testChannelPlugin(String path, String name) {
        System.out.println("\n\u25b6 Testing " + name + " plugin via SynurangChannel: " + path);

        if (!new File(path).exists()) {
            System.out.println("  \u26a0 SKIP: Plugin not found");
            skipped++;
            return;
        }

        try {
            PluginHost plugin = PluginHost.load(path);
            SynurangChannel channel = SynurangChannel.create(plugin, "GoGreeterService");

            // Test 1: Unary via ClientCalls.blockingUnaryCall (standard grpc-java blocking stub path)
            System.out.print("  [1/4] Channel Unary... ");
            try {
                MethodDescriptor<byte[], byte[]> md = methodDesc(
                        MethodDescriptor.MethodType.UNARY,
                        "example.v1.GoGreeterService/Bar");
                byte[] resp = ClientCalls.blockingUnaryCall(
                        channel, md, CallOptions.DEFAULT, makeHelloRequest("ChannelUnary"));
                System.out.println("\u2713 " + extractMessage(resp));
                passed++;
            } catch (Exception e) {
                System.out.println("\u2717 " + e.getMessage());
                failed++;
            }

            // Test 2: Server Streaming via ClientCalls.blockingServerStreamingCall
            System.out.print("  [2/4] Channel Server Streaming... ");
            try {
                MethodDescriptor<byte[], byte[]> md = methodDesc(
                        MethodDescriptor.MethodType.SERVER_STREAMING,
                        "example.v1.GoGreeterService/BarServerStream");
                Iterator<byte[]> iter = ClientCalls.blockingServerStreamingCall(
                        channel, md, CallOptions.DEFAULT, makeHelloRequest("ChannelStream"));
                int count = 0;
                while (iter.hasNext()) {
                    iter.next();
                    count++;
                }
                System.out.println("\u2713 received " + count + " messages");
                passed++;
            } catch (Exception e) {
                System.out.println("\u2717 " + e.getMessage());
                failed++;
            }

            // Test 3: Client Streaming via direct ClientCall
            System.out.print("  [3/4] Channel Client Streaming... ");
            try {
                MethodDescriptor<byte[], byte[]> md = methodDesc(
                        MethodDescriptor.MethodType.CLIENT_STREAMING,
                        "example.v1.GoGreeterService/BarClientStream");
                final byte[][] result = new byte[1][];
                final Status[] statusResult = new Status[1];
                final CountDownLatch latch = new CountDownLatch(1);

                ClientCall<byte[], byte[]> call = channel.newCall(md, CallOptions.DEFAULT);
                call.start(new ClientCall.Listener<byte[]>() {
                    @Override
                    public void onMessage(byte[] message) { result[0] = message; }
                    @Override
                    public void onClose(Status status, Metadata trailers) {
                        statusResult[0] = status;
                        latch.countDown();
                    }
                }, new Metadata());
                call.request(2);
                for (int i = 0; i < 3; i++) {
                    call.sendMessage(makeHelloRequest("CMsg" + i));
                }
                call.halfClose();

                if (!latch.await(10, TimeUnit.SECONDS)) throw new Exception("Timed out");
                if (!statusResult[0].isOk()) throw new Exception("Failed: " + statusResult[0]);
                System.out.println("\u2713 " + extractMessage(result[0]));
                passed++;
            } catch (Exception e) {
                System.out.println("\u2717 " + e.getMessage());
                failed++;
            }

            // Test 4: Bidi Streaming via direct ClientCall
            System.out.print("  [4/4] Channel Bidi Streaming... ");
            try {
                MethodDescriptor<byte[], byte[]> md = methodDesc(
                        MethodDescriptor.MethodType.BIDI_STREAMING,
                        "example.v1.GoGreeterService/BarBidiStream");
                final List<byte[]> results = new ArrayList<>();
                final Status[] statusResult = new Status[1];
                final CountDownLatch latch = new CountDownLatch(1);

                ClientCall<byte[], byte[]> call = channel.newCall(md, CallOptions.DEFAULT);
                call.start(new ClientCall.Listener<byte[]>() {
                    @Override
                    public void onMessage(byte[] message) {
                        results.add(message);
                        call.request(1);
                    }
                    @Override
                    public void onClose(Status status, Metadata trailers) {
                        statusResult[0] = status;
                        latch.countDown();
                    }
                }, new Metadata());
                call.request(1);
                for (int i = 0; i < 3; i++) {
                    call.sendMessage(makeHelloRequest("BPing" + i));
                }
                call.halfClose();

                if (!latch.await(10, TimeUnit.SECONDS)) throw new Exception("Timed out");
                if (!statusResult[0].isOk()) throw new Exception("Failed: " + statusResult[0]);
                System.out.println("\u2713 echoed " + results.size() + " messages");
                passed++;
            } catch (Exception e) {
                System.out.println("\u2717 " + e.getMessage());
                failed++;
            }

            plugin.close();
        } catch (Exception e) {
            System.out.println("  \u2717 Failed: " + e.getMessage());
            failed++;
        }
    }

    static void testProcessMode() {
        System.out.println("\n\u25b6 Testing Process Mode");
        // ProcessHost requires the child executable to print SYNURANG_PORT:<port>
        // This test requires the Go process server to be built.
        String executable = "bin/synurang-process-server";
        if (!new File(executable).exists()) {
            System.out.println("  \u26a0 SKIP: Process server not found: " + executable);
            skipped++;
            return;
        }

        try {
            var proc = io.github.ivere27.synurang.ProcessHost.start(executable);
            if (proc.isSocketpairMode()) {
                System.out.println("  Process started (socketpair mode, pid=" + proc.getPid() + ")");
            } else {
                System.out.println("  Process started, target: " + proc.target());
            }

            System.out.println("  \u2713 Process mode startup OK");
            passed++;

            proc.close();
        } catch (Exception e) {
            System.out.println("  \u2717 " + e.getMessage());
            failed++;
        }
    }

    public static void main(String[] args) {
        System.out.println("\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550");
        System.out.println("  Java Host Test (All 4 RPC Types \u00d7 3 Plugin Languages)");
        System.out.println("\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550");

        testPlugin("bin/libplugin_go.so", "Go");
        testPlugin("bin/libplugin_cpp.so", "C++");
        testPlugin("bin/libplugin_rust.so", "Rust");

        testChannelPlugin("bin/libplugin_go.so", "Go");
        testChannelPlugin("bin/libplugin_cpp.so", "C++");
        testChannelPlugin("bin/libplugin_rust.so", "Rust");

        testProcessMode();

        System.out.println("\n\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550");
        System.out.println("  Java Host Test Complete");
        System.out.println("  Passed: " + passed + "  Failed: " + failed + "  Skipped: " + skipped);
        System.out.println("\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550");

        System.exit(failed > 0 ? 1 : 0);
    }
}

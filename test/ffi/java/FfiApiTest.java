// FFI API Test (Java) — No gRPC dependency
//
// Tests all 4 RPC types using PluginHost directly with hand-crafted protobuf
// bytes. No io.grpc.* imports anywhere.
//
// Build (from project root):
//   cd java/src/main/c && cmake -B build && cmake --build build && cd -
//   cd java && gradle build && cd -
//   javac -cp java/build/libs/java.jar test/ffi/java/FfiApiTest.java
//
// Run (from project root):
//   java -Djava.library.path=java/src/main/c/build \
//        -cp java/build/libs/java.jar:test/ffi/java \
//        FfiApiTest [plugin-path]
//
// Default plugin: bin/libplugin_go.so

import io.github.ivere27.synurang.PluginHost;
import io.github.ivere27.synurang.PluginStream;
import io.github.ivere27.synurang.PluginError;
// No io.grpc imports

import java.io.File;
import java.nio.charset.StandardCharsets;

public class FfiApiTest {

    // =========================================================================
    // Protobuf helpers (hand-crafted, no protobuf library needed)
    // =========================================================================

    /** Encode HelloRequest { name = value } */
    static byte[] encodeHelloRequest(String name) {
        byte[] nameBytes = name.getBytes(StandardCharsets.UTF_8);
        byte[] data = new byte[2 + nameBytes.length];
        data[0] = 0x0a;  // field 1, wire type 2
        data[1] = (byte) nameBytes.length;
        System.arraycopy(nameBytes, 0, data, 2, nameBytes.length);
        return data;
    }

    /** Decode HelloResponse.message (field 1, string) */
    static String decodeHelloMessage(byte[] data) {
        if (data == null || data.length < 2 || data[0] != 0x0a) {
            return null;
        }
        int len = data[1] & 0xFF;
        if (data.length < 2 + len) {
            return null;
        }
        return new String(data, 2, len, StandardCharsets.UTF_8);
    }

    // =========================================================================
    // Tests
    // =========================================================================

    static int passed = 0;
    static int failed = 0;

    static void run(String name, TestFunc fn) {
        System.out.print("  " + name + "... ");
        try {
            fn.run();
            System.out.println("OK");
            passed++;
        } catch (Exception e) {
            System.out.println("FAIL: " + e.getMessage());
            failed++;
        }
    }

    @FunctionalInterface
    interface TestFunc {
        void run() throws Exception;
    }

    /** Unary: invoke(service, method, bytes) -> bytes */
    static void testUnary(PluginHost plugin) throws Exception {
        byte[] req = encodeHelloRequest("JavaFFI");
        byte[] resp = plugin.invoke("GoGreeterService",
                "/example.v1.GoGreeterService/Bar", req);

        String msg = decodeHelloMessage(resp);
        if (msg == null || msg.isEmpty()) {
            throw new Exception("bad response");
        }
    }

    /** Server streaming: open -> send -> closeSend -> recv loop */
    static void testServerStream(PluginHost plugin) throws Exception {
        PluginStream stream = plugin.openStream("GoGreeterService",
                "/example.v1.GoGreeterService/BarServerStream");

        stream.send(encodeHelloRequest("StreamTest"));
        stream.closeSend();

        int count = 0;
        byte[] data;
        while ((data = stream.recv()) != null) {
            String msg = decodeHelloMessage(data);
            if (msg == null) {
                stream.close();
                throw new Exception("bad message at index " + count);
            }
            count++;
        }
        stream.close();

        if (count == 0) {
            throw new Exception("received 0 messages");
        }
    }

    /** Client streaming: open -> send multiple -> closeSend -> recv one */
    static void testClientStream(PluginHost plugin) throws Exception {
        PluginStream stream = plugin.openStream("GoGreeterService",
                "/example.v1.GoGreeterService/BarClientStream");

        for (int i = 0; i < 3; i++) {
            stream.send(encodeHelloRequest("Msg" + i));
        }
        stream.closeSend();

        byte[] resp = stream.recv();
        stream.close();

        if (resp == null) {
            throw new Exception("no response");
        }
        String msg = decodeHelloMessage(resp);
        if (msg == null || msg.isEmpty()) {
            throw new Exception("bad response");
        }
    }

    /** Bidi streaming: open -> send+recv concurrently */
    static void testBidiStream(PluginHost plugin) throws Exception {
        PluginStream stream = plugin.openStream("GoGreeterService",
                "/example.v1.GoGreeterService/BarBidiStream");

        // Send in a separate thread
        Thread sender = new Thread(() -> {
            try {
                for (int i = 0; i < 3; i++) {
                    stream.send(encodeHelloRequest("Ping" + i));
                }
                stream.closeSend();
            } catch (PluginError e) {
                throw new RuntimeException(e);
            }
        });
        sender.start();

        // Recv on current thread
        int count = 0;
        byte[] data;
        while ((data = stream.recv()) != null) {
            String msg = decodeHelloMessage(data);
            if (msg == null) {
                stream.close();
                throw new Exception("bad message at index " + count);
            }
            count++;
        }

        sender.join(10_000);
        stream.close();

        if (count == 0) {
            throw new Exception("received 0 messages");
        }
    }

    // =========================================================================
    // Main
    // =========================================================================

    public static void main(String[] args) {
        String pluginPath = args.length > 0 ? args[0] : "bin/libplugin_go.so";

        System.out.println("\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550");
        System.out.println("  Java FFI API Test (No gRPC \u2014 all 4 RPC types)");
        System.out.println("\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550");

        if (!new File(pluginPath).exists()) {
            System.err.println("Plugin not found: " + pluginPath);
            System.exit(1);
        }

        try {
            PluginHost plugin = PluginHost.load(pluginPath);

            run("[1/4] Unary RPC", () -> testUnary(plugin));
            run("[2/4] Server Streaming", () -> testServerStream(plugin));
            run("[3/4] Client Streaming", () -> testClientStream(plugin));
            run("[4/4] Bidi Streaming", () -> testBidiStream(plugin));

            plugin.close();
        } catch (PluginError e) {
            System.err.println("Fatal: " + e.getMessage());
            System.exit(1);
        }

        System.out.println();
        System.out.println("\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550");
        System.out.println("  Results: " + passed + " passed, " + failed + " failed");
        System.out.println("\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550");

        System.exit(failed > 0 ? 1 : 0);
    }
}

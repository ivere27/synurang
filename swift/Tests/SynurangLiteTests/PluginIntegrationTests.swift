import XCTest
@testable import SynurangLite

/// End-to-end Swift host integration tests against a real Synurang plugin.
///
/// Mirrors the coverage in `test/host/csharp/Program.cs` and
/// `test/host/java/JavaHostTest.java`:
///   * unary RPC happy path
///   * server-streaming
///   * client-streaming
///   * bidi-streaming
///   * structured `FfiError` propagation on all 4 RPC types
///   * close-cascades-streams behaviour
///
/// All tests are skipped unless `SYNURANG_TEST_PLUGIN_PATH` points at a real
/// plugin shared library (`bin/libplugin_go.so` etc.). The plugin is expected
/// to expose the `example.v1.GoGreeterService` API and to recognise the magic
/// request name `trigger_error` (matching the .NET / Java fixtures).
final class PluginIntegrationTests: XCTestCase {

    private static let serviceName = "GoGreeterService"
    private static let unaryMethod = "/example.v1.GoGreeterService/Bar"
    private static let serverStreamMethod = "/example.v1.GoGreeterService/BarServerStream"
    private static let clientStreamMethod = "/example.v1.GoGreeterService/BarClientStream"
    private static let bidiStreamMethod = "/example.v1.GoGreeterService/BarBidiStream"
    private static let errorTrigger = "trigger_error"

    // MARK: - Test plumbing

    private func pluginPath() throws -> String {
        guard let p = ProcessInfo.processInfo.environment["SYNURANG_TEST_PLUGIN_PATH"] else {
            throw XCTSkip("set SYNURANG_TEST_PLUGIN_PATH to run plugin integration tests")
        }
        return p
    }

    private func pluginKindFromPath(_ path: String) -> String {
        if path.contains("plugin_go") { return "Go" }
        if path.contains("plugin_cpp") { return "C++" }
        if path.contains("plugin_rust") { return "Rust" }
        return "Unknown"
    }

    private func expectedError(_ kind: String, rpc: String) -> (msg: String, code: Int32, grpc: Int32)? {
        switch (kind, rpc) {
        case ("Go", "unary"):    return ("go unary ffi error",         4101, 10)
        case ("Go", "server"):   return ("go server stream ffi error", 4102, 10)
        case ("Go", "client"):   return ("go client stream ffi error", 4103, 10)
        case ("Go", "bidi"):     return ("go bidi stream ffi error",   4104, 10)
        case ("C++", "unary"):   return ("cpp unary ffi error",         4201, 10)
        case ("C++", "server"):  return ("cpp server stream ffi error", 4202, 10)
        case ("C++", "client"):  return ("cpp client stream ffi error", 4203, 10)
        case ("C++", "bidi"):    return ("cpp bidi stream ffi error",   4204, 10)
        case ("Rust", "unary"):  return ("rust unary ffi error",         4301, 10)
        case ("Rust", "server"): return ("rust server stream ffi error", 4302, 10)
        case ("Rust", "client"): return ("rust client stream ffi error", 4303, 10)
        case ("Rust", "bidi"):   return ("rust bidi stream ffi error",   4304, 10)
        default: return nil
        }
    }

    private struct TimeoutError: Error, CustomStringConvertible {
        let description = "operation timed out"
    }

    private func withTimeout<T: Sendable>(
        seconds: Double,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let nanos = UInt64(seconds * 1_000_000_000)
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: nanos)
                throw TimeoutError()
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    // MARK: - Proto helpers (manual wire encoding — no SwiftProtobuf dep)

    private func makeHelloRequest(_ name: String) -> Data {
        var w = ProtoWriter()
        w.writeString(fieldNumber: 1, value: name)
        return w.data
    }

    private func extractMessage(_ data: Data) -> String? {
        var r = ProtoReader(data: data)
        while let tag = try? r.readTag() {
            if tag.fieldNumber == 1, tag.wire == .lengthDelimited {
                return try? r.readString()
            }
            try? r.skip(wire: tag.wire)
        }
        return nil
    }

    // MARK: - Lifecycle

    func testLoadAndCloseIsIdempotent() async throws {
        let path = try pluginPath()
        let host = try PluginHost.load(path: path)
        await host.close()
        // Second close is a no-op.
        await host.close()
    }

    // MARK: - Unary

    func testUnaryRoundTrip() async throws {
        let path = try pluginPath()
        let host = try PluginHost.load(path: path)
        defer { Task { await host.close() } }

        let resp = try await host.invoke(
            service: Self.serviceName,
            method: Self.unaryMethod,
            data: makeHelloRequest("SwiftHost")
        )
        let msg = extractMessage(resp)
        XCTAssertNotNil(msg, "could not decode HelloResponse")
        XCTAssertFalse(msg!.isEmpty, "empty echo message")
    }

    // MARK: - Server streaming

    func testServerStreaming() async throws {
        let path = try pluginPath()
        let host = try PluginHost.load(path: path)
        defer { Task { await host.close() } }

        let stream = try await host.openStream(
            service: Self.serviceName,
            method: Self.serverStreamMethod
        )
        try await stream.send(makeHelloRequest("StreamTest"))
        try await stream.closeSend()

        var count = 0
        while let data = try await stream.recv() {
            if extractMessage(data) == nil {
                XCTFail("could not parse server-stream message")
                break
            }
            count += 1
        }
        XCTAssertGreaterThan(count, 0, "expected at least one stream message")
        await stream.close()
    }

    // MARK: - Client streaming

    func testClientStreaming() async throws {
        let path = try pluginPath()
        let host = try PluginHost.load(path: path)
        defer { Task { await host.close() } }

        let stream = try await host.openStream(
            service: Self.serviceName,
            method: Self.clientStreamMethod
        )
        for i in 0..<3 {
            try await stream.send(makeHelloRequest("Msg\(i)"))
        }
        try await stream.closeSend()

        let resp = try await stream.recv()
        XCTAssertNotNil(resp, "client-stream returned EOF before single aggregate response")
        XCTAssertNotNil(extractMessage(resp ?? Data()))
        await stream.close()
    }

    // MARK: - Bidi streaming

    func testBidiStreaming() async throws {
        let path = try pluginPath()
        let host = try PluginHost.load(path: path)
        defer { Task { await host.close() } }

        let stream = try await host.openStream(
            service: Self.serviceName,
            method: Self.bidiStreamMethod
        )
        for i in 0..<3 {
            try await stream.send(makeHelloRequest("Ping\(i)"))
        }
        try await stream.closeSend()

        var count = 0
        while let data = try await stream.recv() {
            if extractMessage(data) == nil { XCTFail("bidi parse fail"); break }
            count += 1
        }
        XCTAssertEqual(count, 3, "bidi echo count mismatch")
        await stream.close()
    }

    func testBidiResponsesCanStartBeforeSending() async throws {
        let path = try pluginPath()
        let host = try PluginHost.load(path: path)
        defer { Task { await host.close() } }

        let raw = try await host.openStream(
            service: Self.serviceName,
            method: Self.bidiStreamMethod
        )
        let bidi = BidiStream<Data, Data>(
            stream: raw,
            serializer: { $0 },
            deserializer: { $0 }
        )

        let decodeMessage: @Sendable (Data) -> String? = { data in
            var r = ProtoReader(data: data)
            while let tag = try? r.readTag() {
                if tag.fieldNumber == 1, tag.wire == .lengthDelimited {
                    return try? r.readString()
                }
                try? r.skip(wire: tag.wire)
            }
            return nil
        }

        let receiver = Task { () throws -> [String] in
            var messages: [String] = []
            for try await data in bidi.responses() {
                if let msg = decodeMessage(data) {
                    messages.append(msg)
                }
            }
            return messages
        }
        defer {
            receiver.cancel()
            Task { await bidi.close() }
        }

        // Let recv() block before any send. This catches stream implementations
        // that serialize send and recv through one blocking executor lane.
        try await Task.sleep(nanoseconds: 50_000_000)

        for i in 0..<3 {
            try await bidi.send(makeHelloRequest("Concurrent\(i)"))
        }
        try await bidi.closeSend()

        let messages = try await withTimeout(seconds: 2) {
            try await receiver.value
        }
        XCTAssertEqual(messages.count, 3)
        XCTAssertTrue(messages.allSatisfy { $0.contains("Concurrent") })
    }

    // MARK: - Structured FfiError on all RPC kinds

    func testStructuredFfiError_Unary() async throws {
        let path = try pluginPath()
        let kind = pluginKindFromPath(path)
        guard let expected = expectedError(kind, rpc: "unary") else {
            throw XCTSkip("plugin kind \(kind) has no expectation table")
        }
        let host = try PluginHost.load(path: path)
        defer { Task { await host.close() } }
        do {
            _ = try await host.invoke(
                service: Self.serviceName,
                method: Self.unaryMethod,
                data: makeHelloRequest(Self.errorTrigger)
            )
            XCTFail("expected FfiError")
        } catch let err as FfiError {
            XCTAssertEqual(err.message, expected.msg)
            XCTAssertEqual(err.code, expected.code)
            XCTAssertEqual(err.grpcCode, expected.grpc)
        }
    }

    func testStructuredFfiError_ServerStream() async throws {
        let path = try pluginPath()
        let kind = pluginKindFromPath(path)
        guard let expected = expectedError(kind, rpc: "server") else {
            throw XCTSkip("plugin kind \(kind) has no expectation table")
        }
        let host = try PluginHost.load(path: path)
        defer { Task { await host.close() } }

        let stream = try await host.openStream(
            service: Self.serviceName,
            method: Self.serverStreamMethod
        )
        defer { Task { await stream.close() } }

        try await stream.send(makeHelloRequest(Self.errorTrigger))
        try await stream.closeSend()
        do {
            _ = try await stream.recv()
            XCTFail("expected FfiError on server-stream recv")
        } catch let err as FfiError {
            XCTAssertEqual(err.message, expected.msg)
            XCTAssertEqual(err.code, expected.code)
        }
    }

    func testStructuredFfiError_ClientStream() async throws {
        let path = try pluginPath()
        let kind = pluginKindFromPath(path)
        guard let expected = expectedError(kind, rpc: "client") else {
            throw XCTSkip("plugin kind \(kind) has no expectation table")
        }
        let host = try PluginHost.load(path: path)
        defer { Task { await host.close() } }

        let stream = try await host.openStream(
            service: Self.serviceName,
            method: Self.clientStreamMethod
        )
        defer { Task { await stream.close() } }

        try await stream.send(makeHelloRequest(Self.errorTrigger))
        try await stream.closeSend()
        do {
            _ = try await stream.recv()
            XCTFail("expected FfiError on client-stream recv")
        } catch let err as FfiError {
            XCTAssertEqual(err.message, expected.msg)
            XCTAssertEqual(err.code, expected.code)
        }
    }

    func testStructuredFfiError_Bidi() async throws {
        let path = try pluginPath()
        let kind = pluginKindFromPath(path)
        guard let expected = expectedError(kind, rpc: "bidi") else {
            throw XCTSkip("plugin kind \(kind) has no expectation table")
        }
        let host = try PluginHost.load(path: path)
        defer { Task { await host.close() } }

        let stream = try await host.openStream(
            service: Self.serviceName,
            method: Self.bidiStreamMethod
        )
        defer { Task { await stream.close() } }

        try await stream.send(makeHelloRequest(Self.errorTrigger))
        try await stream.closeSend()
        do {
            _ = try await stream.recv()
            XCTFail("expected FfiError on bidi recv")
        } catch let err as FfiError {
            XCTAssertEqual(err.message, expected.msg)
            XCTAssertEqual(err.code, expected.code)
        }
    }

    // MARK: - Cascade close

    func testHostCloseCascadesToStreams() async throws {
        let path = try pluginPath()
        let host = try PluginHost.load(path: path)

        let stream = try await host.openStream(
            service: Self.serviceName,
            method: Self.bidiStreamMethod
        )

        // Close host before draining stream.
        await host.close()

        do {
            _ = try await stream.send(Data())
            XCTFail("expected PluginClosedError after host close")
        } catch is PluginClosedError {
            // expected
        } catch {
            // Some plugins may close the underlying handle and surface a
            // generic FfiError instead. Either is acceptable here.
            XCTAssertNotNil(error)
        }
    }

    // MARK: - Concurrent invokes (actor serialisation smoke test)

    func testConcurrentInvokes() async throws {
        let path = try pluginPath()
        let host = try PluginHost.load(path: path)
        defer { Task { await host.close() } }

        // Fan out 32 concurrent unary calls; each must produce a valid reply.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<32 {
                group.addTask {
                    let resp = try await host.invoke(
                        service: Self.serviceName,
                        method: Self.unaryMethod,
                        data: self.makeHelloRequest("c\(i)")
                    )
                    if self.extractMessage(resp) == nil {
                        throw FfiError(message: "concurrent: parse fail")
                    }
                }
            }
            try await group.waitForAll()
        }
    }
}

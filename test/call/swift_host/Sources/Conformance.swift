import Foundation
import SynurangLite

private let prefix = "/synurang.test.Calls/"
private struct TestFailure: Error { let message: String }
private func equal<T: Equatable>(_ actual: T, _ expected: T) throws {
    guard actual == expected else { throw TestFailure(message: "Expected \(expected), got \(actual)") }
}
private func encode(_ value: Int32) -> Data {
    if value == 0 { return Data() }
    var bytes: [UInt8] = [8]
    var n = UInt64(bitPattern: Int64(value))
    while n >= 128 { bytes.append(UInt8(n & 127) | 128); n >>= 7 }
    bytes.append(UInt8(n)); return Data(bytes)
}
private func decode(_ bytes: Data) throws -> Int32 {
    if bytes.isEmpty { return 0 }
    guard bytes.first == 8 else { throw TestFailure(message: "Invalid Value protobuf") }
    var n: UInt64 = 0, shift: UInt64 = 0
    for byte in bytes.dropFirst() {
        n |= UInt64(byte & 127) << shift
        if byte < 128 { return Int32(truncatingIfNeeded: n) }
        shift += 7
    }
    throw TestFailure(message: "Invalid Value protobuf")
}
private func unary(_ host: any ModuleCallTransport, _ value: Int32, _ method: String = "Unary",
                   options: ModuleCallOptions = .init()) async throws -> Int32 {
    try await ModuleClient.unary(transport: host, path: prefix + method, request: value,
                                encode: { encode($0) }, decode: { try decode($0) }, options: options)
}
private func rejects(_ code: Int32, details: Bool = false, operation: () async throws -> Void) async throws {
    do { try await operation() }
    catch let error as ModuleRpcError {
        try equal(error.code, code)
        if details { try equal(error.details.isEmpty, false) }
        return
    }
    throw TestFailure(message: "Expected RPC code \(code)")
}
private struct Inputs: AsyncSequence, Sendable {
    typealias Element = Int32
    let count: Int32
    struct Iterator: AsyncIteratorProtocol {
        var current: Int32 = 0
        let count: Int32
        mutating func next() async -> Int32? {
            if current == count { return nil }
            defer { current += 1 }
            return current
        }
    }
    func makeAsyncIterator() -> Iterator { Iterator(count: count) }
}
private actor SuspendedInputState {
    private var continuation: CheckedContinuation<Int32?, Never>?
    private(set) var cancelled = false
    func next() async -> Int32? {
        if cancelled { return nil }
        return await withCheckedContinuation { continuation = $0 }
    }
    func cancel() { cancelled = true; continuation?.resume(returning: nil); continuation = nil }
}
private struct SuspendedInput: AsyncSequence, Sendable {
    typealias Element = Int32
    let state: SuspendedInputState
    struct Iterator: AsyncIteratorProtocol {
        let state: SuspendedInputState
        var first = true
        mutating func next() async -> Int32? {
            if first { first = false; return -2 }
            let state = state
            return await withTaskCancellationHandler(operation: { await state.next() },
                onCancel: { Task { await state.cancel() } })
        }
    }
    func makeAsyncIterator() -> Iterator { Iterator(state: state) }
}

private func releaseBacklog() async throws {
    guard let module = ProcessInfo.processInfo.environment["SYNURANG_TEST_RELEASE_MODULE"] else { return }
    let marker = FileManager.default.temporaryDirectory.appendingPathComponent("synurang-swift-release-" + UUID().uuidString)
    try Data().write(to: marker)
    defer { try? FileManager.default.removeItem(at: marker) }
    let host = try ModuleHost.load(path: module)
    do {
        let target = try await host.open(path: "/test.Release/Watch", requestStream: false, responseStream: true)
        try await target.send(Data(marker.path.utf8))
        try equal(try await target.receive(), Data())
        var peers: [any ModuleCallChannel] = []
        for _ in 0..<512 {
            peers.append(try await host.open(path: "/test.Release/Watch", requestStream: false, responseStream: true))
        }
        await target.close()
        let deadline = Date().addingTimeInterval(2)
        while try Data(contentsOf: marker) != Data("CD".utf8) && Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        try equal(try Data(contentsOf: marker), Data("CD".utf8))
        try await host.close()
        for peer in peers { await peer.close() }
        print("Swift release drains through a ready queue backlog")
    } catch { try? await host.close(); throw error }
}

@main struct Main {
    private static func makeHost(_ path: String) throws -> ModuleHost {
        if path == "--linked" {
            typealias GetApi = @convention(c) () -> UnsafeRawPointer?
            let getApi = unsafeBitCast(try NativeLoader.resolve("Synurang_GetApi", in: NativeLoader.loadProcess()), to: GetApi.self)
            guard let api = getApi() else { throw TestFailure(message: "Missing linked API table") }
            return try ModuleHost.linked(api: api)
        }
        return try ModuleHost.load(path: path)
    }
    static func main() async throws {
        try await releaseBacklog()
        guard CommandLine.arguments.count > 1 else { throw TestFailure(message: "Pass native module paths") }
        for path in CommandLine.arguments.dropFirst() {
            let host = try makeHost(path)
            let other = try makeHost(path)
            do {
                try equal(try await unary(host, 0), 0)
                try equal(try await unary(host, 42), 42)
#if GENERATED_CONFORMANCE
                try await generated(host)
#endif
                var count: Int32 = 0
                for try await response in ModuleClient.serverStream(transport: host, path: prefix + "Server",
                    request: Int32(50), encode: { encode($0) }, decode: { try decode($0) }) {
                    try equal(response, count); count += 1
                }
                try equal(count, 50)
                let sum = try await ModuleClient.clientStream(transport: host, path: prefix + "Client", requests: Inputs(count: 50),
                    encode: { encode($0) }, decode: { try decode($0) })
                try equal(sum, 1225)
                try await earlyCompletion(host)
                let bidi: ModuleDuplex<Int32, Int32> = try await ModuleClient.duplex(transport: host, path: prefix + "Bidi",
                    encode: { encode($0) }, decode: { try decode($0) })
                for n: Int32 in 0..<30 {
                    try await bidi.send(n)
                    try equal(try await bidi.receive(), n) // The provider must reply before half-close.
                }
                async let send: Void = {
                    for n: Int32 in 0..<500 { try await bidi.send(n) }
                    try await bidi.halfClose()
                }()
                async let receive: Void = {
                    for n: Int32 in 0..<500 { try equal(try await bidi.receive(), n) }
                    try equal(try await bidi.receive(), nil)
                }()
                _ = try await (send, receive)
                await bidi.close()
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for n: Int32 in 0..<25 { group.addTask { try equal(try await unary(host, n), n) } }
                    try await group.waitForAll()
                }
                try equal(try await unary(other, 123), 123)
                try await rejects(7, details: true) { _ = try await unary(host, 0, "Fail") }
                try await rejects(7, details: true) { _ = try await unary(host, -1) }
                let unknown = try await host.open(path: "/unknown.Service/Method", requestStream: false, responseStream: false)
                try await rejects(12) { _ = try await unknown.receive() }
                await unknown.close()
                let waiting = Task { try await unary(host, 0, "Wait") }
                try await Task.sleep(nanoseconds: 10_000_000)
                waiting.cancel()
                try await rejects(1) { _ = try await waiting.value }
                try await rejects(4) { _ = try await unary(host, 0, "Wait", options: .init(timeoutMilliseconds: 20)) }
                try await rejects(4) { _ = try await unary(host, 0, "Wait", options: .init(timeoutMilliseconds: 0)) }
                let cancelled = Task {
                    withUnsafeCurrentTask { $0?.cancel() }
                    return try await unary(host, 0, "Wait")
                }
                try await rejects(1) { _ = try await cancelled.value }
                for try await response in ModuleClient.serverStream(transport: host, path: prefix + "Server",
                    request: Int32(10000), encode: { encode($0) }, decode: { try decode($0) }) {
                    try equal(response, 0); break
                }
                let pending = Task { try await unary(host, 0, "Wait") }
                try await Task.sleep(nanoseconds: 5_000_000)
                try await host.close()
                try await rejects(1) { _ = try await pending.value }
                try await rejects(14) { _ = try await unary(host, 0) }
                try equal(try await unary(other, 9), 9)
                try await other.close()
                print("Swift module conformance passed: \(path)")
            } catch { try? await host.close(); try? await other.close(); throw error }
        }
    }

    private static func earlyCompletion(_ host: ModuleHost) async throws {
        let state = SuspendedInputState()
        let response = try await ModuleClient.clientStream(transport: host, path: prefix + "Client",
            requests: SuspendedInput(state: state), encode: { encode($0) }, decode: { try decode($0) },
            options: .init(timeoutMilliseconds: 2_000))
        try equal(response, 42)
        for _ in 0..<100 {
            if await state.cancelled { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        try equal(await state.cancelled, true)
        let stream = try await host.open(path: prefix + "Server", requestStream: false, responseStream: true)
        try await stream.send(encode(100)); try await stream.halfClose()
        do { try await stream.send(Data()); throw TestFailure(message: "Expected closed request side") }
        catch is ModuleRequestClosedError { }
        for n: Int32 in 0..<100 { try equal(try decode(try await stream.receive()!), n) }
        try equal(try await stream.receive(), nil)
        await stream.close()
    }

#if GENERATED_CONFORMANCE
    private static func generated(_ host: ModuleHost) async throws {
        let client = CallsClient(transport: host)
        func value(_ n: Int32) -> Value { var result = Value(); result.value = n; return result }
        try equal(try await client.unary(value(42)).value, 42)
        var count: Int32 = 0
        for try await response in client.server(value(50)) { try equal(response.value, count); count += 1 }
        try equal(count, 50)
        try equal(try await client.client(Inputs(count: 50).map { value($0) }).value, 1225)
        let bidi = try await client.bidi()
        for n: Int32 in 0..<30 { try await bidi.send(value(n)); try equal(try await bidi.receive()?.value, n) }
        try await bidi.halfClose()
        try equal(try await bidi.receive()?.value, nil)
        await bidi.close()
    }
#endif
}

import Foundation

public enum ModuleClient {
    public static func unary<Request: Sendable, Response: Sendable>(
        transport: any ModuleCallTransport, path: String, request: Request,
        encode: @Sendable (Request) throws -> Data, decode: @Sendable (Data) throws -> Response,
        options: ModuleCallOptions = .init()
    ) async throws -> Response {
        let call = try await transport.open(path: path, requestStream: false, responseStream: false, options: options)
        do {
            try await call.send(encode(request))
            try await call.halfClose()
            let response = try await one(call: call, decode: decode)
            await call.close()
            return response
        } catch { await call.close(); throw error }
    }

    private static func one<Response>(call: any ModuleCallChannel, decode: (Data) throws -> Response) async throws -> Response {
        guard let data = try await call.receive() else { throw ModuleRpcError(code: 13, message: "Missing unary response") }
        guard try await call.receive() == nil else { throw ModuleRpcError(code: 13, message: "Multiple unary responses") }
        return try decode(data)
    }

    public static func serverStream<Request: Sendable, Response: Sendable>(
        transport: any ModuleCallTransport, path: String, request: Request,
        encode: @escaping @Sendable (Request) throws -> Data, decode: @escaping @Sendable (Data) throws -> Response,
        options: ModuleCallOptions = .init()
    ) -> ModuleResponses<Response> {
        ModuleResponses(start: {
            let call = try await transport.open(path: path, requestStream: false, responseStream: true, options: options)
            do { try await call.send(encode(request)); try await call.halfClose(); return call }
            catch { await call.close(); throw error }
        }, decode: decode)
    }

    public static func clientStream<Requests: AsyncSequence & Sendable, Response: Sendable>(
        transport: any ModuleCallTransport, path: String, requests: Requests,
        encode: @escaping @Sendable (Requests.Element) throws -> Data, decode: @escaping @Sendable (Data) throws -> Response,
        options: ModuleCallOptions = .init()
    ) async throws -> Response where Requests.Element: Sendable {
        let call = try await transport.open(path: path, requestStream: true, responseStream: false, options: options)
        let input = ModuleClientInput(call: call)
        let (results, continuation) = AsyncThrowingStream<Response, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let receiving = Task {
            do { continuation.yield(try await one(call: call, decode: decode)); continuation.finish() }
            catch { continuation.finish(throwing: error) }
        }
        let sending = Task {
            do {
                for try await request in requests {
                    if Task.isCancelled { return }
                    if try await !input.send(encode(request)) { return }
                }
                try await input.halfClose()
            } catch is ModuleRequestClosedError { /* Receive owns terminal status. */ }
            catch { continuation.finish(throwing: error) }
        }
        return try await withTaskCancellationHandler(operation: {
            do {
                var iterator = results.makeAsyncIterator()
                guard let response = try await iterator.next() else {
                    throw ModuleRpcError(code: Task.isCancelled ? 1 : 13, message: "Client stream cancelled or missing response")
                }
                sending.cancel(); receiving.cancel(); await input.stop(); await call.close()
                return response
            } catch {
                sending.cancel(); receiving.cancel(); await input.stop(); await call.close(); throw error
            }
        }, onCancel: {
            sending.cancel(); receiving.cancel()
            continuation.finish(throwing: ModuleRpcError(code: 1, message: "Call cancelled"))
            Task { await call.cancel() }
        })
    }

    public static func duplex<Request: Sendable, Response: Sendable>(
        transport: any ModuleCallTransport, path: String,
        encode: @escaping @Sendable (Request) throws -> Data, decode: @escaping @Sendable (Data) throws -> Response,
        options: ModuleCallOptions = .init()
    ) async throws -> ModuleDuplex<Request, Response> {
        ModuleDuplex(call: try await transport.open(path: path, requestStream: true, responseStream: true, options: options),
                     encode: encode, decode: decode)
    }
}

/// Stopping clears the foreign call even when application input ignores task
/// cancellation and leaves its next() suspended indefinitely.
private actor ModuleClientInput {
    private var call: (any ModuleCallChannel)?
    init(call: any ModuleCallChannel) { self.call = call }
    func send(_ data: Data) async throws -> Bool {
        guard let call else { return false }
        try await call.send(data)
        return true
    }
    func halfClose() async throws { try await call?.halfClose() }
    func stop() { call = nil }
}

/// Pulls exactly one native message per next(). The iterator owns call cleanup,
/// including early loop exits; no unbounded AsyncThrowingStream buffer is used.
public struct ModuleResponses<Element: Sendable>: AsyncSequence, Sendable {
    private let start: @Sendable () async throws -> any ModuleCallChannel
    private let decode: @Sendable (Data) throws -> Element
    public init(start: @escaping @Sendable () async throws -> any ModuleCallChannel,
                decode: @escaping @Sendable (Data) throws -> Element) {
        self.start = start; self.decode = decode
    }
    public func makeAsyncIterator() -> Iterator { Iterator(start: start, decode: decode) }

    public final class Iterator: AsyncIteratorProtocol {
        private let start: @Sendable () async throws -> any ModuleCallChannel
        private let decode: @Sendable (Data) throws -> Element
        private var call: (any ModuleCallChannel)?
        private var finished = false
        fileprivate init(start: @escaping @Sendable () async throws -> any ModuleCallChannel,
                         decode: @escaping @Sendable (Data) throws -> Element) {
            self.start = start; self.decode = decode
        }
        public func next() async throws -> Element? {
            if finished { return nil }
            do {
                if call == nil { call = try await start() }
                guard let call else { return nil }
                guard let data = try await call.receive() else {
                    finished = true; await call.close(); self.call = nil; return nil
                }
                return try decode(data)
            } catch {
                finished = true
                if let call { await call.close() }
                call = nil
                throw error
            }
        }
        deinit { if let call { Task { await call.close() } } }
    }
}

public final class ModuleDuplex<Request: Sendable, Response: Sendable>: Sendable {
    private let call: any ModuleCallChannel
    private let encode: @Sendable (Request) throws -> Data
    private let decode: @Sendable (Data) throws -> Response
    public init(call: any ModuleCallChannel, encode: @escaping @Sendable (Request) throws -> Data,
                decode: @escaping @Sendable (Data) throws -> Response) {
        self.call = call; self.encode = encode; self.decode = decode
    }
    public func send(_ request: Request) async throws { try await call.send(encode(request)) }
    public func halfClose() async throws { try await call.halfClose() }
    public func receive() async throws -> Response? {
        guard let data = try await call.receive() else { return nil }
        return try decode(data)
    }
    public var responses: ModuleResponses<Response> { ModuleResponses(start: { self.call }, decode: decode) }
    public func cancel() async { await call.cancel() }
    public func close() async { await call.close() }
}

import Foundation

/// Typed wrapper used by generated code for client-streaming and
/// bidirectional RPCs.
///
/// Construction:
///   - `stream`: an open `PluginStream` from `PluginHost.openStream`.
///   - `serializer`: encodes one request message to wire bytes.
///   - `deserializer`: decodes one response message from wire bytes.
///
/// Note: `Req` / `Resp` are not constrained to any protocol — closure-based
/// (de)serialization keeps the generated code (and SynurangLite) free of
/// SwiftProtobuf or grpc-swift dependencies. See README for the rationale.
public final actor BidiStream<Req: Sendable, Resp: Sendable> {

    private let stream: PluginStream
    private let serializer: @Sendable (Req) throws -> Data
    private let deserializer: @Sendable (Data) throws -> Resp

    public init(
        stream: PluginStream,
        serializer: @escaping @Sendable (Req) throws -> Data,
        deserializer: @escaping @Sendable (Data) throws -> Resp
    ) {
        self.stream = stream
        self.serializer = serializer
        self.deserializer = deserializer
    }

    public func send(_ request: Req) async throws {
        let bytes = try serializer(request)
        try await stream.send(bytes)
    }

    public func closeSend() async throws {
        try await stream.closeSend()
    }

    public func close() async {
        await stream.close()
    }

    /// Async sequence of responses. The stream is drained until EOF; any
    /// error from the plugin or the deserializer terminates the sequence.
    public nonisolated func responses() -> AsyncThrowingStream<Resp, Error> {
        let stream = self.stream
        let deserializer = self.deserializer
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    while let data = try await stream.recv() {
                        let msg = try deserializer(data)
                        continuation.yield(msg)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

import Foundation

/// A handle to a streaming RPC opened via `PluginHost.openStream`.
///
/// `PluginStream` is an `actor` so concurrent `send` / `recv` calls from
/// different tasks are serialised. The underlying C ABI is single-threaded
/// per stream handle, so this matches the plugin's expectations.
///
/// Lifetime: holds a *strong* reference to its `PluginHost`. The C function
/// pointers cached in `funcs` are only valid while the host's dylib is
/// loaded, so the stream must keep the host (and therefore the dlopen
/// handle) alive until it is closed. `PluginHost.openStreams` correspondingly
/// holds weak refs to avoid a retain cycle.
///
/// Closing semantics:
///   - `close()` is idempotent.
///   - The host may call `closeFromHost()` to cascade-close on its own teardown.
///   - After close, all methods throw `PluginClosedError`.
public final actor PluginStream {

    private let host: PluginHost
    private let handle: UInt64
    private let funcs: StreamFuncs
    private let free: SynurangFreeFn
    private var closed: Bool = false
    private var receiving: Bool = false

    internal init(
        host: PluginHost,
        handle: UInt64,
        funcs: StreamFuncs,
        free: @escaping SynurangFreeFn
    ) {
        self.host = host
        self.handle = handle
        self.funcs = funcs
        self.free = free
    }

    /// Sends a payload to the stream.
    public func send(_ data: Data) async throws {
        if closed { throw PluginClosedError() }
        if await host.isClosed() { throw PluginClosedError() }

        let dataLen = Int32(data.count)
        var dataPtr: UnsafeMutablePointer<CChar>? = nil
        if data.count > 0 {
            let p = UnsafeMutablePointer<CChar>.allocate(capacity: data.count)
            data.withUnsafeBytes { raw in
                if let base = raw.bindMemory(to: CChar.self).baseAddress {
                    p.initialize(from: base, count: data.count)
                }
            }
            dataPtr = p
        }
        defer { dataPtr?.deallocate() }

        let result = funcs.send(handle, dataPtr, dataLen)
        if result != 0 {
            throw FfiError(message: "Stream send failed with code \(result)")
        }
    }

    /// Receives the next response payload. Returns `nil` on EOF.
    /// Throws `FfiError` on stream error.
    public func recv() async throws -> Data? {
        if closed { throw PluginClosedError() }
        if await host.isClosed() { throw PluginClosedError() }
        if receiving {
            throw FfiError(message: "Stream recv already in progress")
        }
        receiving = true
        defer { receiving = false }

        return try await Self.recvBlocking(handle: handle, funcs: funcs, free: free)
    }

    private nonisolated static func recvBlocking(
        handle: UInt64,
        funcs: StreamFuncs,
        free: @escaping SynurangFreeFn
    ) async throws -> Data? {
        try await Task.detached {
            () throws -> Data? in

            var respLen: Int32 = 0
            var status: Int32 = 0
            let resultPtr = funcs.recv(handle, &respLen, &status)

            if status == 1 {
                // EOF
                if let p = resultPtr { free(p) }
                return nil
            }

            if status < 0 {
                // Error path: payload (if any) is a serialized FfiError proto.
                if let p = resultPtr {
                    defer { free(p) }
                    if respLen > 0 {
                        var bytes = Data()
                        p.withMemoryRebound(to: UInt8.self, capacity: Int(respLen)) { typed in
                            bytes = Data(bytes: typed, count: Int(respLen))
                        }
                        throw FfiError.fromPayload(bytes)
                    }
                }
                throw FfiError(message: "Stream recv failed with status \(status)")
            }

            if status != 0 {
                if let p = resultPtr { free(p) }
                throw FfiError(message: "Stream recv failed with status \(status)")
            }

            // Normal data
            guard let p = resultPtr else {
                if respLen == 0 { return Data() }
                throw FfiError(message: "Plugin returned null for stream recv")
            }
            defer { free(p) }

            var payload = Data()
            if respLen > 0 {
                let n = Int(respLen)
                p.withMemoryRebound(to: UInt8.self, capacity: n) { typed in
                    payload = Data(bytes: typed, count: n)
                }
            }
            return payload
        }.value
    }

    /// Closes the send side. The stream can still receive after this.
    public func closeSend() async throws {
        if closed { throw PluginClosedError() }
        if await host.isClosed() { throw PluginClosedError() }
        funcs.closeSend(handle)
    }

    /// Closes the stream fully. Idempotent.
    public func close() async {
        if closed { return }
        closed = true
        funcs.close(handle)
        await host.unregisterStream(handle)
    }

    /// Called from `PluginHost.close()`. Same behaviour as `close()` but
    /// the host has already removed us from its tracking map.
    internal func closeFromHost() async {
        if closed { return }
        closed = true
        funcs.close(handle)
    }
}

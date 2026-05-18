import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// MARK: - C ABI function pointer typealiases
//
// Mirrors csharp/Synurang/NativeDelegates.cs:
//
//   char* Synurang_Invoke_<Service>(const char* method, const char* data,
//                                    int data_len, int* resp_len);
//   void  Synurang_Free(char* ptr);
//   uint64_t Synurang_Stream_<Service>_Open(const char* method);
//   int   Synurang_Stream_Send(uint64_t handle, const char* data, int data_len);
//   char* Synurang_Stream_Recv(uint64_t handle, int* resp_len, int* status);
//   void  Synurang_Stream_CloseSend(uint64_t handle);
//   void  Synurang_Stream_Close(uint64_t handle);

public typealias SynurangInvokeFn = @convention(c) (
    UnsafePointer<CChar>?,        // method (UTF-8 C string)
    UnsafePointer<CChar>?,        // data ptr (may be nil if data_len == 0)
    Int32,                        // data_len
    UnsafeMutablePointer<Int32>?  // out resp_len
) -> UnsafeMutablePointer<CChar>?

public typealias SynurangFreeFn = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void

public typealias SynurangStreamOpenFn = @convention(c) (
    UnsafePointer<CChar>?
) -> UInt64

public typealias SynurangStreamSendFn = @convention(c) (
    UInt64,
    UnsafePointer<CChar>?,
    Int32
) -> Int32

public typealias SynurangStreamRecvFn = @convention(c) (
    UInt64,
    UnsafeMutablePointer<Int32>?, // out resp_len
    UnsafeMutablePointer<Int32>?  // out status
) -> UnsafeMutablePointer<CChar>?

public typealias SynurangStreamCloseFn = @convention(c) (UInt64) -> Void

/// Bundle of stream function pointers resolved lazily from the plugin.
internal struct StreamFuncs: @unchecked Sendable {
    let send: SynurangStreamSendFn
    let recv: SynurangStreamRecvFn
    let closeSend: SynurangStreamCloseFn
    let close: SynurangStreamCloseFn
}

/// Weak wrapper so `PluginHost.openStreams` can track streams without
/// retaining them — streams keep a strong ref back to the host (so the
/// dylib outlives them), and that cycle is broken by this weak edge.
private final class WeakStreamRef {
    weak var stream: PluginStream?
    init(_ stream: PluginStream) { self.stream = stream }
}

/// Loads and communicates with Synurang plugins (Go/C++/Rust shared
/// libraries) via dlopen/dlsym + the Synurang C ABI.
///
/// `PluginHost` is an `actor`: all symbol-table mutations and invocations
/// are serialised on the actor executor. This buys most of the
/// thread-safety the .NET version achieves with `ManualResetEventSlim`
/// + `Interlocked` refcounts — at the cost that a long-running invoke
/// will queue subsequent calls behind it. For Phase A this is acceptable:
/// the generated lite stubs hand each `async throws` call directly to the
/// host actor and Swift concurrency dispatches them fairly.
///
/// Close semantics:
///   - `close()` flips the `closed` flag.
///   - Streams currently open are closed in turn (`PluginStream.closeFromHost`).
///   - Subsequent calls throw `PluginClosedError`.
///   - `dlclose` is deferred to `deinit` so a pending caller never trips
///     over a freed function pointer. Memory cost is one library handle;
///     XCFramework consumers using `attachToProcess` don't pay it.
public final actor PluginHost {

    // MARK: - State

    private let handle: NativeLoader.Handle?
    private let owns: Bool        // true if we should dlclose on deinit
    private let free: SynurangFreeFn

    private var closed: Bool = false
    private var invokers: [String: SynurangInvokeFn] = [:]
    private var streamOpeners: [String: SynurangStreamOpenFn] = [:]
    private var streamFuncs: StreamFuncs?

    // Open streams are tracked by their numeric handle so close() can
    // cascade-close. Held weakly so the stream → host → stream cycle does
    // not leak when the user simply drops a stream without calling close().
    // Streams unregister themselves on their own close().
    private var openStreams: [UInt64: WeakStreamRef] = [:]

    // MARK: - Construction

    private init(handle: NativeLoader.Handle?, owns: Bool, free: SynurangFreeFn) {
        self.handle = handle
        self.owns = owns
        self.free = free
    }

    /// Loads the plugin at `path` (dlopen) and resolves `Synurang_Free`.
    public static func load(path: String) throws -> PluginHost {
        let h = try NativeLoader.load(path)
        do {
            let freeSym = try NativeLoader.resolve("Synurang_Free", in: h)
            let free = unsafeBitCast(freeSym, to: SynurangFreeFn.self)
            return PluginHost(handle: h, owns: true, free: free)
        } catch {
            NativeLoader.free(h)
            throw error
        }
    }

    /// Attaches to the host process image (RTLD_DEFAULT). Use this when
    /// the Synurang C ABI symbols are statically linked into the main app
    /// binary (typical XCFramework setup).
    public static func attachToProcess() throws -> PluginHost {
        let h = NativeLoader.loadProcess()
        let freeSym = try NativeLoader.resolve("Synurang_Free", in: h)
        let free = unsafeBitCast(freeSym, to: SynurangFreeFn.self)
        return PluginHost(handle: h, owns: false, free: free)
    }

    deinit {
        if owns, let h = handle {
            NativeLoader.free(h)
        }
    }

    // MARK: - Lifecycle

    /// Marks the host as closed and cascades close to all open streams.
    /// Idempotent.
    public func close() async {
        if closed { return }
        closed = true
        let streams = openStreams.values.compactMap { $0.stream }
        for s in streams {
            // Best-effort: swallow errors during teardown.
            await s.closeFromHost()
        }
        openStreams.removeAll()
    }

    // MARK: - Unary invoke

    /// Invokes a unary RPC. Returns the raw response bytes on success;
    /// throws `FfiError` on error responses, `PluginClosedError` if the
    /// host is closed.
    public func invoke(
        service: String,
        method: String,
        data: Data
    ) async throws -> Data {
        if closed { throw PluginClosedError() }

        let invoker = try getInvoker(service: service)

        // Copy method to a heap-allocated NUL-terminated UTF-8 buffer.
        let methodBytes = Array(method.utf8) + [0]
        let methodPtr = UnsafeMutablePointer<CChar>.allocate(capacity: methodBytes.count)
        defer { methodPtr.deallocate() }
        methodBytes.withUnsafeBufferPointer { src in
            src.baseAddress!.withMemoryRebound(to: CChar.self, capacity: methodBytes.count) { typed in
                methodPtr.initialize(from: typed, count: methodBytes.count)
            }
        }

        // Copy payload to a heap buffer (may be empty).
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

        var respLen: Int32 = 0
        let resultPtr = invoker(methodPtr, dataPtr, dataLen, &respLen)

        guard let result = resultPtr else {
            if respLen == 0 { return Data() }
            throw FfiError(message: "Plugin returned null for \(method)")
        }
        defer { free(result) }

        let copyLen = Int(respLen < 0 ? -respLen : respLen)
        var payload = Data()
        if copyLen > 0 {
            result.withMemoryRebound(to: UInt8.self, capacity: copyLen) { typed in
                payload = Data(bytes: typed, count: copyLen)
            }
        }

        if respLen < 0 {
            throw FfiError.fromPayload(payload)
        }
        return payload
    }

    // MARK: - Streaming

    /// Opens a streaming RPC. The returned `PluginStream` is owned by the
    /// host until `close()` is called on it (or on the host).
    public func openStream(
        service: String,
        method: String
    ) async throws -> PluginStream {
        if closed { throw PluginClosedError() }

        let opener = try getStreamOpener(service: service)
        let funcs = try ensureStreamFuncs()

        let methodBytes = Array(method.utf8) + [0]
        let methodPtr = UnsafeMutablePointer<CChar>.allocate(capacity: methodBytes.count)
        defer { methodPtr.deallocate() }
        methodBytes.withUnsafeBufferPointer { src in
            src.baseAddress!.withMemoryRebound(to: CChar.self, capacity: methodBytes.count) { typed in
                methodPtr.initialize(from: typed, count: methodBytes.count)
            }
        }

        let streamHandle = opener(methodPtr)
        if streamHandle == 0 {
            throw FfiError(message: "Failed to open stream for \(method)")
        }

        let stream = PluginStream(host: self, handle: streamHandle, funcs: funcs, free: free)
        openStreams[streamHandle] = WeakStreamRef(stream)
        return stream
    }

    // MARK: - Internal hooks for PluginStream

    internal func unregisterStream(_ h: UInt64) {
        openStreams.removeValue(forKey: h)
    }

    internal func isClosed() -> Bool { closed }

    // MARK: - Symbol resolution

    private func getInvoker(service: String) throws -> SynurangInvokeFn {
        if let cached = invokers[service] { return cached }
        let symName = "Synurang_Invoke_\(service)"
        let sym = try NativeLoader.resolve(symName, in: handle)
        let fn = unsafeBitCast(sym, to: SynurangInvokeFn.self)
        invokers[service] = fn
        return fn
    }

    private func getStreamOpener(service: String) throws -> SynurangStreamOpenFn {
        if let cached = streamOpeners[service] { return cached }
        let symName = "Synurang_Stream_\(service)_Open"
        let sym = try NativeLoader.resolve(symName, in: handle)
        let fn = unsafeBitCast(sym, to: SynurangStreamOpenFn.self)
        streamOpeners[service] = fn
        return fn
    }

    private func ensureStreamFuncs() throws -> StreamFuncs {
        if let cached = streamFuncs { return cached }
        let sendSym = try NativeLoader.resolve("Synurang_Stream_Send", in: handle)
        let recvSym = try NativeLoader.resolve("Synurang_Stream_Recv", in: handle)
        let csSym = try NativeLoader.resolve("Synurang_Stream_CloseSend", in: handle)
        let clSym = try NativeLoader.resolve("Synurang_Stream_Close", in: handle)
        let f = StreamFuncs(
            send: unsafeBitCast(sendSym, to: SynurangStreamSendFn.self),
            recv: unsafeBitCast(recvSym, to: SynurangStreamRecvFn.self),
            closeSend: unsafeBitCast(csSym, to: SynurangStreamCloseFn.self),
            close: unsafeBitCast(clSym, to: SynurangStreamCloseFn.self)
        )
        streamFuncs = f
        return f
    }
}

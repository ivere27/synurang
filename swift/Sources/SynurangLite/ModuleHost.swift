import Foundation

// A stored generation closes the check-to-suspend race. Native callbacks only
// resume tasks; they never enter the actor or call the provider inline.
private final class ModuleSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var version: UInt64 { lock.lock(); defer { lock.unlock() }; return generation }
    func wake() {
        lock.lock()
        generation &+= 1
        let waiting = waiters
        waiters.removeAll()
        lock.unlock()
        for waiter in waiting { waiter.resume() }
    }
    func wait(after version: UInt64) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if generation != version { lock.unlock(); continuation.resume() }
            else { waiters.append(continuation); lock.unlock() }
        }
    }
}

private func moduleWakeup(_ data: UnsafeMutableRawPointer?) {
    guard let data else { return }
    Unmanaged<ModuleSignal>.fromOpaque(data).takeUnretainedValue().wake()
}

public struct ModuleRpcError: Error, Sendable, CustomStringConvertible {
    public let code: Int32
    /// Serialized core.v1.Error supplied by the module, when available.
    public let details: Data
    public let description: String
    public init(code: Int32, message: String, details: Data = Data()) {
        self.code = code; self.description = message; self.details = details
    }
}

public struct ModuleCallOptions: Sendable {
    public var timeoutMilliseconds: UInt64?
    public init(timeoutMilliseconds: UInt64? = nil) { self.timeoutMilliseconds = timeoutMilliseconds }
}

/// The peer closed its request side. Responses and terminal status are still readable.
public struct ModuleRequestClosedError: Error, Sendable {
    public init() { }
}

public protocol ModuleCallTransport: Sendable {
    func open(path: String, requestStream: Bool, responseStream: Bool,
              options: ModuleCallOptions) async throws -> any ModuleCallChannel
}

public protocol ModuleCallChannel: Sendable {
    func send(_ data: Data) async throws
    func halfClose() async throws
    func receive() async throws -> Data?
    func cancel() async
    func close() async
}

/// An independently owned module instance. Its actor serializes all native entry
/// calls, while pending operations suspend their Swift task. The native module
/// loader shim must be installed alongside the application.
public final actor ModuleHost: ModuleCallTransport {
    private let native: ModuleNative
    private let notification = ModuleSignal()
    private let progress = ModuleSignal()
    private var address: UInt
    private var pointer: UnsafeMutableRawPointer? {
        get { UnsafeMutableRawPointer(bitPattern: address) }
        set { address = newValue.map { UInt(bitPattern: $0) } ?? 0 }
    }
    private var closing = false
    private var closeTask: Task<Void, Error>?
    private var calls: [UInt64: Entry] = [:]
    private struct Entry {
        var error: ModuleRpcError?
        var finished = false
        var sending = false
        var receiving = false
        var pending: Data?
        var deadline: Task<Void, Never>?
    }

    private init(native: ModuleNative, address: UInt) {
        self.native = native; self.address = address
        native.setWakeup(UnsafeMutableRawPointer(bitPattern: address), moduleWakeup,
                         Unmanaged.passUnretained(notification).toOpaque())
        Task { [weak self, notification] in
            var version: UInt64 = 0
            while true {
                await notification.wait(after: version)
                version = notification.version
                guard await self?.drain() == true else { return }
                await Task.yield()
            }
        }
    }

    private func drain() -> Bool {
        guard let pointer else { return false }
        _ = native.poll(pointer, 64)
        progress.wake()
        if native.hasWork(pointer) != 0 { notification.wake() }
        return true
    }
    fileprivate var generation: UInt64 { progress.version }
    fileprivate func wait(after version: UInt64) async { await progress.wait(after: version) }

    public static func load(path: String, symbol: String = "Synurang_GetApi",
                            loaderPath: String? = nil) throws -> ModuleHost {
        let native = try ModuleNative(path: loaderPath)
        let pointer = path.withCString { path in
            symbol.withCString { symbol in native.load(path, symbol, nil) }
        }
        guard let pointer else { throw NativeLoaderError(native.lastError()) }
        return ModuleHost(native: native, address: UInt(bitPattern: pointer))
    }

    /// The caller keeps the statically linked API table and code alive until close finishes.
    public static func linked(api: UnsafeRawPointer, loaderPath: String? = nil) throws -> ModuleHost {
        let native = try ModuleNative(path: loaderPath, inProcess: loaderPath == nil)
        guard let pointer = native.linked(api, nil) else { throw NativeLoaderError(native.lastError()) }
        return ModuleHost(native: native, address: UInt(bitPattern: pointer))
    }

    public func open(path: String, requestStream: Bool, responseStream: Bool,
                     options: ModuleCallOptions = .init()) async throws -> any ModuleCallChannel {
        guard !closing, let pointer else { throw ModuleRpcError(code: 14, message: "Module is closed") }
        let id = native.openCall(pointer, path: path, requestStream: requestStream,
                                 responseStream: responseStream, timeout: options.timeoutMilliseconds)
        guard id != 0 else { throw ModuleRpcError(code: 13, message: "Module could not open call") }
        calls[id] = Entry()
        if let timeout = options.timeoutMilliseconds {
            let delay = min(timeout, UInt64.max / 1_000_000) * 1_000_000
            calls[id]?.deadline = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: delay) } catch { return }
                await self?.cancel(id, code: 4)
            }
        }
        if Task.isCancelled { cancel(id, code: 1) }
        return ModuleCall(host: self, id: id)
    }

    fileprivate func cancel(_ id: UInt64, code: Int32 = 1) {
        guard var entry = calls[id], !entry.finished, entry.error == nil, let pointer else { return }
        entry.error = ModuleRpcError(code: code, message: code == 4 ? "Deadline exceeded" : "Call cancelled")
        calls[id] = entry
        _ = native.cancel(pointer, id, code)
        notification.wake()
        progress.wake()
    }

    private func check(_ id: UInt64) throws {
        if Task.isCancelled { cancel(id) }
        guard let entry = calls[id], pointer != nil else { throw ModuleRpcError(code: 1, message: "Call closed") }
        if let error = entry.error { throw error }
    }

    fileprivate func begin(_ id: UInt64, sending: Bool) throws {
        try check(id)
        guard var entry = calls[id] else { return }
        if sending ? entry.sending : entry.receiving {
            throw ModuleRpcError(code: 9, message: "Concurrent operations in the same stream direction are unsupported")
        }
        if sending { entry.sending = true } else { entry.receiving = true }
        calls[id] = entry
    }
    fileprivate func end(_ id: UInt64, sending: Bool) {
        if sending { calls[id]?.sending = false } else { calls[id]?.receiving = false }
    }

    fileprivate func send(_ id: UInt64, data: Data) throws -> Bool {
        try check(id)
        guard let pointer else { throw ModuleRpcError(code: 1, message: "Call closed") }
        guard data.count <= Int(UInt32.max) else { throw ModuleRpcError(code: 3, message: "Message too large") }
        let status = data.withUnsafeBytes { native.send(pointer, id, $0.baseAddress, UInt32(data.count)) }
        if status == 0 { return true }
        if status == -4 || status == 3 { return false }
        try closedInput(id, status: status)
    }

    fileprivate func halfClose(_ id: UInt64) throws {
        try check(id)
        guard let pointer else { throw ModuleRpcError(code: 1, message: "Call closed") }
        let status = native.halfClose(pointer, id)
        if status != 0 {
            try closedInput(id, status: status)
        }
    }

    private func closedInput(_ id: UInt64, status: Int32) throws -> Never {
        if calls[id]?.pending == nil, case .message(let data) = try read(id) {
            calls[id]?.pending = data
        }
        throw ModuleRequestClosedError()
    }

    fileprivate enum Read: Sendable { case pending, message(Data), finished }
    fileprivate func read(_ id: UInt64) throws -> Read {
        try check(id)
        guard let pointer else { throw ModuleRpcError(code: 1, message: "Call closed") }
        if calls[id]?.finished == true { return .finished }
        if let pending = calls[id]?.pending {
            calls[id]?.pending = nil
            return .message(pending)
        }
        // This is the C layout, not a Swift struct's unspecified layout.
        let pointerSize = MemoryLayout<UnsafeRawPointer>.size
        let result = UnsafeMutableRawPointer.allocate(byteCount: 24, alignment: 8)
        defer { result.deallocate() }
        result.initializeMemory(as: UInt8.self, repeating: 0, count: 24)
        let status = native.receive(pointer, id, result)
        let kind = result.load(as: UInt32.self)
        let code = result.load(fromByteOffset: 4, as: Int32.self)
        let buffer = result.load(fromByteOffset: 8, as: UnsafeMutableRawPointer?.self)
        let size = result.load(fromByteOffset: 8 + pointerSize, as: UInt32.self)
        defer { if let buffer { native.free(pointer, buffer) } }
        if status != 0 { throw ModuleRpcError(code: 13, message: "Module receive failed: \(status)") }
        let data: Data
        if size == 0 { data = Data() }
        else if let buffer { data = Data(bytes: buffer, count: Int(size)) }
        else { throw ModuleRpcError(code: 13, message: "Module returned a null buffer") }
        switch kind {
        case 0: return .pending
        case 1: return .message(data)
        case 2:
            calls[id]?.finished = true
            calls[id]?.deadline?.cancel()
            if code != 0 {
                let error = ModuleRpcError(code: code, message: "RPC failed (\(code))", details: data)
                calls[id]?.error = error
                throw error
            }
            return .finished
        default: throw ModuleRpcError(code: 13, message: "Invalid module read kind")
        }
    }

    fileprivate func release(_ id: UInt64) {
        guard let entry = calls.removeValue(forKey: id), let pointer else { return }
        entry.deadline?.cancel()
        if !entry.finished { _ = native.cancel(pointer, id, 1) }
        native.release(pointer, id)
        notification.wake()
        progress.wake()
    }

    /// Cancels calls immediately; awaits retained native producer cleanup before unloading.
    public func close() async throws {
        if let closeTask { return try await closeTask.value }
        closing = true
        for id in Array(calls.keys) { release(id) }
        let task = Task { try await self.finishClose() }
        closeTask = task
        try await task.value
    }

    private func finishClose() async throws {
        while let pointer {
            let version = progress.version
            let status = native.destroy(pointer)
            if status == 0 { self.pointer = nil; progress.wake(); notification.wake(); return }
            if status != 3 { throw ModuleRpcError(code: 13, message: "Module shutdown failed: \(status)") }
            // Teardown must complete even if the closing task was cancelled.
            if native.hasWork(pointer) != 0 { notification.wake() }
            await progress.wait(after: version)
        }
    }

    deinit {
        // A dropped host still owns producer cleanup. Keep both libraries alive
        // in an independent task until destroy reports that unloading is safe.
        if let pointer = UnsafeMutableRawPointer(bitPattern: address) {
            ModuleRetirement(native: native, pointer: pointer, notification: notification).start()
        }
        notification.wake()
    }
}

public final class ModuleCall: ModuleCallChannel {
    private let host: ModuleHost
    private let id: UInt64
    fileprivate init(host: ModuleHost, id: UInt64) { self.host = host; self.id = id }
    deinit { let host = host, id = id; Task { await host.release(id) } }

    public func send(_ data: Data) async throws {
        try await withTaskCancellationHandler(operation: {
            try await host.begin(id, sending: true)
            do {
                while true {
                    let version = await host.generation
                    if try await host.send(id, data: data) { break }
                    await host.wait(after: version)
                }
                await host.end(id, sending: true)
            } catch {
                if Task.isCancelled { await host.cancel(id) }
                await host.end(id, sending: true)
                if error is CancellationError { throw ModuleRpcError(code: 1, message: "Call cancelled") }
                throw error
            }
        }, onCancel: { Task { await self.host.cancel(self.id) } })
    }

    public func halfClose() async throws {
        try await host.begin(id, sending: true)
        do { try await host.halfClose(id); await host.end(id, sending: true) }
        catch { await host.end(id, sending: true); throw error }
    }

    public func receive() async throws -> Data? {
        try await withTaskCancellationHandler(operation: {
            try await host.begin(id, sending: false)
            do {
                while true {
                    let version = await host.generation
                    switch try await host.read(id) {
                    case .pending: await host.wait(after: version)
                    case .message(let data): await host.end(id, sending: false); return data
                    case .finished: await host.end(id, sending: false); return nil
                    }
                }
            } catch {
                if Task.isCancelled { await host.cancel(id) }
                await host.end(id, sending: false)
                if error is CancellationError { throw ModuleRpcError(code: 1, message: "Call cancelled") }
                throw error
            }
        }, onCancel: { Task { await self.host.cancel(self.id) } })
    }
    public func cancel() async { await host.cancel(id) }
    public func close() async { await host.release(id) }
}

/// Function pointers are immutable and only invoked by ModuleHost's actor.
private final class ModuleNative: @unchecked Sendable {
    typealias Load = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafeRawPointer?) -> UnsafeMutableRawPointer?
    typealias Linked = @convention(c) (UnsafeRawPointer?, UnsafeRawPointer?) -> UnsafeMutableRawPointer?
    typealias LastError = @convention(c) () -> UnsafePointer<CChar>?
    typealias Open = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafeRawPointer?) -> UInt64
    typealias Send = @convention(c) (UnsafeMutableRawPointer?, UInt64, UnsafeRawPointer?, UInt32) -> Int32
    typealias HalfClose = @convention(c) (UnsafeMutableRawPointer?, UInt64) -> Int32
    typealias Receive = @convention(c) (UnsafeMutableRawPointer?, UInt64, UnsafeMutableRawPointer?) -> Int32
    typealias Cancel = @convention(c) (UnsafeMutableRawPointer?, UInt64, Int32) -> Int32
    typealias Release = @convention(c) (UnsafeMutableRawPointer?, UInt64) -> Void
    typealias Free = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
    typealias Poll = @convention(c) (UnsafeMutableRawPointer?, UInt32) -> UInt32
    typealias Destroy = @convention(c) (UnsafeMutableRawPointer?) -> Int32
    typealias Wakeup = @convention(c) (UnsafeMutableRawPointer?) -> Void
    typealias SetWakeup = @convention(c) (UnsafeMutableRawPointer?, Wakeup?, UnsafeMutableRawPointer?) -> Void
    let load: Load, linked: Linked, error: LastError, open: Open, send: Send
    let halfClose: HalfClose, receive: Receive, cancel: Cancel, release: Release, free: Free, poll: Poll, destroy: Destroy
    let setWakeup: SetWakeup, hasWork: Destroy
    private let library: NativeLoader.Handle?
    private let ownsLibrary: Bool
    init(path: String?, inProcess: Bool = false) throws {
        #if os(Windows)
        let defaultPath = "synurang_module_host.dll"
        #elseif canImport(Darwin)
        let defaultPath = "libsynurang_module_host.dylib"
        #else
        let defaultPath = "libsynurang_module_host.so"
        #endif
        let library = inProcess ? NativeLoader.loadProcess() : try NativeLoader.load(path ?? defaultPath)
        self.library = library
        self.ownsLibrary = !inProcess
        func symbol<T>(_ name: String, _ type: T.Type) throws -> T {
            unsafeBitCast(try NativeLoader.resolve("synurang_host_" + name, in: library), to: type)
        }
        do {
            load = try symbol("load", Load.self); linked = try symbol("linked", Linked.self)
            error = try symbol("error", LastError.self); open = try symbol("open", Open.self)
            send = try symbol("send", Send.self); halfClose = try symbol("half_close", HalfClose.self)
            receive = try symbol("receive", Receive.self); cancel = try symbol("cancel", Cancel.self)
            release = try symbol("release", Release.self); free = try symbol("free", Free.self)
            poll = try symbol("poll", Poll.self); destroy = try symbol("destroy", Destroy.self)
            setWakeup = try symbol("set_wakeup", SetWakeup.self); hasWork = try symbol("has_work", Destroy.self)
        } catch { if !inProcess, let library { NativeLoader.free(library) }; throw error }
    }
    func lastError() -> String { error().map { String(cString: $0) } ?? "Native loader failed" }
    func openCall(_ pointer: UnsafeMutableRawPointer, path: String, requestStream: Bool,
                  responseStream: Bool, timeout: UInt64?) -> UInt64 {
        let bytes = UnsafeMutableRawPointer.allocate(byteCount: 24, alignment: 8)
        defer { bytes.deallocate() }
        bytes.initializeMemory(as: UInt8.self, repeating: 0, count: 24)
        bytes.storeBytes(of: UInt32(24), as: UInt32.self)
        bytes.storeBytes(of: UInt32(requestStream ? 1 : 0), toByteOffset: 4, as: UInt32.self)
        bytes.storeBytes(of: UInt32(responseStream ? 1 : 0), toByteOffset: 8, as: UInt32.self)
        bytes.storeBytes(of: timeout ?? UInt64.max, toByteOffset: 16, as: UInt64.self)
        return path.withCString { open(pointer, $0, bytes) }
    }
    deinit { if ownsLibrary, let library { NativeLoader.free(library) } }
}

private final class ModuleRetirement: @unchecked Sendable {
    let native: ModuleNative
    let pointer: UnsafeMutableRawPointer
    let notification: ModuleSignal
    init(native: ModuleNative, pointer: UnsafeMutableRawPointer, notification: ModuleSignal) {
        self.native = native; self.pointer = pointer; self.notification = notification
    }
    func start() {
        Task.detached {
            while true {
                let version = self.notification.version
                _ = self.native.poll(self.pointer, 64)
                let status = self.native.destroy(self.pointer)
                if status == 0 { return }
                if status != 3 { return } // Keep the provider loaded if it cannot safely stop.
                if self.native.hasWork(self.pointer) != 0 { await Task.yield() }
                else { await self.notification.wait(after: version) }
            }
        }
    }
}

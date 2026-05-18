import XCTest
@testable import SynurangLite

/// Swift counterpart to `test/host/csharp-brute/Program.cs` and
/// `test/host/java/JavaHostBruteTest.java`.
///
/// Gated on `SYNURANG_BRUTE=1` *and* `SYNURANG_TEST_PLUGIN_PATH` — these tests
/// stress concurrency, lifetime and resource handling. Defaults are tuned for
/// a single Docker container minute; override with:
///
///   SYNURANG_BRUTE=1
///   SYNURANG_BRUTE_DURATION=30s   (or "2m" / "5000ms")
///   SYNURANG_BRUTE_WORKERS=4
///   SYNURANG_BRUTE_MAX_FD_DELTA=128
///   SYNURANG_BRUTE_MAX_RSS_MB_DELTA=256
///   SYNURANG_TEST_PLUGIN_PATH=/path/to/libplugin_go.so
///
/// The suite checks for both *correctness* (no unexpected errors during the
/// chaos mix) and *liveness* (no FD / RSS leak across all phases).
final class PluginStressTests: XCTestCase {

    private static let serviceName = "GoGreeterService"
    private static let unaryMethod = "/example.v1.GoGreeterService/Bar"
    private static let serverStreamMethod = "/example.v1.GoGreeterService/BarServerStream"
    private static let clientStreamMethod = "/example.v1.GoGreeterService/BarClientStream"
    private static let bidiStreamMethod = "/example.v1.GoGreeterService/BarBidiStream"

    // MARK: - Environment helpers

    private struct Env {
        let pluginPath: String
        let duration: TimeInterval
        let workers: Int
        let maxFdDelta: Int
        let maxRssMbDelta: Int

        static func load() throws -> Env {
            let p = ProcessInfo.processInfo.environment
            guard p["SYNURANG_BRUTE"] == "1" else {
                throw XCTSkip("set SYNURANG_BRUTE=1 to run Swift brute test")
            }
            guard let path = p["SYNURANG_TEST_PLUGIN_PATH"] else {
                throw XCTSkip("set SYNURANG_TEST_PLUGIN_PATH to run brute test")
            }
            return Env(
                pluginPath: path,
                duration: parseDuration(p["SYNURANG_BRUTE_DURATION"]) ?? 60,
                workers: parseInt(p["SYNURANG_BRUTE_WORKERS"]) ?? 4,
                maxFdDelta: parseInt(p["SYNURANG_BRUTE_MAX_FD_DELTA"]) ?? 128,
                maxRssMbDelta: parseInt(p["SYNURANG_BRUTE_MAX_RSS_MB_DELTA"]) ?? 256
            )
        }
    }

    private static func parseInt(_ s: String?) -> Int? {
        guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        return Int(s)
    }

    private static func parseDuration(_ s: String?) -> TimeInterval? {
        guard let raw = s?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        let lower = raw.lowercased()
        if lower.hasSuffix("ms"), let n = Double(lower.dropLast(2)) { return n / 1000 }
        if lower.hasSuffix("s"), let n = Double(lower.dropLast(1)) { return n }
        if lower.hasSuffix("m"), let n = Double(lower.dropLast(1)) { return n * 60 }
        if let n = Double(lower) { return n }
        return nil
    }

    // MARK: - Resource snapshots

    private struct ResourceSnapshot {
        let fdCount: Int?
        let rssBytes: Int64?

        static func capture() -> ResourceSnapshot {
            let fdCount: Int? = {
                guard let listing = try? FileManager.default.contentsOfDirectory(atPath: "/proc/self/fd") else {
                    return nil
                }
                return listing.count
            }()
            let rss: Int64? = {
                guard let raw = try? String(contentsOfFile: "/proc/self/statm", encoding: .utf8) else {
                    return nil
                }
                let parts = raw.split(separator: " ")
                guard parts.count >= 2, let pages = Int64(parts[1]) else { return nil }
                return pages * 4096
            }()
            return ResourceSnapshot(fdCount: fdCount, rssBytes: rss)
        }
    }

    // MARK: - Wire helpers (same as C# brute test)

    private func makeHelloRequest(_ name: String) -> Data {
        var w = ProtoWriter()
        w.writeString(fieldNumber: 1, value: name)
        return w.data
    }

    private func makeHelloRequestWithLanguage(_ name: String, _ language: String) -> Data {
        var w = ProtoWriter()
        if !name.isEmpty { w.writeString(fieldNumber: 1, value: name) }
        if !language.isEmpty { w.writeString(fieldNumber: 2, value: language) }
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

    // MARK: - Error classification (matches csharp-brute)

    private func isExpectedError(_ error: Error) -> Bool {
        if error is PluginClosedError { return true }
        if let ffi = error as? FfiError {
            let m = ffi.message.lowercased()
            if m.contains("deadline") || m.contains("cancel")
                || m.contains("closed") || m.contains("eof")
                || m.contains("broken pipe") || m.contains("connection") {
                return true
            }
        }
        let msg = String(describing: error).lowercased()
        return msg.contains("cancel") || msg.contains("deadline")
            || msg.contains("closed") || msg.contains("eof")
            || msg.contains("broken pipe") || msg.contains("plugin is closed")
            || msg.contains("returned zero")
    }

    // MARK: - Phase counters (actor — thread-safe across worker tasks)

    private actor PhaseStats {
        var ops: Int = 0
        var expected: Int = 0
        var unexpected: Int = 0
        var firstUnexpected: String?

        func recordOp() { ops += 1 }
        func recordExpected() { expected += 1 }
        func recordUnexpected(_ what: String) {
            unexpected += 1
            if firstUnexpected == nil { firstUnexpected = what }
        }
    }

    // MARK: - Random op mix

    private func runRandomOp(host: PluginHost, rng: inout SystemRandomNumberGenerator,
                              workerId: Int) async throws {
        let x = Int.random(in: 0..<100, using: &rng)
        switch x {
        case ..<40:  try await opUnary(host: host, workerId: workerId, rng: &rng)
        case ..<62:  try await opServerStream(host: host, workerId: workerId, rng: &rng)
        case ..<78:  try await opClientStream(host: host, workerId: workerId, rng: &rng)
        case ..<88:  try await opBidi(host: host, workerId: workerId, rng: &rng)
        default:     try await opChaos(host: host, workerId: workerId, rng: &rng)
        }
    }

    private func opUnary(host: PluginHost, workerId: Int,
                          rng: inout SystemRandomNumberGenerator) async throws {
        let marker = "u-\(workerId)-\(Int.random(in: 0..<Int.max, using: &rng))"
        let resp = try await host.invoke(
            service: Self.serviceName,
            method: Self.unaryMethod,
            data: makeHelloRequest(marker)
        )
        guard let msg = extractMessage(resp), msg.contains(marker) else {
            throw FfiError(message: "unary mismatch")
        }
    }

    private func opServerStream(host: PluginHost, workerId: Int,
                                 rng: inout SystemRandomNumberGenerator) async throws {
        let marker = "ss-\(workerId)-\(Int.random(in: 0..<Int.max, using: &rng))"
        let stream = try await host.openStream(
            service: Self.serviceName,
            method: Self.serverStreamMethod
        )
        defer { Task { await stream.close() } }
        try await stream.send(makeHelloRequest(marker))
        try await stream.closeSend()
        var count = 0
        while let data = try await stream.recv() {
            if extractMessage(data) == nil {
                throw FfiError(message: "server-stream parse")
            }
            count += 1
        }
        if count == 0 { throw FfiError(message: "server-stream returned zero messages") }
    }

    private func opClientStream(host: PluginHost, workerId: Int,
                                 rng: inout SystemRandomNumberGenerator) async throws {
        let stream = try await host.openStream(
            service: Self.serviceName,
            method: Self.clientStreamMethod
        )
        defer { Task { await stream.close() } }
        let n = 1 + Int.random(in: 0..<20, using: &rng)
        for i in 0..<n {
            try await stream.send(makeHelloRequest("cs-\(workerId)-\(i)"))
        }
        try await stream.closeSend()
        guard let resp = try await stream.recv(), extractMessage(resp) != nil else {
            throw FfiError(message: "client-stream parse")
        }
    }

    private func opBidi(host: PluginHost, workerId: Int,
                        rng: inout SystemRandomNumberGenerator) async throws {
        let stream = try await host.openStream(
            service: Self.serviceName,
            method: Self.bidiStreamMethod
        )
        defer { Task { await stream.close() } }
        let n = 1 + Int.random(in: 0..<12, using: &rng)
        for i in 0..<n {
            try await stream.send(makeHelloRequest("bs-\(workerId)-\(i)"))
        }
        try await stream.closeSend()
        var received = 0
        while let _ = try await stream.recv() { received += 1 }
        if received == 0 { throw FfiError(message: "bidi returned zero responses") }
    }

    private func opChaos(host: PluginHost, workerId: Int,
                          rng: inout SystemRandomNumberGenerator) async throws {
        let x = Int.random(in: 0..<100, using: &rng)
        if x < 25 {
            // Open + immediately close — exercises stream lifetime.
            let stream = try await host.openStream(
                service: Self.serviceName,
                method: Self.bidiStreamMethod
            )
            await stream.close()
            return
        }
        if x < 50 {
            // Best-effort: client-stream may error, that's fine.
            do { try await opClientStream(host: host, workerId: workerId, rng: &rng) }
            catch { /* expected */ }
            return
        }
        if x < 75 {
            // Large payload (64KB–256KB).
            let size = 64 * 1024 + Int.random(in: 0..<(192 * 1024), using: &rng)
            let pad = String(repeating: "B", count: size)
            _ = try await host.invoke(
                service: Self.serviceName,
                method: Self.unaryMethod,
                data: makeHelloRequestWithLanguage("boundary", pad)
            )
            return
        }
        // Fall through to server stream.
        try await opServerStream(host: host, workerId: workerId, rng: &rng)
    }

    // MARK: - Phase runner

    private func runPhase(host: PluginHost, duration: TimeInterval,
                          workers: Int, label: String) async -> (ops: Int, expected: Int, unexpected: Int, firstFail: String?) {
        let deadline = Date().addingTimeInterval(duration)
        let stats = PhaseStats()

        await withTaskGroup(of: Void.self) { group in
            for w in 0..<workers {
                let workerId = w
                let host = host
                let stats = stats
                let isExpected: (Error) -> Bool = { self.isExpectedError($0) }
                group.addTask {
                    var rng = SystemRandomNumberGenerator()
                    while Date() < deadline {
                        if Task.isCancelled { break }
                        do {
                            try await self.runRandomOp(host: host, rng: &rng, workerId: workerId)
                            await stats.recordOp()
                        } catch {
                            if isExpected(error) {
                                await stats.recordExpected()
                            } else {
                                await stats.recordUnexpected("worker \(workerId): \(error)")
                                return
                            }
                        }
                        // Small jitter so workers don't lock-step.
                        try? await Task.sleep(nanoseconds: UInt64.random(in: 1_000_000...6_000_000, using: &rng))
                    }
                }
            }
        }

        let snap = (
            ops: await stats.ops,
            expected: await stats.expected,
            unexpected: await stats.unexpected,
            firstFail: await stats.firstUnexpected
        )
        print("  [\(label)] ops=\(snap.ops) expected_errs=\(snap.expected) unexpected_errs=\(snap.unexpected)")
        return snap
    }

    // MARK: - The actual stress test

    func testBruteForceConcurrentMix() async throws {
        let env = try Env.load()

        print("===============================================================")
        print("  Swift Host Brute-Force Chaos Test")
        print("  duration=\(env.duration)s workers=\(env.workers)"
            + " max_fd_delta=\(env.maxFdDelta) max_rss_mb_delta=\(env.maxRssMbDelta)")
        print("  plugin=\(env.pluginPath)")
        print("===============================================================")

        let baseline = ResourceSnapshot.capture()

        let host = try PluginHost.load(path: env.pluginPath)
        let phase = await runPhase(
            host: host,
            duration: env.duration,
            workers: env.workers,
            label: "plugin"
        )
        await host.close()

        // Wait for any in-flight cleanup tasks to settle before snapshotting.
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        let final = ResourceSnapshot.capture()

        // Liveness / leak guards.
        if let b = baseline.fdCount, let f = final.fdCount {
            let delta = f - b
            print("  fd_delta=\(delta) (baseline=\(b) final=\(f))")
            XCTAssertLessThanOrEqual(delta, env.maxFdDelta,
                                     "FD leak: delta=\(delta) > \(env.maxFdDelta)")
        }
        if let b = baseline.rssBytes, let f = final.rssBytes {
            let deltaMb = (f - b) / (1024 * 1024)
            print("  rss_delta_mb=\(deltaMb) (baseline_mb=\(b / 1024 / 1024) final_mb=\(f / 1024 / 1024))")
            XCTAssertLessThanOrEqual(Int(deltaMb), env.maxRssMbDelta,
                                     "RSS leak: delta_mb=\(deltaMb) > \(env.maxRssMbDelta)")
        }

        // Op-mix correctness.
        XCTAssertEqual(phase.unexpected, 0,
                       "unexpected errors during phase: \(phase.firstFail ?? "?")")
        XCTAssertGreaterThan(phase.ops, 0, "phase made zero successful ops")
    }

    // MARK: - Many open streams (lifetime stress for the UAF fix)

    func testManyConcurrentStreamsClosed() async throws {
        let env = try Env.load()
        let host = try PluginHost.load(path: env.pluginPath)
        defer { Task { await host.close() } }

        // Open 64 bidi streams, send one ping each, then close. Exercises
        // PluginHost.openStreams bookkeeping (weak refs) and the strong-back
        // reference from PluginStream to PluginHost.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<64 {
                group.addTask {
                    let s = try await host.openStream(
                        service: Self.serviceName,
                        method: Self.bidiStreamMethod
                    )
                    try await s.send(self.makeHelloRequest("stream-\(i)"))
                    try await s.closeSend()
                    // Drain one response then close.
                    _ = try await s.recv()
                    await s.close()
                }
            }
            try await group.waitForAll()
        }
    }

    // MARK: - Large payload smoke

    func testLargePayloadUnary() async throws {
        let env = try Env.load()
        let host = try PluginHost.load(path: env.pluginPath)
        defer { Task { await host.close() } }

        // 512 KB padding.
        let pad = String(repeating: "X", count: 512 * 1024)
        let resp = try await host.invoke(
            service: Self.serviceName,
            method: Self.unaryMethod,
            data: makeHelloRequestWithLanguage("large", pad)
        )
        XCTAssertNotNil(extractMessage(resp))
    }
}

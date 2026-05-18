import XCTest
@testable import SynurangLite

/// Integration tests for `PluginHost`. These tests require a real Synurang
/// plugin shared library at the path given by the `SYNURANG_TEST_PLUGIN_PATH`
/// environment variable. In CI they are skipped unless the env var is set.
final class PluginHostTests: XCTestCase {

    func testLoadFailsForMissingPath() async throws {
        do {
            _ = try PluginHost.load(path: "/definitely/does/not/exist.dylib")
            XCTFail("expected dlopen failure")
        } catch is NativeLoaderError {
            // expected
        } catch {
            XCTFail("expected NativeLoaderError, got \(error)")
        }
    }

    func testInvokeAfterCloseThrows() async throws {
        // Without a real plugin we can't actually invoke, but we can check
        // that closing flips the closed flag.
        guard let path = ProcessInfo.processInfo.environment["SYNURANG_TEST_PLUGIN_PATH"] else {
            throw XCTSkip("set SYNURANG_TEST_PLUGIN_PATH to run plugin integration tests")
        }
        let host = try PluginHost.load(path: path)
        await host.close()
        do {
            _ = try await host.invoke(service: "Anything", method: "/x.y/z", data: Data())
            XCTFail("expected PluginClosedError")
        } catch is PluginClosedError {
            // expected
        }
    }
}

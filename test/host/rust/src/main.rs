//! Rust Host Test
//!
//! Tests Rust parent loading Go/C++/Rust plugins and invoking all 4 RPC types.
//!
//! Run:
//!   cargo run --release

use std::path::Path;

const ERROR_TRIGGER_NAME: &str = "trigger_error";

struct Counters {
    passed: usize,
    failed: usize,
    skipped: usize,
}

struct ExpectedPluginError {
    message: &'static str,
    code: i32,
    grpc_code: i32,
}

fn expected_plugin_error(plugin_name: &str, rpc_kind: &str) -> ExpectedPluginError {
    match (plugin_name, rpc_kind) {
        ("Go", "unary") => ExpectedPluginError {
            message: "go unary ffi error",
            code: 4101,
            grpc_code: 10,
        },
        ("Go", "server") => ExpectedPluginError {
            message: "go server stream ffi error",
            code: 4102,
            grpc_code: 10,
        },
        ("Go", "client") => ExpectedPluginError {
            message: "go client stream ffi error",
            code: 4103,
            grpc_code: 10,
        },
        ("Go", "bidi") => ExpectedPluginError {
            message: "go bidi stream ffi error",
            code: 4104,
            grpc_code: 10,
        },
        ("C++", "unary") => ExpectedPluginError {
            message: "cpp unary ffi error",
            code: 4201,
            grpc_code: 10,
        },
        ("C++", "server") => ExpectedPluginError {
            message: "cpp server stream ffi error",
            code: 4202,
            grpc_code: 10,
        },
        ("C++", "client") => ExpectedPluginError {
            message: "cpp client stream ffi error",
            code: 4203,
            grpc_code: 10,
        },
        ("C++", "bidi") => ExpectedPluginError {
            message: "cpp bidi stream ffi error",
            code: 4204,
            grpc_code: 10,
        },
        ("Rust", "unary") => ExpectedPluginError {
            message: "rust unary ffi error",
            code: 4301,
            grpc_code: 10,
        },
        ("Rust", "server") => ExpectedPluginError {
            message: "rust server stream ffi error",
            code: 4302,
            grpc_code: 10,
        },
        ("Rust", "client") => ExpectedPluginError {
            message: "rust client stream ffi error",
            code: 4303,
            grpc_code: 10,
        },
        ("Rust", "bidi") => ExpectedPluginError {
            message: "rust bidi stream ffi error",
            code: 4304,
            grpc_code: 10,
        },
        _ => panic!("unknown plugin/rpc expectation: {plugin_name}/{rpc_kind}"),
    }
}

fn assert_plugin_error(
    label: &str,
    err: &synurang_host::FfiError,
    expected: &ExpectedPluginError,
) -> Result<(), String> {
    if err.message != expected.message {
        return Err(format!(
            "{label} message mismatch: expected={} got={}",
            expected.message, err.message
        ));
    }
    if err.code != expected.code {
        return Err(format!(
            "{label} code mismatch: expected={} got={}",
            expected.code, err.code
        ));
    }
    if err.grpc_code != expected.grpc_code {
        return Err(format!(
            "{label} grpc_code mismatch: expected={} got={}",
            expected.grpc_code, err.grpc_code
        ));
    }
    Ok(())
}

fn expect_plugin_error(
    label: &str,
    result: Result<Vec<u8>, synurang_host::Error>,
    expected: &ExpectedPluginError,
) -> Result<(), String> {
    match result {
        Err(synurang_host::Error::PluginError(err))
        | Err(synurang_host::Error::StreamError(err)) => assert_plugin_error(label, &err, expected),
        Err(synurang_host::Error::Eof) => Err(format!("{label} expected FfiError, got EOF")),
        Err(other) => Err(format!("{label} expected FfiError, got {other}")),
        Ok(_) => Err(format!("{label} expected FfiError, got data")),
    }
}

// For this test, we need synurang-host from parent crate
// In a real project, you'd add it as a dependency
fn main() {
    let mut counters = Counters {
        passed: 0,
        failed: 0,
        skipped: 0,
    };
    println!("═══════════════════════════════════════════════════════════════");
    println!("  Rust Host Test (All 4 RPC Types × 3 Plugin Languages)");
    println!("═══════════════════════════════════════════════════════════════");

    test_plugin("bin/libplugin_go.so", "Go", &mut counters);
    test_plugin("bin/libplugin_cpp.so", "C++", &mut counters);
    test_plugin("bin/libplugin_rust.so", "Rust", &mut counters);

    println!("\n═══════════════════════════════════════════════════════════════");
    println!("  Rust Host Test Complete");
    println!(
        "  Passed: {}  Failed: {}  Skipped: {}",
        counters.passed, counters.failed, counters.skipped
    );
    println!("═══════════════════════════════════════════════════════════════");

    if counters.failed > 0 {
        std::process::exit(1);
    }
}

fn test_plugin(path: &str, name: &str, counters: &mut Counters) {
    println!("\n▶ Testing {} plugin: {}", name, path);

    if !Path::new(path).exists() {
        println!("  ⚠ SKIP: Plugin not found");
        counters.skipped += 1;
        return;
    }

    match synurang_host::PluginHost::load(path) {
        Ok(plugin) => {
            test_unary(&plugin, counters);
            test_server_stream(&plugin, counters);
            test_client_stream(&plugin, counters);
            test_bidi_stream(&plugin, counters);
            test_structured_ffi_errors(&plugin, name, counters);
            plugin.close();

            // Close-safety tests (each loads its own plugin instance)
            test_close_with_active_stream(path, counters);
            test_close_rejects_new_ops(path, counters);
            test_concurrent_close_and_streams(path, counters);
        }
        Err(e) => {
            println!("  ✗ Failed: {}", e);
            counters.failed += 1;
        }
    }
}

fn make_hello_request(name: &str) -> Vec<u8> {
    // HelloRequest: field 1 (string name)
    let mut data = vec![0x0a, name.len() as u8];
    data.extend_from_slice(name.as_bytes());
    data
}

fn extract_message(data: &[u8]) -> String {
    // HelloResponse: field 1 (string message)
    if data.len() < 2 || data[0] != 0x0a {
        return "<parse error>".to_string();
    }
    // Decode protobuf varint length
    let mut len: usize = 0;
    let mut offset: usize = 1;
    let mut shift: u32 = 0;
    while offset < data.len() {
        let b = data[offset];
        offset += 1;
        len |= ((b & 0x7f) as usize) << shift;
        if b & 0x80 == 0 {
            break;
        }
        shift += 7;
        if shift >= 35 {
            return "<varint overflow>".to_string();
        }
    }
    if data.len() < offset + len {
        return "<truncated>".to_string();
    }
    String::from_utf8_lossy(&data[offset..offset + len]).to_string()
}

fn test_unary(plugin: &synurang_host::PluginHost, counters: &mut Counters) {
    print!("  [1/4] Unary RPC... ");
    match plugin.invoke(
        "GoGreeterService",
        "/example.v1.GoGreeterService/Bar",
        &make_hello_request("RustHost"),
    ) {
        Ok(resp) => {
            println!("✓ {}", extract_message(&resp));
            counters.passed += 1;
        }
        Err(e) => {
            println!("✗ {}", e);
            counters.failed += 1;
        }
    }
}

fn test_server_stream(plugin: &synurang_host::PluginHost, counters: &mut Counters) {
    print!("  [2/4] Server Streaming... ");
    match plugin.open_stream(
        "GoGreeterService",
        "/example.v1.GoGreeterService/BarServerStream",
    ) {
        Ok(stream) => {
            if let Err(e) = stream.send(&make_hello_request("StreamTest")) {
                println!("✗ send: {}", e);
                counters.failed += 1;
                return;
            }
            stream.close_send();

            let mut count = 0;
            loop {
                match stream.recv() {
                    Ok(_) => count += 1,
                    Err(synurang_host::Error::Eof) => break,
                    Err(e) => {
                        println!("✗ recv: {}", e);
                        return;
                    }
                }
            }
            println!("✓ received {} messages", count);
            counters.passed += 1;
        }
        Err(e) => {
            println!("✗ {}", e);
            counters.failed += 1;
        }
    }
}

fn test_client_stream(plugin: &synurang_host::PluginHost, counters: &mut Counters) {
    print!("  [3/4] Client Streaming... ");
    match plugin.open_stream(
        "GoGreeterService",
        "/example.v1.GoGreeterService/BarClientStream",
    ) {
        Ok(stream) => {
            for i in 0..3 {
                if let Err(e) = stream.send(&make_hello_request(&format!("Msg{}", i))) {
                    println!("✗ send: {}", e);
                    counters.failed += 1;
                    return;
                }
            }
            stream.close_send();

            match stream.recv() {
                Ok(resp) => {
                    println!("✓ {}", extract_message(&resp));
                    counters.passed += 1;
                }
                Err(e) => {
                    println!("✗ recv: {}", e);
                    counters.failed += 1;
                }
            }
        }
        Err(e) => {
            println!("✗ {}", e);
            counters.failed += 1;
        }
    }
}

fn test_bidi_stream(plugin: &synurang_host::PluginHost, counters: &mut Counters) {
    print!("  [4/4] Bidi Streaming... ");
    match plugin.open_stream(
        "GoGreeterService",
        "/example.v1.GoGreeterService/BarBidiStream",
    ) {
        Ok(stream) => {
            for i in 0..3 {
                if let Err(e) = stream.send(&make_hello_request(&format!("Ping{}", i))) {
                    println!("✗ send: {}", e);
                    counters.failed += 1;
                    return;
                }
            }
            stream.close_send();

            let mut count = 0;
            loop {
                match stream.recv() {
                    Ok(_) => count += 1,
                    Err(synurang_host::Error::Eof) => break,
                    Err(e) => {
                        println!("✗ recv: {}", e);
                        return;
                    }
                }
            }
            println!("✓ echoed {} messages", count);
            counters.passed += 1;
        }
        Err(e) => {
            println!("✗ {}", e);
            counters.failed += 1;
        }
    }
}

fn test_structured_ffi_errors(
    plugin: &synurang_host::PluginHost,
    plugin_name: &str,
    counters: &mut Counters,
) {
    print!("  [5/5] Structured FFI Errors... ");

    let unary_expected = expected_plugin_error(plugin_name, "unary");
    if let Err(msg) = expect_plugin_error(
        "unary",
        plugin.invoke(
            "GoGreeterService",
            "/example.v1.GoGreeterService/Bar",
            &make_hello_request(ERROR_TRIGGER_NAME),
        ),
        &unary_expected,
    ) {
        println!("✗ {}", msg);
        counters.failed += 1;
        return;
    }

    let server_expected = expected_plugin_error(plugin_name, "server");
    let server_stream = match plugin.open_stream(
        "GoGreeterService",
        "/example.v1.GoGreeterService/BarServerStream",
    ) {
        Ok(stream) => stream,
        Err(e) => {
            println!("✗ {}", e);
            counters.failed += 1;
            return;
        }
    };
    if let Err(e) = server_stream.send(&make_hello_request(ERROR_TRIGGER_NAME)) {
        println!("✗ {}", e);
        counters.failed += 1;
        return;
    }
    server_stream.close_send();
    if let Err(msg) = expect_plugin_error("server-stream", server_stream.recv(), &server_expected) {
        println!("✗ {}", msg);
        counters.failed += 1;
        return;
    }

    let client_expected = expected_plugin_error(plugin_name, "client");
    let client_stream = match plugin.open_stream(
        "GoGreeterService",
        "/example.v1.GoGreeterService/BarClientStream",
    ) {
        Ok(stream) => stream,
        Err(e) => {
            println!("✗ {}", e);
            counters.failed += 1;
            return;
        }
    };
    if let Err(e) = client_stream.send(&make_hello_request(ERROR_TRIGGER_NAME)) {
        println!("✗ {}", e);
        counters.failed += 1;
        return;
    }
    client_stream.close_send();
    if let Err(msg) = expect_plugin_error("client-stream", client_stream.recv(), &client_expected) {
        println!("✗ {}", msg);
        counters.failed += 1;
        return;
    }

    let bidi_expected = expected_plugin_error(plugin_name, "bidi");
    let bidi_stream = match plugin.open_stream(
        "GoGreeterService",
        "/example.v1.GoGreeterService/BarBidiStream",
    ) {
        Ok(stream) => stream,
        Err(e) => {
            println!("✗ {}", e);
            counters.failed += 1;
            return;
        }
    };
    if let Err(e) = bidi_stream.send(&make_hello_request(ERROR_TRIGGER_NAME)) {
        println!("✗ {}", e);
        counters.failed += 1;
        return;
    }
    bidi_stream.close_send();
    if let Err(msg) = expect_plugin_error("bidi", bidi_stream.recv(), &bidi_expected) {
        println!("✗ {}", msg);
        counters.failed += 1;
        return;
    }

    println!("✓ unary/server/client/bidi");
    counters.passed += 1;
}

// =============================================================================
// Close-with-active-streams regression tests
// =============================================================================

fn test_close_with_active_stream(path: &str, counters: &mut Counters) {
    print!("  [6/8] Close with active stream... ");

    let plugin = match synurang_host::PluginHost::load(path) {
        Ok(p) => p,
        Err(e) => {
            println!("✗ load: {}", e);
            counters.failed += 1;
            return;
        }
    };

    let stream = match plugin.open_stream(
        "GoGreeterService",
        "/example.v1.GoGreeterService/BarBidiStream",
    ) {
        Ok(s) => s,
        Err(e) => {
            println!("✗ open: {}", e);
            counters.failed += 1;
            return;
        }
    };

    // Close plugin while stream is still active — library must NOT unload
    plugin.close();

    // Stream should still work (lease keeps library loaded)
    if let Err(e) = stream.send(&make_hello_request("after-close")) {
        println!("✗ send after close: {}", e);
        counters.failed += 1;
        return;
    }
    stream.close_send();

    // Drain the stream
    loop {
        match stream.recv() {
            Ok(_) => {}
            Err(synurang_host::Error::Eof) => break,
            Err(e) => {
                println!("✗ recv after close: {}", e);
                counters.failed += 1;
                return;
            }
        }
    }

    // Drop stream (triggers release_stream_lease → close_if_idle → dlclose)
    // Then plugin drops (close() no-ops since already requested)
    // Must not crash/segfault

    println!("✓");
    counters.passed += 1;
}

fn test_close_rejects_new_ops(path: &str, counters: &mut Counters) {
    print!("  [7/8] Close rejects new operations... ");

    let plugin = match synurang_host::PluginHost::load(path) {
        Ok(p) => p,
        Err(e) => {
            println!("✗ load: {}", e);
            counters.failed += 1;
            return;
        }
    };

    // Keep a stream alive so the library stays loaded
    let _stream = match plugin.open_stream(
        "GoGreeterService",
        "/example.v1.GoGreeterService/BarBidiStream",
    ) {
        Ok(s) => s,
        Err(e) => {
            println!("✗ open: {}", e);
            counters.failed += 1;
            return;
        }
    };

    plugin.close();

    // New invoke must be rejected
    match plugin.invoke(
        "GoGreeterService",
        "/example.v1.GoGreeterService/Bar",
        &make_hello_request("rejected"),
    ) {
        Err(synurang_host::Error::PluginClosed) => {}
        Ok(_) => {
            println!("✗ invoke should be rejected");
            counters.failed += 1;
            return;
        }
        Err(e) => {
            println!("✗ invoke wrong error: {}", e);
            counters.failed += 1;
            return;
        }
    }

    // New open_stream must be rejected
    match plugin.open_stream(
        "GoGreeterService",
        "/example.v1.GoGreeterService/BarBidiStream",
    ) {
        Err(synurang_host::Error::PluginClosed) => {}
        Ok(_) => {
            println!("✗ open_stream should be rejected");
            counters.failed += 1;
            return;
        }
        Err(e) => {
            println!("✗ open_stream wrong error: {}", e);
            counters.failed += 1;
            return;
        }
    }

    println!("✓");
    counters.passed += 1;
}

fn test_concurrent_close_and_streams(path: &str, counters: &mut Counters) {
    print!("  [8/8] Concurrent close + stream ops... ");

    let plugin = match synurang_host::PluginHost::load(path) {
        Ok(p) => p,
        Err(e) => {
            println!("✗ load: {}", e);
            counters.failed += 1;
            return;
        }
    };

    std::thread::scope(|s| {
        // 4 workers opening/using/closing streams concurrently
        for _ in 0..4 {
            s.spawn(|| {
                for _ in 0..10 {
                    match plugin.open_stream(
                        "GoGreeterService",
                        "/example.v1.GoGreeterService/BarBidiStream",
                    ) {
                        Ok(stream) => {
                            let _ = stream.send(&make_hello_request("concurrent"));
                            stream.close_send();
                            let _ = stream.recv();
                        }
                        Err(_) => {} // Expected after close
                    }
                }
            });
        }

        // Closer thread fires after a short delay
        s.spawn(|| {
            std::thread::sleep(std::time::Duration::from_millis(5));
            plugin.close();
        });
    });

    // If we reach here, no crash/segfault occurred
    println!("✓ no crash");
    counters.passed += 1;
}

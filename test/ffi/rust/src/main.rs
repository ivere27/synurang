//! FFI API Test (Rust) — No gRPC dependency
//!
//! Tests all 4 RPC types using synurang_host::PluginHost directly with
//! hand-crafted protobuf bytes. No tonic/gRPC dependency.
//!
//! Run (from project root):
//!   cargo run --manifest-path test/ffi/rust/Cargo.toml [-- plugin-path]
//!
//! Default plugin: bin/libplugin_go.so

use std::path::Path;

// =============================================================================
// Protobuf helpers (hand-crafted, no prost needed)
// =============================================================================

/// Encode HelloRequest { name = value }
fn encode_hello_request(name: &str) -> Vec<u8> {
    let mut data = vec![0x0a, name.len() as u8];
    data.extend_from_slice(name.as_bytes());
    data
}

/// Decode HelloResponse.message (field 1, string)
fn decode_hello_message(data: &[u8]) -> Option<String> {
    if data.len() < 2 || data[0] != 0x0a {
        return None;
    }
    let len = data[1] as usize;
    if data.len() < 2 + len {
        return None;
    }
    Some(String::from_utf8_lossy(&data[2..2 + len]).to_string())
}

// =============================================================================
// Tests
// =============================================================================

fn test_unary(plugin: &synurang_host::PluginHost) -> Result<(), String> {
    let req = encode_hello_request("RustFFI");
    let resp = plugin
        .invoke("GoGreeterService", "/example.v1.GoGreeterService/Bar", &req)
        .map_err(|e| format!("invoke: {}", e))?;

    let msg = decode_hello_message(&resp).ok_or("bad response")?;
    if msg.is_empty() {
        return Err("empty message".into());
    }
    Ok(())
}

fn test_server_stream(plugin: &synurang_host::PluginHost) -> Result<(), String> {
    let mut stream = plugin
        .open_stream(
            "GoGreeterService",
            "/example.v1.GoGreeterService/BarServerStream",
        )
        .map_err(|e| format!("open: {}", e))?;

    // Send request, close send side
    stream
        .send(&encode_hello_request("StreamTest"))
        .map_err(|e| format!("send: {}", e))?;
    stream.close_send();

    // Recv loop
    let mut count = 0;
    loop {
        match stream.recv() {
            Ok(data) => {
                decode_hello_message(&data).ok_or(format!("bad message at {}", count))?;
                count += 1;
            }
            Err(synurang_host::Error::Eof) => break,
            Err(e) => return Err(format!("recv: {}", e)),
        }
    }
    stream.close();

    if count == 0 {
        return Err("received 0 messages".into());
    }
    Ok(())
}

fn test_client_stream(plugin: &synurang_host::PluginHost) -> Result<(), String> {
    let mut stream = plugin
        .open_stream(
            "GoGreeterService",
            "/example.v1.GoGreeterService/BarClientStream",
        )
        .map_err(|e| format!("open: {}", e))?;

    // Send 3 messages
    for i in 0..3 {
        stream
            .send(&encode_hello_request(&format!("Msg{}", i)))
            .map_err(|e| format!("send[{}]: {}", i, e))?;
    }
    stream.close_send();

    // Receive single response
    let resp = stream.recv().map_err(|e| format!("recv: {}", e))?;
    stream.close();

    let msg = decode_hello_message(&resp).ok_or("bad response")?;
    if msg.is_empty() {
        return Err("empty message".into());
    }
    Ok(())
}

fn test_bidi_stream(plugin: &synurang_host::PluginHost) -> Result<(), String> {
    let stream = plugin
        .open_stream(
            "GoGreeterService",
            "/example.v1.GoGreeterService/BarBidiStream",
        )
        .map_err(|e| format!("open: {}", e))?;

    // Send all messages, then close send side, then recv all responses.
    // (PluginStream holds a single mutex for stream_funcs, so concurrent
    //  send+recv would deadlock when recv blocks while holding the lock.)
    for i in 0..3 {
        stream
            .send(&encode_hello_request(&format!("Ping{}", i)))
            .map_err(|e| format!("send[{}]: {}", i, e))?;
    }
    stream.close_send();

    let mut count = 0;
    loop {
        match stream.recv() {
            Ok(data) => {
                decode_hello_message(&data).ok_or(format!("bad message at {}", count))?;
                count += 1;
            }
            Err(synurang_host::Error::Eof) => break,
            Err(e) => return Err(format!("recv: {}", e)),
        }
    }

    if count == 0 {
        return Err("received 0 messages".into());
    }
    Ok(())
}

// =============================================================================
// Main
// =============================================================================

fn main() {
    let plugin_path = std::env::args()
        .nth(1)
        .unwrap_or_else(|| "bin/libplugin_go.so".to_string());

    println!("═══════════════════════════════════════════════════════════════");
    println!("  Rust FFI API Test (No gRPC — all 4 RPC types)");
    println!("═══════════════════════════════════════════════════════════════");

    if !Path::new(&plugin_path).exists() {
        eprintln!("Plugin not found: {}", plugin_path);
        std::process::exit(1);
    }

    let plugin = match synurang_host::PluginHost::load(&plugin_path) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("Failed to load plugin: {}", e);
            std::process::exit(1);
        }
    };

    let mut passed = 0;
    let mut failed = 0;

    let tests: Vec<(&str, Box<dyn Fn(&synurang_host::PluginHost) -> Result<(), String>>)> = vec![
        ("[1/4] Unary RPC", Box::new(test_unary)),
        ("[2/4] Server Streaming", Box::new(test_server_stream)),
        ("[3/4] Client Streaming", Box::new(test_client_stream)),
        ("[4/4] Bidi Streaming", Box::new(test_bidi_stream)),
    ];

    for (name, test_fn) in &tests {
        print!("  {}... ", name);
        match test_fn(&plugin) {
            Ok(()) => {
                println!("OK");
                passed += 1;
            }
            Err(e) => {
                println!("FAIL: {}", e);
                failed += 1;
            }
        }
    }

    plugin.close();

    println!();
    println!("═══════════════════════════════════════════════════════════════");
    println!("  Results: {} passed, {} failed", passed, failed);
    println!("═══════════════════════════════════════════════════════════════");

    if failed > 0 {
        std::process::exit(1);
    }
}

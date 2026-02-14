//! Rust Host Test
//!
//! Tests Rust parent loading Go/C++/Rust plugins and invoking all 4 RPC types.
//!
//! Run:
//!   cargo run --release

use std::path::Path;

// For this test, we need synurang-host from parent crate
// In a real project, you'd add it as a dependency
fn main() {
    println!("═══════════════════════════════════════════════════════════════");
    println!("  Rust Host Test (All 4 RPC Types × 3 Plugin Languages)");
    println!("═══════════════════════════════════════════════════════════════");

    test_plugin("bin/libplugin_go.so", "Go");
    test_plugin("bin/libplugin_cpp.so", "C++");
    test_plugin("bin/libplugin_rust.so", "Rust");

    println!("\n═══════════════════════════════════════════════════════════════");
    println!("  Rust Host Test Complete");
    println!("═══════════════════════════════════════════════════════════════");
}

fn test_plugin(path: &str, name: &str) {
    println!("\n▶ Testing {} plugin: {}", name, path);

    if !Path::new(path).exists() {
        println!("  ⚠ SKIP: Plugin not found");
        return;
    }

    match synurang_host::PluginHost::load(path) {
        Ok(plugin) => {
            test_unary(&plugin);
            test_server_stream(&plugin);
            test_client_stream(&plugin);
            test_bidi_stream(&plugin);
            plugin.close();
        }
        Err(e) => {
            println!("  ✗ Failed: {}", e);
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

fn test_unary(plugin: &synurang_host::PluginHost) {
    print!("  [1/4] Unary RPC... ");
    match plugin.invoke(
        "GoGreeterService",
        "/example.v1.GoGreeterService/Bar",
        &make_hello_request("RustHost"),
    ) {
        Ok(resp) => println!("✓ {}", extract_message(&resp)),
        Err(e) => println!("✗ {}", e),
    }
}

fn test_server_stream(plugin: &synurang_host::PluginHost) {
    print!("  [2/4] Server Streaming... ");
    match plugin.open_stream("GoGreeterService", "/example.v1.GoGreeterService/BarServerStream") {
        Ok(mut stream) => {
            if let Err(e) = stream.send(&make_hello_request("StreamTest")) {
                println!("✗ send: {}", e);
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
        }
        Err(e) => println!("✗ {}", e),
    }
}

fn test_client_stream(plugin: &synurang_host::PluginHost) {
    print!("  [3/4] Client Streaming... ");
    match plugin.open_stream("GoGreeterService", "/example.v1.GoGreeterService/BarClientStream") {
        Ok(mut stream) => {
            for i in 0..3 {
                if let Err(e) = stream.send(&make_hello_request(&format!("Msg{}", i))) {
                    println!("✗ send: {}", e);
                    return;
                }
            }
            stream.close_send();

            match stream.recv() {
                Ok(resp) => println!("✓ {}", extract_message(&resp)),
                Err(e) => println!("✗ recv: {}", e),
            }
        }
        Err(e) => println!("✗ {}", e),
    }
}

fn test_bidi_stream(plugin: &synurang_host::PluginHost) {
    print!("  [4/4] Bidi Streaming... ");
    match plugin.open_stream("GoGreeterService", "/example.v1.GoGreeterService/BarBidiStream") {
        Ok(mut stream) => {
            for i in 0..3 {
                if let Err(e) = stream.send(&make_hello_request(&format!("Ping{}", i))) {
                    println!("✗ send: {}", e);
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
        }
        Err(e) => println!("✗ {}", e),
    }
}

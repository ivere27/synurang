//! Rust Host Brute-Force Chaos Test
//!
//! Multi-threaded stress test that loads all 3 plugin languages (Go, C++, Rust)
//! and hammers them with randomized RPC operations + chaos edge cases.
//!
//! Gated by SYNURANG_BRUTE=1 environment variable.
//!
//! Environment variables:
//!   SYNURANG_BRUTE=1                — required to run
//!   SYNURANG_BRUTE_DURATION         — total duration in seconds (default: 60)
//!   SYNURANG_BRUTE_WORKERS          — thread count (default: 4)
//!   SYNURANG_BRUTE_MAX_FD_DELTA     — max FD increase (default: 48)
//!   SYNURANG_BRUTE_MAX_RSS_MB_DELTA — max RSS increase MB (default: 256)

use std::path::Path;
use std::sync::atomic::{AtomicI64, Ordering};
use std::time::{Duration, Instant};

use synurang_host::{Error, PluginHost};

// ---------------------------------------------------------------------------
// Proto helpers (same as main.rs)
// ---------------------------------------------------------------------------

fn make_hello_request(name: &str) -> Vec<u8> {
    if name.is_empty() {
        return vec![];
    }
    let mut data = vec![0x0a]; // field 1, wire type 2
                               // Varint encoding for length
    let len = name.len();
    if len < 128 {
        data.push(len as u8);
    } else {
        let mut remaining = len;
        while remaining >= 128 {
            data.push(((remaining & 0x7f) | 0x80) as u8);
            remaining >>= 7;
        }
        data.push(remaining as u8);
    }
    data.extend_from_slice(name.as_bytes());
    data
}

fn extract_message(data: &[u8]) -> String {
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

// ---------------------------------------------------------------------------
// Resource snapshot (Linux /proc/self)
// ---------------------------------------------------------------------------

struct ResourceSnapshot {
    fd_count: i32,
    rss_bytes: i64,
}

fn capture_resources() -> ResourceSnapshot {
    let mut s = ResourceSnapshot {
        fd_count: -1,
        rss_bytes: -1,
    };

    // FD count
    if let Ok(entries) = std::fs::read_dir("/proc/self/fd") {
        s.fd_count = entries.count() as i32;
    }

    // RSS from /proc/self/statm
    if let Ok(content) = std::fs::read_to_string("/proc/self/statm") {
        let fields: Vec<&str> = content.split_whitespace().collect();
        if fields.len() >= 2 {
            if let Ok(pages) = fields[1].parse::<i64>() {
                let page_size = unsafe { libc::sysconf(libc::_SC_PAGESIZE) } as i64;
                s.rss_bytes = pages * page_size;
            }
        }
    }

    s
}

// ---------------------------------------------------------------------------
// Environment variable helpers
// ---------------------------------------------------------------------------

fn env_int(key: &str, fallback: i32) -> i32 {
    std::env::var(key)
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(fallback)
}

fn env_duration_secs(key: &str, fallback: u64) -> u64 {
    let val = match std::env::var(key) {
        Ok(v) if !v.is_empty() => v,
        _ => return fallback,
    };
    if let Some(s) = val.strip_suffix('s') {
        s.parse().unwrap_or(fallback)
    } else if let Some(m) = val.strip_suffix('m') {
        m.parse::<u64>().unwrap_or(fallback / 60) * 60
    } else {
        val.parse().unwrap_or(fallback)
    }
}

// ---------------------------------------------------------------------------
// Error classification
// ---------------------------------------------------------------------------

fn is_expected_error(e: &Error) -> bool {
    match e {
        Error::PluginClosed => true,
        Error::Eof => true,
        Error::StreamError(err) => {
            err.message.contains("stream send failed")
                || err.message.contains("Stream send failed")
                || err.message.contains("Empty stream response")
                || err.message.contains("stream is closed")
                || err.message.contains("Failed to open stream")
        }
        Error::PluginError(err) => {
            err.message.contains("plugin is closed")
                || err.message.contains("Empty response")
                || err.message.contains("Plugin returned null")
                || err.message.contains("Stream error")
                || err.message.contains("stream send failed")
                || err.message.contains("Stream send failed")
        }
        _ => false,
    }
}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const SERVICE: &str = "GoGreeterService";
const METHOD_UNARY: &str = "/example.v1.GoGreeterService/Bar";
const METHOD_SERVER_STREAM: &str = "/example.v1.GoGreeterService/BarServerStream";
const METHOD_CLIENT_STREAM: &str = "/example.v1.GoGreeterService/BarClientStream";
const METHOD_BIDI: &str = "/example.v1.GoGreeterService/BarBidiStream";

// ---------------------------------------------------------------------------
// Simple RNG (xorshift64 — avoid pulling in rand crate)
// ---------------------------------------------------------------------------

struct Rng(u64);

impl Rng {
    fn new(seed: u64) -> Self {
        Self(if seed == 0 { 1 } else { seed })
    }
    fn next_u64(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.0 = x;
        x
    }
    fn next_int(&mut self, bound: i32) -> i32 {
        (self.next_u64() % bound as u64) as i32
    }
    fn next_range(&mut self, lo: i32, hi: i32) -> i32 {
        lo + self.next_int(hi - lo + 1)
    }
}

// ---------------------------------------------------------------------------
// Operation implementations
// ---------------------------------------------------------------------------

fn op_unary(plugin: &PluginHost, rng: &mut Rng, worker_id: i32) -> Result<(), Error> {
    let name = format!("u-{}-{}", worker_id, rng.next_u64());
    let req = make_hello_request(&name);
    let resp = plugin.invoke(SERVICE, METHOD_UNARY, &req)?;
    let msg = extract_message(&resp);
    if msg.is_empty() && name.len() <= 127 {
        return Err(Error::PluginError(synurang_host::FfiError::new(
            "unary response mismatch",
        )));
    }
    Ok(())
}

fn op_server_stream(plugin: &PluginHost, rng: &mut Rng, worker_id: i32) -> Result<(), Error> {
    let name = format!("ss-{}-{}", worker_id, rng.next_u64());
    let stream = plugin.open_stream(SERVICE, METHOD_SERVER_STREAM)?;
    stream.send(&make_hello_request(&name))?;
    stream.close_send();

    let target = rng.next_range(1, 5);
    let mut received = 0;

    for _ in 0..target {
        match stream.recv() {
            Ok(_) => received += 1,
            Err(Error::Eof) => break,
            Err(e) => return Err(e),
        }
    }

    // Sometimes drain fully
    if rng.next_int(100) < 40 {
        loop {
            match stream.recv() {
                Ok(_) => received += 1,
                Err(Error::Eof) => break,
                Err(e) => return Err(e),
            }
        }
    }

    if received == 0 {
        return Err(Error::PluginError(synurang_host::FfiError::new(
            "server-stream returned zero messages",
        )));
    }
    Ok(())
}

fn op_client_stream(plugin: &PluginHost, rng: &mut Rng, worker_id: i32) -> Result<(), Error> {
    let stream = plugin.open_stream(SERVICE, METHOD_CLIENT_STREAM)?;

    let count = rng.next_range(1, 20);
    for i in 0..count {
        let name = format!("cs-{}-{}", worker_id, i);
        stream.send(&make_hello_request(&name))?;
    }
    stream.close_send();

    let resp = stream.recv()?;
    let msg = extract_message(&resp);
    if msg.is_empty() {
        return Err(Error::PluginError(synurang_host::FfiError::new(
            "client-stream empty response",
        )));
    }
    Ok(())
}

fn op_bidi_stream(plugin: &PluginHost, rng: &mut Rng, worker_id: i32) -> Result<(), Error> {
    let stream = plugin.open_stream(SERVICE, METHOD_BIDI)?;

    let count = rng.next_range(1, 12);
    let mut received = 0;

    for i in 0..count {
        let name = format!("bs-{}-{}", worker_id, i);
        stream.send(&make_hello_request(&name))?;

        match stream.recv() {
            Ok(_) => received += 1,
            Err(Error::Eof) => break,
            Err(e) => return Err(e),
        }
    }
    stream.close_send();

    if received == 0 {
        return Err(Error::PluginError(synurang_host::FfiError::new(
            "bidi received zero responses",
        )));
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Chaos operations
// ---------------------------------------------------------------------------

fn chaos_open_and_abandon(plugin: &PluginHost, _rng: &mut Rng) -> Result<(), Error> {
    let _stream = plugin.open_stream(SERVICE, METHOD_BIDI)?;
    // Drop will close
    Ok(())
}

fn chaos_double_close(plugin: &PluginHost, _rng: &mut Rng) -> Result<(), Error> {
    let mut stream = plugin.open_stream(SERVICE, METHOD_BIDI)?;
    let _ = stream.send(&make_hello_request("chaos-dc"));
    stream.close();
    stream.close();
    stream.close();
    Ok(())
}

fn chaos_send_after_close_send(
    plugin: &PluginHost,
    _rng: &mut Rng,
    worker_id: i32,
) -> Result<(), Error> {
    let stream = plugin.open_stream(SERVICE, METHOD_CLIENT_STREAM)?;
    let name = format!("chaos-sac-{}", worker_id);
    stream.send(&make_hello_request(&name))?;
    stream.close_send();

    // Attempt send after close_send
    match stream.send(&make_hello_request("after-close")) {
        Ok(_) => {}  // Some transports may buffer
        Err(_) => {} // Expected
    }
    Ok(())
}

fn chaos_recv_after_close(plugin: &PluginHost, _rng: &mut Rng) -> Result<(), Error> {
    let mut stream = plugin.open_stream(SERVICE, METHOD_SERVER_STREAM)?;
    let _ = stream.send(&make_hello_request("chaos-rac"));
    stream.close_send();

    let _ = stream.recv();
    stream.close();

    match stream.recv() {
        Ok(_) => {}
        Err(_) => {} // Expected
    }
    Ok(())
}

fn chaos_rapid_stream_cycling(plugin: &PluginHost, rng: &mut Rng) -> Result<(), Error> {
    let count = rng.next_range(5, 20);
    for _ in 0..count {
        match plugin.open_stream(SERVICE, METHOD_BIDI) {
            Ok(mut s) => s.close(),
            Err(_) => {} // Expected during rapid cycling
        }
    }
    Ok(())
}

fn chaos_boundary_payloads(
    plugin: &PluginHost,
    rng: &mut Rng,
    _worker_id: i32,
) -> Result<(), Error> {
    let name = match rng.next_int(3) {
        0 => String::new(),
        1 => "x".to_string(),
        _ => {
            let size = rng.next_range(64 * 1024, 256 * 1024) as usize;
            "B".repeat(size)
        }
    };
    let req = make_hello_request(&name);
    let _resp = plugin.invoke(SERVICE, METHOD_UNARY, &req)?;
    Ok(())
}

fn chaos_mismatched_bidi(plugin: &PluginHost, rng: &mut Rng, worker_id: i32) -> Result<(), Error> {
    let stream = plugin.open_stream(SERVICE, METHOD_BIDI)?;

    let send_count = rng.next_range(3, 10);
    for i in 0..send_count {
        let name = format!("chaos-mm-{}-{}", worker_id, i);
        stream.send(&make_hello_request(&name))?;
    }

    let recv_count = rng.next_range(1, send_count - 1);
    for _ in 0..recv_count {
        match stream.recv() {
            Ok(_) => {}
            Err(Error::Eof) => break,
            Err(_) => break,
        }
    }
    // Abandon — drop will clean up
    Ok(())
}

fn chaos_immediate_close(plugin: &PluginHost, _rng: &mut Rng) -> Result<(), Error> {
    let mut stream = plugin.open_stream(SERVICE, METHOD_BIDI)?;
    stream.close();
    Ok(())
}

fn run_chaos(plugin: &PluginHost, rng: &mut Rng, worker_id: i32) -> Result<(), Error> {
    let x = rng.next_int(100);
    if x < 15 {
        chaos_open_and_abandon(plugin, rng)
    } else if x < 30 {
        chaos_double_close(plugin, rng)
    } else if x < 45 {
        chaos_send_after_close_send(plugin, rng, worker_id)
    } else if x < 60 {
        chaos_recv_after_close(plugin, rng)
    } else if x < 74 {
        chaos_rapid_stream_cycling(plugin, rng)
    } else if x < 86 {
        chaos_boundary_payloads(plugin, rng, worker_id)
    } else if x < 94 {
        chaos_mismatched_bidi(plugin, rng, worker_id)
    } else {
        chaos_immediate_close(plugin, rng)
    }
}

// ---------------------------------------------------------------------------
// Main operation router
// ---------------------------------------------------------------------------

fn run_random_op(plugin: &PluginHost, rng: &mut Rng, worker_id: i32) -> Result<(), Error> {
    let x = rng.next_int(100);
    if x < 40 {
        op_unary(plugin, rng, worker_id)
    } else if x < 62 {
        op_server_stream(plugin, rng, worker_id)
    } else if x < 78 {
        op_client_stream(plugin, rng, worker_id)
    } else if x < 88 {
        op_bidi_stream(plugin, rng, worker_id)
    } else {
        run_chaos(plugin, rng, worker_id)
    }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

fn main() {
    if std::env::var("SYNURANG_BRUTE").as_deref() != Ok("1") {
        println!("SKIP: set SYNURANG_BRUTE=1 to run Rust host brute-force test");
        return;
    }

    let duration_secs = env_duration_secs("SYNURANG_BRUTE_DURATION", 60);
    let workers = env_int("SYNURANG_BRUTE_WORKERS", 4);
    let max_fd_delta = env_int("SYNURANG_BRUTE_MAX_FD_DELTA", 48);
    let max_rss_mb_delta = env_int("SYNURANG_BRUTE_MAX_RSS_MB_DELTA", 256);

    println!("═══════════════════════════════════════════════════════════════");
    println!("  Rust Host Brute-Force Chaos Test");
    println!(
        "  duration={}s workers={} max_fd_delta={} max_rss_mb_delta={}",
        duration_secs, workers, max_fd_delta, max_rss_mb_delta
    );
    println!("═══════════════════════════════════════════════════════════════");

    // Load all 3 plugins
    let specs = [
        ("Go", "bin/libplugin_go.so"),
        ("C++", "bin/libplugin_cpp.so"),
        ("Rust", "bin/libplugin_rust.so"),
    ];

    let mut plugins: Vec<(&str, PluginHost)> = Vec::new();
    for (name, path) in &specs {
        if !Path::new(path).exists() {
            eprintln!(
                "FATAL: plugin not found: {} (run `make build_plugin_all` first)",
                path
            );
            std::process::exit(1);
        }
        match PluginHost::load(path) {
            Ok(host) => {
                println!("  Loaded {} plugin: {}", name, path);
                plugins.push((name, host));
            }
            Err(e) => {
                eprintln!("FATAL: failed to load {} plugin: {}", name, e);
                std::process::exit(1);
            }
        }
    }

    // Stabilize and capture baseline
    std::thread::sleep(Duration::from_millis(100));
    let baseline = capture_resources();
    println!(
        "  Baseline: fd={} rss_mb={}",
        baseline.fd_count,
        baseline.rss_bytes / (1024 * 1024)
    );

    // Counters
    let ops = AtomicI64::new(0);
    let expected_errors = AtomicI64::new(0);
    let unexpected_errors = AtomicI64::new(0);

    let start = Instant::now();
    let duration = Duration::from_secs(duration_secs);

    // Run workers using scoped threads
    std::thread::scope(|s| {
        // Worker threads
        for w in 0..workers {
            let plugins_ref = &plugins;
            let ops_ref = &ops;
            let expected_ref = &expected_errors;
            let unexpected_ref = &unexpected_errors;

            s.spawn(move || {
                let seed = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap()
                    .as_nanos() as u64
                    + w as u64 * 100103;
                let mut rng = Rng::new(seed);

                while start.elapsed() < duration {
                    // Pick random plugin
                    let idx = rng.next_int(plugins_ref.len() as i32) as usize;
                    let (_, ref plugin) = plugins_ref[idx];

                    match run_random_op(plugin, &mut rng, w) {
                        Ok(()) => {
                            ops_ref.fetch_add(1, Ordering::Relaxed);
                        }
                        Err(ref e) if is_expected_error(e) => {
                            expected_ref.fetch_add(1, Ordering::Relaxed);
                        }
                        Err(e) => {
                            let prev = unexpected_ref.fetch_add(1, Ordering::Relaxed);
                            if prev < 5 {
                                eprintln!("  UNEXPECTED ERROR [worker {}]: {}", w, e);
                            }
                        }
                    }

                    // Small sleep
                    let ms = rng.next_range(1, 5) as u64;
                    std::thread::sleep(Duration::from_millis(ms));
                }
            });
        }

        // Progress reporter
        let ops_ref = &ops;
        let expected_ref = &expected_errors;
        let unexpected_ref = &unexpected_errors;
        s.spawn(move || {
            while start.elapsed() < duration {
                std::thread::sleep(Duration::from_secs(10));
                if start.elapsed() >= duration {
                    break;
                }
                println!(
                    "  [{}s] ops={} expected_errs={} unexpected_errs={}",
                    start.elapsed().as_secs(),
                    ops_ref.load(Ordering::Relaxed),
                    expected_ref.load(Ordering::Relaxed),
                    unexpected_ref.load(Ordering::Relaxed),
                );
            }
        });
    });

    let elapsed = start.elapsed().as_secs();

    // Close all plugins
    for (_, plugin) in &plugins {
        plugin.close();
    }

    // Stabilize and capture final resources
    std::thread::sleep(Duration::from_millis(100));
    let final_res = capture_resources();

    // Report
    let total_ops = ops.load(Ordering::Relaxed);
    let total_expected = expected_errors.load(Ordering::Relaxed);
    let total_unexpected = unexpected_errors.load(Ordering::Relaxed);

    println!();
    println!("═══════════════════════════════════════════════════════════════");
    println!("  Results ({}s):", elapsed);
    println!("    ops:              {}", total_ops);
    println!("    expected_errors:  {}", total_expected);
    println!("    unexpected_errors:{}", total_unexpected);
    println!(
        "    fd:  baseline={} final={} delta={}",
        baseline.fd_count,
        final_res.fd_count,
        final_res.fd_count - baseline.fd_count
    );
    println!(
        "    rss: baseline={}MB final={}MB delta={}MB",
        baseline.rss_bytes / (1024 * 1024),
        final_res.rss_bytes / (1024 * 1024),
        (final_res.rss_bytes - baseline.rss_bytes) / (1024 * 1024)
    );
    println!("═══════════════════════════════════════════════════════════════");

    // Check for failures
    let mut exit_code = 0;

    if total_unexpected > 0 {
        eprintln!("FAIL: {} unexpected errors", total_unexpected);
        exit_code = 1;
    }

    if baseline.fd_count >= 0 && final_res.fd_count >= 0 {
        let fd_delta = final_res.fd_count - baseline.fd_count;
        if fd_delta > max_fd_delta {
            eprintln!(
                "FAIL: FD leak suspected: delta={} allowed={}",
                fd_delta, max_fd_delta
            );
            exit_code = 1;
        }
    }

    if baseline.rss_bytes >= 0 && final_res.rss_bytes >= 0 {
        let rss_delta_mb = (final_res.rss_bytes - baseline.rss_bytes) / (1024 * 1024);
        if rss_delta_mb > max_rss_mb_delta as i64 {
            eprintln!(
                "FAIL: RSS leak suspected: delta={}MB allowed={}MB",
                rss_delta_mb, max_rss_mb_delta
            );
            exit_code = 1;
        }
    }

    if total_ops == 0 {
        eprintln!("FAIL: zero successful operations");
        exit_code = 1;
    }

    if exit_code == 0 {
        println!("PASS");
    }

    std::process::exit(exit_code);
}

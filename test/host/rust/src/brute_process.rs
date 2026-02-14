//! Rust Process-Mode Brute-Force Chaos Test
//!
//! Multi-threaded stress test that uses a Rust parent process host to start
//! Go/C++/Rust child processes and hammer them with randomized gRPC operations.
//!
//! Gated by SYNURANG_BRUTE=1 environment variable.
//!
//! Environment variables:
//!   SYNURANG_BRUTE=1                - required to run
//!   SYNURANG_BRUTE_DURATION         - total duration in seconds (default: 60)
//!   SYNURANG_BRUTE_WORKERS          - worker count (default: 4)
//!   SYNURANG_BRUTE_MAX_FD_DELTA     - max FD increase (default: 48)
//!   SYNURANG_BRUTE_MAX_RSS_MB_DELTA - max RSS increase MB (default: 256)
//!   SYNURANG_BRUTE_INCLUDE_CPP_CHILD=1 - also test C++ child (opt-in)

use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicI64, Ordering};
use std::sync::Arc;
use std::time::Duration;

use bytes::{Buf, BufMut};
use synurang_host::ProcessHost;
use tokio::sync::Mutex;
use tokio::time::{sleep, timeout, Instant};
use tokio_stream::wrappers::ReceiverStream;
use tokio_stream::Stream;
use tonic::codegen::http::uri::PathAndQuery;
use tonic::codegen::Bytes;
use tonic::transport::Channel;
use tonic::Request;
use tonic::{Code, Status};

const METHOD_UNARY: &str = "/example.v1.GoGreeterService/Bar";
const METHOD_SERVER_STREAM: &str = "/example.v1.GoGreeterService/BarServerStream";
const METHOD_CLIENT_STREAM: &str = "/example.v1.GoGreeterService/BarClientStream";
const METHOD_BIDI_STREAM: &str = "/example.v1.GoGreeterService/BarBidiStream";

// ---------------------------------------------------------------------------
// Proto helpers (manual protobuf for HelloRequest/HelloResponse)
// ---------------------------------------------------------------------------

fn push_varint(mut n: usize, out: &mut Vec<u8>) {
    while n >= 0x80 {
        out.push(((n & 0x7f) as u8) | 0x80);
        n >>= 7;
    }
    out.push((n & 0x7f) as u8);
}

fn push_len_delimited_field(tag: u8, value: &str, out: &mut Vec<u8>) {
    if value.is_empty() {
        return;
    }
    out.push(tag);
    push_varint(value.len(), out);
    out.extend_from_slice(value.as_bytes());
}

fn make_hello_request(name: &str) -> Bytes {
    make_hello_request_with_language(name, None)
}

fn make_hello_request_with_language(name: &str, language: Option<&str>) -> Bytes {
    let mut data = Vec::with_capacity(name.len() + language.map_or(0, str::len) + 8);
    push_len_delimited_field(0x0a, name, &mut data); // field 1 (name)
    if let Some(lang) = language {
        push_len_delimited_field(0x12, lang, &mut data); // field 2 (language)
    }
    Bytes::from(data)
}

fn parse_varint(data: &[u8]) -> Option<(usize, usize)> {
    let mut shift = 0usize;
    let mut value = 0usize;
    for (idx, b) in data.iter().copied().enumerate() {
        let part = (b & 0x7f) as usize;
        value |= part << shift;
        if (b & 0x80) == 0 {
            return Some((value, idx + 1));
        }
        shift += 7;
        if shift > 35 {
            return None;
        }
    }
    None
}

fn extract_message(data: &[u8]) -> String {
    if data.len() < 2 || data[0] != 0x0a {
        return "<parse error>".to_string();
    }
    let Some((msg_len, varint_len)) = parse_varint(&data[1..]) else {
        return "<invalid varint>".to_string();
    };
    let start = 1 + varint_len;
    let end = start + msg_len;
    if end > data.len() {
        return "<truncated>".to_string();
    }
    String::from_utf8_lossy(&data[start..end]).to_string()
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

    if let Ok(entries) = std::fs::read_dir("/proc/self/fd") {
        s.fd_count = entries.count() as i32;
    }

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
// Env helpers
// ---------------------------------------------------------------------------

fn env_int(key: &str, fallback: i32) -> i32 {
    std::env::var(key)
        .ok()
        .and_then(|v| v.parse::<i32>().ok())
        .unwrap_or(fallback)
}

fn env_duration_secs(key: &str, fallback: u64) -> u64 {
    let val = match std::env::var(key) {
        Ok(v) if !v.is_empty() => v,
        _ => return fallback,
    };

    let secs = if let Some(raw) = val.strip_suffix('s') {
        raw.parse::<u64>().unwrap_or(fallback)
    } else if let Some(raw) = val.strip_suffix('m') {
        raw.parse::<u64>().unwrap_or(fallback / 60) * 60
    } else {
        val.parse::<u64>().unwrap_or(fallback)
    };
    secs.max(1)
}

fn env_bool(key: &str, fallback: bool) -> bool {
    match std::env::var(key) {
        Ok(v) => matches!(v.to_ascii_lowercase().as_str(), "1" | "true" | "yes" | "on"),
        Err(_) => fallback,
    }
}

// ---------------------------------------------------------------------------
// RNG
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
// Child specs
// ---------------------------------------------------------------------------

#[derive(Clone)]
struct ChildSpec {
    name: &'static str,
    path: String,
}

fn with_exe_suffix(path: &str) -> String {
    if cfg!(windows) {
        format!("{}.exe", path)
    } else {
        path.to_string()
    }
}

fn process_child_specs() -> Vec<ChildSpec> {
    let mut specs = vec![
        ChildSpec {
            name: "Go",
            path: with_exe_suffix("bin/process_child"),
        },
        ChildSpec {
            name: "Rust",
            path: with_exe_suffix("bin/process_child_rust"),
        },
    ];

    // Rust host <-> C++ child over fd-backed IPC can be flaky depending on
    // local gRPC/tonic versions; keep it opt-in for deterministic CI.
    if env_bool("SYNURANG_BRUTE_INCLUDE_CPP_CHILD", false) {
        specs.insert(
            1,
            ChildSpec {
                name: "C++",
                path: with_exe_suffix("bin/process_child_cpp"),
            },
        );
    }

    specs
}

// ---------------------------------------------------------------------------
// Error classification
// ---------------------------------------------------------------------------

enum OpError {
    Status(Status),
    Check(String),
}

impl OpError {
    fn as_string(&self) -> String {
        match self {
            OpError::Status(st) => format!("status code={:?}: {}", st.code(), st.message()),
            OpError::Check(msg) => msg.clone(),
        }
    }
}

fn is_expected_error(err: &OpError) -> bool {
    match err {
        OpError::Status(st) => {
            matches!(
                st.code(),
                Code::Cancelled | Code::DeadlineExceeded | Code::Unavailable | Code::Aborted | Code::Unknown | Code::Internal
            ) || {
                let m = st.message().to_lowercase();
                m.contains("deadline")
                    || m.contains("canceled")
                    || m.contains("cancelled")
                    || m.contains("connection")
                    || m.contains("transport")
                    || m.contains("broken pipe")
                    || m.contains("eof")
                    || m.contains("malformed header")
                    || m.contains("http/2")
                    || m.contains("h2 protocol error")
            }
        }
        OpError::Check(msg) => {
            let m = msg.to_lowercase();
            m.contains("deadline")
                || m.contains("canceled")
                || m.contains("cancelled")
                || m.contains("connection")
                || m.contains("transport")
                || m.contains("broken pipe")
                || m.contains("malformed header")
                || m.contains("http/2")
        }
    }
}

// ---------------------------------------------------------------------------
// Generic RPC helpers (BytesCodec)
// ---------------------------------------------------------------------------

type Client = tonic::client::Grpc<Channel>;

fn new_client(channel: Channel) -> Client {
    tonic::client::Grpc::new(channel)
}

async fn ensure_ready(client: &mut Client) -> Result<(), Status> {
    client
        .ready()
        .await
        .map_err(|e| Status::unavailable(format!("grpc client not ready: {}", e)))
}

#[derive(Clone, Default)]
struct RawBytesCodec;

#[derive(Clone, Default)]
struct RawBytesEncoder;

#[derive(Clone, Default)]
struct RawBytesDecoder;

impl tonic::codec::Codec for RawBytesCodec {
    type Encode = Bytes;
    type Decode = Bytes;
    type Encoder = RawBytesEncoder;
    type Decoder = RawBytesDecoder;

    fn encoder(&mut self) -> Self::Encoder {
        RawBytesEncoder
    }

    fn decoder(&mut self) -> Self::Decoder {
        RawBytesDecoder
    }
}

impl tonic::codec::Encoder for RawBytesEncoder {
    type Item = Bytes;
    type Error = Status;

    fn encode(
        &mut self,
        item: Self::Item,
        dst: &mut tonic::codec::EncodeBuf<'_>,
    ) -> Result<(), Self::Error> {
        dst.put_slice(&item);
        Ok(())
    }
}

impl tonic::codec::Decoder for RawBytesDecoder {
    type Item = Bytes;
    type Error = Status;

    fn decode(
        &mut self,
        src: &mut tonic::codec::DecodeBuf<'_>,
    ) -> Result<Option<Self::Item>, Self::Error> {
        let len = src.remaining();
        let bytes = src.copy_to_bytes(len);
        Ok(Some(bytes))
    }
}

async fn rpc_unary(
    client: &mut Client,
    req: Request<Bytes>,
    method: &'static str,
) -> Result<Bytes, Status> {
    ensure_ready(client).await?;
    let codec = RawBytesCodec;
    let path = PathAndQuery::from_static(method);
    client.unary(req, path, codec).await.map(|r| r.into_inner())
}

async fn rpc_server_stream(
    client: &mut Client,
    req: Request<Bytes>,
    method: &'static str,
) -> Result<tonic::Streaming<Bytes>, Status> {
    ensure_ready(client).await?;
    let codec = RawBytesCodec;
    let path = PathAndQuery::from_static(method);
    client
        .server_streaming(req, path, codec)
        .await
        .map(|r| r.into_inner())
}

async fn rpc_client_stream<S>(
    client: &mut Client,
    req: Request<S>,
    method: &'static str,
) -> Result<Bytes, Status>
where
    S: Stream<Item = Bytes> + Send + 'static,
{
    ensure_ready(client).await?;
    let codec = RawBytesCodec;
    let path = PathAndQuery::from_static(method);
    client
        .client_streaming(req, path, codec)
        .await
        .map(|r| r.into_inner())
}

async fn rpc_bidi_stream<S>(
    client: &mut Client,
    req: Request<S>,
    method: &'static str,
) -> Result<tonic::Streaming<Bytes>, Status>
where
    S: Stream<Item = Bytes> + Send + 'static,
{
    ensure_ready(client).await?;
    let codec = RawBytesCodec;
    let path = PathAndQuery::from_static(method);
    client
        .streaming(req, path, codec)
        .await
        .map(|r| r.into_inner())
}

// ---------------------------------------------------------------------------
// Operation helpers
// ---------------------------------------------------------------------------

fn random_timeout(rng: &mut Rng) -> Duration {
    let n = rng.next_int(100);
    let ms = if n < 15 {
        rng.next_range(2, 5)
    } else if n < 65 {
        rng.next_range(20, 99)
    } else {
        rng.next_range(100, 450)
    };
    Duration::from_millis(ms as u64)
}

async fn op_unary(
    client: &mut Client,
    rng: &mut Rng,
    worker_id: i32,
    child_name: &str,
) -> Result<(), OpError> {
    let name = format!("u-{}-{}-{}", child_name, worker_id, rng.next_u64());
    let mut req = Request::new(make_hello_request(&name));
    req.set_timeout(random_timeout(rng));

    let resp = rpc_unary(client, req, METHOD_UNARY)
        .await
        .map_err(OpError::Status)?;
    let msg = extract_message(&resp);
    if msg.is_empty() || msg.starts_with('<') {
        return Err(OpError::Check("unary parse failure".into()));
    }
    if !msg.contains(&name) {
        return Err(OpError::Check(
            "unary response missing request marker".into(),
        ));
    }
    Ok(())
}

async fn op_server_stream(
    client: &mut Client,
    rng: &mut Rng,
    worker_id: i32,
    child_name: &str,
) -> Result<(), OpError> {
    let name = format!("ss-{}-{}-{}", child_name, worker_id, rng.next_u64());
    let mut req = Request::new(make_hello_request(&name));
    req.set_timeout(random_timeout(rng));

    let mut stream = rpc_server_stream(client, req, METHOD_SERVER_STREAM)
        .await
        .map_err(OpError::Status)?;

    let target = rng.next_range(1, 5);
    let mut received = 0;
    for _ in 0..target {
        match stream.message().await {
            Ok(Some(resp)) => {
                let msg = extract_message(&resp);
                if msg.is_empty() || msg.starts_with('<') {
                    return Err(OpError::Check("server-stream parse failure".into()));
                }
                received += 1;
            }
            Ok(None) => break,
            Err(st) => return Err(OpError::Status(st)),
        }
    }

    if received == 0 {
        return Err(OpError::Check(
            "server-stream returned zero messages".into(),
        ));
    }

    if rng.next_int(100) < 40 {
        loop {
            match stream.message().await {
                Ok(Some(_)) => received += 1,
                Ok(None) => break,
                Err(st) => return Err(OpError::Status(st)),
            }
        }
    }

    Ok(())
}

async fn op_client_stream(
    client: &mut Client,
    rng: &mut Rng,
    worker_id: i32,
    child_name: &str,
) -> Result<(), OpError> {
    let count = rng.next_range(1, 20);
    let mut requests = Vec::with_capacity(count as usize);
    for i in 0..count {
        requests.push(make_hello_request(&format!(
            "cs-{}-{}-{}-{}",
            child_name,
            worker_id,
            i,
            rng.next_u64()
        )));
    }

    let outbound = tokio_stream::iter(requests);
    let mut req = Request::new(outbound);
    req.set_timeout(random_timeout(rng));

    let resp = rpc_client_stream(client, req, METHOD_CLIENT_STREAM)
        .await
        .map_err(OpError::Status)?;
    let msg = extract_message(&resp);
    if msg.is_empty() || msg.starts_with('<') {
        return Err(OpError::Check("client-stream parse failure".into()));
    }
    Ok(())
}

async fn op_bidi_stream(
    client: &mut Client,
    rng: &mut Rng,
    worker_id: i32,
    child_name: &str,
) -> Result<(), OpError> {
    let (tx, rx) = tokio::sync::mpsc::channel(16);
    let mut req = Request::new(ReceiverStream::new(rx));
    req.set_timeout(random_timeout(rng));

    let mut inbound = rpc_bidi_stream(client, req, METHOD_BIDI_STREAM)
        .await
        .map_err(OpError::Status)?;

    let count = rng.next_range(1, 12);
    let mut received = 0;
    for i in 0..count {
        let name = format!("bs-{}-{}-{}-{}", child_name, worker_id, i, rng.next_u64());
        tx.send(make_hello_request(&name))
            .await
            .map_err(|_| OpError::Check("bidi outbound channel closed".into()))?;

        match inbound.message().await {
            Ok(Some(resp)) => {
                let msg = extract_message(&resp);
                if msg.is_empty() || msg.starts_with('<') {
                    return Err(OpError::Check("bidi parse failure".into()));
                }
                received += 1;
            }
            Ok(None) => break,
            Err(st) => return Err(OpError::Status(st)),
        }
    }

    drop(tx);

    if received == 0 {
        return Err(OpError::Check("bidi received zero responses".into()));
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Chaos operations
// ---------------------------------------------------------------------------

async fn chaos_open_and_abandon(client: &mut Client, rng: &mut Rng) -> Result<(), OpError> {
    let mut req = Request::new(make_hello_request("chaos-open-abandon"));
    req.set_timeout(Duration::from_millis(rng.next_range(20, 80) as u64));
    let _ = rpc_server_stream(client, req, METHOD_SERVER_STREAM)
        .await
        .map_err(OpError::Status)?;
    Ok(())
}

async fn chaos_double_close(client: &mut Client, rng: &mut Rng) -> Result<(), OpError> {
    let (tx, rx) = tokio::sync::mpsc::channel(4);
    let mut req = Request::new(ReceiverStream::new(rx));
    req.set_timeout(random_timeout(rng));
    let mut inbound = rpc_bidi_stream(client, req, METHOD_BIDI_STREAM)
        .await
        .map_err(OpError::Status)?;

    tx.send(make_hello_request("chaos-double-close"))
        .await
        .map_err(|_| OpError::Check("chaos_double_close send failed".into()))?;
    drop(tx);
    match inbound.message().await {
        Ok(Some(_)) | Ok(None) => Ok(()),
        Err(st) => Err(OpError::Status(st)),
    }
}

async fn chaos_send_after_close_send(
    client: &mut Client,
    rng: &mut Rng,
    worker_id: i32,
) -> Result<(), OpError> {
    let (tx, rx) = tokio::sync::mpsc::channel(2);
    let mut req = Request::new(ReceiverStream::new(rx));
    req.set_timeout(random_timeout(rng));
    let response_fut = rpc_client_stream(client, req, METHOD_CLIENT_STREAM);

    tx.send(make_hello_request(&format!("chaos-sac-{}", worker_id)))
        .await
        .map_err(|_| OpError::Check("chaos_send_after_close_send send failed".into()))?;
    drop(tx);
    let _ = response_fut.await.map_err(OpError::Status)?;
    Ok(())
}

async fn chaos_recv_after_cancel(client: &mut Client, rng: &mut Rng) -> Result<(), OpError> {
    let mut req = Request::new(make_hello_request("chaos-rac"));
    req.set_timeout(Duration::from_millis(rng.next_range(20, 60) as u64));
    let mut inbound = rpc_server_stream(client, req, METHOD_SERVER_STREAM)
        .await
        .map_err(OpError::Status)?;

    let _ = inbound.message().await;
    match inbound.message().await {
        Ok(Some(_)) | Ok(None) => Ok(()),
        Err(st) => Err(OpError::Status(st)),
    }
}

async fn chaos_concurrent_send_recv(
    client: &mut Client,
    rng: &mut Rng,
    worker_id: i32,
) -> Result<(), OpError> {
    let (tx, rx) = tokio::sync::mpsc::channel(16);
    let mut req = Request::new(ReceiverStream::new(rx));
    req.set_timeout(random_timeout(rng));
    let mut inbound = rpc_bidi_stream(client, req, METHOD_BIDI_STREAM)
        .await
        .map_err(OpError::Status)?;

    let count = rng.next_range(3, 7);
    let sender = tokio::spawn(async move {
        for i in 0..count {
            if tx
                .send(make_hello_request(&format!(
                    "chaos-csr-{}-{}",
                    worker_id, i
                )))
                .await
                .is_err()
            {
                return;
            }
            sleep(Duration::from_millis(1)).await;
        }
    });

    let mut reads = 0;
    while reads < count {
        match inbound.message().await {
            Ok(Some(_)) => reads += 1,
            Ok(None) => break,
            Err(st) => return Err(OpError::Status(st)),
        }
    }

    let _ = sender.await;
    Ok(())
}

async fn chaos_boundary_payloads(
    client: &mut Client,
    rng: &mut Rng,
    worker_id: i32,
) -> Result<(), OpError> {
    let (name, language) = match rng.next_int(3) {
        0 => (String::new(), "en".to_string()),
        1 => ("x".to_string(), format!("w{}", worker_id)),
        _ => {
            let size = rng.next_range(64 * 1024, 256 * 1024) as usize;
            ("boundary".to_string(), "B".repeat(size))
        }
    };

    let mut req = Request::new(make_hello_request_with_language(&name, Some(&language)));
    req.set_timeout(Duration::from_millis(rng.next_range(500, 1500) as u64));
    let _ = rpc_unary(client, req, METHOD_UNARY)
        .await
        .map_err(OpError::Status)?;
    Ok(())
}

async fn chaos_mismatched_bidi(
    client: &mut Client,
    rng: &mut Rng,
    worker_id: i32,
) -> Result<(), OpError> {
    let (tx, rx) = tokio::sync::mpsc::channel(32);
    let mut req = Request::new(ReceiverStream::new(rx));
    req.set_timeout(random_timeout(rng));
    let mut inbound = rpc_bidi_stream(client, req, METHOD_BIDI_STREAM)
        .await
        .map_err(OpError::Status)?;

    let send_count = rng.next_range(3, 10);
    for i in 0..send_count {
        tx.send(make_hello_request(&format!("chaos-mm-{}-{}", worker_id, i)))
            .await
            .map_err(|_| OpError::Check("chaos_mismatched_bidi send failed".into()))?;
    }

    let recv_count = rng.next_range(1, std::cmp::max(1, send_count - 1));
    for _ in 0..recv_count {
        match inbound.message().await {
            Ok(Some(_)) => {}
            Ok(None) => break,
            Err(st) => return Err(OpError::Status(st)),
        }
    }

    drop(tx);
    Ok(())
}

async fn chaos_immediate_cancel(client: &mut Client) -> Result<(), OpError> {
    let req = Request::new(make_hello_request("chaos-immediate-cancel"));
    match timeout(
        Duration::from_millis(1),
        rpc_unary(client, req, METHOD_UNARY),
    )
    .await
    {
        Ok(Ok(_)) => Ok(()),
        Ok(Err(st)) => Err(OpError::Status(st)),
        Err(_) => Ok(()), // local timeout is acceptable chaos behavior
    }
}

async fn run_chaos_op(client: &mut Client, rng: &mut Rng, worker_id: i32) -> Result<(), OpError> {
    let x = rng.next_int(100);
    if x < 15 {
        chaos_open_and_abandon(client, rng).await
    } else if x < 30 {
        chaos_double_close(client, rng).await
    } else if x < 43 {
        chaos_send_after_close_send(client, rng, worker_id).await
    } else if x < 56 {
        chaos_recv_after_cancel(client, rng).await
    } else if x < 70 {
        chaos_concurrent_send_recv(client, rng, worker_id).await
    } else if x < 82 {
        chaos_boundary_payloads(client, rng, worker_id).await
    } else if x < 92 {
        chaos_mismatched_bidi(client, rng, worker_id).await
    } else {
        chaos_immediate_cancel(client).await
    }
}

async fn run_random_op(
    client: &mut Client,
    rng: &mut Rng,
    worker_id: i32,
    child_name: &str,
) -> Result<(), OpError> {
    let x = rng.next_int(100);
    if x < 40 {
        op_unary(client, rng, worker_id, child_name).await
    } else if x < 62 {
        op_server_stream(client, rng, worker_id, child_name).await
    } else if x < 78 {
        op_client_stream(client, rng, worker_id, child_name).await
    } else if x < 88 {
        op_bidi_stream(client, rng, worker_id, child_name).await
    } else {
        run_chaos_op(client, rng, worker_id).await
    }
}

// ---------------------------------------------------------------------------
// Phase runner
// ---------------------------------------------------------------------------

struct PhaseResult {
    child_name: String,
    pass: bool,
    crashed: bool,
    warmup_ok: bool,
    ops: i64,
    expected_errors: i64,
    unexpected_errors: i64,
    fd_delta: i32,
    rss_delta_mb: i64,
}

async fn warmup_unary(client: &mut Client, child_name: &str) -> Result<bool, OpError> {
    for attempt in 0..60 {
        let mut req = Request::new(make_hello_request(&format!(
            "warmup-{}-{}",
            child_name, attempt
        )));
        req.set_timeout(Duration::from_millis(500));

        match rpc_unary(client, req, METHOD_UNARY).await {
            Ok(resp) => {
                let msg = extract_message(&resp);
                if !msg.is_empty() && !msg.starts_with('<') {
                    return Ok(true);
                }
            }
            Err(st) => {
                let err = OpError::Status(st);
                if !is_expected_error(&err) {
                    return Err(err);
                }
            }
        }

        sleep(Duration::from_millis(25)).await;
    }

    Ok(false)
}

async fn run_child_phase(
    spec: &ChildSpec,
    duration: Duration,
    workers: i32,
    max_fd_delta: i32,
    max_rss_mb_delta: i32,
) -> PhaseResult {
    let mut result = PhaseResult {
        child_name: spec.name.to_string(),
        pass: false,
        crashed: false,
        warmup_ok: false,
        ops: 0,
        expected_errors: 0,
        unexpected_errors: 0,
        fd_delta: 0,
        rss_delta_mb: 0,
    };

    if !Path::new(&spec.path).exists() {
        eprintln!(
            "  FATAL [{}]: child not found: {} (run `make build_process_all` first)",
            spec.name, spec.path
        );
        result.unexpected_errors = 1;
        return result;
    }

    let process = match ProcessHost::start(&spec.path, &[]).await {
        Ok(p) => p,
        Err(e) => {
            eprintln!("  FATAL [{}]: ProcessHost::start failed: {}", spec.name, e);
            result.unexpected_errors = 1;
            return result;
        }
    };

    let channel = process.channel();
    let process = Arc::new(Mutex::new(process));

    let mut warmup_client = new_client(channel.clone());
    let warmup_ok = match warmup_unary(&mut warmup_client, spec.name).await {
        Ok(ok) => ok,
        Err(err) => {
            eprintln!(
                "  FATAL [{}]: warmup failed unexpectedly: {}",
                spec.name,
                err.as_string()
            );
            result.unexpected_errors = 1;
            return result;
        }
    };
    if !warmup_ok {
        eprintln!(
            "  WARN  [{}]: warmup did not get a successful unary response before phase",
            spec.name
        );
    }
    result.warmup_ok = warmup_ok;

    sleep(Duration::from_millis(40)).await;
    let baseline = capture_resources();

    let ops = Arc::new(AtomicI64::new(if warmup_ok { 1 } else { 0 }));
    let expected = Arc::new(AtomicI64::new(0));
    let unexpected = Arc::new(AtomicI64::new(0));
    let stop_all = Arc::new(AtomicBool::new(false));
    let stop_monitor = Arc::new(AtomicBool::new(false));
    let crashed = Arc::new(AtomicBool::new(false));

    let process_for_monitor = Arc::clone(&process);
    let stop_all_for_monitor = Arc::clone(&stop_all);
    let stop_monitor_for_monitor = Arc::clone(&stop_monitor);
    let crashed_for_monitor = Arc::clone(&crashed);
    let monitor = tokio::spawn(async move {
        while !stop_monitor_for_monitor.load(Ordering::Relaxed)
            && !stop_all_for_monitor.load(Ordering::Relaxed)
        {
            let running = {
                let mut guard = process_for_monitor.lock().await;
                guard.is_running()
            };
            if !running {
                crashed_for_monitor.store(true, Ordering::Relaxed);
                stop_all_for_monitor.store(true, Ordering::Relaxed);
                break;
            }
            sleep(Duration::from_millis(100)).await;
        }
    });

    let mut handles = Vec::new();
    for w in 0..workers {
        let mut client = new_client(channel.clone());
        let ops_ref = Arc::clone(&ops);
        let expected_ref = Arc::clone(&expected);
        let unexpected_ref = Arc::clone(&unexpected);
        let stop_all_ref = Arc::clone(&stop_all);
        let child_name = spec.name.to_string();

        handles.push(tokio::spawn(async move {
            let mut rng =
                Rng::new(Instant::now().elapsed().as_nanos() as u64 + (w as u64 * 100_103));
            let started = Instant::now();

            while started.elapsed() < duration && !stop_all_ref.load(Ordering::Relaxed) {
                match run_random_op(&mut client, &mut rng, w, &child_name).await {
                    Ok(()) => {
                        ops_ref.fetch_add(1, Ordering::Relaxed);
                    }
                    Err(err) if is_expected_error(&err) => {
                        expected_ref.fetch_add(1, Ordering::Relaxed);
                    }
                    Err(err) => {
                        let prev = unexpected_ref.fetch_add(1, Ordering::Relaxed);
                        if prev < 5 {
                            eprintln!(
                                "  UNEXPECTED [{} worker {}]: {}",
                                child_name,
                                w,
                                err.as_string()
                            );
                        }
                        stop_all_ref.store(true, Ordering::Relaxed);
                        return;
                    }
                }

                let ms = rng.next_range(1, 5) as u64;
                sleep(Duration::from_millis(ms)).await;
            }
        }));
    }

    for handle in handles {
        let _ = handle.await;
    }

    stop_monitor.store(true, Ordering::Relaxed);
    let _ = monitor.await;

    if crashed.load(Ordering::Relaxed) {
        result.crashed = true;
        unexpected.fetch_add(1, Ordering::Relaxed);
        eprintln!("  UNEXPECTED [{}]: child exited during phase", spec.name);
    }

    {
        let mut guard = process.lock().await;
        let _ = guard.terminate();
        let _ = guard.wait();
    }

    sleep(Duration::from_millis(80)).await;
    let final_res = capture_resources();

    result.ops = ops.load(Ordering::Relaxed);
    result.expected_errors = expected.load(Ordering::Relaxed);
    result.unexpected_errors = unexpected.load(Ordering::Relaxed);

    if baseline.fd_count >= 0 && final_res.fd_count >= 0 {
        result.fd_delta = final_res.fd_count - baseline.fd_count;
    }
    if baseline.rss_bytes >= 0 && final_res.rss_bytes >= 0 {
        result.rss_delta_mb = (final_res.rss_bytes - baseline.rss_bytes) / (1024 * 1024);
    }

    result.pass = true;
    if result.unexpected_errors > 0 || result.crashed {
        result.pass = false;
    }
    if baseline.fd_count >= 0 && final_res.fd_count >= 0 && result.fd_delta > max_fd_delta {
        result.pass = false;
    }
    if baseline.rss_bytes >= 0
        && final_res.rss_bytes >= 0
        && result.rss_delta_mb > max_rss_mb_delta as i64
    {
        result.pass = false;
    }

    println!(
        "  [{}] ops={} expected_errs={} unexpected_errs={} warmup_ok={} fd_delta={} rss_delta_mb={} crashed={}",
        spec.name,
        result.ops,
        result.expected_errors,
        result.unexpected_errors,
        if result.warmup_ok { "yes" } else { "no" },
        result.fd_delta,
        result.rss_delta_mb,
        if result.crashed { "yes" } else { "no" }
    );

    result
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

#[tokio::main(flavor = "multi_thread")]
async fn main() {
    if std::env::var("SYNURANG_BRUTE").as_deref() != Ok("1") {
        println!("SKIP: set SYNURANG_BRUTE=1 to run Rust process host brute-force test");
        return;
    }

    let total_duration_secs = env_duration_secs("SYNURANG_BRUTE_DURATION", 60);
    let workers = env_int("SYNURANG_BRUTE_WORKERS", 4).max(1);
    let max_fd_delta = env_int("SYNURANG_BRUTE_MAX_FD_DELTA", 48);
    let max_rss_mb_delta = env_int("SYNURANG_BRUTE_MAX_RSS_MB_DELTA", 256);

    let specs = process_child_specs();
    let per_child_secs = std::cmp::max(1, total_duration_secs / specs.len() as u64);
    let per_child_duration = Duration::from_secs(per_child_secs);

    println!("═══════════════════════════════════════════════════════════════");
    println!("  Rust Process Host Brute-Force Chaos Test");
    println!(
        "  total_duration={}s per_child={}s workers={} max_fd_delta={} max_rss_mb_delta={}",
        total_duration_secs, per_child_secs, workers, max_fd_delta, max_rss_mb_delta
    );
    println!("═══════════════════════════════════════════════════════════════");

    let mut exit_code = 0;
    let mut total_ops = 0_i64;
    let mut total_expected = 0_i64;
    let mut total_unexpected = 0_i64;

    for spec in &specs {
        println!("\n▶ Process child: {} ({})", spec.name, spec.path);
        let phase = run_child_phase(
            spec,
            per_child_duration,
            workers,
            max_fd_delta,
            max_rss_mb_delta,
        )
        .await;

        total_ops += phase.ops;
        total_expected += phase.expected_errors;
        total_unexpected += phase.unexpected_errors;

        if !phase.pass {
            exit_code = 1;
            if phase.ops == 0 && phase.warmup_ok {
                eprintln!("  FAIL [{}]: zero successful operations", phase.child_name);
            }
            if phase.fd_delta > max_fd_delta {
                eprintln!(
                    "  FAIL [{}]: FD leak suspected: delta={} allowed={}",
                    phase.child_name, phase.fd_delta, max_fd_delta
                );
            }
            if phase.rss_delta_mb > max_rss_mb_delta as i64 {
                eprintln!(
                    "  FAIL [{}]: RSS leak suspected: delta={}MB allowed={}MB",
                    phase.child_name, phase.rss_delta_mb, max_rss_mb_delta
                );
            }
        }
    }

    if total_ops == 0 {
        eprintln!("FAIL: zero successful operations across all process children");
        exit_code = 1;
    }

    println!();
    println!("═══════════════════════════════════════════════════════════════");
    println!("  Aggregate Results:");
    println!("    ops:               {}", total_ops);
    println!("    expected_errors:   {}", total_expected);
    println!("    unexpected_errors: {}", total_unexpected);
    println!("═══════════════════════════════════════════════════════════════");

    if exit_code == 0 {
        println!("PASS");
    }

    std::process::exit(exit_code);
}

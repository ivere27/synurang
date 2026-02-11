//! Synurang Media Processor Plugin (Rust)
//!
//! Implements the MediaProcessor service for the Android Java/Kotlin example:
//!   - ProcessFrames: receives camera frame pointers, processes pixels, signals release
//!   - ProcessAudio: receives PCM audio, applies gain adjustment, returns processed audio
//!
//! Build for Android:
//!   cargo ndk -t arm64-v8a -o jniLibs build --release
//!
//! Build for Linux (testing):
//!   cargo build --release

use prost::Message;
use std::collections::{HashMap, VecDeque};
use std::ffi::{c_char, c_int, c_ulonglong, CStr};
use std::sync::{Arc, Mutex};
use std::sync::mpsc;
use std::time::Instant;

pub mod media {
    include!(concat!(env!("OUT_DIR"), "/media.v1.rs"));
}

use media::{AudioChunk, FrameRef, FrameResult};

// =============================================================================
// Frame Processing
// =============================================================================

/// Modify Y plane in-place: posterize. Same buffer, zero-copy.
fn process_frame_inplace(y_plane: &mut [u8], width: usize, height: usize, stride: usize) {
    for row in 0..height {
        let off = row * stride;
        for col in 0..width {
            let y = y_plane[off + col];
            y_plane[off + col] = (y / 64) * 85;
        }
    }
}

// =============================================================================
// Stream State
// =============================================================================

struct StreamState {
    send_tx: Option<mpsc::Sender<Vec<u8>>>,
    recv_rx: Arc<Mutex<mpsc::Receiver<Vec<u8>>>>,
}

static STREAMS: Mutex<Option<(u64, HashMap<u64, StreamState>)>> = Mutex::new(None);

fn with_streams<R>(f: impl FnOnce(&mut u64, &mut HashMap<u64, StreamState>) -> R) -> R {
    let mut guard = STREAMS.lock().unwrap();
    let (counter, map) = guard.get_or_insert_with(|| (0, HashMap::new()));
    f(counter, map)
}

// =============================================================================
// Audio Processing
// =============================================================================

/// Apply 1.5x gain to 16-bit little-endian PCM samples with clamping.
fn apply_gain(data: &[u8]) -> Vec<u8> {
    let mut out = data.to_vec();
    let mut i = 0;
    while i + 1 < out.len() {
        let sample = i16::from_le_bytes([out[i], out[i + 1]]);
        let gained = (sample as f32 * 1.5) as i32;
        let clamped = gained.clamp(-32768, 32767) as i16;
        let bytes = clamped.to_le_bytes();
        out[i] = bytes[0];
        out[i + 1] = bytes[1];
        i += 2;
    }
    out
}

// =============================================================================
// Audio Volume Envelope (drawn on Y plane by frame handler)
// =============================================================================

/// RMS envelope values (0.0–1.0) shared between ProcessAudio and ProcessFrames.
static AUDIO_ENVELOPE: Mutex<Option<VecDeque<f32>>> = Mutex::new(None);

const ENVELOPE_SIZE: usize = 256;
const RMS_WINDOW: usize = 256;

/// Compute RMS of PCM in windows and store as envelope values.
fn store_audio_samples(pcm: &[u8]) {
    let mut guard = AUDIO_ENVELOPE.lock().unwrap();
    let buf = guard.get_or_insert_with(|| VecDeque::with_capacity(ENVELOPE_SIZE));
    let mut i = 0;
    let mut window_sum: f64 = 0.0;
    let mut window_count: usize = 0;
    while i + 1 < pcm.len() {
        let sample = i16::from_le_bytes([pcm[i], pcm[i + 1]]) as f64;
        window_sum += sample * sample;
        window_count += 1;
        i += 2;
        if window_count >= RMS_WINDOW {
            let rms = (window_sum / window_count as f64).sqrt() as f32 / 32768.0;
            buf.push_back(rms);
            window_sum = 0.0;
            window_count = 0;
        }
    }
    if window_count > 0 {
        let rms = (window_sum / window_count as f64).sqrt() as f32 / 32768.0;
        buf.push_back(rms);
    }
    while buf.len() > ENVELOPE_SIZE {
        buf.pop_front();
    }
}

/// Draw volume envelope (mirrored bars) on the center of the Y plane.
fn draw_waveform_on_y_plane(y_plane: &mut [u8], width: usize, height: usize, stride: usize) {
    let envelope: Vec<f32> = {
        let guard = AUDIO_ENVELOPE.lock().unwrap();
        match guard.as_ref() {
            Some(buf) if !buf.is_empty() => buf.iter().copied().collect(),
            _ => return,
        }
    };

    let wave_height = height * 3 / 5;
    if wave_height < 4 {
        return;
    }
    let wave_top = (height - wave_height) / 2;
    let wave_bot = wave_top + wave_height;
    let wave_mid = wave_top + wave_height / 2;
    let half_h = wave_height / 2;

    // Draw envelope — mirrored filled bars from center with gaps
    let env_count = envelope.len();
    let bar_w = (width / env_count).max(2);
    let gap = (bar_w / 3).max(1);
    let bar_fill = bar_w - gap;
    for i in 0..env_count {
        let x_start = i * width / env_count;
        let amp = envelope[i].min(1.0);
        let bar_half = (amp * half_h as f32 * 2.7) as usize;
        if bar_half == 0 {
            for col in x_start..x_start + bar_fill {
                if col >= width { break; }
                let off = wave_mid * stride + col;
                if off < y_plane.len() {
                    y_plane[off] = 80;
                }
            }
            continue;
        }
        let y_top = wave_mid.saturating_sub(bar_half).max(wave_top);
        let y_bot = (wave_mid + bar_half).min(wave_bot - 1);
        for col in x_start..x_start + bar_fill {
            if col >= width { break; }
            for row in y_top..=y_bot {
                let off = row * stride + col;
                if off < y_plane.len() {
                    y_plane[off] = 220;
                }
            }
            // Bright edge at top and bottom
            for &edge in &[y_top, y_bot] {
                let off = edge * stride + col;
                if off < y_plane.len() {
                    y_plane[off] = 255;
                }
            }
        }
    }
}

// =============================================================================
// Process Stats (read from /proc/self)
// =============================================================================

fn read_rss_mb() -> i32 {
    std::fs::read_to_string("/proc/self/status")
        .ok()
        .and_then(|s| {
            s.lines()
                .find(|l| l.starts_with("VmRSS:"))
                .and_then(|l| l.split_whitespace().nth(1))
                .and_then(|v| v.parse::<i64>().ok())
                .map(|kb| (kb / 1024) as i32)
        })
        .unwrap_or(0)
}

fn read_cpu_ticks() -> u64 {
    std::fs::read_to_string("/proc/self/stat")
        .ok()
        .and_then(|s| {
            let after = s.split(") ").nth(1)?;
            let fields: Vec<&str> = after.split_whitespace().collect();
            // [11]=utime, [12]=stime (0-indexed after ")")
            let utime = fields.get(11)?.parse::<u64>().ok()?;
            let stime = fields.get(12)?.parse::<u64>().ok()?;
            Some(utime + stime)
        })
        .unwrap_or(0)
}

// =============================================================================
// Stream Handlers
// =============================================================================

fn handle_process_frames(rx: mpsc::Receiver<Vec<u8>>, tx: mpsc::Sender<Vec<u8>>) {
    let mut last_time = Instant::now();
    let mut fps: f32 = 0.0;
    let mut last_stats_time = Instant::now();
    let mut last_cpu_ticks: u64 = 0;
    let mut cached_rss_mb: i32 = 0;
    let mut cached_cpu_pct: f32 = 0.0;

    while let Ok(data) = rx.recv() {
        let frame = match FrameRef::decode(data.as_slice()) {
            Ok(f) => f,
            Err(_) => continue,
        };

        // Calculate FPS
        let now = Instant::now();
        let dt = now.duration_since(last_time).as_secs_f32();
        if dt > 0.0 {
            fps = fps * 0.8 + (1.0 / dt) * 0.2; // smoothed
        }
        last_time = now;

        // Update process stats once per second
        let stats_dt = now.duration_since(last_stats_time).as_secs_f32();
        if stats_dt >= 1.0 {
            cached_rss_mb = read_rss_mb();
            let ticks = read_cpu_ticks();
            if last_cpu_ticks > 0 {
                let delta = ticks - last_cpu_ticks;
                cached_cpu_pct = delta as f32 / 100.0 / stats_dt * 100.0; // CLK_TCK=100
            }
            last_cpu_ticks = ticks;
            last_stats_time = now;
        }

        // Zero-copy: dereference native pointer, modify Y plane in-place
        if frame.handle != 0 && frame.data_size > 0 {
            let ptr = frame.handle as *mut u8;
            if !ptr.is_null() {
                // SAFETY: pointer comes from Camera2 DirectByteBuffer in the same process.
                // Kotlin keeps the Image alive until we return the result.
                let w = frame.width as usize;
                let h = frame.height as usize;
                let stride = if frame.row_stride > 0 { frame.row_stride as usize } else { w };
                let y_plane = unsafe { std::slice::from_raw_parts_mut(ptr, frame.data_size as usize) };
                process_frame_inplace(y_plane, w, h, stride);
                draw_waveform_on_y_plane(y_plane, w, h, stride);
            }
        }

        let result = FrameResult {
            release: true,
            rss_mb: cached_rss_mb,
            cpu_percent: cached_cpu_pct,
            rust_fps: fps,
        };

        let mut resp_bytes = Vec::new();
        let _ = result.encode(&mut resp_bytes);

        // Prepend status byte (0 = success)
        let mut resp = Vec::with_capacity(1 + resp_bytes.len());
        resp.push(0);
        resp.extend_from_slice(&resp_bytes);

        if tx.send(resp).is_err() {
            break;
        }
    }
}

fn handle_process_audio(rx: mpsc::Receiver<Vec<u8>>, tx: mpsc::Sender<Vec<u8>>) {
    while let Ok(data) = rx.recv() {
        let chunk = match AudioChunk::decode(data.as_slice()) {
            Ok(c) => c,
            Err(_) => continue,
        };

        store_audio_samples(&chunk.data);
        let processed = apply_gain(&chunk.data);
        let result = AudioChunk {
            data: processed,
            sample_rate: chunk.sample_rate,
        };

        let mut resp_bytes = Vec::new();
        let _ = result.encode(&mut resp_bytes);

        let mut resp = Vec::with_capacity(1 + resp_bytes.len());
        resp.push(0);
        resp.extend_from_slice(&resp_bytes);

        if tx.send(resp).is_err() {
            break;
        }
    }
    // Clear envelope so waveform disappears from frames
    if let Ok(mut guard) = AUDIO_ENVELOPE.lock() {
        *guard = None;
    }
}

// =============================================================================
// C ABI Helpers
// =============================================================================

/// Allocate a response buffer using malloc-compatible allocation.
/// Caller must free with Synurang_Free.
fn alloc_c_bytes(data: &[u8]) -> *mut c_char {
    if data.is_empty() {
        return std::ptr::null_mut();
    }
    let ptr = unsafe { libc_malloc(data.len()) } as *mut u8;
    if ptr.is_null() {
        return std::ptr::null_mut();
    }
    unsafe {
        std::ptr::copy_nonoverlapping(data.as_ptr(), ptr, data.len());
    }
    ptr as *mut c_char
}

// Minimal libc wrappers to avoid adding libc crate dependency
extern "C" {
    fn malloc(size: usize) -> *mut std::ffi::c_void;
    fn free(ptr: *mut std::ffi::c_void);
}

unsafe fn libc_malloc(size: usize) -> *mut std::ffi::c_void {
    unsafe { malloc(size) }
}

unsafe fn libc_free(ptr: *mut std::ffi::c_void) {
    unsafe { free(ptr) }
}

// =============================================================================
// Synurang C ABI Exports
// =============================================================================

#[no_mangle]
pub extern "C" fn Synurang_Free(ptr: *mut c_char) {
    if !ptr.is_null() {
        unsafe { libc_free(ptr as *mut std::ffi::c_void) };
    }
}

#[no_mangle]
pub extern "C" fn Synurang_Invoke_MediaProcessor(
    _method: *mut c_char,
    _data: *mut c_char,
    _data_len: c_int,
    resp_len: *mut c_int,
) -> *mut c_char {
    // MediaProcessor only supports streaming RPCs
    let msg = b"\x01MediaProcessor only supports streaming RPCs";
    unsafe { *resp_len = msg.len() as c_int; }
    alloc_c_bytes(msg)
}

#[no_mangle]
pub extern "C" fn Synurang_Stream_MediaProcessor_Open(method: *mut c_char) -> c_ulonglong {
    let method_str = unsafe { CStr::from_ptr(method).to_string_lossy().to_string() };

    let (send_to_handler_tx, send_to_handler_rx) = mpsc::channel::<Vec<u8>>();
    let (recv_from_handler_tx, recv_from_handler_rx) = mpsc::channel::<Vec<u8>>();

    // Start handler thread based on method
    match method_str.as_str() {
        "/media.v1.MediaProcessor/ProcessFrames" => {
            std::thread::spawn(move || handle_process_frames(send_to_handler_rx, recv_from_handler_tx));
        }
        "/media.v1.MediaProcessor/ProcessAudio" => {
            std::thread::spawn(move || handle_process_audio(send_to_handler_rx, recv_from_handler_tx));
        }
        _ => return 0,
    }

    with_streams(|counter, map| {
        *counter += 1;
        let id = *counter;
        map.insert(id, StreamState {
            send_tx: Some(send_to_handler_tx),
            recv_rx: Arc::new(Mutex::new(recv_from_handler_rx)),
        });
        id as c_ulonglong
    })
}

#[no_mangle]
pub extern "C" fn Synurang_Stream_Send(
    handle: c_ulonglong,
    data: *mut c_char,
    data_len: c_int,
) -> c_int {
    let bytes = if data.is_null() || data_len <= 0 {
        Vec::new()
    } else {
        unsafe { std::slice::from_raw_parts(data as *const u8, data_len as usize).to_vec() }
    };

    with_streams(|_, map| {
        if let Some(state) = map.get(&(handle as u64)) {
            if let Some(ref tx) = state.send_tx {
                match tx.send(bytes) {
                    Ok(_) => 0,
                    Err(_) => 1,
                }
            } else {
                1 // send side already closed
            }
        } else {
            1
        }
    })
}

#[no_mangle]
pub extern "C" fn Synurang_Stream_Recv(
    handle: c_ulonglong,
    resp_len: *mut c_int,
    status: *mut c_int,
) -> *mut c_char {
    // Clone the Arc to release the global STREAMS lock before blocking on recv
    let rx = with_streams(|_, map| {
        map.get(&(handle as u64)).map(|s| s.recv_rx.clone())
    });

    let result = match rx {
        Some(rx) => {
            let guard = rx.lock().unwrap();
            match guard.recv() {
                Ok(data) => Some(data),
                Err(_) => None, // channel closed = EOF
            }
        }
        None => None,
    };

    match result {
        Some(data) => {
            unsafe {
                *resp_len = data.len() as c_int;
                *status = 0;
            }
            alloc_c_bytes(&data)
        }
        None => {
            unsafe {
                *resp_len = 0;
                *status = 1; // EOF
            }
            std::ptr::null_mut()
        }
    }
}

#[no_mangle]
pub extern "C" fn Synurang_Stream_CloseSend(handle: c_ulonglong) {
    with_streams(|_, map| {
        if let Some(state) = map.get_mut(&(handle as u64)) {
            // Drop the sender to signal EOF to the handler
            state.send_tx.take();
        }
    });
}

#[no_mangle]
pub extern "C" fn Synurang_Stream_Close(handle: c_ulonglong) {
    with_streams(|_, map| {
        map.remove(&(handle as u64));
        // Dropping StreamState drops both sender and receiver,
        // which terminates the handler thread
    });
}

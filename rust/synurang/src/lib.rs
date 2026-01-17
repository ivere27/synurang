//! Synurang Rust Runtime
//!
//! This crate provides the FFI interface for Rust backends to integrate with
//! the Synurang Flutter/Dart bridge.
//!
//! # Status: Experimental
//!
//! Rust support is experimental. Unary RPCs are fully functional with zero-copy
//! memory management. Streaming RPCs are not yet implemented.
//!
//! # Zero-Copy Memory Model
//!
//! - **Request (Dart → Rust)**: Uses `slice::from_raw_parts` to create a view of
//!   Dart's memory without copying. The slice is only valid during the invoke call.
//!
//! - **Response (Rust → Dart)**: Uses `Vec::leak()` to transfer ownership to FFI.
//!   The allocation is tracked in `ALLOC_REGISTRY` and freed when Dart calls
//!   `FreeFfiData()`.

use std::ffi::{c_char, c_void, CStr};
use std::slice;
use std::sync::Mutex;

/// FFI data structure matching C/Go definitions
#[repr(C)]
pub struct FfiData {
    pub data: *mut c_void,
    pub len: i64,
}

/// Stored allocation metadata for proper deallocation
struct AllocInfo {
    len: usize,
    cap: usize,
}

// Send is safe because we only store usize values
unsafe impl Send for AllocInfo {}

/// Thread-safe registry for tracking allocations
static ALLOC_REGISTRY: std::sync::LazyLock<Mutex<std::collections::HashMap<usize, AllocInfo>>> = 
    std::sync::LazyLock::new(|| Mutex::new(std::collections::HashMap::new()));

impl FfiData {
    pub fn from_vec(v: Vec<u8>) -> Self {
        let len = v.len() as i64;
        let cap = v.capacity();
        let v_len = v.len();
        
        let ptr = v.leak().as_mut_ptr();
        
        // Register for later deallocation
        if let Ok(mut registry) = ALLOC_REGISTRY.lock() {
            registry.insert(ptr as usize, AllocInfo { len: v_len, cap });
        }
        
        FfiData { 
            data: ptr as *mut c_void, 
            len 
        }
    }

    pub fn empty() -> Self {
        FfiData {
            data: std::ptr::null_mut(),
            len: 0,
        }
    }
}

/// Core argument structure matching C/Go definitions
#[repr(C)]
pub struct CoreArgument {
    pub storage_path: *const c_char,
    pub cache_path: *const c_char,
    pub engine_socket_path: *const c_char,
    pub engine_tcp_port: *const c_char,
    pub view_socket_path: *const c_char,
    pub view_tcp_port: *const c_char,
    pub token: *const c_char,
    pub enable_cache: i32,
    pub stream_timeout: i64,
}

/// Service trait that generated code will implement
pub trait GeneratedService: Send + Sync {
    fn invoke(&self, method: &str, data: &[u8]) -> Result<Vec<u8>, String>;
}

/// Global service registry for FFI dispatch
static SERVICE: std::sync::LazyLock<Mutex<Option<Box<dyn GeneratedService>>>> = 
    std::sync::LazyLock::new(|| Mutex::new(None));

/// Register a service implementation for FFI dispatch
pub fn register_service<S: GeneratedService + 'static>(service: S) {
    let mut guard = SERVICE.lock().unwrap();
    *guard = Some(Box::new(service));
}

/// Helper to safely convert C string to Rust str
unsafe fn c_str_to_str<'a>(ptr: *const c_char) -> &'a str {
    if ptr.is_null() {
        ""
    } else {
        CStr::from_ptr(ptr).to_str().unwrap_or("")
    }
}

// =============================================================================
// FFI Exports - Server Lifecycle
// =============================================================================

#[no_mangle]
pub extern "C" fn StartGrpcServer(_arg: CoreArgument) -> i32 {
    // Rust backend initialization (stub)
    0
}

#[no_mangle]
pub extern "C" fn StopGrpcServer() -> i32 {
    0
}

// =============================================================================
// FFI Exports - Unary Invocation (Dart → Rust) - ZERO-COPY
// =============================================================================

#[no_mangle]
pub extern "C" fn InvokeBackend(
    method: *const c_char,
    data: *const c_void,
    len: i64,
) -> FfiData {
    // Zero-copy request: create view of Dart's memory
    let method_str = unsafe { c_str_to_str(method) };
    let data_slice = if data.is_null() || len <= 0 {
        &[]
    } else {
        unsafe { slice::from_raw_parts(data as *const u8, len as usize) }
    };

    let guard = SERVICE.lock().unwrap();
    if let Some(ref service) = *guard {
        match service.invoke(method_str, data_slice) {
            // Zero-copy response: Vec is leaked, Dart will free via FreeFfiData
            Ok(result) => FfiData::from_vec(result),
            Err(_) => FfiData::empty(),
        }
    } else {
        FfiData::empty()
    }
}

#[no_mangle]
pub extern "C" fn InvokeBackendWithMeta(
    method: *const c_char,
    data: *const c_void,
    len: i64,
    _meta: *const c_void,
    _meta_len: i64,
) -> FfiData {
    // Metadata not used in Rust backend yet
    InvokeBackend(method, data, len)
}

// =============================================================================
// FFI Exports - Memory Management
// =============================================================================

#[no_mangle]
pub extern "C" fn FreeFfiData(data: *mut c_void) {
    if !data.is_null() {
        if let Ok(mut registry) = ALLOC_REGISTRY.lock() {
            if let Some(info) = registry.remove(&(data as usize)) {
                // Reconstruct and drop the Vec to properly deallocate
                unsafe {
                    let _ = Vec::from_raw_parts(data as *mut u8, info.len, info.cap);
                }
            }
        }
    }
}

// =============================================================================
// FFI Exports - Dart Callback (Rust → Dart)
// =============================================================================

#[no_mangle]
pub extern "C" fn RegisterDartCallback(_callback: *const c_void) {
    // TODO: Implement reverse FFI callback for Rust -> Dart calls
}

#[no_mangle]
pub extern "C" fn SendFfiResponse(_request_id: i64, _data: *const c_void, _len: i64) {
    // TODO: Implement response handling for async Rust -> Dart calls
}

// =============================================================================
// FFI Exports - Streaming (Stubs)
// TODO: Streaming support not yet implemented for Rust backend
// =============================================================================

#[no_mangle]
pub extern "C" fn RegisterStreamCallback(_callback: *const c_void) {
    // TODO: Implement streaming callback registration
}

#[no_mangle]
pub extern "C" fn InvokeBackendServerStream(_method: *const c_char, _data: *const c_void, _len: i64) -> i64 { 
    // TODO: Implement server streaming
    -1 
}

#[no_mangle]
pub extern "C" fn InvokeBackendClientStream(_method: *const c_char) -> i64 { 
    // TODO: Implement client streaming
    -1 
}

#[no_mangle]
pub extern "C" fn InvokeBackendBidiStream(_method: *const c_char) -> i64 { 
    // TODO: Implement bidirectional streaming
    -1 
}

#[no_mangle]
pub extern "C" fn SendStreamData(_stream_id: i64, _data: *const c_void, _len: i64) -> i32 { 
    // TODO: Implement stream data sending
    0 
}

#[no_mangle]
pub extern "C" fn CloseStream(_stream_id: i64) {
    // TODO: Implement stream close
}

#[no_mangle]
pub extern "C" fn CloseStreamInput(_stream_id: i64) {
    // TODO: Implement stream input close
}

#[no_mangle]
pub extern "C" fn StreamReady(_stream_id: i64) {
    // TODO: Implement stream ready signal
}

// =============================================================================
// FFI Exports - Cache (Stubs)
// TODO: Cache support not yet implemented for Rust backend
// =============================================================================

#[no_mangle]
pub extern "C" fn CacheGet(_store: *const c_char, _key: *const c_char) -> FfiData { 
    FfiData::empty() 
}

#[no_mangle]
pub extern "C" fn CachePut(_store: *const c_char, _key: *const c_char, _data: *const c_void, _len: i64, _ttl: i64) -> i32 { 
    0 
}

#[no_mangle]
pub extern "C" fn CacheContains(_store: *const c_char, _key: *const c_char) -> i32 { 
    0 
}

#[no_mangle]
pub extern "C" fn CacheDelete(_store: *const c_char, _key: *const c_char) -> i32 { 
    0 
}

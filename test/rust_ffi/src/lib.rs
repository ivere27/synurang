//! Mock Rust backend for FFI integration testing
//!
//! This crate provides a simple mock implementation of the Synurang FFI
//! interface for testing purposes.

use std::ffi::{c_char, c_void, CStr};

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

// Send + Sync is safe because we only store usize (address as integer)
unsafe impl Send for AllocInfo {}

/// Thread-safe registry for tracking allocations
static ALLOC_REGISTRY: std::sync::LazyLock<std::sync::Mutex<std::collections::HashMap<usize, AllocInfo>>> = 
    std::sync::LazyLock::new(|| std::sync::Mutex::new(std::collections::HashMap::new()));

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

/// Core argument structure
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

fn c_str_to_string(ptr: *const c_char) -> String {
    if ptr.is_null() {
        String::from("null")
    } else {
        unsafe { CStr::from_ptr(ptr).to_string_lossy().into_owned() }
    }
}

// =============================================================================
// FFI Exports
// =============================================================================

#[no_mangle]
pub extern "C" fn StartGrpcServer(arg: CoreArgument) -> i32 {
    let token = c_str_to_string(arg.token);
    println!("[Rust] StartGrpcServer called");
    println!("[Rust] Token: {}", token);
    0
}

#[no_mangle]
pub extern "C" fn StopGrpcServer() -> i32 {
    println!("[Rust] StopGrpcServer called");
    0
}

#[no_mangle]
pub extern "C" fn InvokeBackend(
    method: *const c_char,
    _data: *const c_void,
    len: i64,
) -> FfiData {
    let method_str = c_str_to_string(method);
    println!("[Rust] InvokeBackend called: {} (len: {})", method_str, len);

    let response = b"Hello from Rust Backend!";
    FfiData::from_vec(response.to_vec())
}

#[no_mangle]
pub extern "C" fn InvokeBackendWithMeta(
    method: *const c_char,
    data: *const c_void,
    len: i64,
    _meta: *const c_void,
    _meta_len: i64,
) -> FfiData {
    InvokeBackend(method, data, len)
}

#[no_mangle]
pub extern "C" fn FreeFfiData(data: *mut c_void) {
    if !data.is_null() {
        println!("[Rust] FreeFfiData called");
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

// Streaming stubs (not implemented in this mock)
#[no_mangle]
pub extern "C" fn InvokeBackendServerStream(_method: *const c_char, _data: *const c_void, _len: i64) -> i64 { -1 }
#[no_mangle]
pub extern "C" fn InvokeBackendClientStream(_method: *const c_char) -> i64 { -1 }
#[no_mangle]
pub extern "C" fn InvokeBackendBidiStream(_method: *const c_char) -> i64 { -1 }
#[no_mangle]
pub extern "C" fn SendStreamData(_stream_id: i64, _data: *const c_void, _len: i64) -> i32 { 0 }
#[no_mangle]
pub extern "C" fn CloseStream(_stream_id: i64) {}
#[no_mangle]
pub extern "C" fn CloseStreamInput(_stream_id: i64) {}
#[no_mangle]
pub extern "C" fn StreamReady(_stream_id: i64) {}
#[no_mangle]
pub extern "C" fn RegisterDartCallback(_callback: *const c_void) {}
#[no_mangle]
pub extern "C" fn RegisterStreamCallback(_callback: *const c_void) {}
#[no_mangle]
pub extern "C" fn SendFfiResponse(_request_id: i64, _data: *const c_void, _len: i64) {}

// Cache stubs
#[no_mangle]
pub extern "C" fn CacheGet(_store: *const c_char, _key: *const c_char) -> FfiData { FfiData::empty() }
#[no_mangle]
pub extern "C" fn CachePut(_store: *const c_char, _key: *const c_char, _data: *const c_void, _len: i64, _ttl: i64) -> i32 { 0 }
#[no_mangle]
pub extern "C" fn CacheContains(_store: *const c_char, _key: *const c_char) -> i32 { 0 }
#[no_mangle]
pub extern "C" fn CacheDelete(_store: *const c_char, _key: *const c_char) -> i32 { 0 }

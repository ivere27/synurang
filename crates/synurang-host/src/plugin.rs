//! Plugin loader for Synurang plugins
//!
//! Supports loading Go/C++/Rust plugins that export Synurang FFI symbols.

use crate::{Error, FfiError, Result};
use std::collections::HashMap;
use std::ffi::{CStr, CString};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::Mutex;

/// Plugin host for loading and calling Synurang plugins
pub struct PluginHost {
    #[cfg(unix)]
    handle: *mut libc::c_void,
    #[cfg(windows)]
    handle: windows::Win32::Foundation::HMODULE,

    free_ptr: FreeFunc,
    invokers: Mutex<HashMap<String, InvokeFunc>>,
    stream_openers: Mutex<HashMap<String, StreamOpenFunc>>,
    stream_funcs: Mutex<Option<StreamFuncs>>,
    close_requested: AtomicBool,
    active_leases: AtomicUsize,
    closed: Mutex<bool>,
}

// FFI function types
type InvokeFunc = unsafe extern "C" fn(*const i8, *const u8, i32, *mut i32) -> *mut u8;
type FreeFunc = unsafe extern "C" fn(*mut u8);
type StreamOpenFunc = unsafe extern "C" fn(*const i8) -> u64;
type StreamSendFunc = unsafe extern "C" fn(u64, *const u8, i32) -> i32;
type StreamRecvFunc = unsafe extern "C" fn(u64, *mut i32, *mut i32) -> *mut u8;
type StreamCloseSendFunc = unsafe extern "C" fn(u64);
type StreamCloseFunc = unsafe extern "C" fn(u64);

struct StreamFuncs {
    send: StreamSendFunc,
    recv: StreamRecvFunc,
    close_send: StreamCloseSendFunc,
    close: StreamCloseFunc,
}

// Safety: Plugin handles can be sent between threads
unsafe impl Send for PluginHost {}
unsafe impl Sync for PluginHost {}

fn read_varint(data: &[u8], index: &mut usize) -> Option<u64> {
    let mut value = 0u64;
    let mut shift = 0u32;
    while *index < data.len() && shift < 64 {
        let b = data[*index];
        *index += 1;
        value |= ((b & 0x7f) as u64) << shift;
        if (b & 0x80) == 0 {
            return Some(value);
        }
        shift += 7;
    }
    None
}

fn skip_field(data: &[u8], index: &mut usize, wire_type: u64) {
    match wire_type {
        0 => {
            let _ = read_varint(data, index);
        }
        2 => {
            if let Some(len) = read_varint(data, index) {
                let next = index.saturating_add(len as usize);
                *index = next.min(data.len());
            } else {
                *index = data.len();
            }
        }
        _ => {
            *index = data.len();
        }
    }
}

fn decode_ffi_error_payload(payload: &[u8]) -> FfiError {
    let mut index = 0usize;
    let mut code = 0i32;
    let mut grpc_code = 0i32;
    let mut message: Option<String> = None;

    while index < payload.len() {
        let Some(tag) = read_varint(payload, &mut index) else {
            break;
        };
        if tag == 0 {
            break;
        }
        let field = tag >> 3;
        let wire = tag & 0x07;
        match field {
            1 if wire == 0 => {
                let Some(value) = read_varint(payload, &mut index) else {
                    break;
                };
                code = value as i32;
            }
            2 if wire == 2 => {
                let Some(len) = read_varint(payload, &mut index) else {
                    break;
                };
                let len = len as usize;
                if index + len > payload.len() {
                    break;
                }
                message = Some(String::from_utf8_lossy(&payload[index..index + len]).into_owned());
                index += len;
            }
            3 if wire == 0 => {
                let Some(value) = read_varint(payload, &mut index) else {
                    break;
                };
                grpc_code = value as i32;
            }
            _ => skip_field(payload, &mut index, wire),
        }
    }

    FfiError {
        message: message.unwrap_or_else(|| String::from_utf8_lossy(payload).into_owned()),
        code,
        grpc_code,
        payload: payload.to_vec(),
    }
}

impl PluginHost {
    /// Load a plugin from the given path
    #[cfg(unix)]
    pub fn load(path: &str) -> Result<Self> {
        use libc::{dlclose, dlerror, dlopen, dlsym, RTLD_LAZY};

        let c_path = CString::new(path).map_err(|_| Error::LoadError("Invalid path".into()))?;

        let handle = unsafe { dlopen(c_path.as_ptr(), RTLD_LAZY) };
        if handle.is_null() {
            let err = unsafe { CStr::from_ptr(dlerror()) };
            return Err(Error::LoadError(err.to_string_lossy().into()));
        }

        // Lookup Synurang_Free
        let free_name = CString::new("Synurang_Free").unwrap();
        let free_ptr = unsafe { dlsym(handle, free_name.as_ptr()) };
        if free_ptr.is_null() {
            unsafe { dlclose(handle) };
            return Err(Error::SymbolNotFound("Synurang_Free".into()));
        }

        Ok(Self {
            handle,
            free_ptr: unsafe { std::mem::transmute(free_ptr) },
            invokers: Mutex::new(HashMap::new()),
            stream_openers: Mutex::new(HashMap::new()),
            stream_funcs: Mutex::new(None),
            close_requested: AtomicBool::new(false),
            active_leases: AtomicUsize::new(0),
            closed: Mutex::new(false),
        })
    }

    /// Load a plugin from the given path (Windows)
    #[cfg(windows)]
    pub fn load(path: &str) -> Result<Self> {
        use std::ffi::OsStr;
        use std::os::windows::ffi::OsStrExt;
        use windows::core::PCWSTR;
        use windows::Win32::Foundation::GetLastError;
        use windows::Win32::System::LibraryLoader::{FreeLibrary, GetProcAddress, LoadLibraryW};

        // Convert path to UTF-16 with null terminator
        let wide_path: Vec<u16> = OsStr::new(path)
            .encode_wide()
            .chain(std::iter::once(0))
            .collect();

        let handle =
            unsafe { LoadLibraryW(PCWSTR::from_raw(wide_path.as_ptr())) }.map_err(|_| {
                let err = unsafe { GetLastError() };
                Error::LoadError(format!("LoadLibrary failed: {:?}", err))
            })?;

        // Lookup Synurang_Free (symbol names are ASCII, so PCSTR is fine)
        let free_name = CString::new("Synurang_Free").unwrap();
        let free_ptr = unsafe {
            GetProcAddress(
                handle,
                windows::core::PCSTR::from_raw(free_name.as_ptr() as *const u8),
            )
        };
        if free_ptr.is_none() {
            unsafe { FreeLibrary(handle) };
            return Err(Error::SymbolNotFound("Synurang_Free".into()));
        }

        Ok(Self {
            handle,
            free_ptr: unsafe { std::mem::transmute(free_ptr.unwrap()) },
            invokers: Mutex::new(HashMap::new()),
            stream_openers: Mutex::new(HashMap::new()),
            stream_funcs: Mutex::new(None),
            close_requested: AtomicBool::new(false),
            active_leases: AtomicUsize::new(0),
            closed: Mutex::new(false),
        })
    }

    /// Close the plugin
    pub fn close(&self) {
        if self.close_requested.swap(true, Ordering::SeqCst) {
            return;
        }
        self.close_if_idle();
    }

    /// Invoke a unary RPC method
    pub fn invoke(&self, service_name: &str, method: &str, data: &[u8]) -> Result<Vec<u8>> {
        self.retain_lease()?;

        let result = (|| {
            let invoke_fn = self.get_invoker(service_name)?;

            let c_method = CString::new(method)
                .map_err(|_| Error::PluginError(FfiError::new("Invalid method")))?;

            let mut resp_len: i32 = 0;
            let resp = unsafe {
                invoke_fn(
                    c_method.as_ptr(),
                    if data.is_empty() {
                        std::ptr::null()
                    } else {
                        data.as_ptr()
                    },
                    data.len() as i32,
                    &mut resp_len,
                )
            };

            if resp.is_null() {
                if resp_len == 0 {
                    return Ok(Vec::new());
                }
                return Err(Error::PluginError(FfiError::new(format!(
                    "Plugin returned null for {}",
                    method
                ))));
            }

            let copy_len = if resp_len < 0 { -resp_len } else { resp_len } as usize;
            // Copy response before freeing
            let result = unsafe { std::slice::from_raw_parts(resp, copy_len).to_vec() };
            unsafe { (self.free_ptr)(resp) };

            if resp_len < 0 {
                return Err(Error::PluginError(decode_ffi_error_payload(&result)));
            }

            Ok(result)
        })();

        self.release_lease();
        result
    }

    fn get_invoker(&self, service_name: &str) -> Result<InvokeFunc> {
        {
            let invokers = self.invokers.lock().unwrap();
            if let Some(&ptr) = invokers.get(service_name) {
                return Ok(ptr);
            }
        }

        let sym_name = format!("Synurang_Invoke_{}", service_name);
        let ptr = self.lookup_symbol(&sym_name)?;

        let mut invokers = self.invokers.lock().unwrap();
        let func: InvokeFunc = unsafe { std::mem::transmute(ptr) };
        invokers.insert(service_name.to_string(), func);
        Ok(func)
    }

    #[cfg(unix)]
    fn lookup_symbol(&self, name: &str) -> Result<*mut libc::c_void> {
        let c_name = CString::new(name).map_err(|_| Error::SymbolNotFound(name.into()))?;
        let ptr = unsafe { libc::dlsym(self.handle, c_name.as_ptr()) };
        if ptr.is_null() {
            return Err(Error::SymbolNotFound(name.into()));
        }
        Ok(ptr)
    }

    #[cfg(windows)]
    fn lookup_symbol(&self, name: &str) -> Result<*mut std::ffi::c_void> {
        use windows::core::PCSTR;
        use windows::Win32::System::LibraryLoader::GetProcAddress;

        let c_name = CString::new(name).map_err(|_| Error::SymbolNotFound(name.into()))?;
        let ptr =
            unsafe { GetProcAddress(self.handle, PCSTR::from_raw(c_name.as_ptr() as *const u8)) };
        match ptr {
            Some(p) => Ok(p as *mut std::ffi::c_void),
            None => Err(Error::SymbolNotFound(name.into())),
        }
    }

    /// Open a streaming RPC
    pub fn open_stream(&self, service_name: &str, method: &str) -> Result<PluginStream<'_>> {
        self.retain_lease()?;

        let result = (|| {
            self.ensure_stream_funcs()?;
            let open_fn = self.get_stream_opener(service_name)?;

            let c_method = CString::new(method)
                .map_err(|_| Error::StreamError(FfiError::new("Invalid method")))?;

            let handle = unsafe { open_fn(c_method.as_ptr()) };
            if handle == 0 {
                return Err(Error::StreamError(FfiError::new(format!(
                    "Failed to open stream for {}",
                    method
                ))));
            }

            Ok(PluginStream {
                plugin: self,
                handle,
                closed: false,
            })
        })();

        if result.is_err() {
            self.release_lease();
        }

        result
    }

    fn ensure_stream_funcs(&self) -> Result<()> {
        let mut funcs = self.stream_funcs.lock().unwrap();
        if funcs.is_some() {
            return Ok(());
        }

        let send = self.lookup_symbol("Synurang_Stream_Send")?;
        let recv = self.lookup_symbol("Synurang_Stream_Recv")?;
        let close_send = self.lookup_symbol("Synurang_Stream_CloseSend")?;
        let close = self.lookup_symbol("Synurang_Stream_Close")?;

        *funcs = Some(StreamFuncs {
            send: unsafe { std::mem::transmute(send) },
            recv: unsafe { std::mem::transmute(recv) },
            close_send: unsafe { std::mem::transmute(close_send) },
            close: unsafe { std::mem::transmute(close) },
        });

        Ok(())
    }

    fn get_stream_opener(&self, service_name: &str) -> Result<StreamOpenFunc> {
        {
            let openers = self.stream_openers.lock().unwrap();
            if let Some(&ptr) = openers.get(service_name) {
                return Ok(ptr);
            }
        }

        let sym_name = format!("Synurang_Stream_{}_Open", service_name);
        let ptr = self.lookup_symbol(&sym_name)?;

        let mut openers = self.stream_openers.lock().unwrap();
        let func: StreamOpenFunc = unsafe { std::mem::transmute(ptr) };
        openers.insert(service_name.to_string(), func);
        Ok(func)
    }

    fn retain_lease(&self) -> Result<()> {
        loop {
            if self.close_requested.load(Ordering::SeqCst) {
                return Err(Error::PluginClosed);
            }
            let current = self.active_leases.load(Ordering::SeqCst);
            if self
                .active_leases
                .compare_exchange(current, current + 1, Ordering::SeqCst, Ordering::SeqCst)
                .is_ok()
            {
                if self.close_requested.load(Ordering::SeqCst) {
                    self.release_lease();
                    return Err(Error::PluginClosed);
                }
                return Ok(());
            }
        }
    }

    fn release_lease(&self) {
        loop {
            let current = self.active_leases.load(Ordering::SeqCst);
            if current == 0 {
                debug_assert!(false, "release_lease called with active_leases == 0");
                self.close_if_idle();
                return;
            }
            if self
                .active_leases
                .compare_exchange(current, current - 1, Ordering::SeqCst, Ordering::SeqCst)
                .is_ok()
            {
                self.close_if_idle();
                return;
            }
        }
    }

    fn close_if_idle(&self) {
        if !self.close_requested.load(Ordering::SeqCst)
            || self.active_leases.load(Ordering::SeqCst) != 0
        {
            return;
        }

        let mut closed = self.closed.lock().unwrap();
        if *closed {
            return;
        }
        *closed = true;

        #[cfg(unix)]
        unsafe {
            libc::dlclose(self.handle);
        }

        #[cfg(windows)]
        unsafe {
            windows::Win32::System::LibraryLoader::FreeLibrary(self.handle);
        }
    }
}

impl Drop for PluginHost {
    fn drop(&mut self) {
        self.close();
    }
}

/// Stream handle for streaming RPCs
pub struct PluginStream<'a> {
    plugin: &'a PluginHost,
    handle: u64,
    closed: bool,
}

impl<'a> PluginStream<'a> {
    /// Send data to the stream
    pub fn send(&self, data: &[u8]) -> Result<()> {
        if self.closed {
            return Err(Error::PluginClosed);
        }

        let funcs = self.plugin.stream_funcs.lock().unwrap();
        let funcs = funcs
            .as_ref()
            .ok_or(Error::StreamError(FfiError::new("No stream funcs")))?;

        let result = unsafe {
            (funcs.send)(
                self.handle,
                if data.is_empty() {
                    std::ptr::null()
                } else {
                    data.as_ptr()
                },
                data.len() as i32,
            )
        };

        if result != 0 {
            return Err(Error::StreamError(FfiError::new(format!(
                "Stream send failed with code {}",
                result
            ))));
        }
        Ok(())
    }

    /// Receive data from the stream
    pub fn recv(&self) -> Result<Vec<u8>> {
        if self.closed {
            return Err(Error::PluginClosed);
        }

        let funcs = self.plugin.stream_funcs.lock().unwrap();
        let funcs = funcs
            .as_ref()
            .ok_or(Error::StreamError(FfiError::new("No stream funcs")))?;

        let mut resp_len: i32 = 0;
        let mut status: i32 = 0;
        let resp = unsafe { (funcs.recv)(self.handle, &mut resp_len, &mut status) };

        match status {
            0 => {
                if resp.is_null() {
                    if resp_len == 0 {
                        return Ok(Vec::new());
                    }
                    return Err(Error::StreamError(FfiError::new(
                        "Plugin returned null for stream recv",
                    )));
                }
                let result =
                    unsafe { std::slice::from_raw_parts(resp, resp_len as usize).to_vec() };
                unsafe { (self.plugin.free_ptr)(resp) };
                Ok(result)
            }
            1 => {
                // EOF
                if !resp.is_null() {
                    unsafe { (self.plugin.free_ptr)(resp) };
                }
                Err(Error::Eof)
            }
            s if s < 0 => {
                if !resp.is_null() && resp_len > 0 {
                    let result =
                        unsafe { std::slice::from_raw_parts(resp, resp_len as usize).to_vec() };
                    unsafe { (self.plugin.free_ptr)(resp) };
                    return Err(Error::PluginError(decode_ffi_error_payload(&result)));
                }
                if !resp.is_null() {
                    unsafe { (self.plugin.free_ptr)(resp) };
                }
                Err(Error::PluginError(FfiError::new(format!(
                    "Stream error with status {}",
                    status
                ))))
            }
            _ => {
                if !resp.is_null() {
                    unsafe { (self.plugin.free_ptr)(resp) };
                }
                Err(Error::StreamError(FfiError::new(format!(
                    "Stream error with status {}",
                    status
                ))))
            }
        }
    }

    /// Close the send side of the stream
    pub fn close_send(&self) {
        if self.closed {
            return;
        }

        if let Ok(funcs) = self.plugin.stream_funcs.lock() {
            if let Some(ref f) = *funcs {
                unsafe { (f.close_send)(self.handle) };
            }
        }
    }

    /// Close the stream completely
    pub fn close(&mut self) {
        if self.closed {
            return;
        }
        self.closed = true;

        {
            if let Ok(funcs) = self.plugin.stream_funcs.lock() {
                if let Some(ref f) = *funcs {
                    unsafe { (f.close)(self.handle) };
                }
            }
        }
        self.plugin.release_lease();
    }
}

impl<'a> Drop for PluginStream<'a> {
    fn drop(&mut self) {
        self.close();
    }
}

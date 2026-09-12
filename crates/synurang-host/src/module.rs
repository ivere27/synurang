//! Async consumers for the unified module ABI. Each instance is owned by one
//! Tokio task; a bounded command queue serializes all foreign calls. This host
//! has no dependency on the C runtime or the legacy plugin ABI.

use futures_core::Stream;
use futures_util::{stream, StreamExt};
use libloading::Library;
use std::{
    collections::{HashMap, VecDeque},
    ffi::{c_char, c_void, CString},
    mem::size_of,
    path::Path,
    ptr,
    sync::{
        atomic::{AtomicBool, AtomicI32, AtomicUsize, Ordering},
        Arc, Condvar, Mutex, Weak,
    },
    time::Duration,
};
use tokio::{
    sync::{mpsc, oneshot, watch, Notify},
    time::Instant,
};

/// The layout of `include/synurang/call.h`, for statically linked modules.
pub mod abi {
    use super::{c_char, c_void};
    #[repr(C)]
    #[derive(Clone, Copy)]
    pub struct RuntimeOptions {
        pub struct_size: usize,
        pub execution_mode: u32,
        pub worker_count: usize,
        pub inbound_queue_capacity: usize,
        pub outbound_queue_capacity: usize,
        pub wakeup: Option<unsafe extern "C" fn(*mut c_void)>,
        pub wakeup_user_data: *mut c_void,
    }
    #[repr(C)]
    #[derive(Clone, Copy)]
    pub struct CallOptions {
        pub struct_size: u32,
        pub request_stream: u32,
        pub response_stream: u32,
        pub reserved: u32,
        pub timeout_ms: u64,
    }
    #[repr(C)]
    pub struct ReadResult {
        pub kind: u32,
        pub code: i32,
        pub data: *mut u8,
        pub size: u32,
    }
    #[repr(C)]
    #[derive(Clone, Copy)]
    pub struct Api {
        pub abi_version: u32,
        pub struct_size: u32,
        pub create: Option<unsafe extern "C" fn(*const RuntimeOptions) -> *mut c_void>,
        pub destroy: Option<unsafe extern "C" fn(*mut c_void) -> i32>,
        pub open:
            Option<unsafe extern "C" fn(*mut c_void, *const c_char, *const CallOptions) -> u64>,
        pub send: Option<unsafe extern "C" fn(*mut c_void, u64, *const u8, u32) -> i32>,
        pub half_close: Option<unsafe extern "C" fn(*mut c_void, u64) -> i32>,
        pub receive: Option<unsafe extern "C" fn(*mut c_void, u64, *mut ReadResult) -> i32>,
        pub cancel: Option<unsafe extern "C" fn(*mut c_void, u64, i32) -> i32>,
        pub release: Option<unsafe extern "C" fn(*mut c_void, u64)>,
        pub poll: Option<unsafe extern "C" fn(*mut c_void, u32) -> u32>,
        pub has_work: Option<unsafe extern "C" fn(*mut c_void) -> i32>,
        pub free_buffer: Option<unsafe extern "C" fn(*mut c_void)>,
    }
}

#[derive(Debug, Clone, thiserror::Error)]
#[error("RPC {code}: {message}")]
pub struct RpcError {
    pub code: i32,
    pub message: String,
    /// Original serialized core.v1.Error, copied before the module frees it.
    pub details: Vec<u8>,
    request_closed: bool,
}
pub type RpcResult<T> = std::result::Result<T, RpcError>;

impl RpcError {
    pub fn new(code: i32, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
            details: Vec::new(),
            request_closed: false,
        }
    }
    /// The request side is closed while responses/status remain readable.
    /// This is distinct from a terminal RPC failure, despite sharing Result.
    pub fn is_request_closed(&self) -> bool {
        self.request_closed
    }
    fn request_closed() -> Self {
        let mut error = Self::new(9, "RPC request side is closed");
        error.request_closed = true;
        error
    }
    fn status(code: i32) -> Self {
        Self::new(
            code,
            match code {
                1 => "Call cancelled",
                4 => "Deadline exceeded",
                14 => "Host is closed",
                _ => "RPC failed",
            },
        )
    }
    fn terminal(code: i32, details: Vec<u8>) -> Self {
        fn varint(data: &[u8], pos: &mut usize) -> Option<u64> {
            let mut value = 0;
            for shift in (0..64).step_by(7) {
                let byte = *data.get(*pos)?;
                *pos += 1;
                if shift == 63 && byte > 1 {
                    return None;
                }
                value |= u64::from(byte & 127) << shift;
                if byte < 128 {
                    return Some(value);
                }
            }
            None
        }
        let mut error = Self::status(code);
        let mut pos = 0;
        while let Some(tag) = varint(&details, &mut pos) {
            match tag & 7 {
                0 => {
                    if varint(&details, &mut pos).is_none() {
                        break;
                    }
                }
                1 => {
                    pos = pos.saturating_add(8);
                }
                2 => {
                    let Some(size) =
                        varint(&details, &mut pos).and_then(|n| usize::try_from(n).ok())
                    else {
                        break;
                    };
                    let Some(end) = pos.checked_add(size) else {
                        break;
                    };
                    let Some(bytes) = details.get(pos..end) else {
                        break;
                    };
                    if tag == 18 {
                        error.message = String::from_utf8_lossy(bytes).into_owned();
                    }
                    pos = end;
                }
                5 => {
                    pos = pos.saturating_add(4);
                }
                _ => break,
            }
        }
        error.details = details;
        error
    }
}

#[derive(Clone, Default)]
pub struct CancellationToken(Arc<Cancellation>);
#[derive(Default)]
struct Cancellation {
    cancelled: AtomicBool,
    hosts: Mutex<Vec<Weak<Control>>>,
}
impl CancellationToken {
    pub fn new() -> Self {
        Self::default()
    }
    pub fn cancel(&self) {
        self.0.cancelled.store(true, Ordering::Release);
        for host in self
            .0
            .hosts
            .lock()
            .unwrap()
            .iter()
            .filter_map(Weak::upgrade)
        {
            host.wake.notify_one();
        }
    }
    pub fn is_cancelled(&self) -> bool {
        self.0.cancelled.load(Ordering::Acquire)
    }
}

#[derive(Clone, Default)]
pub struct ModuleCallOptions {
    pub timeout: Option<Duration>,
    pub cancellation: Option<CancellationToken>,
}

#[derive(Clone, Debug)]
pub struct ModuleMethod {
    pub path: String,
    pub request_stream: bool,
    pub response_stream: bool,
}
impl ModuleMethod {
    pub fn new(path: impl Into<String>, request_stream: bool, response_stream: bool) -> Self {
        Self {
            path: path.into(),
            request_stream,
            response_stream,
        }
    }
}

#[derive(Clone, Debug)]
pub struct ModuleOptions {
    pub capacity: usize,
    pub command_capacity: usize,
}
impl Default for ModuleOptions {
    fn default() -> Self {
        Self {
            capacity: 16,
            command_capacity: 64,
        }
    }
}

struct Control {
    closing: AtomicBool,
    wake: Notify,
    done: watch::Sender<Option<RpcResult<()>>>,
    progress: watch::Sender<()>,
    generation: Mutex<u64>,
    changed: Condvar,
}
unsafe extern "C" fn native_wakeup(data: *mut c_void) {
    let control = &*data.cast::<Control>();
    let mut generation = control.generation.lock().unwrap();
    *generation = generation.wrapping_add(1);
    control.changed.notify_all();
    control.wake.notify_one();
}
impl Control {
    fn complete(&self, result: RpcResult<()>) {
        self.done.send_if_modified(|value| {
            if value.is_some() {
                false
            } else {
                *value = Some(result);
                true
            }
        });
    }
}

struct Native {
    api: abi::Api,
    instance: *mut c_void,
    library: Option<Library>,
    control: Arc<Control>,
}
// The actor exclusively owns Native. The ABI permits foreign entry on different
// OS threads when calls are serialized; no pointers escape that executor.
unsafe impl Send for Native {}

impl Native {
    unsafe fn create(
        api: *const abi::Api,
        library: Option<Library>,
        options: &ModuleOptions,
        control: Arc<Control>,
    ) -> RpcResult<Self> {
        #[repr(C)]
        struct Header {
            version: u32,
            size: u32,
        }
        if api.is_null() {
            return Err(RpcError::new(13, "Null module API"));
        }
        let header = &*api.cast::<Header>();
        if header.version != 1 || header.size as usize != size_of::<abi::Api>() {
            return Err(RpcError::new(13, "Unsupported Synurang module ABI"));
        }
        let api = *api;
        if api.create.is_none()
            || api.destroy.is_none()
            || api.open.is_none()
            || api.send.is_none()
            || api.half_close.is_none()
            || api.receive.is_none()
            || api.cancel.is_none()
            || api.release.is_none()
            || api.poll.is_none()
            || api.has_work.is_none()
            || api.free_buffer.is_none()
        {
            return Err(RpcError::new(13, "Incomplete module API"));
        }
        let runtime = abi::RuntimeOptions {
            struct_size: size_of::<abi::RuntimeOptions>(),
            execution_mode: 1,
            worker_count: 1,
            inbound_queue_capacity: options.capacity,
            outbound_queue_capacity: options.capacity,
            wakeup: Some(native_wakeup),
            wakeup_user_data: Arc::as_ptr(&control) as *mut c_void,
        };
        let instance = api.create.unwrap()(&runtime);
        if instance.is_null() {
            return Err(RpcError::new(13, "Module could not create an instance"));
        }
        Ok(Self {
            api,
            instance,
            library,
            control,
        })
    }
    fn destroy(&mut self) -> i32 {
        let status = unsafe { self.api.destroy.unwrap()(self.instance) };
        if status == 0 {
            self.instance = ptr::null_mut();
            self.library.take();
        }
        status
    }
}

impl Drop for Native {
    fn drop(&mut self) {
        if self.instance.is_null() {
            return;
        }
        // If Tokio is shut down or the actor is cancelled, cleanup must outlive
        // that executor. The module stays loaded until destroy actually succeeds.
        struct Cleanup {
            api: abi::Api,
            instance: *mut c_void,
            library: Option<Library>,
            control: Arc<Control>,
        }
        let cleanup = Box::new(Cleanup {
            api: self.api,
            instance: std::mem::replace(&mut self.instance, ptr::null_mut()),
            library: self.library.take(),
            control: self.control.clone(),
        });
        let address = Box::into_raw(cleanup) as usize;
        // Failed thread creation intentionally retains the allocation/module:
        // unloading live foreign producer code would be unsafe.
        let spawned = std::thread::Builder::new()
            .name("synurang-cleanup".into())
            .spawn(move || {
                let cleanup = unsafe { Box::from_raw(address as *mut Cleanup) };
                loop {
                    let generation = *cleanup.control.generation.lock().unwrap();
                    let status = unsafe { cleanup.api.destroy.unwrap()(cleanup.instance) };
                    if status == 0 {
                        let Cleanup {
                            library, control, ..
                        } = *cleanup;
                        drop(library);
                        control.complete(Ok(()));
                        return;
                    }
                    if status != 3 {
                        cleanup.control.complete(Err(RpcError::new(
                            13,
                            format!("Module teardown failed ({status}); module retained"),
                        )));
                        std::mem::forget(cleanup);
                        return;
                    }
                    unsafe {
                        cleanup.api.poll.unwrap()(cleanup.instance, 64);
                    }
                    if unsafe { cleanup.api.has_work.unwrap()(cleanup.instance) != 0 } {
                        std::thread::yield_now();
                    } else {
                        let guard = cleanup.control.generation.lock().unwrap();
                        let _guard = cleanup
                            .control
                            .changed
                            .wait_while(guard, |value| *value == generation)
                            .unwrap();
                    }
                }
            });
        if spawned.is_err() {
            self.control.complete(Err(RpcError::new(
                13,
                "Could not schedule module cleanup; module retained",
            )));
        }
    }
}

struct CallState {
    control: Arc<Control>,
    id: u64,
    cancelled: AtomicI32,
    cancellation_forwarded: AtomicBool,
    released: AtomicBool,
    terminal: Mutex<Option<RpcResult<()>>>,
    replay: Mutex<VecDeque<Vec<u8>>>,
    read_leases: AtomicUsize,
    deadline: Option<Instant>,
    token: Option<CancellationToken>,
}
impl CallState {
    fn cancellation(&self) -> i32 {
        if self.terminal.lock().unwrap().is_some() {
            return 0;
        }
        let mut code = self.cancelled.load(Ordering::Acquire);
        if code == 0 {
            if self
                .token
                .as_ref()
                .is_some_and(|token| token.is_cancelled())
            {
                code = 1;
            } else if self
                .deadline
                .is_some_and(|deadline| Instant::now() >= deadline)
            {
                code = 4;
            }
            if code != 0 {
                let _ =
                    self.cancelled
                        .compare_exchange(0, code, Ordering::AcqRel, Ordering::Acquire);
                code = self.cancelled.load(Ordering::Acquire);
            }
        }
        code
    }
    fn check(&self) -> RpcResult<()> {
        let code = self.cancellation();
        if code != 0 {
            return Err(RpcError::status(code));
        }
        if let Some(result) = self.terminal.lock().unwrap().as_ref() {
            return result.clone().and(Err(RpcError::request_closed()));
        }
        if self.released.load(Ordering::Acquire) {
            return Err(RpcError::status(1));
        }
        Ok(())
    }
}

enum Operation {
    Open(ModuleMethod, ModuleCallOptions, Option<Instant>),
    Send(u64, Arc<[u8]>),
    HalfClose(u64),
    Receive(u64),
}
struct OpenLease {
    state: Arc<CallState>,
    claimed: bool,
}
impl Drop for OpenLease {
    fn drop(&mut self) {
        if !self.claimed {
            self.state.released.store(true, Ordering::Release);
            self.state.control.wake.notify_one();
        }
    }
}
struct ReadLease {
    state: Arc<CallState>,
    bytes: Option<Vec<u8>>,
}
impl ReadLease {
    fn new(state: &Arc<CallState>, bytes: Vec<u8>) -> Self {
        state.read_leases.fetch_add(1, Ordering::AcqRel);
        Self {
            state: state.clone(),
            bytes: Some(bytes),
        }
    }
}
impl Drop for ReadLease {
    fn drop(&mut self) {
        if let Some(bytes) = self.bytes.take() {
            self.state.replay.lock().unwrap().push_front(bytes);
        }
        self.state.read_leases.fetch_sub(1, Ordering::AcqRel);
        self.state.control.progress.send_replace(());
    }
}
enum Reply {
    Open(OpenLease),
    Status(i32),
    Read(Option<ReadLease>),
}
struct Command {
    operation: Operation,
    response: oneshot::Sender<RpcResult<Reply>>,
}
struct Client {
    commands: mpsc::Sender<Command>,
    control: Arc<Control>,
}
impl Client {
    async fn execute(&self, operation: Operation) -> RpcResult<Reply> {
        if self.control.closing.load(Ordering::Acquire) {
            return Err(RpcError::status(1));
        }
        let (response, result) = oneshot::channel();
        self.commands
            .send(Command {
                operation,
                response,
            })
            .await
            .map_err(|_| RpcError::status(1))?;
        result.await.map_err(|_| RpcError::status(1))?
    }
}

/// A cloneable handle to an independently owned native module instance.
#[derive(Clone)]
pub struct ModuleHost {
    client: Arc<Client>,
}

impl ModuleHost {
    pub fn load(path: impl AsRef<Path>, options: ModuleOptions) -> RpcResult<Self> {
        Self::load_symbol(path, "Synurang_GetApi", options)
    }
    pub fn load_symbol(
        path: impl AsRef<Path>,
        symbol: &str,
        options: ModuleOptions,
    ) -> RpcResult<Self> {
        Self::validate_options(&options)?;
        let symbol = CString::new(symbol).map_err(|_| RpcError::new(3, "NUL in module symbol"))?;
        let library = unsafe { Library::new(path.as_ref()) }
            .map_err(|error| RpcError::new(13, error.to_string()))?;
        let get_api = unsafe {
            library.get::<unsafe extern "C" fn() -> *const abi::Api>(symbol.as_bytes_with_nul())
        }
        .map_err(|error| RpcError::new(13, error.to_string()))?;
        let api = unsafe { get_api() };
        unsafe { Self::create(api, Some(library), options) }
    }

    /// Create an instance from a table in a statically linked module.
    ///
    /// # Safety
    /// The pointer must describe a valid `SynurangApi`. Its table, function code
    /// and supporting module state must remain available for the process lifetime
    /// (including cleanup if the Tokio runtime is dropped before close).
    pub unsafe fn from_static_api(api: *const abi::Api, options: ModuleOptions) -> RpcResult<Self> {
        Self::validate_options(&options)?;
        Self::create(api, None, options)
    }

    fn validate_options(options: &ModuleOptions) -> RpcResult<()> {
        if !(1..=65536).contains(&options.capacity)
            || !(1..=65536).contains(&options.command_capacity)
        {
            return Err(RpcError::new(3, "Invalid capacity"));
        }
        tokio::runtime::Handle::try_current()
            .map_err(|_| RpcError::new(13, "ModuleHost requires an active Tokio runtime"))?;
        Ok(())
    }
    unsafe fn create(
        api: *const abi::Api,
        library: Option<Library>,
        options: ModuleOptions,
    ) -> RpcResult<Self> {
        let (done, _) = watch::channel(None);
        let control = Arc::new(Control {
            closing: AtomicBool::new(false),
            wake: Notify::new(),
            done,
            progress: watch::channel(()).0,
            generation: Mutex::new(0),
            changed: Condvar::new(),
        });
        let native = Native::create(api, library, &options, control.clone())?;
        let (commands, receiver) = mpsc::channel(options.command_capacity);
        let client = Arc::new(Client { commands, control });
        tokio::spawn(run_actor(native, receiver));
        Ok(Self { client })
    }

    pub async fn open(
        &self,
        method: ModuleMethod,
        options: ModuleCallOptions,
    ) -> RpcResult<ModuleCall> {
        if self.client.control.closing.load(Ordering::Acquire) {
            return Err(RpcError::status(14));
        }
        if options
            .cancellation
            .as_ref()
            .is_some_and(|token| token.is_cancelled())
        {
            return Err(RpcError::status(1));
        }
        let deadline = options
            .timeout
            .map(|duration| {
                Instant::now()
                    .checked_add(duration)
                    .ok_or_else(|| RpcError::new(3, "Timeout is too large"))
            })
            .transpose()?;
        let Reply::Open(mut lease) = self
            .client
            .execute(Operation::Open(method, options, deadline))
            .await?
        else {
            unreachable!()
        };
        if self.client.control.closing.load(Ordering::Acquire) {
            return Err(RpcError::status(14));
        }
        let call = ModuleCall {
            inner: Arc::new(CallHandle {
                client: self.client.clone(),
                state: lease.state.clone(),
                send: tokio::sync::Mutex::new(()),
                receive: tokio::sync::Mutex::new(()),
            }),
        };
        lease.claimed = true;
        Ok(call)
    }

    pub async fn unary(
        &self,
        path: impl Into<String>,
        request: &[u8],
        options: ModuleCallOptions,
    ) -> RpcResult<Vec<u8>> {
        let call = self
            .open(ModuleMethod::new(path, false, false), options)
            .await?;
        let result = async {
            call.send(request).await?;
            call.half_close().await?;
            call.single().await
        }
        .await;
        call.close().await;
        result
    }
    pub async fn server_stream(
        &self,
        path: impl Into<String>,
        request: &[u8],
        options: ModuleCallOptions,
    ) -> RpcResult<ModuleCall> {
        let call = self
            .open(ModuleMethod::new(path, false, true), options)
            .await?;
        if let Err(error) = async {
            call.send(request).await?;
            call.half_close().await
        }
        .await
        {
            call.close().await;
            return Err(error);
        }
        Ok(call)
    }
    pub async fn client_stream<S>(
        &self,
        path: impl Into<String>,
        requests: S,
        options: ModuleCallOptions,
    ) -> RpcResult<Vec<u8>>
    where
        S: Stream<Item = Vec<u8>>,
    {
        let call = self
            .open(ModuleMethod::new(path, true, false), options)
            .await?;
        let sending = async {
            futures_util::pin_mut!(requests);
            while let Some(request) = requests.next().await {
                call.send(&request).await?;
            }
            call.half_close().await
        };
        let receiving = call.single();
        tokio::pin!(sending, receiving);
        let result = tokio::select! {
            result = &mut receiving => result,
            result = &mut sending => match result {
                Ok(()) => receiving.await,
                Err(error) if error.is_request_closed() => receiving.await,
                Err(error) => Err(error),
            },
        };
        call.close().await;
        result
    }
    pub async fn bidi(
        &self,
        path: impl Into<String>,
        options: ModuleCallOptions,
    ) -> RpcResult<ModuleCall> {
        self.open(ModuleMethod::new(path, true, true), options)
            .await
    }

    /// Cancels active calls and waits until foreign producer cleanup is complete.
    /// Concurrent close calls all observe the same completion result.
    pub async fn close(&self) -> RpcResult<()> {
        let mut done = self.client.control.done.subscribe();
        self.client.control.closing.store(true, Ordering::Release);
        self.client.control.wake.notify_one();
        loop {
            if let Some(result) = done.borrow().clone() {
                return result;
            }
            done.changed()
                .await
                .map_err(|_| RpcError::new(13, "Host completion channel closed"))?;
        }
    }
}

struct CallHandle {
    client: Arc<Client>,
    state: Arc<CallState>,
    send: tokio::sync::Mutex<()>,
    receive: tokio::sync::Mutex<()>,
}
impl Drop for CallHandle {
    fn drop(&mut self) {
        self.state.released.store(true, Ordering::Release);
        self.client.control.wake.notify_one();
    }
}

/// Clones share one call. Sends are ordered; one receive can run concurrently
/// with sends. Dropping the last clone cancels/releases the foreign handle.
#[derive(Clone)]
pub struct ModuleCall {
    inner: Arc<CallHandle>,
}
impl ModuleCall {
    pub async fn send(&self, bytes: &[u8]) -> RpcResult<()> {
        if bytes.len() > u32::MAX as usize {
            return Err(RpcError::new(3, "Message too large"));
        }
        let bytes: Arc<[u8]> = bytes.into();
        let _sending = self.inner.send.lock().await;
        loop {
            let mut changed = self.inner.client.control.progress.subscribe();
            self.inner.state.check()?;
            let Reply::Status(status) = self
                .inner
                .client
                .execute(Operation::Send(self.inner.state.id, bytes.clone()))
                .await?
            else {
                unreachable!()
            };
            if status == 0 {
                return Ok(());
            }
            if status != -4 {
                return Err(RpcError::request_closed());
            }
            let _ = changed.changed().await;
        }
    }
    pub async fn half_close(&self) -> RpcResult<()> {
        let _sending = self.inner.send.lock().await;
        self.inner.state.check()?;
        let Reply::Status(status) = self
            .inner
            .client
            .execute(Operation::HalfClose(self.inner.state.id))
            .await?
        else {
            unreachable!()
        };
        if status == 0 {
            Ok(())
        } else {
            Err(RpcError::request_closed())
        }
    }
    pub async fn recv(&self) -> RpcResult<Option<Vec<u8>>> {
        let _receiving = self
            .inner
            .receive
            .try_lock()
            .map_err(|_| RpcError::new(9, "Only one receive may be pending per call"))?;
        loop {
            let mut changed = self.inner.client.control.progress.subscribe();
            if let Some(result) = self.inner.state.terminal.lock().unwrap().clone() {
                return result.map(|_| None);
            }
            self.inner.state.check()?;
            match self
                .inner
                .client
                .execute(Operation::Receive(self.inner.state.id))
                .await?
            {
                Reply::Read(bytes) => return Ok(bytes.and_then(|mut lease| lease.bytes.take())),
                Reply::Status(3) => {
                    let _ = changed.changed().await;
                }
                _ => unreachable!(),
            }
        }
    }
    async fn single(&self) -> RpcResult<Vec<u8>> {
        let response = self
            .recv()
            .await?
            .ok_or_else(|| RpcError::new(13, "RPC completed without a response"))?;
        if self.recv().await?.is_some() {
            return Err(RpcError::new(13, "RPC produced multiple responses"));
        }
        Ok(response)
    }
    /// A stream owns this call clone. Drop/cancellation releases the call when
    /// no other clones remain. Terminal errors are emitted once by the stream.
    pub fn responses(self) -> impl Stream<Item = RpcResult<Vec<u8>>> {
        stream::try_unfold(self, |call| async move {
            match call.recv().await {
                Ok(Some(bytes)) => Ok(Some((bytes, call))),
                Ok(None) => {
                    call.close().await;
                    Ok(None)
                }
                Err(error) => {
                    call.close().await;
                    Err(error)
                }
            }
        })
    }
    pub fn cancel(&self) {
        self.cancel_with_code(1);
    }
    pub fn cancel_with_code(&self, code: i32) {
        if !(1..=16).contains(&code) {
            return;
        }
        if self.inner.state.terminal.lock().unwrap().is_some() {
            return;
        }
        let _ = self.inner.state.cancelled.compare_exchange(
            0,
            code,
            Ordering::AcqRel,
            Ordering::Acquire,
        );
        self.inner.client.control.wake.notify_one();
    }
    /// Release is scheduled on the serialized executor; host.close waits for
    /// the module's final cleanup. This method is idempotent across clones.
    pub async fn close(&self) {
        self.cancel();
        self.inner.state.released.store(true, Ordering::Release);
        self.inner.client.control.wake.notify_one();
    }
}

fn execute(
    native: &Native,
    calls: &mut HashMap<u64, Arc<CallState>>,
    operation: Operation,
) -> RpcResult<Reply> {
    if let Operation::Open(method, options, deadline) = operation {
        let path = CString::new(method.path).map_err(|_| RpcError::new(3, "NUL in method path"))?;
        let timeout_ms = deadline
            .map(|deadline| {
                let duration = deadline.saturating_duration_since(Instant::now());
                // Round a positive sub-millisecond remainder up; zero specifically
                // means an expired call in the module ABI.
                let millis = duration.as_nanos().div_ceil(1_000_000);
                u64::try_from(millis)
                    .ok()
                    .filter(|&value| value != u64::MAX)
                    .ok_or_else(|| RpcError::new(3, "Timeout is too large"))
            })
            .transpose()?
            .unwrap_or(u64::MAX);
        let abi_options = abi::CallOptions {
            struct_size: size_of::<abi::CallOptions>() as u32,
            request_stream: u32::from(method.request_stream),
            response_stream: u32::from(method.response_stream),
            reserved: 0,
            timeout_ms,
        };
        let id = unsafe { native.api.open.unwrap()(native.instance, path.as_ptr(), &abi_options) };
        if id == 0 {
            return Err(RpcError::new(13, "Module rejected call creation"));
        }
        let state = Arc::new(CallState {
            control: native.control.clone(),
            id,
            cancelled: AtomicI32::new(0),
            cancellation_forwarded: AtomicBool::new(false),
            released: AtomicBool::new(false),
            terminal: Mutex::new(None),
            replay: Mutex::new(VecDeque::new()),
            read_leases: AtomicUsize::new(0),
            deadline,
            token: options.cancellation,
        });
        if let Some(token) = &state.token {
            let mut hosts = token.0.hosts.lock().unwrap();
            hosts.retain(|host| host.strong_count() != 0);
            if !hosts
                .iter()
                .any(|host| host.ptr_eq(&Arc::downgrade(&native.control)))
            {
                hosts.push(Arc::downgrade(&native.control));
            }
            if token.is_cancelled() {
                native.control.wake.notify_one();
            }
        }
        calls.insert(id, state.clone());
        return Ok(Reply::Open(OpenLease {
            state,
            claimed: false,
        }));
    }
    let id = match operation {
        Operation::Send(id, _) | Operation::HalfClose(id) | Operation::Receive(id) => id,
        Operation::Open(..) => unreachable!(),
    };
    let state = calls.get(&id).ok_or_else(|| RpcError::status(1))?;
    if matches!(operation, Operation::Receive(_)) {
        if let Some(result) = state.terminal.lock().unwrap().clone() {
            return result.map(|_| Reply::Read(None));
        }
    }
    state.check()?;
    unsafe {
        match operation {
            Operation::Send(id, bytes) => {
                let status = native.api.send.unwrap()(
                    native.instance,
                    id,
                    bytes.as_ptr(),
                    bytes.len() as u32,
                );
                if status == 0 || status == -4 {
                    Ok(Reply::Status(status))
                } else {
                    Err(write_error(native, state))
                }
            }
            Operation::HalfClose(id) => {
                let status = native.api.half_close.unwrap()(native.instance, id);
                if status == 0 {
                    Ok(Reply::Status(status))
                } else {
                    Err(write_error(native, state))
                }
            }
            Operation::Receive(_) => receive_once(native, state),
            Operation::Open(..) => unreachable!(),
        }
    }
}

fn write_error(native: &Native, state: &Arc<CallState>) -> RpcError {
    // Peek at most once and retain any message. In-flight receive leases also
    // count as retained output: peeking past one could expose terminal status
    // before a cancelled receive has returned that message to the replay queue.
    if state.replay.lock().unwrap().is_empty()
        && state.read_leases.load(Ordering::Acquire) == 0
        && state.terminal.lock().unwrap().is_none()
    {
        if let Err(error) = receive_once(native, state) {
            return error;
        }
        // Dropping a ReadLease here returns its bytes to the replay queue.
    }
    if let Some(Err(error)) = state.terminal.lock().unwrap().as_ref() {
        return error.clone();
    }
    RpcError::request_closed()
}

fn receive_once(native: &Native, state: &Arc<CallState>) -> RpcResult<Reply> {
    unsafe {
        if let Some(bytes) = state.replay.lock().unwrap().pop_front() {
            return Ok(Reply::Read(Some(ReadLease::new(state, bytes))));
        }
        let mut result = abi::ReadResult {
            kind: 0,
            code: 0,
            data: ptr::null_mut(),
            size: 0,
        };
        let status = native.api.receive.unwrap()(native.instance, state.id, &mut result);
        let bytes = if result.size == 0 {
            Ok(Vec::new())
        } else if result.data.is_null() {
            Err(RpcError::new(13, "Module returned null message bytes"))
        } else {
            Ok(std::slice::from_raw_parts(result.data, result.size as usize).to_vec())
        };
        if !result.data.is_null() {
            native.api.free_buffer.unwrap()(result.data.cast());
        }
        if status != 0 {
            return Err(RpcError::new(
                13,
                format!("Module receive failed ({status})"),
            ));
        }
        let bytes = bytes?;
        match result.kind {
            0 => Ok(Reply::Status(3)),
            1 => Ok(Reply::Read(Some(ReadLease::new(state, bytes)))),
            2 => {
                let terminal = if result.code == 0 {
                    Ok(())
                } else {
                    Err(RpcError::terminal(result.code, bytes))
                };
                *state.terminal.lock().unwrap() = Some(terminal.clone());
                terminal.map(|_| Reply::Read(None))
            }
            kind => Err(RpcError::new(
                13,
                format!("Invalid module read kind {kind}"),
            )),
        }
    }
}

async fn run_actor(mut native: Native, mut commands: mpsc::Receiver<Command>) {
    let control = native.control.clone();
    let mut calls: HashMap<u64, Arc<CallState>> = HashMap::new();
    loop {
        if control.closing.load(Ordering::Acquire) {
            break;
        }
        let deadline = calls
            .values()
            .filter(|state| {
                state.cancelled.load(Ordering::Acquire) == 0
                    && state.terminal.lock().unwrap().is_none()
            })
            .filter_map(|state| state.deadline)
            .min();
        let ready = unsafe { native.api.has_work.unwrap()(native.instance) != 0 };
        let mut progressed = true;
        tokio::select! {
            command = commands.recv() => {
                let Some(command) = command else { break; };
                if command.response.is_closed() { continue; }
                let result = execute(&native, &mut calls, command.operation);
                // Reply leases release abandoned opens and replay messages if
                // the waiting future is cancelled before accepting its result.
                let _ = command.response.send(result);
                progressed = false;
            }
            _ = tokio::task::yield_now(), if ready => {
                unsafe { native.api.poll.unwrap()(native.instance, 64); }
            }
            _ = control.wake.notified() => {
                unsafe { native.api.poll.unwrap()(native.instance, 64); }
            },
            _ = async { match deadline {
                Some(deadline) => tokio::time::sleep_until(deadline).await,
                None => std::future::pending::<()>().await,
            }} => {},
        }
        calls.retain(|&id, state| {
            let cancelled = state.cancellation();
            if cancelled != 0 && !state.cancellation_forwarded.swap(true, Ordering::AcqRel) {
                unsafe {
                    native.api.cancel.unwrap()(native.instance, id, cancelled);
                }
            }
            if state.released.load(Ordering::Acquire) {
                unsafe {
                    native.api.release.unwrap()(native.instance, id);
                }
                false
            } else {
                true
            }
        });
        if progressed {
            control.progress.send_replace(());
            tokio::task::yield_now().await;
        }
    }
    control.closing.store(true, Ordering::Release);
    commands.close();
    while let Ok(command) = commands.try_recv() {
        let _ = command.response.send(Err(RpcError::status(1)));
    }
    for (&id, state) in &calls {
        if state.terminal.lock().unwrap().is_none() {
            let _ = state
                .cancelled
                .compare_exchange(0, 1, Ordering::AcqRel, Ordering::Acquire);
            unsafe {
                native.api.cancel.unwrap()(
                    native.instance,
                    id,
                    state.cancelled.load(Ordering::Acquire),
                );
            }
        }
        state.released.store(true, Ordering::Release);
        unsafe {
            native.api.release.unwrap()(native.instance, id);
        }
    }
    calls.clear();
    control.progress.send_replace(());
    loop {
        let status = native.destroy();
        if status == 0 {
            control.complete(Ok(()));
            return;
        }
        if status != 3 {
            control.complete(Err(RpcError::new(
                13,
                format!("Module teardown failed ({status})"),
            )));
            return;
        }
        unsafe {
            native.api.poll.unwrap()(native.instance, 64);
        }
        if unsafe { native.api.has_work.unwrap()(native.instance) != 0 } {
            tokio::task::yield_now().await;
        } else {
            control.wake.notified().await;
        }
    }
}

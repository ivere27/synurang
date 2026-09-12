//! The same async service runs on native and wasm32-unknown-unknown. The host
//! polls ready futures with a bounded budget; no executor thread is required.
//! Timers/I/O can use a platform executor and wake the supplied task waker.
//! Foreign entry calls on an instance must be serialized by its host.
use prost::Message;
use std::collections::{BTreeMap, HashMap, VecDeque};
use std::future::{poll_fn, Future};
use std::pin::Pin;
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc, Mutex,
};
use std::task::{Context as TaskContext, Poll, Wake, Waker};

pub mod abi;
#[cfg(not(target_family = "wasm"))]
pub type BoxFuture<T> = Pin<Box<dyn Future<Output = T> + Send + 'static>>;
#[cfg(target_family = "wasm")]
pub type BoxFuture<T> = Pin<Box<dyn Future<Output = T> + 'static>>;
// Native hosts may serialize calls from different OS threads (Go, JVM, .NET).
// Browser futures may instead contain local JS values. Both use one executor.
#[cfg(not(target_family = "wasm"))]
pub trait Service: Send + Sync {}
#[cfg(not(target_family = "wasm"))]
impl<T: Send + Sync> Service for T {}
#[cfg(target_family = "wasm")]
pub trait Service {}
#[cfg(target_family = "wasm")]
impl<T> Service for T {}
#[cfg(not(target_family = "wasm"))]
pub trait ServiceFuture<T>: Future<Output = T> + Send {}
#[cfg(not(target_family = "wasm"))]
impl<T, F: Future<Output = T> + Send> ServiceFuture<T> for F {}
#[cfg(target_family = "wasm")]
pub trait ServiceFuture<T>: Future<Output = T> {}
#[cfg(target_family = "wasm")]
impl<T, F: Future<Output = T>> ServiceFuture<T> for F {}
pub type Result<T> = std::result::Result<T, RpcError>;

#[derive(Clone, Debug)]
pub struct RpcError {
    pub code: i32,
    pub message: String,
    pub details: Vec<u8>,
}
#[derive(Clone, PartialEq, Message)]
struct CoreError {
    #[prost(int32, tag = "1")]
    application_code: i32,
    #[prost(string, tag = "2")]
    message: String,
    #[prost(int32, tag = "3")]
    grpc_code: i32,
}
impl RpcError {
    pub fn new(code: i32, message: impl Into<String>) -> Self {
        Self::application(code, 0, message)
    }
    pub fn application(code: i32, application_code: i32, message: impl Into<String>) -> Self {
        let code = if (1..=16).contains(&code) { code } else { 2 };
        let message = message.into();
        let details = CoreError {
            application_code,
            message: message.clone(),
            grpc_code: code,
        }
        .encode_to_vec();
        Self {
            code,
            message,
            details,
        }
    }
}
impl std::fmt::Display for RpcError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        self.message.fmt(f)
    }
}
impl std::error::Error for RpcError {}

struct State {
    input: VecDeque<Vec<u8>>,
    output: VecDeque<Vec<u8>>,
    capacity_in: usize,
    capacity_out: usize,
    half_closed: bool,
    cancelled: Option<RpcError>,
    terminal: Option<Result<()>>,
    input_waker: Option<Waker>,
    output_wakers: Vec<Waker>,
    cancel_wakers: Vec<Waker>,
    timeout_ms: Option<u64>,
}
struct Shared {
    state: Mutex<State>,
    ready: AtomicBool,
    notification: Arc<Notification>,
}
#[derive(Default)]
struct Notification(Mutex<NotificationState>);
#[derive(Default)]
struct NotificationState {
    callback: Option<unsafe extern "C" fn(*mut std::ffi::c_void)>,
    user_data: usize,
    live: usize,
}
impl NotificationState {
    fn wake(&self) {
        if let Some(callback) = self.callback {
            unsafe { callback(self.user_data as *mut std::ffi::c_void) }
        }
    }
}
impl Notification {
    fn wake(&self) {
        self.0.lock().unwrap().wake();
    }
}
impl Drop for Shared {
    fn drop(&mut self) {
        let mut notification = self.notification.0.lock().unwrap();
        notification.live -= 1;
        notification.wake();
    }
}
impl Wake for Shared {
    fn wake(self: Arc<Self>) {
        self.wake_by_ref();
    }
    fn wake_by_ref(self: &Arc<Self>) {
        self.ready.store(true, Ordering::Release);
        self.notification.wake();
    }
}
impl Shared {
    fn stop(&self, error: RpcError) {
        let mut state = self.state.lock().unwrap();
        if state.cancelled.is_some() {
            return;
        }
        state.cancelled = Some(error.clone());
        state.terminal = Some(Err(error));
        state.input.clear();
        state.output.clear();
        if let Some(waker) = state.input_waker.take() {
            waker.wake();
        }
        for waker in state.output_wakers.drain(..) {
            waker.wake();
        }
        for waker in state.cancel_wakers.drain(..) {
            waker.wake();
        }
        self.notification.wake();
    }
}

#[derive(Clone)]
pub struct Context {
    shared: Arc<Shared>,
}
impl Context {
    pub fn timeout_ms(&self) -> Option<u64> {
        self.shared.state.lock().unwrap().timeout_ms
    }
    pub fn is_cancelled(&self) -> bool {
        self.shared.state.lock().unwrap().cancelled.is_some()
    }
    pub async fn cancelled(&self) -> RpcError {
        poll_fn(|cx| {
            let mut state = self.shared.state.lock().unwrap();
            if let Some(error) = &state.cancelled {
                Poll::Ready(error.clone())
            } else {
                if !state
                    .cancel_wakers
                    .iter()
                    .any(|waker| waker.will_wake(cx.waker()))
                {
                    state.cancel_wakers.push(cx.waker().clone());
                }
                Poll::Pending
            }
        })
        .await
    }
}
pub struct Receiver<T> {
    shared: Arc<Shared>,
    marker: std::marker::PhantomData<T>,
}
pub struct Sender<T> {
    shared: Arc<Shared>,
    marker: std::marker::PhantomData<T>,
}
impl<T> Receiver<T> {
    pub fn typed<U>(self) -> Receiver<U> {
        Receiver {
            shared: self.shared,
            marker: std::marker::PhantomData,
        }
    }
    pub async fn recv_bytes(&mut self) -> Result<Option<Vec<u8>>> {
        poll_fn(|cx| {
            let mut state = self.shared.state.lock().unwrap();
            if let Some(error) = &state.cancelled {
                return Poll::Ready(Err(error.clone()));
            }
            if let Some(data) = state.input.pop_front() {
                self.shared.notification.wake();
                return Poll::Ready(Ok(Some(data)));
            }
            if state.half_closed {
                return Poll::Ready(Ok(None));
            }
            state.input_waker = Some(cx.waker().clone());
            Poll::Pending
        })
        .await
    }
}
impl<T: Message + Default> Receiver<T> {
    pub async fn recv(&mut self) -> Result<Option<T>> {
        self.recv_bytes()
            .await?
            .map(|data| {
                T::decode(data.as_slice()).map_err(|_| RpcError::new(3, "Malformed request"))
            })
            .transpose()
    }
    pub async fn one(&mut self) -> Result<T> {
        self.recv()
            .await?
            .ok_or_else(|| RpcError::new(3, "RPC requires one request"))
    }
}
impl<T> Clone for Sender<T> {
    fn clone(&self) -> Self {
        Self {
            shared: self.shared.clone(),
            marker: std::marker::PhantomData,
        }
    }
}
impl<T> Sender<T> {
    pub fn typed<U>(self) -> Sender<U> {
        Sender {
            shared: self.shared,
            marker: std::marker::PhantomData,
        }
    }
    pub async fn send_bytes(&self, data: Vec<u8>) -> Result<()> {
        let mut data = Some(data);
        poll_fn(|cx| {
            let mut state = self.shared.state.lock().unwrap();
            if let Some(error) = &state.cancelled {
                return Poll::Ready(Err(error.clone()));
            }
            if state.terminal.is_some() {
                return Poll::Ready(Err(RpcError::new(1, "Call is finished")));
            }
            if state.output.len() >= state.capacity_out {
                if !state
                    .output_wakers
                    .iter()
                    .any(|waker| waker.will_wake(cx.waker()))
                {
                    state.output_wakers.push(cx.waker().clone());
                }
                return Poll::Pending;
            }
            state.output.push_back(data.take().unwrap());
            self.shared.notification.wake();
            Poll::Ready(Ok(()))
        })
        .await
    }
}
impl<T: Message> Sender<T> {
    pub async fn send(&self, response: T) -> Result<()> {
        self.send_bytes(response.encode_to_vec()).await
    }
}

#[cfg(not(target_family = "wasm"))]
type Handler =
    Box<dyn Fn(Context, Receiver<Vec<u8>>, Sender<Vec<u8>>) -> BoxFuture<Result<()>> + Send + Sync>;
#[cfg(target_family = "wasm")]
type Handler = Box<dyn Fn(Context, Receiver<Vec<u8>>, Sender<Vec<u8>>) -> BoxFuture<Result<()>>>;
struct Method {
    request_stream: bool,
    response_stream: bool,
    handler: Handler,
}
struct Call {
    shared: Arc<Shared>,
    future: Option<BoxFuture<Result<()>>>,
    request_stream: bool,
    response_stream: bool,
    sent: u64,
    received: u64,
}
impl Call {
    fn cancel(&mut self, error: RpcError) {
        self.shared.stop(error);
        // Rust async cancellation drops the future. Outstanding platform work
        // must release its Context/Sender and task wakers before module unload.
        self.future = None;
    }
}
pub struct Instance {
    methods: HashMap<String, Method>,
    calls: BTreeMap<u64, Call>,
    notification: Arc<Notification>,
    next: u64,
    capacity_in: usize,
    capacity_out: usize,
    closing: bool,
    cursor: u64,
}
impl Default for Instance {
    fn default() -> Self {
        Self::new(16, 16)
    }
}
impl Instance {
    pub fn new(capacity_in: usize, capacity_out: usize) -> Self {
        Self {
            methods: HashMap::new(),
            calls: BTreeMap::new(),
            notification: Arc::default(),
            next: 1,
            capacity_in: capacity_in.max(1),
            capacity_out: capacity_out.max(1),
            closing: false,
            cursor: 0,
        }
    }
    pub fn register<F>(
        &mut self,
        path: &str,
        request_stream: bool,
        response_stream: bool,
        handler: F,
    ) -> Result<()>
    where
        F: Fn(Context, Receiver<Vec<u8>>, Sender<Vec<u8>>) -> BoxFuture<Result<()>>
            + Service
            + 'static,
    {
        if self.next != 1
            || self.closing
            || !path.starts_with('/')
            || self.methods.contains_key(path)
        {
            return Err(RpcError::new(3, "Invalid or duplicate method registration"));
        }
        self.methods.insert(
            path.into(),
            Method {
                request_stream,
                response_stream,
                handler: Box::new(handler),
            },
        );
        Ok(())
    }
    fn open(&mut self, path: &str, shape: Option<(bool, bool)>, timeout_ms: Option<u64>) -> u64 {
        if self.closing || self.next == 0 {
            return 0;
        }
        let method = self.methods.get(path);
        let request_stream = method.is_some_and(|m| m.request_stream);
        let response_stream = method.is_some_and(|m| m.response_stream);
        self.notification.0.lock().unwrap().live += 1;
        let shared = Arc::new(Shared {
            notification: self.notification.clone(),
            ready: AtomicBool::new(true),
            state: Mutex::new(State {
                input: VecDeque::new(),
                output: VecDeque::new(),
                capacity_in: self.capacity_in,
                capacity_out: self.capacity_out,
                half_closed: false,
                cancelled: None,
                terminal: None,
                input_waker: None,
                output_wakers: Vec::new(),
                cancel_wakers: Vec::new(),
                timeout_ms,
            }),
        });
        let mut call = Call {
            shared: shared.clone(),
            future: None,
            request_stream,
            response_stream,
            sent: 0,
            received: 0,
        };
        if let Some(method) = method {
            if shape.is_some_and(|shape| shape != (request_stream, response_stream)) {
                call.cancel(RpcError::new(
                    3,
                    "RPC cardinality does not match the service",
                ));
            } else if timeout_ms == Some(0) {
                call.cancel(RpcError::new(4, "Deadline exceeded"));
            } else {
                call.future = Some((method.handler)(
                    Context {
                        shared: shared.clone(),
                    },
                    Receiver {
                        shared: shared.clone(),
                        marker: std::marker::PhantomData,
                    },
                    Sender {
                        shared,
                        marker: std::marker::PhantomData,
                    },
                ));
            }
        } else {
            call.cancel(RpcError::new(12, "Unknown RPC method"));
        }
        let id = self.next;
        self.next = self.next.wrapping_add(1);
        self.calls.insert(id, call);
        self.notification.wake();
        id
    }
    fn send(&mut self, id: u64, data: &[u8]) -> i32 {
        let Some(call) = self.calls.get_mut(&id) else {
            return -2;
        };
        let mut state = call.shared.state.lock().unwrap();
        if state.terminal.is_some() || state.half_closed {
            return -3;
        }
        if !call.request_stream && call.sent != 0 {
            drop(state);
            call.cancel(RpcError::new(3, "RPC accepts exactly one request"));
            return -3;
        }
        if state.input.len() >= state.capacity_in {
            return -4;
        }
        state.input.push_back(data.to_vec());
        call.sent += 1;
        if let Some(waker) = state.input_waker.take() {
            waker.wake();
        }
        0
    }
    fn half_close(&mut self, id: u64) -> i32 {
        let Some(call) = self.calls.get_mut(&id) else {
            return -2;
        };
        let mut state = call.shared.state.lock().unwrap();
        if state.terminal.is_some() || state.half_closed {
            return 0;
        }
        if !call.request_stream && call.sent != 1 {
            drop(state);
            call.cancel(RpcError::new(3, "RPC requires one request"));
            return -3;
        }
        state.half_closed = true;
        if let Some(waker) = state.input_waker.take() {
            waker.wake();
        }
        0
    }
    pub fn poll(&mut self, budget: u32) -> u32 {
        let budget = if budget == 0 { 64 } else { budget } as usize;
        // Round-robin across ready calls. A self-waking task cannot starve its
        // peers, and a perpetually ready task cannot monopolize a JS turn.
        let ids: Vec<_> = self
            .calls
            .range((
                std::ops::Bound::Excluded(self.cursor),
                std::ops::Bound::Unbounded,
            ))
            .chain(self.calls.range(..=self.cursor))
            .map(|(&id, _)| id)
            .collect();
        let mut count = 0;
        for id in ids {
            if count == budget {
                break;
            }
            let call = self.calls.get_mut(&id).unwrap();
            if !call.shared.ready.swap(false, Ordering::AcqRel) {
                continue;
            }
            let Some(future) = call.future.as_mut() else {
                continue;
            };
            let waker = Waker::from(call.shared.clone());
            let mut cx = TaskContext::from_waker(&waker);
            let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                future.as_mut().poll(&mut cx)
            }));
            let result = match result {
                Ok(result) => result,
                Err(_) => Poll::Ready(Err(RpcError::new(13, "Service panicked"))),
            };
            if let Poll::Ready(result) = result {
                call.future = None;
                let mut state = call.shared.state.lock().unwrap();
                state.terminal = Some(result);
                state.input.clear();
                state.input_waker = None;
                for waker in state.output_wakers.drain(..) {
                    waker.wake();
                }
                for waker in state.cancel_wakers.drain(..) {
                    waker.wake();
                }
                self.notification.wake();
            }
            self.cursor = id;
            count += 1;
        }
        count as u32
    }
    fn release(&mut self, id: u64) {
        if let Some(mut call) = self.calls.remove(&id) {
            call.cancel(RpcError::new(1, "Call released"));
        }
    }
    fn shutdown(&mut self) -> bool {
        self.closing = true;
        for id in self.calls.keys().copied().collect::<Vec<_>>() {
            self.release(id);
        }
        let mut notification = self.notification.0.lock().unwrap();
        if notification.live != 0 {
            return false;
        }
        notification.callback = None;
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    unsafe extern "C" fn unused_factory(_: *const abi::RuntimeOptions) -> *mut Instance {
        std::ptr::null_mut()
    }

    fn read(api: &abi::Api, instance: &mut Instance, id: u64) -> (u32, i32, Vec<u8>) {
        let mut result = abi::ReadResult {
            kind: 0,
            code: 0,
            data: std::ptr::null_mut(),
            size: 0,
        };
        unsafe {
            assert_eq!((api.receive)(instance, id, &mut result), 0);
            let data = if result.size == 0 {
                Vec::new()
            } else {
                std::slice::from_raw_parts(result.data, result.size as usize).to_vec()
            };
            (api.free_buffer)(result.data.cast());
            (result.kind, result.code, data)
        }
    }

    #[test]
    fn external_waker_notifies_ready_work_and_final_retirement() {
        use std::sync::mpsc;
        use std::time::Duration;

        unsafe extern "C" fn notify(data: *mut std::ffi::c_void) {
            let _ = (&*data.cast::<mpsc::Sender<()>>()).send(());
        }

        // The callback only records readiness; the host owns all ABI entries.
        let (signal, notifications) = mpsc::channel();
        let signal = Box::new(signal);
        let options = abi::RuntimeOptions {
            struct_size: std::mem::size_of::<abi::RuntimeOptions>(),
            execution_mode: 1,
            worker_count: 0,
            inbound_queue_capacity: 1,
            outbound_queue_capacity: 1,
            wakeup: Some(notify),
            wakeup_user_data: (&*signal as *const mpsc::Sender<()>).cast_mut().cast(),
        };
        let api = abi::Api::new(unused_factory);
        let instance = unsafe { &mut *abi::create(&options, Instance::default) };
        let ready = Arc::new(AtomicBool::new(false));
        let parked = Arc::new(Mutex::new(None::<Waker>));
        let handler_ready = ready.clone();
        let handler_parked = parked.clone();
        instance
            .register("/test/External", false, false, move |_, _, responses| {
                let ready = handler_ready.clone();
                let parked = handler_parked.clone();
                Box::pin(async move {
                    poll_fn(|cx| {
                        if ready.load(Ordering::Acquire) {
                            Poll::Ready(())
                        } else {
                            *parked.lock().unwrap() = Some(cx.waker().clone());
                            Poll::Pending
                        }
                    })
                    .await;
                    responses.send_bytes(vec![7]).await
                })
            })
            .unwrap();
        let id = instance.open("/test/External", Some((false, false)), None);
        assert_eq!(instance.send(id, &[]), 0);
        assert_eq!(instance.half_close(id), 0);
        assert_eq!(instance.poll(64), 1);
        notifications.try_iter().for_each(drop);
        assert_eq!(instance.poll(64), 0);
        assert!(
            notifications.try_recv().is_err(),
            "idle poll notified itself"
        );
        unsafe { assert_eq!((api.has_work)(instance), 0) };

        let waker = parked.lock().unwrap().take().unwrap();
        let producer = std::thread::spawn(move || {
            ready.store(true, Ordering::Release);
            waker.wake_by_ref();
            waker
        });
        notifications.recv_timeout(Duration::from_secs(1)).unwrap();
        unsafe { assert_eq!((api.has_work)(instance), 1) };
        assert_eq!(instance.poll(64), 1);
        assert_eq!(read(&api, instance, id), (1, 0, vec![7]));
        assert_eq!(read(&api, instance, id), (2, 0, vec![]));

        // Retained platform wakers keep destroy pending after call release.
        let waker = producer.join().unwrap();
        instance.release(id);
        unsafe { assert_eq!((api.destroy)(instance), 3) };
        notifications.try_iter().for_each(drop);
        std::thread::spawn(move || drop(waker)).join().unwrap();
        notifications.recv_timeout(Duration::from_secs(1)).unwrap();
        // The final external release wakes destroy without another poll.
        unsafe { assert_eq!((api.destroy)(instance), 0) };
        assert!(notifications.try_recv().is_err());
    }

    #[test]
    fn completed_unary_is_immutable_after_send_half_close_and_cancel() {
        let api = abi::Api::new(unused_factory);
        let mut instance = Instance::default();
        instance
            .register("/test/Unary", false, false, |_, mut requests, responses| {
                Box::pin(async move {
                    let data = requests.recv_bytes().await?.unwrap();
                    responses.send_bytes(data).await
                })
            })
            .unwrap();
        let id = instance.open("/test/Unary", Some((false, false)), None);
        assert_eq!(instance.send(id, &[1, 2, 3]), 0);
        assert_eq!(instance.half_close(id), 0);
        assert_eq!(instance.poll(1), 1);

        // Cancellation after provider completion must preserve queued output,
        // even before the consumer observes the terminal status.
        unsafe { assert_eq!((api.cancel)(&mut instance, id, 1), 0) };
        assert_eq!(read(&api, &mut instance, id), (1, 0, vec![1, 2, 3]));
        assert_eq!(read(&api, &mut instance, id), (2, 0, vec![]));
        assert_eq!(instance.send(id, &[]), -3);
        assert_eq!(read(&api, &mut instance, id), (2, 0, vec![]));
        assert_eq!(instance.half_close(id), 0);
        unsafe { assert_eq!((api.cancel)(&mut instance, id, 4), 0) };
        assert_eq!(read(&api, &mut instance, id), (2, 0, vec![]));
        instance.release(id);
        assert!(instance.shutdown());
    }

    #[test]
    fn early_provider_error_is_immutable_when_requests_arrive_late() {
        let api = abi::Api::new(unused_factory);
        let mut instance = Instance::default();
        instance
            .register("/test/Fail", false, false, |_, _, _| {
                Box::pin(async { Err(RpcError::application(7, 42, "Denied")) })
            })
            .unwrap();
        let id = instance.open("/test/Fail", Some((false, false)), None);
        assert_eq!(instance.poll(1), 1);
        let terminal = read(&api, &mut instance, id);
        assert_eq!((terminal.0, terminal.1), (2, 7));
        // No request was sent; the missing-request check must not replace an
        // error which the provider has already committed.
        assert_eq!(instance.half_close(id), 0);
        assert_eq!(instance.send(id, &[]), -3);
        unsafe { assert_eq!((api.cancel)(&mut instance, id, 1), 0) };
        assert_eq!(read(&api, &mut instance, id), terminal);
        instance.release(id);
        assert!(instance.shutdown());
    }

    #[test]
    fn invalid_public_error_codes_become_unknown_at_the_abi_boundary() {
        let api = abi::Api::new(unused_factory);
        for invalid in [0, -1, 17, i32::MAX] {
            let mut instance = Instance::default();
            instance
                .register("/test/InvalidError", false, false, move |_, _, _| {
                    Box::pin(async move {
                        let mut error = RpcError::new(2, "Invalid service status");
                        error.code = invalid;
                        Err(error)
                    })
                })
                .unwrap();
            let id = instance.open("/test/InvalidError", Some((false, false)), None);
            assert_eq!(instance.poll(1), 1);
            let terminal = read(&api, &mut instance, id);
            assert_eq!((terminal.0, terminal.1), (2, 2));
            assert!(!terminal.2.is_empty());
            instance.release(id);
            assert!(instance.shutdown());
        }
    }
}

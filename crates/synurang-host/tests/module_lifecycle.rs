#![cfg(feature = "module")]

use std::{
    collections::{HashMap, VecDeque},
    ffi::{c_char, c_void, CStr},
    mem::size_of,
    sync::atomic::{AtomicUsize, Ordering},
    time::Duration,
};
use synurang_host::{module::abi, ModuleHost, ModuleMethod, ModuleOptions};

static ACTIVE: AtomicUsize = AtomicUsize::new(0);
static DESTROYED: AtomicUsize = AtomicUsize::new(0);
static BUFFERS: AtomicUsize = AtomicUsize::new(0);
static RELEASE_WORK: AtomicUsize = AtomicUsize::new(0);

struct Call {
    output: VecDeque<u8>,
    half_closed: bool,
    terminal_code: i32,
}
struct Instance {
    calls: HashMap<u64, Call>,
    next: u64,
    closing: bool,
    cleanup_polls: usize,
    release_polls: usize,
    wakeup: abi::RuntimeOptions,
}
impl Instance {
    fn wake(&self) {
        unsafe { self.wakeup.wakeup.unwrap()(self.wakeup.wakeup_user_data) }
    }
}
#[repr(C)]
struct Allocation {
    byte: u8,
}

unsafe extern "C" fn create(options: *const abi::RuntimeOptions) -> *mut c_void {
    Box::into_raw(Box::new(Instance {
        calls: HashMap::new(),
        next: 1,
        closing: false,
        cleanup_polls: 4,
        release_polls: 0,
        wakeup: *options,
    }))
    .cast()
}
unsafe extern "C" fn open(
    instance: *mut c_void,
    path: *const c_char,
    _: *const abi::CallOptions,
) -> u64 {
    let instance = &mut *instance.cast::<Instance>();
    let id = instance.next;
    instance.next += 1;
    instance.calls.insert(
        id,
        Call {
            output: VecDeque::new(),
            half_closed: false,
            terminal_code: if CStr::from_ptr(path).to_bytes().ends_with(b"Missing") {
                12
            } else {
                0
            },
        },
    );
    ACTIVE.fetch_add(1, Ordering::SeqCst);
    instance.wake();
    id
}
unsafe extern "C" fn send(instance: *mut c_void, id: u64, bytes: *const u8, size: u32) -> i32 {
    let call = (&mut *instance.cast::<Instance>())
        .calls
        .get_mut(&id)
        .unwrap();
    if call.half_closed || call.terminal_code != 0 {
        return -3;
    }
    if !call.output.is_empty() {
        return -4;
    }
    if size != 1 {
        return -8;
    }
    if *bytes == 254 {
        call.output.push_back(42);
        call.half_closed = true;
    } else {
        call.output.push_back(*bytes);
    }
    (&*instance.cast::<Instance>()).wake();
    0
}
unsafe extern "C" fn half_close(instance: *mut c_void, id: u64) -> i32 {
    let call = (&mut *instance.cast::<Instance>())
        .calls
        .get_mut(&id)
        .unwrap();
    if call.half_closed || call.terminal_code != 0 {
        return -3;
    }
    call.half_closed = true;
    (&*instance.cast::<Instance>()).wake();
    0
}
unsafe extern "C" fn receive(instance: *mut c_void, id: u64, result: *mut abi::ReadResult) -> i32 {
    let call = (&mut *instance.cast::<Instance>())
        .calls
        .get_mut(&id)
        .unwrap();
    if let Some(byte) = call.output.pop_front() {
        BUFFERS.fetch_add(1, Ordering::SeqCst);
        (*result).kind = 1;
        (*result).size = 1;
        (*result).data = Box::into_raw(Box::new(Allocation { byte })).cast();
        (&*instance.cast::<Instance>()).wake();
    } else {
        (*result).kind = if call.half_closed || call.terminal_code != 0 {
            2
        } else {
            0
        };
        (*result).code = call.terminal_code;
    }
    0
}
unsafe extern "C" fn cancel(instance: *mut c_void, id: u64, _: i32) -> i32 {
    if let Some(call) = (&mut *instance.cast::<Instance>()).calls.get_mut(&id) {
        call.half_closed = true;
        call.output.clear();
    }
    (&*instance.cast::<Instance>()).wake();
    0
}
unsafe extern "C" fn release(instance: *mut c_void, id: u64) {
    let instance = &mut *instance.cast::<Instance>();
    if instance.calls.remove(&id).is_some() {
        ACTIVE.fetch_sub(1, Ordering::SeqCst);
        // Model producer cleanup requiring more than one bounded polling turn.
        instance.release_polls += 3;
        RELEASE_WORK.fetch_add(3, Ordering::SeqCst);
        instance.wake();
    }
}
unsafe extern "C" fn poll(instance: *mut c_void, budget: u32) -> u32 {
    assert_eq!(budget, 64);
    let instance = &mut *instance.cast::<Instance>();
    let changed = instance.release_polls != 0 || (instance.closing && instance.cleanup_polls != 0);
    if instance.release_polls != 0 {
        instance.release_polls -= 1;
        RELEASE_WORK.fetch_sub(1, Ordering::SeqCst);
    }
    if instance.closing {
        instance.cleanup_polls = instance.cleanup_polls.saturating_sub(1);
    }
    if changed {
        instance.wake();
    }
    0
}
unsafe extern "C" fn has_work(instance: *mut c_void) -> i32 {
    let state = &*instance.cast::<Instance>();
    i32::from(state.release_polls != 0 || (state.closing && state.cleanup_polls != 0))
}
unsafe extern "C" fn free(bytes: *mut c_void) {
    BUFFERS.fetch_sub(1, Ordering::SeqCst);
    drop(Box::from_raw(bytes.cast::<Allocation>()));
}
unsafe extern "C" fn destroy(instance: *mut c_void) -> i32 {
    let state = &mut *instance.cast::<Instance>();
    state.closing = true;
    if state.cleanup_polls != 0 || state.release_polls != 0 {
        return 3;
    }
    ACTIVE.fetch_sub(state.calls.len(), Ordering::SeqCst);
    DESTROYED.fetch_add(1, Ordering::SeqCst);
    drop(Box::from_raw(instance.cast::<Instance>()));
    0
}
static API: abi::Api = abi::Api {
    abi_version: 1,
    struct_size: size_of::<abi::Api>() as u32,
    create: Some(create),
    destroy: Some(destroy),
    open: Some(open),
    send: Some(send),
    half_close: Some(half_close),
    receive: Some(receive),
    cancel: Some(cancel),
    release: Some(release),
    poll: Some(poll),
    has_work: Some(has_work),
    free_buffer: Some(free),
};
fn runtime() -> tokio::runtime::Runtime {
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap()
}
fn host() -> ModuleHost {
    unsafe {
        ModuleHost::from_static_api(
            &API,
            ModuleOptions {
                capacity: 1,
                command_capacity: 1,
                ..Default::default()
            },
        )
        .unwrap()
    }
}

#[test]
fn cancelled_futures_and_runtime_shutdown_retain_ownership() {
    let executor = runtime();
    executor.block_on(async {
        let host = host();
        // The actor creates a handle and publishes it to an unpolled oneshot.
        // Dropping that future must return the open lease to the actor.
        let mut opening = Box::pin(host.bidi("/test.Calls/Bidi", Default::default()));
        assert!(futures_util::poll!(&mut opening).is_pending());
        tokio::task::yield_now().await;
        assert_eq!(ACTIVE.load(Ordering::SeqCst), 1);
        drop(opening);
        tokio::time::sleep(Duration::from_millis(5)).await;
        assert_eq!(ACTIVE.load(Ordering::SeqCst), 0);

        let call = host
            .bidi("/test.Calls/Bidi", Default::default())
            .await
            .unwrap();
        call.send(&[9]).await.unwrap();
        let mut receiving = Box::pin(call.recv());
        assert!(futures_util::poll!(&mut receiving).is_pending());
        tokio::task::yield_now().await;
        drop(receiving);
        assert_eq!(call.recv().await.unwrap(), Some(vec![9]));
        assert_eq!(BUFFERS.load(Ordering::SeqCst), 0);

        let missing = host
            .unary("/test.Calls/Missing", &[1], Default::default())
            .await
            .unwrap_err();
        assert_eq!(missing.code, 12);
        assert!(!missing.is_request_closed());

        let early = host
            .bidi("/test.Calls/Early", Default::default())
            .await
            .unwrap();
        early.send(&[254]).await.unwrap();
        assert!(early.send(&[9]).await.unwrap_err().is_request_closed());
        assert_eq!(early.recv().await.unwrap(), Some(vec![42]));
        assert_eq!(early.recv().await.unwrap(), None);
        early.close().await;

        let rejected_half = host
            .bidi("/test.Calls/Early", Default::default())
            .await
            .unwrap();
        rejected_half.send(&[254]).await.unwrap();
        assert!(rejected_half
            .half_close()
            .await
            .unwrap_err()
            .is_request_closed());
        assert_eq!(rejected_half.recv().await.unwrap(), Some(vec![42]));
        assert_eq!(rejected_half.recv().await.unwrap(), None);
        rejected_half.close().await;

        // A write failure must not peek past a message already delivered to an
        // unpolled receive future. Cancelling that future must still replay it.
        let leased = host
            .bidi("/test.Calls/Early", Default::default())
            .await
            .unwrap();
        leased.send(&[254]).await.unwrap();
        let mut receiving = Box::pin(leased.recv());
        assert!(futures_util::poll!(&mut receiving).is_pending());
        tokio::task::yield_now().await;
        assert!(leased.send(&[9]).await.unwrap_err().is_request_closed());
        drop(receiving);
        assert_eq!(leased.recv().await.unwrap(), Some(vec![42]));
        assert_eq!(leased.recv().await.unwrap(), None);
        leased.close().await;

        // The first request completes the response while the sender still has
        // input. A closed request side must not discard or override success.
        let requests =
            futures_util::stream::iter(std::iter::once(vec![254]).chain((0..100).map(|_| vec![1])));
        assert_eq!(
            host.client_stream("/test.Calls/Early", requests, Default::default())
                .await
                .unwrap(),
            vec![42]
        );
        use futures_util::StreamExt;
        let stalled =
            futures_util::stream::once(async { vec![254] }).chain(futures_util::stream::pending());
        assert_eq!(
            tokio::time::timeout(
                Duration::from_secs(1),
                host.client_stream("/test.Calls/Early", stalled, Default::default())
            )
            .await
            .unwrap()
            .unwrap(),
            vec![42]
        );

        let half_closed = host
            .bidi("/test.Calls/HalfClosed", Default::default())
            .await
            .unwrap();
        half_closed.send(&[8]).await.unwrap();
        half_closed.half_close().await.unwrap();
        assert!(half_closed
            .send(&[9])
            .await
            .unwrap_err()
            .is_request_closed());
        assert_eq!(half_closed.recv().await.unwrap(), Some(vec![8]));
        assert_eq!(half_closed.recv().await.unwrap(), None);
        half_closed.close().await;

        // Capacity one rejects the second send until receive frees space. Send
        // and receive are independent operations on the same call.
        call.send(&[1]).await.unwrap();
        let sender = call.clone();
        let send = tokio::spawn(async move { sender.send(&[2]).await });
        tokio::time::sleep(Duration::from_millis(5)).await;
        assert!(!send.is_finished());
        assert_eq!(call.recv().await.unwrap(), Some(vec![1]));
        send.await.unwrap().unwrap();
        assert_eq!(call.recv().await.unwrap(), Some(vec![2]));

        let mut waiting = Box::pin(call.recv());
        assert!(futures_util::poll!(&mut waiting).is_pending());
        assert_eq!(call.recv().await.unwrap_err().code, 9);
        drop(waiting);
        call.close().await;
        tokio::time::timeout(Duration::from_secs(2), async {
            while ACTIVE.load(Ordering::SeqCst) != 0 || RELEASE_WORK.load(Ordering::SeqCst) != 0 {
                tokio::time::sleep(Duration::from_millis(1)).await;
            }
        })
        .await
        .expect("release cleanup stopped before the host was closed");
        let before = DESTROYED.load(Ordering::SeqCst);
        host.close().await.unwrap();
        assert_eq!(DESTROYED.load(Ordering::SeqCst), before + 1);
        assert_eq!(ACTIVE.load(Ordering::SeqCst), 0);
        assert_eq!(BUFFERS.load(Ordering::SeqCst), 0);
    });
    drop(executor);

    // Cleanup survives the executor that originally owned the module. This
    // exercises the drop fallback, which retains foreign code until destroy=0.
    let executor = runtime();
    let (host, call) = executor.block_on(async {
        let host = host();
        let call = host
            .open(
                ModuleMethod::new("/test.Calls/Wait", true, true),
                Default::default(),
            )
            .await
            .unwrap();
        (host, call)
    });
    let before = DESTROYED.load(Ordering::SeqCst);
    drop(executor);
    runtime().block_on(async {
        tokio::time::timeout(Duration::from_secs(2), host.close())
            .await
            .unwrap()
            .unwrap();
        call.close().await;
    });
    assert_eq!(DESTROYED.load(Ordering::SeqCst), before + 1);
    assert_eq!(ACTIVE.load(Ordering::SeqCst), 0);
}

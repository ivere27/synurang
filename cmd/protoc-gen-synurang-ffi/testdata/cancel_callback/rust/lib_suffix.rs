// =============================================================================
// Hard cancel-callback suite
//
// Drives only the public C ABI exported by the generated FFI plugin and
// touches only the public PluginStream::on_cancel surface. No private fields,
// no template-internal helpers, no #include of generated source.
// =============================================================================

use synurang_service::example::v1::*;

// NOTE: The generated lib.rs above already imports c_char/c_int/c_void/Arc/
// Mutex/OnceLock/Ordering. Re-importing them would shadow-conflict, so we
// only pull in what's missing here.
use std::ffi::CString;
use std::sync::atomic::AtomicUsize;
use std::sync::Condvar;
use std::thread::{self, ThreadId};
use std::time::{Duration, Instant};

// One-shot signal: handler thread → driver thread.
#[derive(Default)]
struct ReadyGate {
    flag: Mutex<bool>,
    cv: Condvar,
}

impl ReadyGate {
    fn signal(&self) {
        let mut g = self.flag.lock().unwrap();
        *g = true;
        self.cv.notify_all();
    }
    fn wait(&self) {
        let mut g = self.flag.lock().unwrap();
        while !*g {
            g = self.cv.wait(g).unwrap();
        }
    }
}

// Each scenario installs a closure that the bidi handler runs. The plugin is
// a singleton; scenarios run sequentially.
struct Scenario {
    handler: Box<dyn Fn(&dyn PluginStreamBidi<HelloRequest, HelloResponse>) + Send + Sync>,
}

static CURRENT: OnceLock<Mutex<Option<Arc<Scenario>>>> = OnceLock::new();

fn slot() -> &'static Mutex<Option<Arc<Scenario>>> {
    CURRENT.get_or_init(|| Mutex::new(None))
}

fn install(s: Scenario) {
    *slot().lock().unwrap() = Some(Arc::new(s));
}

fn take() -> Arc<Scenario> {
    slot()
        .lock()
        .unwrap()
        .clone()
        .expect("scenario not installed")
}

// Test plugin: only bar_bidi_stream and bar_server_stream are exercised.
struct TestPlugin;

impl GoGreeterServicePlugin for TestPlugin {
    fn bar(&self, _: HelloRequest) -> Result<HelloResponse, FfiError> {
        Err("unused".into())
    }
    fn bar_server_stream(
        &self,
        _: HelloRequest,
        _: &dyn PluginStreamSender<HelloResponse>,
    ) -> Result<(), FfiError> {
        Ok(())
    }
    fn bar_client_stream(
        &self,
        _: &dyn PluginStreamReceiver<HelloRequest>,
    ) -> Result<HelloResponse, FfiError> {
        Err("unused".into())
    }
    fn bar_bidi_stream(
        &self,
        stream: &dyn PluginStreamBidi<HelloRequest, HelloResponse>,
    ) -> Result<(), FfiError> {
        (take().handler)(stream);
        Ok(())
    }
    fn upload_file(
        &self,
        _: &dyn PluginStreamReceiver<FileChunk>,
    ) -> Result<FileStatus, FfiError> {
        Err("unused".into())
    }
    fn download_file(
        &self,
        _: DownloadFileRequest,
        _: &dyn PluginStreamSender<FileChunk>,
    ) -> Result<(), FfiError> {
        Ok(())
    }
    fn bidi_file(
        &self,
        _: &dyn PluginStreamBidi<FileChunk, FileChunk>,
    ) -> Result<(), FfiError> {
        Ok(())
    }
    fn trigger(&self, _: TriggerRequest) -> Result<HelloResponse, FfiError> {
        Err("unused".into())
    }
    fn get_goroutines(
        &self,
        _: GoroutinesRequest,
    ) -> Result<GoroutinesResponse, FfiError> {
        Err("unused".into())
    }
}

fn ensure_plugin() {
    static REGISTERED: OnceLock<()> = OnceLock::new();
    REGISTERED.get_or_init(|| {
        register_go_greeter_service_plugin(TestPlugin);
    });
}

const BIDI_METHOD: &str = "/example.v1.GoGreeterService/BarBidiStream";

fn open_bidi() -> u64 {
    let m = CString::new(BIDI_METHOD).unwrap();
    let h = Synurang_Stream_GoGreeterService_Open(m.as_ptr());
    assert!(h != 0, "Stream_Open returned 0");
    h
}

fn close_handle(h: u64) {
    Synurang_Stream_Close(h);
}

fn drain_until_eof(h: u64) {
    loop {
        let mut resp_len: c_int = 0;
        let mut status: c_int = 0;
        let p = Synurang_Stream_Recv(h, &mut resp_len, &mut status);
        if !p.is_null() {
            Synurang_Free(p as *mut c_void);
        }
        // status: 0 = data, 1 = EOF, otherwise = error/closed
        if status != 0 {
            return;
        }
    }
}

fn send_dummy(h: u64) -> c_int {
    let bytes: [u8; 0] = [];
    Synurang_Stream_Send(h, bytes.as_ptr() as *const c_char, 0)
}

// =============================================================================
// One #[test]: scenarios share the static plugin singleton, so they run in
// strict sequence. Cargo test order across multiple #[test] fns is not
// guaranteed; one entrypoint avoids that hazard entirely.
// =============================================================================

#[test]
fn cancel_callback_invariants() {
    ensure_plugin();
    s1_basic_cancel_wiring();
    s2_callbacks_fire_in_registration_order();
    s3_double_close_is_idempotent();
    s4_natural_finish_drops_callbacks();
    s5_late_registration_after_cancel_fires_inline();
    s6_register_close_race_loses_no_callbacks();
    s7_cross_stream_isolation();
    s8_send_recv_after_close_is_safe();
    s9_callback_runs_synchronously_before_close_returns();
    s10_close_blocks_until_worker_joins();
    eprintln!("[rust] cancel-callback hard suite OK");
}

// S1 ---------------------------------------------------------------------------
fn s1_basic_cancel_wiring() {
    let fired = Arc::new(AtomicUsize::new(0));
    let ready = Arc::new(ReadyGate::default());
    {
        let f = fired.clone();
        let r = ready.clone();
        install(Scenario {
            handler: Box::new(move |stream| {
                let f = f.clone();
                stream.on_cancel(Box::new(move || {
                    f.fetch_add(1, Ordering::SeqCst);
                }));
                r.signal();
                while stream.recv().is_some() {}
            }),
        });
    }
    let h = open_bidi();
    ready.wait();
    close_handle(h);
    assert_eq!(fired.load(Ordering::SeqCst), 1, "S1: callback must fire exactly once");
}

// S2 ---------------------------------------------------------------------------
fn s2_callbacks_fire_in_registration_order() {
    const N: usize = 8;
    let order = Arc::new(Mutex::new(Vec::<usize>::new()));
    let ready = Arc::new(ReadyGate::default());
    {
        let o = order.clone();
        let r = ready.clone();
        install(Scenario {
            handler: Box::new(move |stream| {
                for i in 0..N {
                    let o = o.clone();
                    stream.on_cancel(Box::new(move || {
                        o.lock().unwrap().push(i);
                    }));
                }
                r.signal();
                while stream.recv().is_some() {}
            }),
        });
    }
    let h = open_bidi();
    ready.wait();
    close_handle(h);
    let got = order.lock().unwrap().clone();
    let want: Vec<usize> = (0..N).collect();
    assert_eq!(got, want, "S2: registration-order firing");
}

// S3 ---------------------------------------------------------------------------
fn s3_double_close_is_idempotent() {
    let fired = Arc::new(AtomicUsize::new(0));
    let ready = Arc::new(ReadyGate::default());
    {
        let f = fired.clone();
        let r = ready.clone();
        install(Scenario {
            handler: Box::new(move |stream| {
                let f = f.clone();
                stream.on_cancel(Box::new(move || {
                    f.fetch_add(1, Ordering::SeqCst);
                }));
                r.signal();
                while stream.recv().is_some() {}
            }),
        });
    }
    let h = open_bidi();
    ready.wait();
    close_handle(h);
    close_handle(h); // handle removed; second call is a no-op
    assert_eq!(fired.load(Ordering::SeqCst), 1, "S3: second close must not refire");
}

// S4 ---------------------------------------------------------------------------
fn s4_natural_finish_drops_callbacks() {
    let fired = Arc::new(AtomicUsize::new(0));
    {
        let f = fired.clone();
        install(Scenario {
            handler: Box::new(move |stream| {
                let f = f.clone();
                stream.on_cancel(Box::new(move || {
                    f.fetch_add(1, Ordering::SeqCst);
                }));
                // return immediately → ctx.finish() runs (cancelled=false)
            }),
        });
    }
    let h = open_bidi();
    drain_until_eof(h);
    assert_eq!(fired.load(Ordering::SeqCst), 0, "S4: natural finish must not fire");
    close_handle(h);
    assert_eq!(fired.load(Ordering::SeqCst), 0, "S4: post-finish close must not refire");
}

// S5 ---------------------------------------------------------------------------
fn s5_late_registration_after_cancel_fires_inline() {
    let initial = Arc::new(AtomicUsize::new(0));
    let late = Arc::new(AtomicUsize::new(0));
    let late_tid = Arc::new(Mutex::new(None::<ThreadId>));
    let ready = Arc::new(ReadyGate::default());
    let driver_tid = thread::current().id();
    {
        let i = initial.clone();
        let l = late.clone();
        let lt = late_tid.clone();
        let r = ready.clone();
        install(Scenario {
            handler: Box::new(move |stream| {
                for _ in 0..3 {
                    let i = i.clone();
                    stream.on_cancel(Box::new(move || {
                        i.fetch_add(1, Ordering::SeqCst);
                    }));
                }
                r.signal();
                while stream.recv().is_some() {}
                // Now cancelled. Late registration must fire on this thread.
                let l = l.clone();
                let lt = lt.clone();
                stream.on_cancel(Box::new(move || {
                    *lt.lock().unwrap() = Some(thread::current().id());
                    l.fetch_add(1, Ordering::SeqCst);
                }));
            }),
        });
    }
    let h = open_bidi();
    ready.wait();
    close_handle(h);
    assert_eq!(initial.load(Ordering::SeqCst), 3, "S5: initial 3 fired");
    assert_eq!(late.load(Ordering::SeqCst), 1, "S5: late fired exactly once");
    let tid = late_tid.lock().unwrap().expect("S5: late callback ran");
    assert_ne!(tid, driver_tid, "S5: late callback must run on the registering (handler) thread");
}

// S6 ---------------------------------------------------------------------------
// Race: handler runs back-to-back register loops; driver fires Close at an
// indeterminate moment between them. Some registrations are queued and drained
// by Close; the rest see cancelled=true and fire inline. Total must equal 2N.
fn s6_register_close_race_loses_no_callbacks() {
    const N: usize = 256;
    let fired = Arc::new(AtomicUsize::new(0));
    let ready = Arc::new(ReadyGate::default());
    {
        let f = fired.clone();
        let r = ready.clone();
        install(Scenario {
            handler: Box::new(move |stream| {
                r.signal();
                for _ in 0..N {
                    let f = f.clone();
                    stream.on_cancel(Box::new(move || {
                        f.fetch_add(1, Ordering::SeqCst);
                    }));
                }
                while stream.recv().is_some() {}
                for _ in 0..N {
                    let f = f.clone();
                    stream.on_cancel(Box::new(move || {
                        f.fetch_add(1, Ordering::SeqCst);
                    }));
                }
            }),
        });
    }
    let h = open_bidi();
    ready.wait();
    // Tiny jitter: let the handler enter the first register loop before we close.
    thread::sleep(Duration::from_micros(50));
    close_handle(h);
    assert_eq!(
        fired.load(Ordering::SeqCst),
        2 * N,
        "S6: register-vs-close race must not lose callbacks"
    );
}

// S7 ---------------------------------------------------------------------------
fn s7_cross_stream_isolation() {
    let fired_a = Arc::new(AtomicUsize::new(0));
    let fired_b = Arc::new(AtomicUsize::new(0));
    let ready_a = Arc::new(ReadyGate::default());
    let ready_b = Arc::new(ReadyGate::default());

    let mode_a = Arc::new(AtomicUsize::new(0)); // 0 → next opener uses A
    {
        let fa = fired_a.clone();
        let fb = fired_b.clone();
        let ra = ready_a.clone();
        let rb = ready_b.clone();
        let mode = mode_a.clone();
        install(Scenario {
            handler: Box::new(move |stream| {
                let which = mode.fetch_add(1, Ordering::SeqCst);
                if which == 0 {
                    let fa = fa.clone();
                    stream.on_cancel(Box::new(move || {
                        fa.fetch_add(1, Ordering::SeqCst);
                    }));
                    ra.signal();
                } else {
                    let fb = fb.clone();
                    stream.on_cancel(Box::new(move || {
                        fb.fetch_add(1, Ordering::SeqCst);
                    }));
                    rb.signal();
                }
                while stream.recv().is_some() {}
            }),
        });
    }
    let ha = open_bidi();
    ready_a.wait();
    let hb = open_bidi();
    ready_b.wait();
    close_handle(ha);
    assert_eq!(fired_a.load(Ordering::SeqCst), 1, "S7: A fired");
    assert_eq!(fired_b.load(Ordering::SeqCst), 0, "S7: B must not fire from A's close");
    close_handle(hb);
    assert_eq!(fired_b.load(Ordering::SeqCst), 1, "S7: B fired on its own close");
}

// S8 ---------------------------------------------------------------------------
fn s8_send_recv_after_close_is_safe() {
    let ready = Arc::new(ReadyGate::default());
    {
        let r = ready.clone();
        install(Scenario {
            handler: Box::new(move |stream| {
                r.signal();
                while stream.recv().is_some() {}
            }),
        });
    }
    let h = open_bidi();
    ready.wait();
    close_handle(h);
    // After close, handle is removed; Send must report failure, Recv returns
    // a stream-not-found error (status == -1) — neither must crash.
    let send_rc = send_dummy(h);
    assert_eq!(send_rc, -1, "S8: Send after Close must return -1");
    let mut resp_len: c_int = 0;
    let mut status: c_int = 0;
    let p = Synurang_Stream_Recv(h, &mut resp_len, &mut status);
    if !p.is_null() {
        Synurang_Free(p as *mut c_void);
    }
    assert_eq!(status, -1, "S8: Recv after Close must report stream-not-found");
}

// S9 ---------------------------------------------------------------------------
fn s9_callback_runs_synchronously_before_close_returns() {
    let started = Arc::new(AtomicUsize::new(0));
    let finished = Arc::new(AtomicUsize::new(0));
    let ready = Arc::new(ReadyGate::default());
    {
        let s = started.clone();
        let f = finished.clone();
        let r = ready.clone();
        install(Scenario {
            handler: Box::new(move |stream| {
                let s = s.clone();
                let f = f.clone();
                stream.on_cancel(Box::new(move || {
                    s.fetch_add(1, Ordering::SeqCst);
                    thread::sleep(Duration::from_millis(50));
                    f.fetch_add(1, Ordering::SeqCst);
                }));
                r.signal();
                while stream.recv().is_some() {}
            }),
        });
    }
    let h = open_bidi();
    ready.wait();
    close_handle(h);
    assert_eq!(started.load(Ordering::SeqCst), 1, "S9: callback started");
    assert_eq!(finished.load(Ordering::SeqCst), 1, "S9: callback completed before Close returned");
}

// S10 --------------------------------------------------------------------------
fn s10_close_blocks_until_worker_joins() {
    let exited = Arc::new(AtomicUsize::new(0));
    let ready = Arc::new(ReadyGate::default());
    {
        let e = exited.clone();
        let r = ready.clone();
        install(Scenario {
            handler: Box::new(move |stream| {
                r.signal();
                while stream.recv().is_some() {}
                // Give the host a chance to "win" if Close is not awaiting us.
                thread::sleep(Duration::from_millis(30));
                e.fetch_add(1, Ordering::SeqCst);
            }),
        });
    }
    let h = open_bidi();
    ready.wait();
    let t0 = Instant::now();
    close_handle(h);
    let elapsed = t0.elapsed();
    assert_eq!(
        exited.load(Ordering::SeqCst),
        1,
        "S10: Close must block until handler thread observes cancel and exits"
    );
    assert!(
        elapsed >= Duration::from_millis(25),
        "S10: Close returned in {:?} — must wait for worker",
        elapsed
    );
}

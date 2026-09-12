//! C layout matching include/synurang/call.h. Opaque pointers and all returned
//! allocations remain owned by this module until their corresponding release.
use super::*;
use std::ffi::{c_char, c_void, CStr};
use std::mem::size_of;
use std::ptr;

#[repr(C)]
pub struct RuntimeOptions {
    pub struct_size: usize,
    pub execution_mode: i32,
    pub worker_count: usize,
    pub inbound_queue_capacity: usize,
    pub outbound_queue_capacity: usize,
    pub wakeup: Option<unsafe extern "C" fn(*mut c_void)>,
    pub wakeup_user_data: *mut c_void,
}
#[repr(C)]
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
pub struct Api {
    pub abi_version: u32,
    pub struct_size: u32,
    pub create: unsafe extern "C" fn(*const RuntimeOptions) -> *mut Instance,
    pub destroy: unsafe extern "C" fn(*mut Instance) -> i32,
    pub open: unsafe extern "C" fn(*mut Instance, *const c_char, *const CallOptions) -> u64,
    pub send: unsafe extern "C" fn(*mut Instance, u64, *const u8, u32) -> i32,
    pub half_close: unsafe extern "C" fn(*mut Instance, u64) -> i32,
    pub receive: unsafe extern "C" fn(*mut Instance, u64, *mut ReadResult) -> i32,
    pub cancel: unsafe extern "C" fn(*mut Instance, u64, i32) -> i32,
    pub release: unsafe extern "C" fn(*mut Instance, u64),
    pub poll: unsafe extern "C" fn(*mut Instance, u32) -> u32,
    pub has_work: unsafe extern "C" fn(*mut Instance) -> i32,
    pub free_buffer: unsafe extern "C" fn(*mut c_void),
}
impl Api {
    pub const fn new(create: unsafe extern "C" fn(*const RuntimeOptions) -> *mut Instance) -> Self {
        Self {
            abi_version: 1,
            struct_size: size_of::<Self>() as u32,
            create,
            destroy,
            open,
            send,
            half_close,
            receive,
            cancel,
            release,
            poll,
            has_work,
            free_buffer,
        }
    }
}
/// The factory registers services; host configuration then sets queue bounds.
/// # Safety
/// `options`, when non-null, points to a valid RuntimeOptions for this call.
pub unsafe fn create(options: *const RuntimeOptions, factory: fn() -> Instance) -> *mut Instance {
    if !options.is_null()
        && ((*options).struct_size != size_of::<RuntimeOptions>() || (*options).execution_mode != 1)
    {
        return ptr::null_mut();
    }
    let Ok(mut instance) = std::panic::catch_unwind(factory) else {
        return ptr::null_mut();
    };
    if let Some(options) = options.as_ref() {
        instance.capacity_in = options.inbound_queue_capacity.max(1);
        instance.capacity_out = options.outbound_queue_capacity.max(1);
        let mut notification = instance.notification.0.lock().unwrap();
        notification.callback = options.wakeup;
        notification.user_data = options.wakeup_user_data as usize;
    }
    Box::into_raw(Box::new(instance))
}
unsafe extern "C" fn destroy(instance: *mut Instance) -> i32 {
    let Some(value) = instance.as_mut() else {
        return 0;
    };
    if !value.shutdown() {
        return 3;
    }
    drop(Box::from_raw(instance));
    0
}
unsafe extern "C" fn open(
    instance: *mut Instance,
    path: *const c_char,
    options: *const CallOptions,
) -> u64 {
    let Some(instance) = instance.as_mut() else {
        return 0;
    };
    if path.is_null() {
        return 0;
    }
    let Ok(path) = CStr::from_ptr(path).to_str() else {
        return 0;
    };
    let (shape, timeout_ms) = if let Some(options) = options.as_ref() {
        if options.struct_size as usize != size_of::<CallOptions>()
            || options.request_stream > 1
            || options.response_stream > 1
            || options.reserved != 0
        {
            return 0;
        }
        (
            Some((options.request_stream != 0, options.response_stream != 0)),
            (options.timeout_ms != u64::MAX).then_some(options.timeout_ms),
        )
    } else {
        (None, None)
    };
    instance.open(path, shape, timeout_ms)
}
unsafe extern "C" fn send(instance: *mut Instance, id: u64, data: *const u8, size: u32) -> i32 {
    let Some(instance) = instance.as_mut() else {
        return -2;
    };
    if size > i32::MAX as u32 || (size != 0 && data.is_null()) {
        return -8;
    }
    instance.send(
        id,
        if size == 0 {
            &[]
        } else {
            std::slice::from_raw_parts(data, size as usize)
        },
    )
}
unsafe extern "C" fn half_close(instance: *mut Instance, id: u64) -> i32 {
    instance
        .as_mut()
        .map_or(-2, |instance| instance.half_close(id))
}
unsafe extern "C" fn receive(instance: *mut Instance, id: u64, result: *mut ReadResult) -> i32 {
    let Some(result) = result.as_mut() else {
        return -8;
    };
    *result = ReadResult {
        kind: 0,
        code: 0,
        data: ptr::null_mut(),
        size: 0,
    };
    let Some(call) = instance
        .as_mut()
        .and_then(|instance| instance.calls.get_mut(&id))
    else {
        return -2;
    };
    let mut state = call.shared.state.lock().unwrap();
    if let Some(data) = state.output.pop_front() {
        call.received += 1;
        if !call.response_stream && call.received > 1 {
            drop(state);
            call.cancel(RpcError::new(13, "RPC produced more than one response"));
            state = call.shared.state.lock().unwrap();
        } else {
            for waker in state.output_wakers.drain(..) {
                waker.wake();
            }
            result.kind = 1;
            return copy_result(result, &data);
        }
    }
    if let Some(terminal) = &state.terminal {
        result.kind = 2;
        if let Err(error) = terminal {
            result.code = if (1..=16).contains(&error.code) {
                error.code
            } else {
                2
            };
            return copy_result(result, &error.details);
        }
        if !call.response_stream && call.received != 1 {
            let error = RpcError::new(13, "RPC completed without a response");
            result.code = error.code;
            return copy_result(result, &error.details);
        }
    }
    0
}
unsafe extern "C" fn cancel(instance: *mut Instance, id: u64, code: i32) -> i32 {
    if !(1..=16).contains(&code) {
        return -8;
    }
    let Some(call) = instance
        .as_mut()
        .and_then(|instance| instance.calls.get_mut(&id))
    else {
        return -2;
    };
    // An already observed/completed terminal is immutable.
    if call.shared.state.lock().unwrap().terminal.is_some() {
        return 0;
    }
    call.cancel(RpcError::new(
        code,
        if code == 4 {
            "Deadline exceeded"
        } else {
            "Call cancelled"
        },
    ));
    0
}
unsafe extern "C" fn release(instance: *mut Instance, id: u64) {
    if let Some(instance) = instance.as_mut() {
        instance.release(id);
    }
}
unsafe extern "C" fn poll(instance: *mut Instance, budget: u32) -> u32 {
    instance
        .as_mut()
        .map_or(0, |instance| instance.poll(budget))
}
unsafe extern "C" fn has_work(instance: *mut Instance) -> i32 {
    instance.as_ref().is_some_and(|instance| {
        instance
            .calls
            .values()
            .any(|call| call.future.is_some() && call.shared.ready.load(Ordering::Acquire))
    }) as i32
}

unsafe fn copy_result(result: &mut ReadResult, data: &[u8]) -> i32 {
    if data.len() > u32::MAX as usize {
        return -7;
    }
    let pointer = allocate(data.len() as u32);
    if pointer.is_null() {
        return -5;
    }
    ptr::copy_nonoverlapping(data.as_ptr(), pointer, data.len());
    result.data = pointer;
    result.size = data.len() as u32;
    0
}
/// Allocate with a module-private length header so free never needs a length.
/// # Safety
/// The returned pointer must only be released with this module's free_buffer.
pub unsafe extern "C" fn allocate(size: u32) -> *mut u8 {
    let Some(total) = (size as usize).checked_add(8) else {
        return ptr::null_mut();
    };
    let Ok(layout) = std::alloc::Layout::from_size_align(total, 8) else {
        return ptr::null_mut();
    };
    let pointer = std::alloc::alloc(layout);
    if pointer.is_null() {
        return pointer;
    }
    (pointer as *mut u64).write(total as u64);
    pointer.add(8)
}
/// # Safety
/// pointer is null or a live allocation returned by this module.
pub unsafe extern "C" fn free_buffer(pointer: *mut c_void) {
    if pointer.is_null() {
        return;
    }
    let pointer = (pointer as *mut u8).sub(8);
    let total = (pointer as *const u64).read() as usize;
    std::alloc::dealloc(
        pointer,
        std::alloc::Layout::from_size_align_unchecked(total, 8),
    );
}

/// Export once per module. Use a unique accessor name for static linking.
/// Native loaders normally use Synurang_GetApi. The WASM exports use the same
/// operations and result layout as src/wasm.c, without wasm-bindgen glue.
#[macro_export]
macro_rules! export_module {
    ($name:ident, $factory:path) => {
        #[no_mangle]
        pub extern "C" fn $name() -> *const $crate::abi::Api {
            unsafe extern "C" fn create(
                options: *const $crate::abi::RuntimeOptions,
            ) -> *mut $crate::Instance {
                $crate::abi::create(options, $factory)
            }
            static API: $crate::abi::Api = $crate::abi::Api::new(create);
            &API
        }
        #[cfg(target_family = "wasm")]
        mod synurang_wasm_exports {
            use super::*;
            use std::ffi::{c_char, c_void};
            use std::mem::size_of;
            use $crate::abi::*;
            use $crate::Instance;
            unsafe fn api() -> &'static Api {
                &*$name()
            }
            #[link(wasm_import_module = "synurang")]
            extern "C" {
                #[link_name = "wakeup"]
                fn host_wakeup(token: u32);
            }
            unsafe extern "C" fn wakeup(token: *mut c_void) {
                host_wakeup(token as u32);
            }
            #[no_mangle]
            pub extern "C" fn synurang_module_abi_version() -> u32 {
                1
            }
            #[no_mangle]
            pub unsafe extern "C" fn synurang_module_create(
                capacity: u32,
                token: u32,
            ) -> *mut Instance {
                let capacity = if capacity == 0 { 16 } else { capacity } as usize;
                let options = RuntimeOptions {
                    struct_size: size_of::<RuntimeOptions>(),
                    execution_mode: 1,
                    worker_count: 0,
                    inbound_queue_capacity: capacity,
                    outbound_queue_capacity: capacity,
                    wakeup: Some(wakeup),
                    wakeup_user_data: token as *mut c_void,
                };
                (api().create)(&options)
            }
            #[no_mangle]
            pub unsafe extern "C" fn synurang_module_destroy(instance: *mut Instance) -> i32 {
                (api().destroy)(instance)
            }
            #[no_mangle]
            pub unsafe extern "C" fn synurang_module_open(
                instance: *mut Instance,
                path: *const c_char,
                request_stream: u32,
                response_stream: u32,
                timeout_ms: f64,
            ) -> u64 {
                let timeout_ms = if timeout_ms == -1.0 {
                    u64::MAX
                } else if timeout_ms.is_finite() && (0.0..=9007199254740991.0).contains(&timeout_ms)
                {
                    timeout_ms as u64
                } else {
                    return 0;
                };
                (api().open)(
                    instance,
                    path,
                    &CallOptions {
                        struct_size: size_of::<CallOptions>() as u32,
                        request_stream,
                        response_stream,
                        reserved: 0,
                        timeout_ms,
                    },
                )
            }
            #[no_mangle]
            pub unsafe extern "C" fn synurang_module_send(
                instance: *mut Instance,
                call: u64,
                data: *const u8,
                size: u32,
            ) -> i32 {
                (api().send)(instance, call, data, size)
            }
            #[no_mangle]
            pub unsafe extern "C" fn synurang_module_half_close(
                instance: *mut Instance,
                call: u64,
            ) -> i32 {
                (api().half_close)(instance, call)
            }
            #[no_mangle]
            pub unsafe extern "C" fn synurang_module_receive(
                instance: *mut Instance,
                call: u64,
                result: *mut ReadResult,
            ) -> i32 {
                (api().receive)(instance, call, result)
            }
            #[no_mangle]
            pub unsafe extern "C" fn synurang_module_cancel(
                instance: *mut Instance,
                call: u64,
                code: i32,
            ) -> i32 {
                (api().cancel)(instance, call, code)
            }
            #[no_mangle]
            pub unsafe extern "C" fn synurang_module_release(instance: *mut Instance, call: u64) {
                (api().release)(instance, call)
            }
            #[no_mangle]
            pub unsafe extern "C" fn synurang_module_poll(
                instance: *mut Instance,
                budget: u32,
            ) -> u32 {
                (api().poll)(instance, budget)
            }
            #[no_mangle]
            pub unsafe extern "C" fn synurang_module_has_work(instance: *mut Instance) -> i32 {
                (api().has_work)(instance)
            }
            #[no_mangle]
            pub unsafe extern "C" fn synurang_module_free(pointer: *mut c_void) {
                (api().free_buffer)(pointer)
            }
            #[no_mangle]
            pub unsafe extern "C" fn synurang_module_alloc(size: u32) -> *mut u8 {
                allocate(size)
            }
        }
    };
}

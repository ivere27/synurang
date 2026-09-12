//go:build cgo && !js

package module

/*
#cgo CFLAGS: -I${SRCDIR}/../../include
#cgo linux LDFLAGS: -ldl
#include <stdlib.h>
#include "synurang/call.h"
static inline void synurang_go_wakeup(SynurangWakeupFn fn, void* data) { fn(data); }
*/
import "C"
import (
	"runtime/cgo"
	"unsafe"
)

// Run is only needed by a js/wasm executable; native shared libraries register
// their factory from init and do not need an application event loop.
func Run() {}

func nativeInstance(pointer unsafe.Pointer) *Instance {
	if pointer == nil {
		return nil
	}
	return cgo.Handle(*(*uintptr)(pointer)).Value().(*Instance)
}

//export SynurangGo_Create
func SynurangGo_Create(options *C.SynurangRuntimeOptions) unsafe.Pointer {
	in, out := 16, 16
	if options != nil {
		if options.struct_size != C.size_t(C.sizeof_SynurangRuntimeOptions) || options.execution_mode != C.SYNURANG_EXECUTION_MANUAL {
			return nil
		}
		if uint64(options.inbound_queue_capacity) > 65536 || uint64(options.outbound_queue_capacity) > 65536 {
			return nil
		}
		in, out = int(options.inbound_queue_capacity), int(options.outbound_queue_capacity)
	}
	instance := createInstance(in, out)
	if instance == nil {
		return nil
	}
	if options != nil && options.wakeup != nil {
		wakeup, data := options.wakeup, options.wakeup_user_data
		instance.wakeup = func() { C.synurang_go_wakeup(wakeup, data) }
	}
	pointer := C.malloc(C.size_t(unsafe.Sizeof(uintptr(0))))
	if pointer == nil {
		return nil
	}
	*(*uintptr)(pointer) = uintptr(cgo.NewHandle(instance))
	return pointer
}

//export SynurangGo_Destroy
func SynurangGo_Destroy(pointer unsafe.Pointer) C.int {
	instance := nativeInstance(pointer)
	if instance == nil {
		return 0
	}
	status := instance.destroy()
	if status == 0 {
		cgo.Handle(*(*uintptr)(pointer)).Delete()
		C.free(pointer)
	}
	return C.int(status)
}

//export SynurangGo_Open
func SynurangGo_Open(pointer unsafe.Pointer, path *C.char, options *C.SynurangCallOptions) C.uint64_t {
	instance := nativeInstance(pointer)
	if instance == nil || path == nil {
		return 0
	}
	request, response, shape, timeout := false, false, false, ^uint64(0)
	if options != nil {
		if options.struct_size != C.sizeof_SynurangCallOptions || options.request_stream > 1 || options.response_stream > 1 || options.reserved != 0 {
			return 0
		}
		request, response, shape, timeout = options.request_stream != 0, options.response_stream != 0, true, uint64(options.timeout_ms)
	}
	return C.uint64_t(instance.open(C.GoString(path), request, response, timeout, shape))
}

//export SynurangGo_Send
func SynurangGo_Send(pointer unsafe.Pointer, id C.uint64_t, data *C.uint8_t, size C.uint32_t) C.int {
	instance := nativeInstance(pointer)
	if instance == nil {
		return -2
	}
	if size > 1<<31-1 || (data == nil && size != 0) {
		return -8
	}
	return C.int(instance.send(uint64(id), C.GoBytes(unsafe.Pointer(data), C.int(size))))
}

//export SynurangGo_HalfClose
func SynurangGo_HalfClose(pointer unsafe.Pointer, id C.uint64_t) C.int {
	instance := nativeInstance(pointer)
	if instance == nil {
		return -2
	}
	return C.int(instance.halfClose(uint64(id)))
}

//export SynurangGo_Receive
func SynurangGo_Receive(pointer unsafe.Pointer, id C.uint64_t, result *C.SynurangReadResult) C.int {
	if result == nil {
		return -8
	}
	*result = C.SynurangReadResult{}
	instance := nativeInstance(pointer)
	if instance == nil {
		return -2
	}
	kind, code, data, status := instance.receive(uint64(id))
	result.kind, result.code, result.size = C.uint32_t(kind), C.int32_t(code), C.uint32_t(len(data))
	if kind != 0 {
		if len(data) == 0 {
			result.data = (*C.uint8_t)(C.malloc(1))
		} else {
			result.data = (*C.uint8_t)(C.CBytes(data))
		}
		if result.data == nil {
			return -5
		}
	}
	return C.int(status)
}

//export SynurangGo_Cancel
func SynurangGo_Cancel(pointer unsafe.Pointer, id C.uint64_t, code C.int32_t) C.int {
	instance := nativeInstance(pointer)
	if instance == nil {
		return -2
	}
	return C.int(instance.cancel(uint64(id), int(code)))
}

//export SynurangGo_Release
func SynurangGo_Release(pointer unsafe.Pointer, id C.uint64_t) {
	if instance := nativeInstance(pointer); instance != nil {
		instance.release(uint64(id))
	}
}

//export SynurangGo_Poll
func SynurangGo_Poll(pointer unsafe.Pointer, budget C.uint32_t) C.uint32_t {
	if instance := nativeInstance(pointer); instance != nil {
		instance.poll()
	}
	return 0
}

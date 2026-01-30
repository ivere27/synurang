//go:build !windows

package synurang

/*
#cgo LDFLAGS: -ldl

#include <stdlib.h>
#include <dlfcn.h>
#include <stdint.h>

// Function pointer types matching Synurang exports
typedef char* (*synurang_invoke_func)(char* method, char* data, int dataLen, int* respLen);
typedef void (*synurang_free_func)(char* ptr);

// Streaming function pointer types
typedef unsigned long long (*synurang_stream_open_func)(char* method);
typedef int (*synurang_stream_send_func)(unsigned long long handle, char* data, int dataLen);
typedef char* (*synurang_stream_recv_func)(unsigned long long handle, int* respLen, int* status);
typedef void (*synurang_stream_close_send_func)(unsigned long long handle);
typedef void (*synurang_stream_close_func)(unsigned long long handle);

// Wrapper to call invoke function pointer
static char* call_invoke(void* fn, char* method, char* data, int dataLen, int* respLen) {
    return ((synurang_invoke_func)fn)(method, data, dataLen, respLen);
}

// Wrapper to call free function pointer
static void call_free(void* fn, char* ptr) {
    ((synurang_free_func)fn)(ptr);
}

// Streaming wrappers
static unsigned long long call_stream_open(void* fn, char* method) {
    return ((synurang_stream_open_func)fn)(method);
}

static int call_stream_send(void* fn, unsigned long long handle, char* data, int dataLen) {
    return ((synurang_stream_send_func)fn)(handle, data, dataLen);
}

static char* call_stream_recv(void* fn, unsigned long long handle, int* respLen, int* status) {
    return ((synurang_stream_recv_func)fn)(handle, respLen, status);
}

static void call_stream_close_send(void* fn, unsigned long long handle) {
    ((synurang_stream_close_send_func)fn)(handle);
}

static void call_stream_close(void* fn, unsigned long long handle) {
    ((synurang_stream_close_func)fn)(handle);
}
*/
import "C"

import (
	"fmt"
	"unsafe"
)

func init() {
	platformOpen = unixOpen
	platformSym = unixSym
	platformClose = unixClose
	platformInvoke = unixInvoke
	platformStreamOpen = unixStreamOpen
	platformStreamSend = unixStreamSend
	platformStreamRecv = unixStreamRecv
	platformStreamCloseSend = unixStreamCloseSend
	platformStreamClose = unixStreamClose
}

func unixOpen(path string) (uintptr, error) {
	cPath := C.CString(path)
	defer C.free(unsafe.Pointer(cPath))

	handle := C.dlopen(cPath, C.RTLD_LAZY)
	if handle == nil {
		return 0, fmt.Errorf("%s", C.GoString(C.dlerror()))
	}
	return uintptr(handle), nil
}

func unixSym(handle uintptr, name string) (uintptr, error) {
	cName := C.CString(name)
	defer C.free(unsafe.Pointer(cName))

	ptr := C.dlsym(unsafe.Pointer(handle), cName)
	if ptr == nil {
		return 0, fmt.Errorf("symbol not found: %s", name)
	}
	return uintptr(ptr), nil
}

func unixClose(handle uintptr) error {
	C.dlclose(unsafe.Pointer(handle))
	return nil
}

func unixInvoke(fn, freePtr uintptr, method string, data []byte) ([]byte, error) {
	cMethod := C.CString(method)
	defer C.free(unsafe.Pointer(cMethod))

	var cData *C.char
	if len(data) > 0 {
		cData = (*C.char)(C.CBytes(data))
		defer C.free(unsafe.Pointer(cData))
	}

	var respLen C.int
	cResp := C.call_invoke(unsafe.Pointer(fn), cMethod, cData, C.int(len(data)), &respLen)
	if cResp == nil {
		return nil, fmt.Errorf("plugin returned nil")
	}
	defer C.call_free(unsafe.Pointer(freePtr), cResp)

	return C.GoBytes(unsafe.Pointer(cResp), respLen), nil
}

func unixStreamOpen(fn uintptr, method string) uint64 {
	cMethod := C.CString(method)
	defer C.free(unsafe.Pointer(cMethod))

	return uint64(C.call_stream_open(unsafe.Pointer(fn), cMethod))
}

func unixStreamSend(fn uintptr, handle uint64, data []byte) int {
	var cData *C.char
	if len(data) > 0 {
		cData = (*C.char)(C.CBytes(data))
		defer C.free(unsafe.Pointer(cData))
	}

	return int(C.call_stream_send(unsafe.Pointer(fn), C.ulonglong(handle), cData, C.int(len(data))))
}

func unixStreamRecv(fn, freePtr uintptr, handle uint64) (data []byte, respLen, status int) {
	var cRespLen C.int
	var cStatus C.int

	cResp := C.call_stream_recv(unsafe.Pointer(fn), C.ulonglong(handle), &cRespLen, &cStatus)

	status = int(cStatus)
	respLen = int(cRespLen)

	if cResp != nil {
		data = C.GoBytes(unsafe.Pointer(cResp), cRespLen)
		C.call_free(unsafe.Pointer(freePtr), cResp)
	}

	return data, respLen, status
}

func unixStreamCloseSend(fn uintptr, handle uint64) {
	C.call_stream_close_send(unsafe.Pointer(fn), C.ulonglong(handle))
}

func unixStreamClose(fn uintptr, handle uint64) {
	C.call_stream_close(unsafe.Pointer(fn), C.ulonglong(handle))
}

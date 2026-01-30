//go:build windows

package synurang

import (
	"fmt"
	"syscall"
	"unsafe"
)

var (
	kernel32        = syscall.NewLazyDLL("kernel32.dll")
	loadLibraryW    = kernel32.NewProc("LoadLibraryW")
	freeLibrary     = kernel32.NewProc("FreeLibrary")
	getProcAddress  = kernel32.NewProc("GetProcAddress")
)

func init() {
	platformOpen = windowsOpen
	platformSym = windowsSym
	platformClose = windowsClose
	platformInvoke = windowsInvoke
	platformStreamOpen = windowsStreamOpen
	platformStreamSend = windowsStreamSend
	platformStreamRecv = windowsStreamRecv
	platformStreamCloseSend = windowsStreamCloseSend
	platformStreamClose = windowsStreamClose
}

func windowsOpen(path string) (uintptr, error) {
	pathPtr, err := syscall.UTF16PtrFromString(path)
	if err != nil {
		return 0, err
	}

	handle, _, err := loadLibraryW.Call(uintptr(unsafe.Pointer(pathPtr)))
	if handle == 0 {
		return 0, fmt.Errorf("LoadLibrary failed: %v", err)
	}
	return handle, nil
}

func windowsSym(handle uintptr, name string) (uintptr, error) {
	namePtr, err := syscall.BytePtrFromString(name)
	if err != nil {
		return 0, err
	}

	ptr, _, err := getProcAddress.Call(handle, uintptr(unsafe.Pointer(namePtr)))
	if ptr == 0 {
		return 0, fmt.Errorf("GetProcAddress failed for %s: %v", name, err)
	}
	return ptr, nil
}

func windowsClose(handle uintptr) error {
	freeLibrary.Call(handle)
	return nil
}

// cstring allocates a null-terminated C string and returns pointer and cleanup function
func cstring(s string) (uintptr, func()) {
	b := make([]byte, len(s)+1)
	copy(b, s)
	return uintptr(unsafe.Pointer(&b[0])), func() { /* prevent GC during call */ _ = b }
}

func windowsInvoke(fn, freePtr uintptr, method string, data []byte) ([]byte, error) {
	methodPtr, methodCleanup := cstring(method)
	defer methodCleanup()

	var dataPtr uintptr
	dataLen := len(data)
	if dataLen > 0 {
		// Allocate on heap to prevent GC movement
		dataCopy := make([]byte, dataLen)
		copy(dataCopy, data)
		dataPtr = uintptr(unsafe.Pointer(&dataCopy[0]))
		defer func() { _ = dataCopy }() // prevent GC during call
	}

	var respLen int32

	// Call: char* invoke(char* method, char* data, int dataLen, int* respLen)
	ret, _, _ := syscall.SyscallN(fn,
		methodPtr,
		dataPtr,
		uintptr(dataLen),
		uintptr(unsafe.Pointer(&respLen)),
	)

	if ret == 0 {
		return nil, fmt.Errorf("plugin returned nil")
	}

	// Copy result before freeing
	result := make([]byte, respLen)
	for i := int32(0); i < respLen; i++ {
		result[i] = *(*byte)(unsafe.Pointer(ret + uintptr(i)))
	}

	// Free the response using plugin's free function
	syscall.SyscallN(freePtr, ret)

	return result, nil
}

func windowsStreamOpen(fn uintptr, method string) uint64 {
	methodPtr, methodCleanup := cstring(method)
	defer methodCleanup()

	// Call: unsigned long long open(char* method)
	ret, _, _ := syscall.SyscallN(fn, methodPtr)
	return uint64(ret)
}

func windowsStreamSend(fn uintptr, handle uint64, data []byte) int {
	var dataPtr uintptr
	dataLen := len(data)
	if dataLen > 0 {
		dataCopy := make([]byte, dataLen)
		copy(dataCopy, data)
		dataPtr = uintptr(unsafe.Pointer(&dataCopy[0]))
		defer func() { _ = dataCopy }()
	}

	// Call: int send(unsigned long long handle, char* data, int dataLen)
	ret, _, _ := syscall.SyscallN(fn,
		uintptr(handle),
		dataPtr,
		uintptr(dataLen),
	)
	return int(ret)
}

func windowsStreamRecv(fn, freePtr uintptr, handle uint64) (data []byte, respLen, status int) {
	var cRespLen int32
	var cStatus int32

	// Call: char* recv(unsigned long long handle, int* respLen, int* status)
	ret, _, _ := syscall.SyscallN(fn,
		uintptr(handle),
		uintptr(unsafe.Pointer(&cRespLen)),
		uintptr(unsafe.Pointer(&cStatus)),
	)

	status = int(cStatus)
	respLen = int(cRespLen)

	if ret != 0 && cRespLen > 0 {
		data = make([]byte, cRespLen)
		for i := int32(0); i < cRespLen; i++ {
			data[i] = *(*byte)(unsafe.Pointer(ret + uintptr(i)))
		}
		// Free the response
		syscall.SyscallN(freePtr, ret)
	}

	return data, respLen, status
}

func windowsStreamCloseSend(fn uintptr, handle uint64) {
	// Call: void closeSend(unsigned long long handle)
	syscall.SyscallN(fn, uintptr(handle))
}

func windowsStreamClose(fn uintptr, handle uint64) {
	// Call: void close(unsigned long long handle)
	syscall.SyscallN(fn, uintptr(handle))
}

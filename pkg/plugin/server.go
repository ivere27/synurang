package plugin

/*
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"sync"
	"sync/atomic"
	"unsafe"
)

// Synurang_Free frees memory allocated by C.CBytes.
//
//export Synurang_Free
func Synurang_Free(ptr *C.char) {
	C.free(unsafe.Pointer(ptr))
}

var (
	streamHandleCounter uint64
	streamHandles       sync.Map // handle -> *PluginStream
)

// PluginStream holds state for a single streaming RPC.
// Fields are exported to be accessible by generated code in other packages.
type PluginStream struct {
	Ctx       context.Context
	Cancel    context.CancelFunc
	Method    string
	SendCh    chan []byte // Data from Host to Plugin
	RecvCh    chan []byte // Data from Plugin to Host
	ErrCh     chan error
	CloseSend bool
	CloseRecv bool
	Mu        sync.Mutex
}

// NewStream creates a new stream and registers it globally.
// Used by generated code in Synurang_Stream_<Service>_Open.
func NewStream(method string) (uint64, *PluginStream) {
	ctx, cancel := context.WithCancel(context.Background())
	ps := &PluginStream{
		Ctx:    ctx,
		Cancel: cancel,
		Method: method,
		SendCh: make(chan []byte, 16),
		RecvCh: make(chan []byte, 16),
		ErrCh:  make(chan error, 1),
	}
	handle := atomic.AddUint64(&streamHandleCounter, 1)
	streamHandles.Store(handle, ps)
	return handle, ps
}

// getStream retrieves stream by handle, returns nil if not found
func getStream(handle C.ulonglong) *PluginStream {
	val, ok := streamHandles.Load(uint64(handle))
	if !ok {
		return nil
	}
	stream, ok := val.(*PluginStream)
	if !ok {
		return nil
	}
	return stream
}

// cToBytes converts C data pointer to Go bytes slice
func cToBytes(data *C.char, dataLen C.int) []byte {
	if data != nil && dataLen > 0 {
		return C.GoBytes(unsafe.Pointer(data), dataLen)
	}
	return []byte{}
}

//export Synurang_Stream_Send
func Synurang_Stream_Send(handle C.ulonglong, data *C.char, dataLen C.int) (result C.int) {
	stream := getStream(handle)
	if stream == nil {
		return 1
	}

	d := cToBytes(data, dataLen)

	defer func() {
		if r := recover(); r != nil {
			result = 3 // send on closed stream
		}
	}()

	stream.Mu.Lock()
	if stream.CloseSend {
		stream.Mu.Unlock()
		return 3
	}
	sendCh := stream.SendCh
	stream.Mu.Unlock()

	select {
	case sendCh <- d:
		return 0
	case <-stream.Ctx.Done():
		return 2
	}
}

//export Synurang_Stream_Recv
func Synurang_Stream_Recv(handle C.ulonglong, respLen *C.int, status *C.int) *C.char {
	stream := getStream(handle)
	if stream == nil {
		*status = 2
		return nil
	}

	// Priority 1: Check for data in RecvCh (non-blocking)
	// This ensures we don't miss data when context is also cancelled
	select {
	case data, ok := <-stream.RecvCh:
		if !ok {
			// Channel closed - check for pending error
			select {
			case err := <-stream.ErrCh:
				errBytes := []byte(err.Error())
				result := make([]byte, 1+len(errBytes))
				result[0] = 1
				copy(result[1:], errBytes)
				*respLen = C.int(len(result))
				*status = 0
				return (*C.char)(C.CBytes(result))
			default:
				*status = 1 // EOF - no error pending
				return nil
			}
		}
		result := make([]byte, 1+len(data))
		result[0] = 0
		copy(result[1:], data)
		*respLen = C.int(len(result))
		*status = 0
		return (*C.char)(C.CBytes(result))
	default:
		// No data immediately available, fall through to blocking select
	}

	// Priority 2: Check for error (non-blocking)
	select {
	case err := <-stream.ErrCh:
		errBytes := []byte(err.Error())
		result := make([]byte, 1+len(errBytes))
		result[0] = 1
		copy(result[1:], errBytes)
		*respLen = C.int(len(result))
		*status = 0
		return (*C.char)(C.CBytes(result))
	default:
	}

	// Priority 3: Blocking wait - data, error, or cancellation
	select {
	case data, ok := <-stream.RecvCh:
		if !ok {
			// Channel closed - check for pending error
			select {
			case err := <-stream.ErrCh:
				errBytes := []byte(err.Error())
				result := make([]byte, 1+len(errBytes))
				result[0] = 1
				copy(result[1:], errBytes)
				*respLen = C.int(len(result))
				*status = 0
				return (*C.char)(C.CBytes(result))
			default:
				*status = 1 // EOF - no error pending
				return nil
			}
		}
		result := make([]byte, 1+len(data))
		result[0] = 0
		copy(result[1:], data)
		*respLen = C.int(len(result))
		*status = 0
		return (*C.char)(C.CBytes(result))
	case err := <-stream.ErrCh:
		errBytes := []byte(err.Error())
		result := make([]byte, 1+len(errBytes))
		result[0] = 1
		copy(result[1:], errBytes)
		*respLen = C.int(len(result))
		*status = 0
		return (*C.char)(C.CBytes(result))
	case <-stream.Ctx.Done():
		// Context cancelled - but check one more time for data that arrived
		select {
		case data, ok := <-stream.RecvCh:
			if ok {
				result := make([]byte, 1+len(data))
				result[0] = 0
				copy(result[1:], data)
				*respLen = C.int(len(result))
				*status = 0
				return (*C.char)(C.CBytes(result))
			}
		default:
		}
		*status = 1 // EOF due to cancellation
		return nil
	}
}

// closeSendCh safely closes the send channel
func (ps *PluginStream) closeSendCh() {
	ps.Mu.Lock()
	if !ps.CloseSend {
		ps.CloseSend = true
		close(ps.SendCh)
	}
	ps.Mu.Unlock()
}

// CloseRecvCh safely closes the receive channel.
// This should be called by generated code when the handler goroutine exits.
func (ps *PluginStream) CloseRecvCh() {
	ps.Mu.Lock()
	if !ps.CloseRecv {
		ps.CloseRecv = true
		close(ps.RecvCh)
	}
	ps.Mu.Unlock()
}

//export Synurang_Stream_CloseSend
func Synurang_Stream_CloseSend(handle C.ulonglong) {
	if stream := getStream(handle); stream != nil {
		stream.closeSendCh()
	}
}

//export Synurang_Stream_Close
func Synurang_Stream_Close(handle C.ulonglong) {
	val, ok := streamHandles.LoadAndDelete(uint64(handle))
	if !ok {
		return
	}
	stream, ok := val.(*PluginStream)
	if !ok {
		return
	}
	stream.Cancel()
	stream.closeSendCh()
	stream.CloseRecvCh()
}

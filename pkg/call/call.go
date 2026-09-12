// Package call hosts versioned Synurang modules. Calls use protobuf bytes and
// context cancellation; the package does not depend on gRPC.
package call

/*
#cgo CFLAGS: -I${SRCDIR}/../../include
#cgo linux LDFLAGS: -ldl
#include <stdlib.h>
#include "synurang/module_host.h"
extern void synurangGoHostWake(uintptr_t);
static void synurang_go_host_wake(void* data) { synurangGoHostWake((uintptr_t)data); }
static void synurang_go_host_options(SynurangRuntimeOptions* options, uintptr_t data) {
    options->wakeup = synurang_go_host_wake;
    options->wakeup_user_data = (void*)data;
}
*/
import "C"

import (
	"context"
	"errors"
	"fmt"
	"io"
	"math"
	"runtime"
	"runtime/cgo"
	"strings"
	"sync"
	"time"
	"unsafe"

	"github.com/ivere27/synurang/pkg/ffierror"
)

type Method struct {
	Path                          string
	RequestStream, ResponseStream bool
}
type Error struct {
	Code    int
	Message string
	Details []byte
}

func (e *Error) Error() string { return e.Message }

type Module struct {
	mu           sync.Mutex
	ptr          *C.SynurangHost
	calls        map[*Call]struct{}
	closing      bool
	notification *notification
	wakeupHandle cgo.Handle
	changed      chan struct{}
	closed       chan struct{}
	closeErr     error
}

type notification struct{ ready chan struct{} }

func (n *notification) wake() {
	select {
	case n.ready <- struct{}{}:
	default:
	}
}

//export synurangGoHostWake
func synurangGoHostWake(value C.uintptr_t) {
	cgo.Handle(value).Value().(*notification).wake()
}

// Load creates an independent module instance. A native module's service
// futures may be polled on different OS threads, but never concurrently.
func Load(path string, capacity int) (*Module, error) {
	if strings.IndexByte(path, 0) >= 0 || capacity < 1 || capacity > 65536 {
		return nil, errors.New("invalid module path or queue capacity")
	}
	cPath := C.CString(path)
	defer C.free(unsafe.Pointer(cPath))
	options := C.SynurangRuntimeOptions{}
	options.struct_size = C.size_t(C.sizeof_SynurangRuntimeOptions)
	options.execution_mode = C.SYNURANG_EXECUTION_MANUAL
	options.inbound_queue_capacity = C.size_t(capacity)
	options.outbound_queue_capacity = C.size_t(capacity)
	notification := &notification{ready: make(chan struct{}, 1)}
	wakeupHandle := cgo.NewHandle(notification)
	C.synurang_go_host_options(&options, C.uintptr_t(wakeupHandle))
	// The loader's diagnostic is thread-local.
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	ptr := C.synurang_host_load(cPath, nil, &options)
	if ptr == nil {
		wakeupHandle.Delete()
		return nil, errors.New(C.GoString(C.synurang_host_error()))
	}
	m := &Module{ptr: ptr, calls: make(map[*Call]struct{}), closed: make(chan struct{}),
		notification: notification, wakeupHandle: wakeupHandle, changed: make(chan struct{})}
	go m.run()
	return m, nil
}

func (m *Module) Open(ctx context.Context, method Method) (*Call, error) {
	if err := ctx.Err(); err != nil {
		return nil, contextError(err)
	}
	if !strings.HasPrefix(method.Path, "/") || strings.IndexByte(method.Path, 0) >= 0 {
		return nil, errors.New("invalid method path")
	}
	options := C.SynurangCallOptions{struct_size: C.uint32_t(C.sizeof_SynurangCallOptions), timeout_ms: C.uint64_t(math.MaxUint64)}
	if method.RequestStream {
		options.request_stream = 1
	}
	if method.ResponseStream {
		options.response_stream = 1
	}
	if deadline, ok := ctx.Deadline(); ok {
		remaining := time.Until(deadline)
		if remaining <= 0 {
			return nil, contextError(context.DeadlineExceeded)
		}
		options.timeout_ms = C.uint64_t((remaining + time.Millisecond - 1) / time.Millisecond)
	}
	path := C.CString(method.Path)
	defer C.free(unsafe.Pointer(path))
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.closing {
		return nil, &Error{Code: 14, Message: "Module is closed"}
	}
	id := C.synurang_host_open(m.ptr, path, &options)
	if id == 0 {
		return nil, &Error{Code: 13, Message: "Module rejected call creation"}
	}
	call := &Call{module: m, id: id, ctx: ctx, done: make(chan struct{})}
	m.calls[call] = struct{}{}
	go func() {
		select {
		case <-ctx.Done():
			call.Cancel(contextError(ctx.Err()).Code)
		case <-call.done:
		}
	}()
	return call, nil
}

// Close waits for cooperative producer cleanup. Foreign calls themselves never
// wait: the Go scheduler resumes on provider notifications.
func (m *Module) Close() error {
	m.mu.Lock()
	if m.closing {
		m.mu.Unlock()
		<-m.closed
		return m.closeErr
	}
	m.closing = true
	m.notification.wake()
	for call := range m.calls {
		call.releaseLocked()
	}
	for {
		status := C.synurang_host_destroy(m.ptr)
		if status == 0 {
			m.ptr = nil
			m.wakeupHandle.Delete()
			close(m.changed)
			close(m.closed)
			m.mu.Unlock()
			return nil
		}
		if status != C.SYNURANG_PENDING {
			m.closeErr = fmt.Errorf("module teardown rejected (%d)", status)
			close(m.closed)
			m.mu.Unlock()
			return m.closeErr
		}
		changed := m.changed
		m.mu.Unlock()
		<-changed
		m.mu.Lock()
	}
}

type Call struct {
	module        *Module
	id            C.uint64_t
	ctx           context.Context
	done          chan struct{}
	closed, ended bool
	err           *Error
	sendMu        sync.Mutex
	recvMu        sync.Mutex
	pending       []byte
	hasPending    bool
}

func contextError(err error) *Error {
	code := 1
	if errors.Is(err, context.DeadlineExceeded) {
		code = 4
	}
	return &Error{Code: code, Message: err.Error()}
}
func (c *Call) checkLocked() error {
	if c.err != nil {
		return c.err
	}
	if c.closed || c.module.closing {
		return &Error{Code: 1, Message: "Call is closed"}
	}
	if err := c.ctx.Err(); err != nil {
		c.err = contextError(err)
		C.synurang_host_cancel(c.module.ptr, c.id, C.int32_t(c.err.Code))
		return c.err
	}
	return nil
}
func (c *Call) pause(changed <-chan struct{}) {
	select {
	case <-changed:
	case <-c.ctx.Done():
	case <-c.done:
	}
}

func rpcError(code int, data []byte) *Error {
	message := fmt.Sprintf("RPC failed (%d)", code)
	if payload, err := ffierror.Unmarshal(data); err == nil && payload.Message != "" {
		message = payload.Message
	}
	return &Error{Code: code, Message: message, Details: data}
}

// A rejected write may mean the peer already sent a terminal RPC status.
// Peek once, preserving a response for Recv rather than discarding it or
// draining an unbounded producer from the sending goroutine.
func (c *Call) writeErrorLocked() error {
	if !c.hasPending && !c.ended {
		var result C.SynurangReadResult
		status := C.synurang_host_receive(c.module.ptr, c.id, &result)
		var data []byte
		if result.data != nil {
			if result.size <= math.MaxInt32 {
				data = C.GoBytes(unsafe.Pointer(result.data), C.int(result.size))
			}
			C.synurang_host_free(c.module.ptr, unsafe.Pointer(result.data))
		}
		if status == 0 && result.size <= math.MaxInt32 {
			if result.kind == C.SYNURANG_READ_MESSAGE {
				c.pending, c.hasPending = data, true
			}
			if result.kind == C.SYNURANG_READ_FINISHED {
				if result.code != 0 {
					c.err = rpcError(int(result.code), data)
					return c.err
				}
				c.ended = true
			}
		}
	}
	return io.EOF
}

// Send returns once the bounded inbound queue accepts a copy of data. One
// goroutine may send while another receives on the same call.
func (c *Call) Send(data []byte) error {
	c.sendMu.Lock()
	defer c.sendMu.Unlock()
	if len(data) > math.MaxInt32 {
		return errors.New("request exceeds ABI size limit")
	}
	for {
		c.module.mu.Lock()
		changed := c.module.changed
		if err := c.checkLocked(); err != nil {
			c.module.mu.Unlock()
			return err
		}
		var pointer *C.uint8_t
		if len(data) != 0 {
			pointer = (*C.uint8_t)(unsafe.Pointer(&data[0]))
		}
		status := C.synurang_host_send(c.module.ptr, c.id, pointer, C.uint32_t(len(data)))
		if status != 0 && status != C.SYNURANG_WOULD_BLOCK {
			err := c.writeErrorLocked()
			c.module.mu.Unlock()
			return err
		}
		c.module.mu.Unlock()
		if status == 0 {
			return nil
		}
		c.pause(changed)
	}
}
func (c *Call) HalfClose() error {
	c.sendMu.Lock()
	defer c.sendMu.Unlock()
	c.module.mu.Lock()
	defer c.module.mu.Unlock()
	if err := c.checkLocked(); err != nil {
		return err
	}
	if status := C.synurang_host_half_close(c.module.ptr, c.id); status != 0 {
		return c.writeErrorLocked()
	}
	return nil
}
func (c *Call) Recv() ([]byte, error) {
	c.recvMu.Lock()
	defer c.recvMu.Unlock()
	for {
		c.module.mu.Lock()
		changed := c.module.changed
		if c.ended {
			c.module.mu.Unlock()
			return nil, io.EOF
		}
		if err := c.checkLocked(); err != nil {
			c.module.mu.Unlock()
			return nil, err
		}
		if c.hasPending {
			data := c.pending
			c.pending, c.hasPending = nil, false
			c.module.mu.Unlock()
			return data, nil
		}
		var result C.SynurangReadResult
		status := C.synurang_host_receive(c.module.ptr, c.id, &result)
		var data []byte
		if result.data != nil {
			if result.size <= math.MaxInt32 {
				data = C.GoBytes(unsafe.Pointer(result.data), C.int(result.size))
			}
			C.synurang_host_free(c.module.ptr, unsafe.Pointer(result.data))
		}
		if status != 0 || result.size > math.MaxInt32 {
			c.module.mu.Unlock()
			return nil, fmt.Errorf("receive rejected (%d)", status)
		}
		if result.kind == C.SYNURANG_READ_MESSAGE {
			c.module.mu.Unlock()
			return data, nil
		}
		if result.kind == C.SYNURANG_READ_FINISHED {
			if result.code != 0 {
				c.err = rpcError(int(result.code), data)
				err := c.err
				c.module.mu.Unlock()
				return nil, err
			}
			c.ended = true
			c.module.mu.Unlock()
			return nil, io.EOF
		}
		c.module.mu.Unlock()
		c.pause(changed)
	}
}
func (c *Call) Cancel(code int) {
	c.module.mu.Lock()
	defer c.module.mu.Unlock()
	if c.closed || c.ended || c.err != nil {
		return
	}
	if code < 1 || code > 16 {
		code = 1
	}
	c.err = &Error{Code: code, Message: "Call cancelled"}
	C.synurang_host_cancel(c.module.ptr, c.id, C.int32_t(code))
	c.module.notification.wake()
}
func (c *Call) releaseLocked() {
	if c.closed {
		return
	}
	c.closed = true
	close(c.done)
	C.synurang_host_release(c.module.ptr, c.id)
	delete(c.module.calls, c)
	c.module.notification.wake()
}

// Continue producer cleanup after the last call is released. One goroutine per
// instance drains bounded turns, yielding the lock and scheduler between them.
func (m *Module) run() {
	for {
		select {
		case <-m.notification.ready:
		case <-m.closed:
			return
		}
		m.mu.Lock()
		if m.ptr == nil {
			m.mu.Unlock()
			return
		}
		C.synurang_host_poll(m.ptr, 64)
		close(m.changed)
		m.changed = make(chan struct{})
		ready := C.synurang_host_has_work(m.ptr) != 0
		if ready {
			m.notification.wake()
		}
		m.mu.Unlock()
		if ready {
			runtime.Gosched()
		}
	}
}
func (c *Call) Close() error {
	c.module.mu.Lock()
	defer c.module.mu.Unlock()
	c.releaseLocked()
	return nil
}

func (m *Module) Unary(ctx context.Context, method string, request []byte) ([]byte, error) {
	call, err := m.Open(ctx, Method{Path: method})
	if err != nil {
		return nil, err
	}
	defer call.Close()
	if err = call.Send(request); err != nil {
		return nil, err
	}
	if err = call.HalfClose(); err != nil {
		return nil, err
	}
	response, err := call.Recv()
	if err != nil {
		return nil, err
	}
	if _, err = call.Recv(); !errors.Is(err, io.EOF) {
		if err == nil {
			err = &Error{Code: 13, Message: "Multiple unary responses"}
		}
		return nil, err
	}
	return response, nil
}

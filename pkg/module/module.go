// Package module implements the Synurang call protocol with Go goroutines.
// The same provider runs as a c-shared/c-archive module or GOOS=js GOARCH=wasm.
package module

import (
	"context"
	"errors"
	"fmt"
	"github.com/ivere27/synurang/pkg/ffierror"
	"google.golang.org/protobuf/proto"
	"io"
	"sync"
	"sync/atomic"
	"time"
)

type Handler func(*Call) error
type Context = context.Context
type method struct {
	requestStream, responseStream bool
	handler                       Handler
}
type Instance struct {
	mu                      sync.Mutex
	methods                 map[string]method
	calls                   map[uint64]*Call
	retired                 []*Call
	next                    uint64
	capacityIn, capacityOut int
	closing                 bool
	cleanup                 []func()
	wakeup                  func()
	notified                atomic.Bool
}

var factoryMu sync.RWMutex
var moduleFactory func() *Instance

// RegisterModule installs a factory during program initialization. Every host
// instance receives newly registered service state, not a global singleton.
func RegisterModule(factory func() *Instance) {
	factoryMu.Lock()
	defer factoryMu.Unlock()
	if moduleFactory != nil {
		panic("Synurang module factory already registered")
	}
	moduleFactory = factory
}
func createInstance(in, out int) (instance *Instance) {
	factoryMu.RLock()
	factory := moduleFactory
	factoryMu.RUnlock()
	if factory == nil {
		return nil
	}
	defer func() {
		if recover() != nil {
			instance = nil
		}
	}()
	instance = factory()
	if instance != nil {
		instance.capacityIn, instance.capacityOut = max(1, in), max(1, out)
	}
	return
}
func New() *Instance {
	return &Instance{methods: make(map[string]method), calls: make(map[uint64]*Call), next: 1, capacityIn: 16, capacityOut: 16}
}

// OnClose registers deterministic service cleanup before the first call.
// It runs once after all handlers and retained work have stopped. Cleanup must
// not block or re-enter the host ABI; stop asynchronous work through call
// cancellation and retained references before this final resource release.
func (instance *Instance) OnClose(cleanup func()) error {
	instance.mu.Lock()
	defer instance.mu.Unlock()
	if cleanup == nil || instance.next != 1 || instance.closing {
		return fmt.Errorf("cleanup must be registered before the first call")
	}
	instance.cleanup = append(instance.cleanup, cleanup)
	return nil
}
func (instance *Instance) Register(path string, requestStream, responseStream bool, handler Handler) error {
	instance.mu.Lock()
	defer instance.mu.Unlock()
	if instance.next != 1 || instance.closing || len(path) == 0 || path[0] != '/' || handler == nil {
		return fmt.Errorf("invalid method registration")
	}
	if _, exists := instance.methods[path]; exists {
		return fmt.Errorf("duplicate method %s", path)
	}
	instance.methods[path] = method{requestStream, responseStream, handler}
	return nil
}

type Call struct {
	mu                            sync.Mutex
	ctx                           context.Context
	cancel                        context.CancelFunc
	changed                       chan struct{}
	input, output                 [][]byte
	capacityIn, capacityOut       int
	halfClosed, finished, running bool
	requestStream, responseStream bool
	sent, received                uint64
	retained                      uint64
	terminal                      error
	wakeup                        func()
}

func (call *Call) Context() context.Context { return call.ctx }

// Retain keeps the module instance alive for work that outlives its handler.
// Call the returned function when that work has stopped, including cancellation.
// Retain must be called while the handler or another retained reference is live.
func (call *Call) Retain() func() {
	call.mu.Lock()
	call.retained++
	call.mu.Unlock()
	var once sync.Once
	return func() {
		once.Do(func() {
			call.mu.Lock()
			call.retained--
			if call.retained == 0 && !call.running {
				call.notifyHost()
			}
			call.mu.Unlock()
		})
	}
}

// signalLocked broadcasts to Go producers waiting on input or output capacity.
// Allocate a channel only when someone actually needs to wait.
func (call *Call) signalLocked() {
	if call.changed != nil {
		close(call.changed)
		call.changed = nil
	}
}
func (call *Call) changedLocked() <-chan struct{} {
	if call.changed == nil {
		call.changed = make(chan struct{})
	}
	return call.changed
}
func (call *Call) notifyHost() {
	if call.wakeup != nil {
		call.wakeup()
	}
}
func (instance *Instance) notifyHost() {
	// A poll acknowledges the outstanding notification. Coalesce before
	// crossing cgo or syscall/js, rather than after entering the host runtime.
	if instance.wakeup != nil && instance.notified.CompareAndSwap(false, true) {
		instance.wakeup()
	}
}
func (call *Call) RecvBytes() ([]byte, error) {
	for {
		call.mu.Lock()
		if err := call.ctx.Err(); err != nil {
			call.mu.Unlock()
			return nil, err
		}
		if len(call.input) > 0 {
			wasFull := len(call.input) == call.capacityIn
			data := call.input[0]
			call.input[0] = nil
			call.input = call.input[1:]
			call.mu.Unlock()
			if wasFull {
				// The running/retained producer keeps the instance alive until
				// this callback returns; foreign code need not hold call.mu.
				call.notifyHost()
			}
			return data, nil
		}
		if call.halfClosed {
			call.mu.Unlock()
			return nil, io.EOF
		}
		if call.finished {
			call.mu.Unlock()
			return nil, io.EOF
		}
		changed := call.changedLocked()
		call.mu.Unlock()
		select {
		case <-changed:
		case <-call.ctx.Done():
		}
	}
}
func (call *Call) SendBytes(data []byte) error {
	for {
		call.mu.Lock()
		if err := call.ctx.Err(); err != nil {
			call.mu.Unlock()
			return err
		}
		if call.finished {
			call.mu.Unlock()
			return fmt.Errorf("call is finished")
		}
		if len(call.output) < call.capacityOut {
			wasEmpty := len(call.output) == 0
			call.output = append(call.output, append([]byte{}, data...))
			call.mu.Unlock()
			if wasEmpty {
				// As in RecvBytes, producer lifetime covers the callback.
				call.notifyHost()
			}
			return nil
		}
		changed := call.changedLocked()
		call.mu.Unlock()
		select {
		case <-changed:
		case <-call.ctx.Done():
		}
	}
}
func (call *Call) Recv(message proto.Message) error {
	data, err := call.RecvBytes()
	if err != nil {
		return err
	}
	if err = proto.Unmarshal(data, message); err != nil {
		return ffierror.New(0, "Malformed request", 3)
	}
	return nil
}
func (call *Call) Send(message proto.Message) error {
	data, err := proto.Marshal(message)
	if err != nil {
		return err
	}
	return call.SendBytes(data)
}
func (call *Call) finish(err error) {
	call.mu.Lock()
	defer call.mu.Unlock()
	call.running = false
	if !call.finished {
		if errors.Is(err, context.DeadlineExceeded) {
			err = ffierror.New(0, "Deadline exceeded", 4)
		}
		call.terminal, call.finished = err, true
		call.input = nil
	}
	call.cancel()
	call.signalLocked()
	// Final retirement and its callback remain atomic with destroy's check.
	call.notifyHost()
}
func (call *Call) stop(code int) {
	call.mu.Lock()
	defer call.mu.Unlock()
	if call.finished {
		return
	}
	message := "Call cancelled"
	if code == 4 {
		message = "Deadline exceeded"
	}
	call.terminal = ffierror.New(0, message, int32(code))
	call.finished = true
	call.input, call.output = nil, nil
	call.cancel()
	call.signalLocked()
	call.notifyHost()
}
func (instance *Instance) open(path string, requestStream, responseStream bool, timeout uint64, shape bool) uint64 {
	instance.mu.Lock()
	defer instance.mu.Unlock()
	if instance.closing || instance.next == 0 {
		return 0
	}
	ctx, cancel := context.WithCancel(context.Background())
	if timeout != ^uint64(0) && timeout <= uint64((1<<63-1)/int64(time.Millisecond)) {
		cancel()
		ctx, cancel = context.WithTimeout(context.Background(), time.Duration(timeout)*time.Millisecond)
	}
	call := &Call{ctx: ctx, cancel: cancel, capacityIn: instance.capacityIn, capacityOut: instance.capacityOut, wakeup: instance.notifyHost}
	id := instance.next
	instance.next++
	instance.calls[id] = call
	method, ok := instance.methods[path]
	call.requestStream, call.responseStream = method.requestStream, method.responseStream
	if !ok {
		call.stop(12)
		call.terminal = ffierror.New(0, "Unknown RPC method", 12)
		return id
	}
	if shape && (method.requestStream != requestStream || method.responseStream != responseStream) {
		call.stop(3)
		call.terminal = ffierror.New(0, "RPC cardinality does not match the service", 3)
		return id
	}
	if timeout == 0 {
		call.stop(4)
		return id
	}
	call.running = true
	go func() {
		var err error
		defer func() {
			if recovered := recover(); recovered != nil {
				err = ffierror.New(0, "Service panicked", 13)
			}
			call.finish(err)
		}()
		err = method.handler(call)
	}()
	return id
}
func (instance *Instance) lookup(id uint64) *Call {
	instance.mu.Lock()
	defer instance.mu.Unlock()
	return instance.calls[id]
}
func (instance *Instance) send(id uint64, data []byte) int {
	call := instance.lookup(id)
	if call == nil {
		return -2
	}
	call.mu.Lock()
	defer call.mu.Unlock()
	if call.finished || call.halfClosed {
		return -3
	}
	if !call.requestStream && call.sent != 0 {
		call.finished = true
		call.terminal = ffierror.New(0, "RPC accepts exactly one request", 3)
		call.input, call.output = nil, nil
		call.cancel()
		call.signalLocked()
		call.notifyHost()
		return -3
	}
	if len(call.input) >= call.capacityIn {
		return -4
	}
	call.input = append(call.input, append([]byte{}, data...))
	call.sent++
	call.signalLocked()
	return 0
}
func (instance *Instance) halfClose(id uint64) int {
	call := instance.lookup(id)
	if call == nil {
		return -2
	}
	call.mu.Lock()
	defer call.mu.Unlock()
	if call.finished || call.halfClosed {
		return 0
	}
	if !call.requestStream && call.sent != 1 {
		call.finished = true
		call.terminal = ffierror.New(0, "RPC requires one request", 3)
		call.input, call.output = nil, nil
		call.cancel()
		call.signalLocked()
		call.notifyHost()
		return -3
	}
	call.halfClosed = true
	call.signalLocked()
	return 0
}
func (instance *Instance) receive(id uint64) (kind, code int, data []byte, status int) {
	call := instance.lookup(id)
	if call == nil {
		return 0, 0, nil, -2
	}
	call.mu.Lock()
	defer call.mu.Unlock()
	if len(call.output) > 0 {
		data = call.output[0]
		call.output[0] = nil
		call.output = call.output[1:]
		call.received++
		call.signalLocked()
		if call.responseStream || call.received == 1 {
			return 1, 0, data, 0
		}
		call.finished = true
		call.terminal = ffierror.New(0, "RPC produced more than one response", 13)
		call.output = nil
		call.cancel()
	}
	if !call.finished {
		return 0, 0, nil, 0
	}
	if call.terminal == nil && !call.responseStream && call.received != 1 {
		call.terminal = ffierror.New(0, "RPC completed without a response", 13)
	}
	if call.terminal != nil {
		payload := ffierror.FromError(call.terminal)
		if payload.GrpcCode < 1 || payload.GrpcCode > 16 {
			payload.GrpcCode = 2
		}
		data, _ = proto.Marshal(payload)
		return 2, int(payload.GrpcCode), data, 0
	}
	return 2, 0, nil, 0
}
func (instance *Instance) cancel(id uint64, code int) int {
	if code < 1 || code > 16 {
		return -8
	}
	call := instance.lookup(id)
	if call == nil {
		return -2
	}
	call.stop(code)
	return 0
}
func (instance *Instance) release(id uint64) {
	instance.mu.Lock()
	defer instance.mu.Unlock()
	if call := instance.calls[id]; call != nil {
		call.stop(1)
		call.cancel()
		call.mu.Lock()
		call.input, call.output = nil, nil
		call.signalLocked()
		// Completed calls need no later poll. Keep only producers whose final
		// notification still protects work or retained callback lifetimes.
		if call.running || call.retained != 0 {
			instance.retired = append(instance.retired, call)
		}
		call.mu.Unlock()
		delete(instance.calls, id)
	}
}
func (instance *Instance) poll() {
	// A producer publishing after this point must post a fresh notification,
	// even when its callback races the scan or the host's subsequent receive.
	instance.notified.Store(false)
	instance.mu.Lock()
	defer instance.mu.Unlock()
	remaining := instance.retired[:0]
	for _, call := range instance.retired {
		call.mu.Lock()
		running := call.running || call.retained != 0
		call.mu.Unlock()
		if running {
			remaining = append(remaining, call)
		}
	}
	for i := len(remaining); i < len(instance.retired); i++ {
		instance.retired[i] = nil
	}
	instance.retired = remaining
}
func (instance *Instance) destroy() int {
	instance.mu.Lock()
	instance.closing = true
	ids := make([]uint64, 0, len(instance.calls))
	for id := range instance.calls {
		ids = append(ids, id)
	}
	instance.mu.Unlock()
	for _, id := range ids {
		instance.release(id)
	}
	instance.poll()
	instance.mu.Lock()
	if len(instance.retired) != 0 {
		instance.mu.Unlock()
		return 3
	}
	cleanup := instance.cleanup
	instance.cleanup = nil
	instance.mu.Unlock()
	for _, release := range cleanup {
		release()
	}
	return 0
}

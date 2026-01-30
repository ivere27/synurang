// Plugin loading support for synurang shared library plugins.
//
// This file provides utilities for loading and calling plugin shared libraries
// (.so on Linux, .dylib on macOS, .dll on Windows) that export Synurang FFI symbols.
//
// Usage:
//
//	plugin, err := synurang.LoadPlugin("./myplugin.so")
//	if err != nil {
//	    log.Fatal(err)
//	}
//	defer plugin.Close()
//
//	// Option 1: Direct invoke
//	resp, err := plugin.Invoke("MyService", "/pkg.MyService/Method", requestBytes)
//
//	// Option 2: Use as grpc.ClientConnInterface (recommended)
//	conn := synurang.NewPluginClientConn(plugin, "MyService")
//	client := pb.NewMyServiceClient(conn)
//	resp, err := client.MyMethod(ctx, req)

package synurang

import (
	"errors"
	"fmt"
	"io"
	"math"
	"sync"
)

// ErrDataTooLarge is returned when data exceeds the maximum size for C interop.
var ErrDataTooLarge = errors.New("data too large for C interop (max 2GB)")

// ErrPluginClosed is returned when operations are attempted on a closed plugin.
var ErrPluginClosed = errors.New("plugin is closed")

// PluginError represents an error returned from a plugin.
type PluginError struct {
	Message string
}

func (e *PluginError) Error() string {
	return "plugin error: " + e.Message
}

// Plugin represents a loaded shared library plugin.
type Plugin struct {
	handle  uintptr
	freePtr uintptr
	mu      sync.RWMutex
	// Cache of service invoke functions: serviceName -> function pointer
	invokers map[string]uintptr
	// Cache of per-service stream open functions: serviceName -> function pointer
	streamOpeners map[string]uintptr
	// Global stream functions (shared across all services)
	streamFuncs *globalStreamFuncs

	// activeStreams tracks currently open stream handles.
	// Used to cancel streams when Close() is called.
	activeStreams map[uintptr]bool

	// wg tracks active calls into the plugin (Invoke, Send, Recv, etc).
	// Close() waits for this waitgroup to ensure no code is executing
	// in the shared library when it is unloaded.
	wg sync.WaitGroup

	closed bool
}

// globalStreamFuncs holds global function pointers for streaming operations
type globalStreamFuncs struct {
	send      uintptr
	recv      uintptr
	closeSend uintptr
	close     uintptr
}

// Platform abstraction - these are set by platform-specific init() functions.
// They can be overridden in tests for mocking.
var (
	platformOpen   func(path string) (uintptr, error)
	platformSym    func(handle uintptr, name string) (uintptr, error)
	platformClose  func(handle uintptr) error
	platformInvoke func(fn, freePtr uintptr, method string, data []byte) ([]byte, error)

	// Streaming platform functions
	platformStreamOpen      func(fn uintptr, method string) uint64
	platformStreamSend      func(fn uintptr, handle uint64, data []byte) int
	platformStreamRecv      func(fn, freePtr uintptr, handle uint64) (data []byte, respLen, status int)
	platformStreamCloseSend func(fn uintptr, handle uint64)
	platformStreamClose     func(fn uintptr, handle uint64)
)

// LoadPlugin loads a shared library plugin from the given path.
// The plugin must export Synurang_Free and Synurang_Invoke_<ServiceName> symbols.
func LoadPlugin(path string) (*Plugin, error) {
	handle, err := platformOpen(path)
	if err != nil {
		return nil, fmt.Errorf("failed to load plugin %s: %w", path, err)
	}

	// Lookup Synurang_Free (required)
	freePtr, err := platformSym(handle, "Synurang_Free")
	if err != nil || freePtr == 0 {
		platformClose(handle)
		return nil, fmt.Errorf("plugin %s missing Synurang_Free symbol", path)
	}

	return &Plugin{
		handle:        handle,
		freePtr:       freePtr,
		invokers:      make(map[string]uintptr),
		streamOpeners: make(map[string]uintptr),
		activeStreams: make(map[uintptr]bool),
	}, nil
}

// Close unloads the plugin.
// It cancels all active streams and waits for running operations to complete.
func (p *Plugin) Close() error {
	p.mu.Lock()
	if p.closed {
		p.mu.Unlock()
		return nil
	}
	p.closed = true

	// Collect active stream handles to close and clear the map
	var handles []uintptr
	for h := range p.activeStreams {
		handles = append(handles, h)
	}
	// Clear activeStreams to prevent double-close from concurrent closeInternal()
	p.activeStreams = make(map[uintptr]bool)

	// Get stream close function pointer while holding lock
	var closeFunc uintptr
	if p.streamFuncs != nil {
		closeFunc = p.streamFuncs.close
	}
	p.mu.Unlock()

	// Close all active streams directly (not through StreamClose, since p.closed is true)
	// This cancels contexts inside the plugin
	if closeFunc != 0 {
		for _, h := range handles {
			p.wg.Add(1)
			func(handle uintptr) {
				defer p.wg.Done()
				platformStreamClose(closeFunc, uint64(handle))
			}(h)
		}
	}

	// Wait for all active calls (Recv, Send, Invoke) to complete
	// This prevents segfaults by ensuring no thread is executing inside
	// the shared library when we unload it.
	p.wg.Wait()

	// Now it is safe to unload
	p.mu.Lock()
	defer p.mu.Unlock()

	if p.handle != 0 {
		platformClose(p.handle)
		p.handle = 0
	}
	return nil
}

// getInvoker returns the invoke function pointer for a service, caching it.
func (p *Plugin) getInvoker(serviceName string) (uintptr, error) {
	p.mu.RLock()
	if ptr, ok := p.invokers[serviceName]; ok {
		p.mu.RUnlock()
		return ptr, nil
	}
	p.mu.RUnlock()

	p.mu.Lock()
	defer p.mu.Unlock()

	// Check if plugin was closed
	if p.closed || p.handle == 0 {
		return 0, ErrPluginClosed
	}

	// Double-check after acquiring write lock
	if ptr, ok := p.invokers[serviceName]; ok {
		return ptr, nil
	}

	symName := "Synurang_Invoke_" + serviceName
	ptr, err := platformSym(p.handle, symName)
	if err != nil || ptr == 0 {
		return 0, fmt.Errorf("service %s not found in plugin (missing %s)", serviceName, symName)
	}

	p.invokers[serviceName] = ptr
	return ptr, nil
}

// invokeInternal performs the actual FFI call and returns raw bytes.
func (p *Plugin) invokeInternal(serviceName, method string, data []byte) ([]byte, error) {
	p.mu.RLock()
	if p.closed {
		p.mu.RUnlock()
		return nil, ErrPluginClosed
	}
	p.wg.Add(1)
	p.mu.RUnlock()
	defer p.wg.Done()

	invokePtr, err := p.getInvoker(serviceName)
	if err != nil {
		return nil, err
	}

	if len(data) > math.MaxInt32 {
		return nil, ErrDataTooLarge
	}

	return platformInvoke(invokePtr, p.freePtr, method, data)
}

// Invoke calls a method on a service in the plugin.
// Returns the response bytes or an error.
//
// The method should be the full gRPC method name, e.g., "/pkg.ServiceName/MethodName".
// Response format from plugin: [status:1byte][payload...]
//   - status=0: success, payload is protobuf response
//   - status=1: error, payload is error message string
func (p *Plugin) Invoke(serviceName, method string, data []byte) ([]byte, error) {
	result, err := p.invokeInternal(serviceName, method, data)
	if err != nil {
		return nil, err
	}
	if len(result) == 0 {
		return nil, fmt.Errorf("empty response from plugin for %s", method)
	}
	if result[0] == 1 {
		return nil, &PluginError{Message: string(result[1:])}
	}
	return result[1:], nil
}

// =============================================================================
// Streaming Support
// =============================================================================

// ensureStreamFuncs loads the global stream functions if not already loaded.
// Must be called with p.mu held for writing.
func (p *Plugin) ensureStreamFuncs() error {
	if p.streamFuncs != nil {
		return nil
	}

	sendPtr, _ := platformSym(p.handle, "Synurang_Stream_Send")
	recvPtr, _ := platformSym(p.handle, "Synurang_Stream_Recv")
	closeSendPtr, _ := platformSym(p.handle, "Synurang_Stream_CloseSend")
	closePtr, _ := platformSym(p.handle, "Synurang_Stream_Close")

	if sendPtr == 0 || recvPtr == 0 || closeSendPtr == 0 || closePtr == 0 {
		return fmt.Errorf("incomplete streaming support in plugin")
	}

	p.streamFuncs = &globalStreamFuncs{
		send:      sendPtr,
		recv:      recvPtr,
		closeSend: closeSendPtr,
		close:     closePtr,
	}
	return nil
}

// getStreamOpener returns the stream open function for a service, caching it.
func (p *Plugin) getStreamOpener(serviceName string) (uintptr, error) {
	p.mu.RLock()
	if ptr, ok := p.streamOpeners[serviceName]; ok {
		p.mu.RUnlock()
		return ptr, nil
	}
	p.mu.RUnlock()

	p.mu.Lock()
	defer p.mu.Unlock()

	if p.closed || p.handle == 0 {
		return 0, ErrPluginClosed
	}
	if ptr, ok := p.streamOpeners[serviceName]; ok {
		return ptr, nil
	}

	// Ensure global stream functions are loaded
	if err := p.ensureStreamFuncs(); err != nil {
		return 0, err
	}

	symName := "Synurang_Stream_" + serviceName + "_Open"
	openPtr, err := platformSym(p.handle, symName)
	if err != nil || openPtr == 0 {
		return 0, fmt.Errorf("streaming not supported for service %s (missing %s)", serviceName, symName)
	}

	p.streamOpeners[serviceName] = openPtr
	return openPtr, nil
}

// OpenStream opens a streaming RPC to the plugin.
func (p *Plugin) OpenStream(serviceName, method string) (*PluginStream, error) {
	p.mu.RLock()
	if p.closed {
		p.mu.RUnlock()
		return nil, ErrPluginClosed
	}
	p.wg.Add(1)
	p.mu.RUnlock()
	defer p.wg.Done()

	openPtr, err := p.getStreamOpener(serviceName)
	if err != nil {
		return nil, err
	}

	handle := platformStreamOpen(openPtr, method)
	if handle == 0 {
		return nil, fmt.Errorf("failed to open stream for %s", method)
	}

	// Track active stream
	p.mu.Lock()
	// Double-check if plugin was closed while we were opening the stream
	if p.closed {
		p.mu.Unlock()
		// Close the just-opened stream to prevent resource leak
		p.wg.Add(1)
		platformStreamClose(p.streamFuncs.close, handle)
		p.wg.Done()
		return nil, ErrPluginClosed
	}
	p.activeStreams[uintptr(handle)] = true
	p.mu.Unlock()

	return &PluginStream{
		plugin: p,
		handle: uintptr(handle),
	}, nil
}

// acquireForStreamOp prepares for a stream operation.
func (p *Plugin) acquireForStreamOp() error {
	p.mu.RLock()
	if p.closed {
		p.mu.RUnlock()
		return ErrPluginClosed
	}
	if p.streamFuncs == nil {
		p.mu.RUnlock()
		return fmt.Errorf("no stream functions available")
	}
	p.wg.Add(1)
	p.mu.RUnlock()
	return nil
}

// StreamSend sends data to a stream.
func (p *Plugin) StreamSend(handle uintptr, data []byte) error {
	if err := p.acquireForStreamOp(); err != nil {
		return err
	}
	defer p.wg.Done()

	if len(data) > math.MaxInt32 {
		return ErrDataTooLarge
	}

	result := platformStreamSend(p.streamFuncs.send, uint64(handle), data)
	if result != 0 {
		return fmt.Errorf("stream send failed with code %d", result)
	}
	return nil
}

// StreamRecv receives data from a stream.
// Returns io.EOF when stream is complete.
func (p *Plugin) StreamRecv(handle uintptr) ([]byte, error) {
	if err := p.acquireForStreamOp(); err != nil {
		return nil, err
	}
	defer p.wg.Done()

	data, respLen, status := platformStreamRecv(p.streamFuncs.recv, p.freePtr, uint64(handle))

	switch status {
	case 0: // data
		if len(data) == 0 {
			return nil, fmt.Errorf("empty stream response")
		}
		if data[0] == 1 {
			return nil, &PluginError{Message: string(data[1:])}
		}
		return data[1:], nil
	case 1: // EOF
		return nil, io.EOF
	default: // error
		if respLen > 0 && len(data) > 0 {
			return nil, fmt.Errorf("stream error: %s", string(data))
		}
		return nil, fmt.Errorf("stream error with status %d", status)
	}
}

// StreamCloseSend closes the send side of a stream.
func (p *Plugin) StreamCloseSend(handle uintptr) error {
	if err := p.acquireForStreamOp(); err != nil {
		return err
	}
	defer p.wg.Done()

	platformStreamCloseSend(p.streamFuncs.closeSend, uint64(handle))
	return nil
}

// StreamClose closes a stream completely.
func (p *Plugin) StreamClose(handle uintptr) {
	p.mu.Lock()
	if p.closed || p.handle == 0 {
		p.mu.Unlock()
		return
	}
	if _, exists := p.activeStreams[handle]; !exists {
		p.mu.Unlock()
		return
	}
	delete(p.activeStreams, handle)
	sf := p.streamFuncs
	if sf != nil {
		p.wg.Add(1)
	}
	p.mu.Unlock()

	if sf != nil {
		defer p.wg.Done()
		platformStreamClose(sf.close, uint64(handle))
	}
}

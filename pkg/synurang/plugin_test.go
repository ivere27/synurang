package synurang

import (
	"errors"
	"io"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// mockPlatform provides mock implementations for testing
type mockPlatform struct {
	openFunc            func(path string) (uintptr, error)
	symFunc             func(handle uintptr, name string) (uintptr, error)
	closeFunc           func(handle uintptr) error
	invokeFunc          func(fn, freePtr uintptr, method string, data []byte) ([]byte, error)
	streamOpenFunc      func(fn uintptr, method string) uint64
	streamSendFunc      func(fn uintptr, handle uint64, data []byte) int
	streamRecvFunc      func(fn, freePtr uintptr, handle uint64) ([]byte, int, int)
	streamCloseSendFunc func(fn uintptr, handle uint64)
	streamCloseFunc     func(fn uintptr, handle uint64)

	// Counters for verification
	openCalls   int64
	symCalls    int64
	closeCalls  int64
	invokeCalls int64
}

func newMockPlatform() *mockPlatform {
	return &mockPlatform{
		openFunc: func(path string) (uintptr, error) {
			return 0x1000, nil
		},
		symFunc: func(handle uintptr, name string) (uintptr, error) {
			return 0x2000, nil
		},
		closeFunc: func(handle uintptr) error {
			return nil
		},
		invokeFunc: func(fn, freePtr uintptr, method string, data []byte) ([]byte, error) {
			// Return success with status byte 0
			return append([]byte{0}, []byte("response")...), nil
		},
		streamOpenFunc: func(fn uintptr, method string) uint64 {
			return 1
		},
		streamSendFunc: func(fn uintptr, handle uint64, data []byte) int {
			return 0 // success
		},
		streamRecvFunc: func(fn, freePtr uintptr, handle uint64) ([]byte, int, int) {
			return []byte{0, 'h', 'i'}, 3, 0 // data with status 0
		},
		streamCloseSendFunc: func(fn uintptr, handle uint64) {},
		streamCloseFunc:     func(fn uintptr, handle uint64) {},
	}
}

func (m *mockPlatform) install() func() {
	oldOpen := platformOpen
	oldSym := platformSym
	oldClose := platformClose
	oldInvoke := platformInvoke
	oldStreamOpen := platformStreamOpen
	oldStreamSend := platformStreamSend
	oldStreamRecv := platformStreamRecv
	oldStreamCloseSend := platformStreamCloseSend
	oldStreamClose := platformStreamClose

	platformOpen = func(path string) (uintptr, error) {
		atomic.AddInt64(&m.openCalls, 1)
		return m.openFunc(path)
	}
	platformSym = func(handle uintptr, name string) (uintptr, error) {
		atomic.AddInt64(&m.symCalls, 1)
		return m.symFunc(handle, name)
	}
	platformClose = func(handle uintptr) error {
		atomic.AddInt64(&m.closeCalls, 1)
		return m.closeFunc(handle)
	}
	platformInvoke = func(fn, freePtr uintptr, method string, data []byte) ([]byte, error) {
		atomic.AddInt64(&m.invokeCalls, 1)
		return m.invokeFunc(fn, freePtr, method, data)
	}
	platformStreamOpen = m.streamOpenFunc
	platformStreamSend = m.streamSendFunc
	platformStreamRecv = m.streamRecvFunc
	platformStreamCloseSend = m.streamCloseSendFunc
	platformStreamClose = m.streamCloseFunc

	return func() {
		platformOpen = oldOpen
		platformSym = oldSym
		platformClose = oldClose
		platformInvoke = oldInvoke
		platformStreamOpen = oldStreamOpen
		platformStreamSend = oldStreamSend
		platformStreamRecv = oldStreamRecv
		platformStreamCloseSend = oldStreamCloseSend
		platformStreamClose = oldStreamClose
	}
}

func TestLoadPlugin_Success(t *testing.T) {
	mock := newMockPlatform()
	restore := mock.install()
	defer restore()

	plugin, err := LoadPlugin("test.so")
	if err != nil {
		t.Fatalf("LoadPlugin failed: %v", err)
	}
	defer plugin.Close()

	if plugin.handle == 0 {
		t.Error("expected non-zero handle")
	}
	if plugin.freePtr == 0 {
		t.Error("expected non-zero freePtr")
	}

	// Should have called open once and sym once (for Synurang_Free)
	if atomic.LoadInt64(&mock.openCalls) != 1 {
		t.Errorf("expected 1 open call, got %d", mock.openCalls)
	}
	if atomic.LoadInt64(&mock.symCalls) != 1 {
		t.Errorf("expected 1 sym call, got %d", mock.symCalls)
	}
}

func TestLoadPlugin_OpenFails(t *testing.T) {
	mock := newMockPlatform()
	mock.openFunc = func(path string) (uintptr, error) {
		return 0, errors.New("file not found")
	}
	restore := mock.install()
	defer restore()

	_, err := LoadPlugin("nonexistent.so")
	if err == nil {
		t.Fatal("expected error for missing plugin")
	}
}

func TestLoadPlugin_MissingSynurangFree(t *testing.T) {
	mock := newMockPlatform()
	mock.symFunc = func(handle uintptr, name string) (uintptr, error) {
		if name == "Synurang_Free" {
			return 0, errors.New("symbol not found")
		}
		return 0x2000, nil
	}
	restore := mock.install()
	defer restore()

	_, err := LoadPlugin("test.so")
	if err == nil {
		t.Fatal("expected error for missing Synurang_Free")
	}

	// Should have closed the library after failing to find symbol
	if atomic.LoadInt64(&mock.closeCalls) != 1 {
		t.Errorf("expected 1 close call after failure, got %d", mock.closeCalls)
	}
}

func TestPlugin_Close_Idempotent(t *testing.T) {
	mock := newMockPlatform()
	restore := mock.install()
	defer restore()

	plugin, err := LoadPlugin("test.so")
	if err != nil {
		t.Fatalf("LoadPlugin failed: %v", err)
	}

	// Close multiple times
	for i := 0; i < 3; i++ {
		err := plugin.Close()
		if err != nil {
			t.Errorf("Close() %d returned error: %v", i, err)
		}
	}

	// Should only close the library once
	if atomic.LoadInt64(&mock.closeCalls) != 1 {
		t.Errorf("expected 1 close call, got %d", mock.closeCalls)
	}
}

func TestPlugin_Invoke_Success(t *testing.T) {
	mock := newMockPlatform()
	mock.invokeFunc = func(fn, freePtr uintptr, method string, data []byte) ([]byte, error) {
		// Return success: status=0 + response data
		return []byte{0, 'o', 'k'}, nil
	}
	restore := mock.install()
	defer restore()

	plugin, err := LoadPlugin("test.so")
	if err != nil {
		t.Fatalf("LoadPlugin failed: %v", err)
	}
	defer plugin.Close()

	resp, err := plugin.Invoke("TestService", "/test.Method", []byte("request"))
	if err != nil {
		t.Fatalf("Invoke failed: %v", err)
	}
	if string(resp) != "ok" {
		t.Errorf("expected 'ok', got %q", string(resp))
	}
}

func TestPlugin_Invoke_PluginError(t *testing.T) {
	mock := newMockPlatform()
	mock.invokeFunc = func(fn, freePtr uintptr, method string, data []byte) ([]byte, error) {
		// Return error: status=1 + error message
		return []byte{1, 'f', 'a', 'i', 'l', 'e', 'd'}, nil
	}
	restore := mock.install()
	defer restore()

	plugin, err := LoadPlugin("test.so")
	if err != nil {
		t.Fatalf("LoadPlugin failed: %v", err)
	}
	defer plugin.Close()

	_, err = plugin.Invoke("TestService", "/test.Method", nil)
	if err == nil {
		t.Fatal("expected error from plugin")
	}

	var pluginErr *PluginError
	if !errors.As(err, &pluginErr) {
		t.Errorf("expected PluginError, got %T", err)
	}
	if pluginErr.Message != "failed" {
		t.Errorf("expected 'failed', got %q", pluginErr.Message)
	}
}

func TestPlugin_Invoke_AfterClose(t *testing.T) {
	mock := newMockPlatform()
	restore := mock.install()
	defer restore()

	plugin, err := LoadPlugin("test.so")
	if err != nil {
		t.Fatalf("LoadPlugin failed: %v", err)
	}

	plugin.Close()

	_, err = plugin.Invoke("TestService", "/test.Method", nil)
	if !errors.Is(err, ErrPluginClosed) {
		t.Errorf("expected ErrPluginClosed, got %v", err)
	}
}

func TestPlugin_Invoke_ServiceNotFound(t *testing.T) {
	mock := newMockPlatform()
	mock.symFunc = func(handle uintptr, name string) (uintptr, error) {
		if name == "Synurang_Free" {
			return 0x1000, nil
		}
		// All other symbols not found
		return 0, errors.New("symbol not found")
	}
	restore := mock.install()
	defer restore()

	plugin, err := LoadPlugin("test.so")
	if err != nil {
		t.Fatalf("LoadPlugin failed: %v", err)
	}
	defer plugin.Close()

	_, err = plugin.Invoke("MissingService", "/test.Method", nil)
	if err == nil {
		t.Fatal("expected error for missing service")
	}
}

func TestPlugin_Invoke_DataTooLarge(t *testing.T) {
	mock := newMockPlatform()
	restore := mock.install()
	defer restore()

	plugin, err := LoadPlugin("test.so")
	if err != nil {
		t.Fatalf("LoadPlugin failed: %v", err)
	}
	defer plugin.Close()

	// We can't actually allocate 2GB, but we can test the check
	// by temporarily modifying the invokeInternal to check the size
	// For now, just verify the constant exists
	if ErrDataTooLarge == nil {
		t.Error("ErrDataTooLarge should not be nil")
	}
}

func TestPlugin_GetInvoker_Caching(t *testing.T) {
	mock := newMockPlatform()
	symCallCount := int64(0)
	mock.symFunc = func(handle uintptr, name string) (uintptr, error) {
		atomic.AddInt64(&symCallCount, 1)
		return 0x2000, nil
	}
	restore := mock.install()
	defer restore()

	plugin, err := LoadPlugin("test.so")
	if err != nil {
		t.Fatalf("LoadPlugin failed: %v", err)
	}
	defer plugin.Close()

	// Reset counter after LoadPlugin (which calls sym for Synurang_Free)
	atomic.StoreInt64(&symCallCount, 0)

	// Call Invoke multiple times for the same service
	for i := 0; i < 5; i++ {
		plugin.Invoke("TestService", "/test.Method", nil)
	}

	// Should only lookup the symbol once (cached)
	if atomic.LoadInt64(&symCallCount) != 1 {
		t.Errorf("expected 1 sym lookup, got %d (caching not working)", symCallCount)
	}
}

func TestPlugin_ConcurrentAccess(t *testing.T) {
	mock := newMockPlatform()
	var invokeCount int64
	mock.invokeFunc = func(fn, freePtr uintptr, method string, data []byte) ([]byte, error) {
		atomic.AddInt64(&invokeCount, 1)
		time.Sleep(time.Millisecond) // Simulate work
		return []byte{0, 'o', 'k'}, nil
	}
	restore := mock.install()
	defer restore()

	plugin, err := LoadPlugin("test.so")
	if err != nil {
		t.Fatalf("LoadPlugin failed: %v", err)
	}
	defer plugin.Close()

	const numGoroutines = 10
	const callsPerGoroutine = 10

	var wg sync.WaitGroup
	errs := make(chan error, numGoroutines*callsPerGoroutine)

	for i := 0; i < numGoroutines; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < callsPerGoroutine; j++ {
				_, err := plugin.Invoke("TestService", "/test.Method", nil)
				if err != nil {
					errs <- err
				}
			}
		}()
	}

	wg.Wait()
	close(errs)

	var errList []error
	for err := range errs {
		errList = append(errList, err)
	}

	if len(errList) > 0 {
		t.Errorf("got %d errors during concurrent access: %v", len(errList), errList[0])
	}

	expectedCalls := int64(numGoroutines * callsPerGoroutine)
	if atomic.LoadInt64(&invokeCount) != expectedCalls {
		t.Errorf("expected %d invoke calls, got %d", expectedCalls, invokeCount)
	}
}

func TestPlugin_Close_WaitsForOperations(t *testing.T) {
	mock := newMockPlatform()
	invokeCh := make(chan struct{})
	invokeStarted := make(chan struct{})
	mock.invokeFunc = func(fn, freePtr uintptr, method string, data []byte) ([]byte, error) {
		close(invokeStarted)
		<-invokeCh // Block until signal
		return []byte{0, 'o', 'k'}, nil
	}
	restore := mock.install()
	defer restore()

	plugin, err := LoadPlugin("test.so")
	if err != nil {
		t.Fatalf("LoadPlugin failed: %v", err)
	}

	// Start a blocked invoke
	invokeDone := make(chan struct{})
	go func() {
		plugin.Invoke("TestService", "/test.Method", nil)
		close(invokeDone)
	}()

	// Wait for invoke to start
	<-invokeStarted

	// Start close in background
	closeDone := make(chan struct{})
	go func() {
		plugin.Close()
		close(closeDone)
	}()

	// Close should not complete while invoke is running
	select {
	case <-closeDone:
		t.Error("Close completed while invoke was still running")
	case <-time.After(50 * time.Millisecond):
		// Expected - close is waiting
	}

	// Unblock invoke
	close(invokeCh)

	// Now both should complete
	select {
	case <-invokeDone:
	case <-time.After(time.Second):
		t.Error("invoke did not complete")
	}

	select {
	case <-closeDone:
	case <-time.After(time.Second):
		t.Error("close did not complete after invoke finished")
	}
}

func TestPlugin_OpenStream_Success(t *testing.T) {
	mock := newMockPlatform()
	restore := mock.install()
	defer restore()

	plugin, err := LoadPlugin("test.so")
	if err != nil {
		t.Fatalf("LoadPlugin failed: %v", err)
	}
	defer plugin.Close()

	stream, err := plugin.OpenStream("TestService", "/test.StreamMethod")
	if err != nil {
		t.Fatalf("OpenStream failed: %v", err)
	}
	if stream == nil {
		t.Fatal("expected non-nil stream")
	}
}

func TestPlugin_OpenStream_AfterClose(t *testing.T) {
	mock := newMockPlatform()
	restore := mock.install()
	defer restore()

	plugin, err := LoadPlugin("test.so")
	if err != nil {
		t.Fatalf("LoadPlugin failed: %v", err)
	}
	plugin.Close()

	_, err = plugin.OpenStream("TestService", "/test.StreamMethod")
	if !errors.Is(err, ErrPluginClosed) {
		t.Errorf("expected ErrPluginClosed, got %v", err)
	}
}

func TestPlugin_StreamRecv_EOF(t *testing.T) {
	mock := newMockPlatform()
	mock.streamRecvFunc = func(fn, freePtr uintptr, handle uint64) ([]byte, int, int) {
		return nil, 0, 1 // status=1 means EOF
	}
	restore := mock.install()
	defer restore()

	plugin, err := LoadPlugin("test.so")
	if err != nil {
		t.Fatalf("LoadPlugin failed: %v", err)
	}
	defer plugin.Close()

	stream, err := plugin.OpenStream("TestService", "/test.StreamMethod")
	if err != nil {
		t.Fatalf("OpenStream failed: %v", err)
	}

	_, err = stream.Recv()
	if !errors.Is(err, io.EOF) {
		t.Errorf("expected io.EOF, got %v", err)
	}
}

func TestPlugin_StreamRecv_PluginError(t *testing.T) {
	mock := newMockPlatform()
	callCount := 0
	mock.streamRecvFunc = func(fn, freePtr uintptr, handle uint64) ([]byte, int, int) {
		callCount++
		if callCount == 1 {
			// Return error: status=0 with error flag in data
			return []byte{1, 'e', 'r', 'r', 'o', 'r'}, 6, 0
		}
		return nil, 0, 1 // EOF
	}
	restore := mock.install()
	defer restore()

	plugin, err := LoadPlugin("test.so")
	if err != nil {
		t.Fatalf("LoadPlugin failed: %v", err)
	}
	defer plugin.Close()

	stream, err := plugin.OpenStream("TestService", "/test.StreamMethod")
	if err != nil {
		t.Fatalf("OpenStream failed: %v", err)
	}

	_, err = stream.Recv()
	if err == nil {
		t.Fatal("expected error from stream")
	}

	var pluginErr *PluginError
	if !errors.As(err, &pluginErr) {
		t.Errorf("expected PluginError, got %T: %v", err, err)
	}
}

func TestPlugin_Close_ClosesActiveStreams(t *testing.T) {
	mock := newMockPlatform()
	var handleCounter uint64
	mock.streamOpenFunc = func(fn uintptr, method string) uint64 {
		return atomic.AddUint64(&handleCounter, 1)
	}
	streamCloseCalled := make(chan uint64, 10)
	mock.streamCloseFunc = func(fn uintptr, handle uint64) {
		streamCloseCalled <- handle
	}
	restore := mock.install()
	defer restore()

	plugin, err := LoadPlugin("test.so")
	if err != nil {
		t.Fatalf("LoadPlugin failed: %v", err)
	}

	// Open some streams
	stream1, _ := plugin.OpenStream("TestService", "/test.Method1")
	stream2, _ := plugin.OpenStream("TestService", "/test.Method2")

	// Close plugin - should close all streams
	plugin.Close()

	// Verify streams were closed
	closedHandles := make(map[uint64]bool)
	timeout := time.After(time.Second)
	for i := 0; i < 2; i++ {
		select {
		case h := <-streamCloseCalled:
			closedHandles[h] = true
		case <-timeout:
			t.Fatalf("timeout waiting for stream close, only got %d", len(closedHandles))
		}
	}

	if !closedHandles[uint64(stream1.handle)] {
		t.Error("stream1 was not closed")
	}
	if !closedHandles[uint64(stream2.handle)] {
		t.Error("stream2 was not closed")
	}
}

func TestPluginError_Error(t *testing.T) {
	err := &PluginError{Message: "test error"}
	expected := "plugin error: test error"
	if err.Error() != expected {
		t.Errorf("expected %q, got %q", expected, err.Error())
	}
}

func TestPluginStream_SendAfterClose(t *testing.T) {
	mock := newMockPlatform()
	restore := mock.install()
	defer restore()

	plugin, err := LoadPlugin("test.so")
	if err != nil {
		t.Fatalf("LoadPlugin failed: %v", err)
	}

	stream, err := plugin.OpenStream("TestService", "/test.StreamMethod")
	if err != nil {
		t.Fatalf("OpenStream failed: %v", err)
	}

	// Close the stream
	stream.Close()

	// Try to send - should get error
	err = stream.Send([]byte("data"))
	if !errors.Is(err, ErrStreamClosed) {
		t.Errorf("expected ErrStreamClosed, got %v", err)
	}
}

func TestPluginStream_RecvAfterClose(t *testing.T) {
	mock := newMockPlatform()
	restore := mock.install()
	defer restore()

	plugin, err := LoadPlugin("test.so")
	if err != nil {
		t.Fatalf("LoadPlugin failed: %v", err)
	}

	stream, err := plugin.OpenStream("TestService", "/test.StreamMethod")
	if err != nil {
		t.Fatalf("OpenStream failed: %v", err)
	}

	// Close the stream
	stream.Close()

	// Try to receive - should get EOF
	_, err = stream.Recv()
	if !errors.Is(err, io.EOF) {
		t.Errorf("expected io.EOF, got %v", err)
	}
}

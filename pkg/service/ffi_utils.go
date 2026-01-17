package service

import (
	"fmt"
	"log"
	"sync"
	"sync/atomic"
	"time"
)

// =============================================================================
// Async Request Handler
// Manages pending requests for Go -> Dart async calls
// =============================================================================

// RequestHandler manages async request/response patterns for FFI calls
type RequestHandler struct {
	pending   map[int64]chan []byte
	pendingMu sync.Mutex
	nextId    int64
	timeout   time.Duration
}

// NewRequestHandler creates a new RequestHandler
func NewRequestHandler(timeout time.Duration) *RequestHandler {
	return &RequestHandler{
		pending: make(map[int64]chan []byte),
		timeout: timeout,
	}
}

// DefaultRequestHandler is a shared instance with 10 second timeout
var DefaultRequestHandler = NewRequestHandler(10 * time.Second)

// CreateRequest creates a new pending request and returns its ID and channel
func (h *RequestHandler) CreateRequest() (int64, chan []byte) {
	requestId := atomic.AddInt64(&h.nextId, 1)
	ch := make(chan []byte, 1)

	h.pendingMu.Lock()
	h.pending[requestId] = ch
	h.pendingMu.Unlock()

	return requestId, ch
}

// WaitForResponse waits for a response with timeout
func (h *RequestHandler) WaitForResponse(requestId int64, ch chan []byte) ([]byte, error) {
	timer := time.NewTimer(h.timeout)
	select {
	case resp := <-ch:
		timer.Stop()
		return resp, nil
	case <-timer.C:
		h.pendingMu.Lock()
		delete(h.pending, requestId)
		h.pendingMu.Unlock()
		return nil, fmt.Errorf("timeout waiting for Dart response")
	}
}

// HandleResponse handles an incoming response for a request ID
func (h *RequestHandler) HandleResponse(requestId int64, data []byte) {
	h.pendingMu.Lock()
	ch, ok := h.pending[requestId]
	if ok {
		delete(h.pending, requestId)
	}
	h.pendingMu.Unlock()

	if ok {
		ch <- data
	} else {
		log.Printf("Warning: Received response for unknown request ID: %d", requestId)
	}
}

// CleanupPending clears all pending requests (for hot-reload cleanup)
func (h *RequestHandler) CleanupPending() {
	h.pendingMu.Lock()
	for id, ch := range h.pending {
		select {
		case ch <- nil:
		default:
		}
		delete(h.pending, id)
	}
	h.pendingMu.Unlock()
}

// =============================================================================
// Dart Callback Manager
// Manages the Go -> Dart callback function
// =============================================================================

// DartCallbackFunc is the function signature for invoking Dart from Go
type DartCallbackFunc func(method string, data []byte) ([]byte, error)

// DartCallbackManager manages the Dart callback registration
type DartCallbackManager struct {
	callback DartCallbackFunc
	mu       sync.RWMutex
}

// NewDartCallbackManager creates a new DartCallbackManager
func NewDartCallbackManager() *DartCallbackManager {
	return &DartCallbackManager{}
}

// DefaultDartCallbackManager is a shared instance
var DefaultDartCallbackManager = NewDartCallbackManager()

// SetCallback sets the Dart callback function
func (m *DartCallbackManager) SetCallback(cb DartCallbackFunc) {
	m.mu.Lock()
	m.callback = cb
	m.mu.Unlock()
}

// GetCallback returns the current Dart callback function
func (m *DartCallbackManager) GetCallback() DartCallbackFunc {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.callback
}

// Invoke invokes the Dart callback
func (m *DartCallbackManager) Invoke(method string, data []byte) ([]byte, error) {
	m.mu.RLock()
	cb := m.callback
	m.mu.RUnlock()

	if cb == nil {
		return nil, fmt.Errorf("dart callback is nil")
	}
	return cb(method, data)
}

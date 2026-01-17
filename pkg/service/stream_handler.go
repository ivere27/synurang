// Package service provides FFI stream session management for Go/Dart communication.
//
// Stream Chunk Ordering:
// Each StreamSession has its own DataChan (buffered channel) that maintains FIFO order.
// Chunks sent to a session are processed sequentially by the handler goroutine.
//
// IMPORTANT: Each stream session must be used by exactly ONE Dart isolate.
// Sharing a session ID across multiple isolates will cause ordering issues.
package service

/*
#include <stdlib.h>
*/
import "C"

import (
	"fmt"
	"log"
	"sync"
	"sync/atomic"
	"time"
	"unsafe"

	"google.golang.org/protobuf/proto"
)

// Stream message types for FFI protocol
const (
	StreamMsgStart   = 0x01 // Stream started
	StreamMsgData    = 0x02 // Stream data chunk
	StreamMsgEnd     = 0x03 // Stream ended normally
	StreamMsgError   = 0x04 // Stream error
	StreamMsgTrailer = 0x05 // Stream trailers (metadata at end)
	StreamMsgHeader  = 0x06 // Stream headers (metadata before data)
)

// StreamSession represents an active streaming RPC session
type StreamSession struct {
	ID          int64
	Method      string
	Type        StreamType
	DataChan    chan []byte       // For client streaming: receives data from Dart
	DoneChan    chan struct{}     // Signals stream completion
	ReadyChan   chan struct{}     // Signals Dart is ready to receive (for server/bidi streams)
	ErrorChan   chan error        // Signals stream error
	Callback    StreamCallback    // For server streaming: sends data to Dart (1 copy)
	CallbackFfi StreamCallbackFfi // For server streaming: zero-copy variant
	Metadata    map[string]string // Request metadata from Dart
	headers     map[string]string
	headersSent bool
	trailers    map[string]string
	mu          sync.Mutex
	closed      bool
	inputClosed bool
}

// StreamType indicates the type of streaming RPC
type StreamType int

const (
	StreamTypeServerStream StreamType = iota // Go sends multiple responses
	StreamTypeClientStream                   // Dart sends multiple requests
	StreamTypeBidiStream                     // Both sides stream
)

// StreamCallback is called to send stream data back to Dart via FFI (1 copy)
type StreamCallback func(streamId int64, msgType byte, data []byte)

// StreamCallbackFfi is the zero-copy variant - receives C pointer directly
type StreamCallbackFfi func(streamId int64, msgType byte, data unsafe.Pointer, len int64)

var (
	streamSessions       = make(map[int64]*StreamSession)
	streamSessionsMu     sync.RWMutex
	nextStreamId         int64
	streamCallback       StreamCallback
	streamCallbackFfi    StreamCallbackFfi
	defaultStreamTimeout time.Duration
)

// SetStreamCallback registers the callback for sending stream data to Dart (1 copy)
func SetStreamCallback(cb StreamCallback) {
	streamCallback = cb
}

// SetStreamCallbackFfi registers the zero-copy callback for FFI mode
func SetStreamCallbackFfi(cb StreamCallbackFfi) {
	streamCallbackFfi = cb
}

// SetDefaultStreamTimeout sets the global timeout for stream readiness
func SetDefaultStreamTimeout(d time.Duration) {
	defaultStreamTimeout = d
}

func (s StreamType) String() string {
	switch s {
	case StreamTypeServerStream:
		return "ServerStream"
	case StreamTypeClientStream:
		return "ClientStream"
	case StreamTypeBidiStream:
		return "BidiStream"
	default:
		return fmt.Sprintf("Unknown(%d)", int(s))
	}
}

// NewStreamSession creates a new stream session
func NewStreamSession(method string, streamType StreamType) *StreamSession {
	session := &StreamSession{
		ID:          atomic.AddInt64(&nextStreamId, 1),
		Method:      method,
		Type:        streamType,
		DataChan:    make(chan []byte, 100),
		DoneChan:    make(chan struct{}),
		ReadyChan:   make(chan struct{}), // For server/bidi streams: wait for Dart to be ready
		ErrorChan:   make(chan error, 1),
		Callback:    streamCallback,
		CallbackFfi: streamCallbackFfi,
	}

	streamSessionsMu.Lock()
	streamSessions[session.ID] = session
	streamSessionsMu.Unlock()

	log.Printf("Created stream session %d for %s (type=%s)", session.ID, method, streamType)
	return session
}

// GetStreamSession retrieves an existing stream session
func GetStreamSession(streamId int64) *StreamSession {
	streamSessionsMu.RLock()
	defer streamSessionsMu.RUnlock()
	return streamSessions[streamId]
}

// CloseStreamSession closes and removes a stream session
func CloseStreamSession(streamId int64) {
	streamSessionsMu.Lock()
	session, ok := streamSessions[streamId]
	if ok {
		delete(streamSessions, streamId)
	}
	streamSessionsMu.Unlock()

	if ok && session != nil {
		session.mu.Lock()
		if !session.closed {
			session.closed = true
			close(session.DoneChan)
			// Also ensure DataChan is closed so readers don't block forever
			if !session.inputClosed {
				session.inputClosed = true
				close(session.DataChan)
			}
		}
		session.mu.Unlock()
		log.Printf("Closed stream session %d", streamId)
	}
}

// CloseStreamInput signals that the client has finished sending data
func CloseStreamInput(streamId int64) {
	session := GetStreamSession(streamId)
	if session == nil {
		return
	}

	session.mu.Lock()
	defer session.mu.Unlock()

	if !session.closed && !session.inputClosed {
		session.inputClosed = true
		close(session.DataChan)
		log.Printf("Closed input for stream session %d", streamId)
	}
}

// SendToStream sends data to a client/bidi stream session (from Dart to Go)
func SendToStream(streamId int64, data []byte) error {
	session := GetStreamSession(streamId)
	if session == nil {
		return fmt.Errorf("stream session %d not found", streamId)
	}

	session.mu.Lock()
	if session.inputClosed {
		session.mu.Unlock()
		return fmt.Errorf("stream %d input is closed", streamId)
	}
	session.mu.Unlock()

	select {
	case session.DataChan <- data:
		return nil
	case <-session.DoneChan:
		return fmt.Errorf("stream %d is closed", streamId)
	}
}

// SignalStreamReady signals that Dart has registered the stream controller
// and is ready to receive data. This is called by Dart after registering.
func SignalStreamReady(streamId int64) {
	session := GetStreamSession(streamId)
	if session == nil {
		log.Printf("SignalStreamReady: session %d not found", streamId)
		return
	}

	session.mu.Lock()
	defer session.mu.Unlock()

	select {
	case <-session.ReadyChan:
		// Already signaled
	default:
		close(session.ReadyChan)
		log.Printf("Stream %d ready signal received", streamId)
	}
}

// WaitForReady waits for the ready signal from Dart (with timeout).
// If defaultStreamTimeout is 0, waits indefinitely.
func (s *StreamSession) WaitForReady() bool {
	// When timeout is 0, wait indefinitely (no timeout case in select)
	if defaultStreamTimeout == 0 {
		select {
		case <-s.ReadyChan:
			return true
		case <-s.DoneChan:
			return false
		}
	}

	// With timeout configured
	select {
	case <-s.ReadyChan:
		return true
	case <-s.DoneChan:
		return false
	case <-time.After(defaultStreamTimeout):
		log.Printf("Stream %d: timeout waiting for ready signal", s.ID)
		return false
	}
}

// SendFromStream sends data from Go to Dart (server/bidi streaming)
// This is the simple variant that takes []byte (1 copy at FFI boundary).
func (s *StreamSession) SendFromStream(data []byte) error {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return fmt.Errorf("stream %d is closed", s.ID)
	}
	cb := s.Callback
	s.mu.Unlock()

	if cb != nil {
		cb(s.ID, StreamMsgData, data)
	}
	return nil
}

// SendFromStreamFfi sends a proto message from Go to Dart (zero-copy).
// It serializes the message directly into C memory, avoiding extra copies.
// Falls back to SendFromStream if FFI callback is not registered.
func (s *StreamSession) SendFromStreamFfi(msg proto.Message) error {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return fmt.Errorf("stream %d is closed", s.ID)
	}
	cbFfi := s.CallbackFfi
	cb := s.Callback
	s.mu.Unlock()

	// Zero-copy path: serialize directly into C memory
	if cbFfi != nil {
		size := proto.Size(msg)
		if size == 0 {
			cbFfi(s.ID, StreamMsgData, nil, 0)
			return nil
		}
		cPtr := C.malloc(C.size_t(size))
		if cPtr == nil {
			return fmt.Errorf("failed to allocate C memory for stream data")
		}
		buf := unsafe.Slice((*byte)(cPtr), size)
		if _, err := (proto.MarshalOptions{}).MarshalAppend(buf[:0], msg); err != nil {
			C.free(cPtr)
			return fmt.Errorf("failed to marshal stream data: %w", err)
		}
		cbFfi(s.ID, StreamMsgData, cPtr, int64(size))
		return nil
	}

	// Fallback to regular callback with 1 copy
	if cb != nil {
		data, err := proto.Marshal(msg)
		if err != nil {
			return fmt.Errorf("failed to marshal stream data: %w", err)
		}
		cb(s.ID, StreamMsgData, data)
	}
	return nil
}

// CloseSend signals to Dart that we have finished sending data (EOF),
// but keeps the session open for receiving data.
func (s *StreamSession) CloseSend() error {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return fmt.Errorf("stream %d is closed", s.ID)
	}
	cb := s.Callback
	s.mu.Unlock()

	if cb != nil {
		cb(s.ID, StreamMsgEnd, nil)
	}
	return nil
}

// SetHeader sets a header key-value pair to be sent before data.
func (s *StreamSession) SetHeader(key, value string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.headers == nil {
		s.headers = make(map[string]string)
	}
	s.headers[key] = value
}

// SendHeader sends all headers to Dart via callback.
// Headers are sent before the first data chunk. Can only be called once.
// Encoded as "key=value\n" pairs (same format as trailers).
func (s *StreamSession) SendHeader() error {
	s.mu.Lock()
	if s.headersSent {
		s.mu.Unlock()
		return nil // Already sent
	}
	s.headersSent = true
	cb := s.Callback
	headers := s.headers
	s.mu.Unlock()

	if len(headers) > 0 && cb != nil {
		var data []byte
		for k, v := range headers {
			data = append(data, []byte(k+"="+v+"\n")...)
		}
		cb(s.ID, StreamMsgHeader, data)
	}
	return nil
}

// SetTrailer sets a trailer key-value pair to be sent when the stream ends.
func (s *StreamSession) SetTrailer(key, value string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.trailers == nil {
		s.trailers = make(map[string]string)
	}
	s.trailers[key] = value
}

// sendTrailers sends all trailers to Dart via callback.
// Trailers are encoded as "key=value\n" pairs.
func (s *StreamSession) sendTrailers(cb StreamCallback) {
	if len(s.trailers) == 0 || cb == nil {
		return
	}
	var data []byte
	for k, v := range s.trailers {
		data = append(data, []byte(k+"="+v+"\n")...)
	}
	cb(s.ID, StreamMsgTrailer, data)
}

// EndStream signals end of stream from Go side.
// Sends trailers (if any) before closing.
func (s *StreamSession) EndStream() {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return
	}
	s.closed = true
	if !s.inputClosed {
		s.inputClosed = true
		close(s.DataChan)
	}
	cb := s.Callback
	trailers := s.trailers
	s.mu.Unlock()

	// Send trailers before end signal
	if len(trailers) > 0 && cb != nil {
		var data []byte
		for k, v := range trailers {
			data = append(data, []byte(k+"="+v+"\n")...)
		}
		cb(s.ID, StreamMsgTrailer, data)
	}

	if cb != nil {
		cb(s.ID, StreamMsgEnd, nil)
	}
	close(s.DoneChan)
}

// ErrorStream signals an error on the stream
func (s *StreamSession) ErrorStream(err error) {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return
	}
	s.closed = true
	// Ensure input is closed too
	if !s.inputClosed {
		s.inputClosed = true
		close(s.DataChan)
	}
	cb := s.Callback
	s.mu.Unlock()

	if cb != nil {
		cb(s.ID, StreamMsgError, []byte(err.Error()))
	}
	close(s.DoneChan)
}

// =============================================================================
// Generic Streaming Handlers
// =============================================================================

// HandlerFunc is the function that handles the stream logic
type HandlerFunc func(session *StreamSession)

// StartServerStream starts a server streaming RPC
func StartServerStream(method string, handler HandlerFunc) int64 {
	session := NewStreamSession(method, StreamTypeServerStream)
	go func() {
		defer CloseStreamSession(session.ID)
		handler(session)
	}()
	return session.ID
}

// StartClientStream starts a client streaming RPC
func StartClientStream(method string, handler HandlerFunc) int64 {
	session := NewStreamSession(method, StreamTypeClientStream)
	go func() {
		defer CloseStreamSession(session.ID)
		handler(session)
	}()
	return session.ID
}

// StartBidiStream starts a bidirectional streaming RPC
func StartBidiStream(method string, handler HandlerFunc) int64 {
	session := NewStreamSession(method, StreamTypeBidiStream)
	go func() {
		defer CloseStreamSession(session.ID)
		handler(session)
	}()
	return session.ID
}

// =============================================================================
// Stream Handler Registry (Allows external handler registration)
// =============================================================================

// ServerStreamHandler handles server streaming RPCs
type ServerStreamHandler func(data []byte) HandlerFunc

// ClientStreamHandler handles client streaming RPCs (no initial data)
type ClientStreamHandler func() HandlerFunc

// BidiStreamHandler handles bidirectional streaming RPCs (no initial data)
type BidiStreamHandler func() HandlerFunc

var (
	serverStreamHandlers    = make(map[string]ServerStreamHandler)
	clientStreamHandlers    = make(map[string]ClientStreamHandler)
	bidiStreamHandlers      = make(map[string]BidiStreamHandler)
	streamHandlerRegistryMu sync.RWMutex
)

// RegisterServerStreamHandler registers a handler for a server streaming method.
// This should be called during initialization, typically in init() or test setup.
func RegisterServerStreamHandler(method string, handler ServerStreamHandler) {
	streamHandlerRegistryMu.Lock()
	defer streamHandlerRegistryMu.Unlock()
	serverStreamHandlers[method] = handler
	log.Printf("Registered server stream handler for: %s", method)
}

// RegisterClientStreamHandler registers a handler for a client streaming method.
func RegisterClientStreamHandler(method string, handler ClientStreamHandler) {
	streamHandlerRegistryMu.Lock()
	defer streamHandlerRegistryMu.Unlock()
	clientStreamHandlers[method] = handler
	log.Printf("Registered client stream handler for: %s", method)
}

// RegisterBidiStreamHandler registers a handler for a bidirectional streaming method.
func RegisterBidiStreamHandler(method string, handler BidiStreamHandler) {
	streamHandlerRegistryMu.Lock()
	defer streamHandlerRegistryMu.Unlock()
	bidiStreamHandlers[method] = handler
	log.Printf("Registered bidi stream handler for: %s", method)
}

// UnregisterAllStreamHandlers removes all registered stream handlers.
// Useful for test cleanup.
func UnregisterAllStreamHandlers() {
	streamHandlerRegistryMu.Lock()
	defer streamHandlerRegistryMu.Unlock()
	serverStreamHandlers = make(map[string]ServerStreamHandler)
	clientStreamHandlers = make(map[string]ClientStreamHandler)
	bidiStreamHandlers = make(map[string]BidiStreamHandler)
	log.Println("Unregistered all stream handlers")
}

// =============================================================================
// Dispatchers (Called from FFI)
// =============================================================================

// HandleServerStream dispatches a server streaming request to the registered handler
func HandleServerStream(method string, data []byte) int64 {
	streamHandlerRegistryMu.RLock()
	handler, ok := serverStreamHandlers[method]
	streamHandlerRegistryMu.RUnlock()

	if ok {
		return StartServerStream(method, handler(data))
	}

	log.Printf("HandleServerStream: method %s not implemented in core", method)
	return -1
}

// HandleClientStream dispatches a client streaming request to the registered handler
func HandleClientStream(method string) int64 {
	streamHandlerRegistryMu.RLock()
	handler, ok := clientStreamHandlers[method]
	streamHandlerRegistryMu.RUnlock()

	if ok {
		return StartClientStream(method, handler())
	}

	log.Printf("HandleClientStream: method %s not implemented in core", method)
	return -1
}

// HandleBidiStream dispatches a bidirectional streaming request to the registered handler
func HandleBidiStream(method string) int64 {
	streamHandlerRegistryMu.RLock()
	handler, ok := bidiStreamHandlers[method]
	streamHandlerRegistryMu.RUnlock()

	if ok {
		return StartBidiStream(method, handler())
	}

	log.Printf("HandleBidiStream: method %s not implemented in core", method)
	return -1
}

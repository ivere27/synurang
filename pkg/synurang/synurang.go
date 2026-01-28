// Package synurang provides runtime support for FFI-based gRPC transport.
//
// This package enables "drop-in" replacement of standard gRPC clients with
// FFI-based clients that route calls through in-process function calls instead
// of network transport. It supports both unary and streaming RPC patterns.
//
// For Go-to-Go FFI, zero-copy mode is used - proto.Message pointers are passed
// directly without serialization.
//
// Usage:
//
//	// Create FfiClientConn with your generated FfiServer
//	conn := synurang.NewFfiClientConn(myFfiServer)
//
//	// Use with standard gRPC generated clients
//	client := pb.NewMyServiceClient(conn)
//	resp, err := client.MyMethod(ctx, req)
package synurang

import (
	"context"
	"fmt"
	"io"
	"sync"

	"google.golang.org/grpc"
	"google.golang.org/grpc/metadata"
	"google.golang.org/protobuf/proto"
)

// =============================================================================
// Invoker Interfaces - implemented by generated code
// =============================================================================

// UnaryInvoker handles unary RPC dispatch (zero-copy).
type UnaryInvoker interface {
	// Invoke dispatches a unary RPC call without serialization.
	// The request is passed directly, and the response is copied into reply.
	Invoke(ctx context.Context, method string, req, reply proto.Message) error
}

// StreamInvoker handles streaming RPC dispatch (zero-copy).
type StreamInvoker interface {
	// InvokeStream dispatches a streaming RPC call without serialization.
	InvokeStream(ctx context.Context, method string, stream ServerStream) error
}

// Invoker combines both unary and streaming invocation capabilities.
// Generated FfiServer implementations should implement this interface.
type Invoker interface {
	UnaryInvoker
	StreamInvoker
}

// =============================================================================
// FfiClientConn - implements grpc.ClientConnInterface for FFI transport
// =============================================================================

// FfiClientConn implements grpc.ClientConnInterface for FFI transport.
// This allows using standard generated gRPC clients with embedded FFI calls
// instead of network transport. Supports unary and all streaming patterns.
// Uses zero-copy mode - proto.Message pointers are passed directly.
type FfiClientConn struct {
	invoker Invoker
}

// NewFfiClientConn creates a new FFI client connection.
// The invoker should be a generated wrapper that implements the Invoker interface.
func NewFfiClientConn(invoker Invoker) *FfiClientConn {
	return &FfiClientConn{invoker: invoker}
}

// Invoke implements grpc.ClientConnInterface for unary calls (zero-copy).
func (c *FfiClientConn) Invoke(ctx context.Context, method string, args any, reply any, opts ...grpc.CallOption) error {
	req, ok := args.(proto.Message)
	if !ok {
		return fmt.Errorf("args must be proto.Message")
	}

	resp, ok := reply.(proto.Message)
	if !ok {
		return fmt.Errorf("reply must be proto.Message")
	}

	return c.invoker.Invoke(ctx, method, req, resp)
}

// NewStream implements grpc.ClientConnInterface for streaming calls (zero-copy).
func (c *FfiClientConn) NewStream(ctx context.Context, desc *grpc.StreamDesc, method string, opts ...grpc.CallOption) (grpc.ClientStream, error) {
	return newFfiClientStream(ctx, c.invoker, desc, method)
}

var _ grpc.ClientConnInterface = (*FfiClientConn)(nil)

// =============================================================================
// ServerStream - zero-copy streaming interface
// =============================================================================

// ServerStream is a zero-copy streaming interface for Go-to-Go FFI.
// Messages are passed as proto.Message pointers without serialization.
// It implements grpc.ServerStream for compatibility with generated server code.
type ServerStream interface {
	grpc.ServerStream
	// RecvMsgDirect receives a message without requiring a pre-allocated target.
	// Returns the message directly (zero-copy from channel).
	RecvMsgDirect() (proto.Message, error)
}

// =============================================================================
// FfiClientStream - implements grpc.ClientStream for zero-copy streaming
// =============================================================================

type ffiClientStream struct {
	ctx       context.Context
	cancel    context.CancelFunc
	method    string
	desc      *grpc.StreamDesc
	sendCh    chan proto.Message
	recvCh    chan proto.Message
	errCh     chan error
	headerMD  metadata.MD
	trailerMD metadata.MD
	mu        sync.Mutex
	closed    bool
	// streamErr stores the error once received, so subsequent RecvMsg calls return it
	streamErr error
	errOnce   sync.Once
}

func newFfiClientStream(ctx context.Context, invoker StreamInvoker, desc *grpc.StreamDesc, method string) (*ffiClientStream, error) {
	ctx, cancel := context.WithCancel(ctx)
	cs := &ffiClientStream{
		ctx:      ctx,
		cancel:   cancel,
		method:   method,
		desc:     desc,
		sendCh:   make(chan proto.Message, 16),
		recvCh:   make(chan proto.Message, 16),
		errCh:    make(chan error, 1),
		headerMD: metadata.MD{},
	}

	// Create server-side stream wrapper
	ss := &ffiServerStream{
		ctx:    ctx,
		sendCh: cs.recvCh, // server sends to client's recv
		recvCh: cs.sendCh, // server receives from client's send
	}

	// Start the streaming RPC in a goroutine
	go func() {
		defer close(cs.recvCh)
		defer close(cs.errCh)
		err := invoker.InvokeStream(ctx, method, ss)
		if err != nil {
			select {
			case cs.errCh <- err:
			default:
			}
		}
	}()

	return cs, nil
}

func (s *ffiClientStream) Header() (metadata.MD, error) {
	return s.headerMD, nil
}

func (s *ffiClientStream) Trailer() metadata.MD {
	return s.trailerMD
}

func (s *ffiClientStream) CloseSend() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.closed {
		s.closed = true
		close(s.sendCh)
	}
	return nil
}

func (s *ffiClientStream) Context() context.Context {
	return s.ctx
}

func (s *ffiClientStream) SendMsg(m any) error {
	msg, ok := m.(proto.Message)
	if !ok {
		return fmt.Errorf("message must be proto.Message")
	}

	select {
	case <-s.ctx.Done():
		return s.ctx.Err()
	case s.sendCh <- msg: // Zero-copy: pass pointer directly
		return nil
	}
}

func (s *ffiClientStream) RecvMsg(m any) error {
	// Check if we already have a stored error
	s.mu.Lock()
	if s.streamErr != nil {
		err := s.streamErr
		s.mu.Unlock()
		return err
	}
	s.mu.Unlock()

	select {
	case <-s.ctx.Done():
		return s.ctx.Err()
	case err, ok := <-s.errCh:
		if ok && err != nil {
			// Store the error so subsequent calls also return it
			s.mu.Lock()
			s.streamErr = err
			s.mu.Unlock()
			return err
		}
		// Channel closed without error, fall through to check recvCh
		select {
		case received, ok := <-s.recvCh:
			if !ok {
				return io.EOF
			}
			dst, ok := m.(proto.Message)
			if !ok {
				return fmt.Errorf("message must be proto.Message")
			}
			proto.Reset(dst)
			proto.Merge(dst, received)
			return nil
		default:
			return io.EOF
		}
	case received, ok := <-s.recvCh:
		if !ok {
			return io.EOF
		}
		// Zero-copy: direct struct copy
		dst, ok := m.(proto.Message)
		if !ok {
			return fmt.Errorf("message must be proto.Message")
		}
		proto.Reset(dst)
		proto.Merge(dst, received)
		return nil
	}
}

var _ grpc.ClientStream = (*ffiClientStream)(nil)

// =============================================================================
// FfiServerStream - implements ServerStream for zero-copy streaming
// =============================================================================

type ffiServerStream struct {
	ctx    context.Context
	sendCh chan proto.Message
	recvCh chan proto.Message
}

func (s *ffiServerStream) SetHeader(md metadata.MD) error {
	return nil
}

func (s *ffiServerStream) SendHeader(md metadata.MD) error {
	return nil
}

func (s *ffiServerStream) SetTrailer(md metadata.MD) {
}

func (s *ffiServerStream) Context() context.Context {
	return s.ctx
}

// SendMsg implements grpc.ServerStream (zero-copy).
func (s *ffiServerStream) SendMsg(m any) error {
	msg, ok := m.(proto.Message)
	if !ok {
		return fmt.Errorf("message must be proto.Message")
	}
	select {
	case <-s.ctx.Done():
		return s.ctx.Err()
	case s.sendCh <- msg: // Zero-copy: pass pointer directly
		return nil
	}
}

// RecvMsg implements grpc.ServerStream (zero-copy with struct copy).
func (s *ffiServerStream) RecvMsg(m any) error {
	select {
	case <-s.ctx.Done():
		return s.ctx.Err()
	case msg, ok := <-s.recvCh:
		if !ok {
			return io.EOF
		}
		// Zero-copy: direct struct copy
		dst, ok := m.(proto.Message)
		if !ok {
			return fmt.Errorf("message must be proto.Message")
		}
		proto.Reset(dst)
		proto.Merge(dst, msg)
		return nil
	}
}

// RecvMsgDirect receives a message directly without copying (true zero-copy).
func (s *ffiServerStream) RecvMsgDirect() (proto.Message, error) {
	select {
	case <-s.ctx.Done():
		return nil, s.ctx.Err()
	case msg, ok := <-s.recvCh:
		if !ok {
			return nil, io.EOF
		}
		return msg, nil // Zero-copy: return pointer directly
	}
}

var _ grpc.ServerStream = (*ffiServerStream)(nil)
var _ ServerStream = (*ffiServerStream)(nil)

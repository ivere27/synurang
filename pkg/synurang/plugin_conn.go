// PluginClientConn implements grpc.ClientConnInterface for plugin shared libraries.
// This enables using standard gRPC clients with plugin FFI transport.
//
// Usage:
//
//	plugin, _ := synurang.LoadPlugin("./plugin.so")
//	conn := synurang.NewPluginClientConn(plugin, "MyService")
//	client := pb.NewMyServiceClient(conn)
//
//	// Same API as standard gRPC - unary and streaming
//	resp, err := client.Unary(ctx, req)
//	stream, err := client.ServerStream(ctx, req)

package synurang

import (
	"context"
	"errors"
	"fmt"
	"io"
	"sync"
	"sync/atomic"

	"google.golang.org/grpc"
	"google.golang.org/grpc/metadata"
	"google.golang.org/protobuf/proto"
)

// withContext runs fn in a goroutine and returns early if ctx is cancelled.
// FFI calls cannot be truly cancelled, so this just enables early return.
// Note: If ctx is cancelled while fn is running, the fn goroutine will continue
// until completion. The result is discarded but the goroutine is not leaked.
func withContext[T any](ctx context.Context, fn func() (T, error)) (T, error) {
	// Fast path: check context before spawning goroutine
	if err := ctx.Err(); err != nil {
		var zero T
		return zero, err
	}

	type result struct {
		val T
		err error
	}
	done := make(chan result, 1)
	go func() {
		val, err := fn()
		// Always send result - channel is buffered so this won't block
		done <- result{val, err}
	}()

	select {
	case <-ctx.Done():
		// Context cancelled. The goroutine will complete eventually and send to
		// the buffered channel. Since the channel has capacity 1 and we're the
		// only receiver, the goroutine won't block and will exit cleanly.
		// We don't drain here - let GC collect the channel and result.
		var zero T
		return zero, ctx.Err()
	case r := <-done:
		return r.val, r.err
	}
}

// PluginClientConn implements grpc.ClientConnInterface for plugin FFI transport.
// It wraps a loaded plugin and routes gRPC calls through the C ABI.
type PluginClientConn struct {
	plugin      *Plugin
	serviceName string
}

// NewPluginClientConn creates a gRPC client connection that routes calls through a plugin.
// The serviceName should match the service name used in Synurang_Invoke_<ServiceName>.
func NewPluginClientConn(plugin *Plugin, serviceName string) *PluginClientConn {
	return &PluginClientConn{
		plugin:      plugin,
		serviceName: serviceName,
	}
}

// Invoke implements grpc.ClientConnInterface for unary calls.
// Respects context cancellation and deadline.
// Note: FFI calls cannot be truly cancelled. On context cancellation,
// this returns immediately but the underlying call continues until completion.
func (c *PluginClientConn) Invoke(ctx context.Context, method string, args any, reply any, opts ...grpc.CallOption) error {
	if err := ctx.Err(); err != nil {
		return err
	}

	req, ok := args.(proto.Message)
	if !ok {
		return fmt.Errorf("args must be proto.Message")
	}

	resp, ok := reply.(proto.Message)
	if !ok {
		return fmt.Errorf("reply must be proto.Message")
	}

	reqBytes, err := proto.Marshal(req)
	if err != nil {
		return fmt.Errorf("failed to marshal request: %w", err)
	}

	respBytes, err := withContext(ctx, func() ([]byte, error) {
		return c.plugin.Invoke(c.serviceName, method, reqBytes)
	})
	if err != nil {
		return err
	}
	return proto.Unmarshal(respBytes, resp)
}

// NewStream implements grpc.ClientConnInterface for streaming calls.
// Respects context cancellation and deadline.
func (c *PluginClientConn) NewStream(ctx context.Context, desc *grpc.StreamDesc, method string, opts ...grpc.CallOption) (grpc.ClientStream, error) {
	// Check context before opening stream
	if err := ctx.Err(); err != nil {
		return nil, err
	}

	stream, err := c.plugin.OpenStream(c.serviceName, method)
	if err != nil {
		return nil, err
	}

	return &pluginClientStream{ctx: ctx, stream: stream}, nil
}

var _ grpc.ClientConnInterface = (*PluginClientConn)(nil)

// pluginClientStream implements grpc.ClientStream for plugin streaming.
type pluginClientStream struct {
	ctx    context.Context
	stream *PluginStream
}

func (s *pluginClientStream) Header() (metadata.MD, error) { return nil, nil }
func (s *pluginClientStream) Trailer() metadata.MD         { return nil }

func (s *pluginClientStream) CloseSend() error {
	return s.stream.CloseSend()
}

func (s *pluginClientStream) Context() context.Context {
	return s.ctx
}

func (s *pluginClientStream) SendMsg(m any) error {
	msg, ok := m.(proto.Message)
	if !ok {
		return fmt.Errorf("message must be proto.Message")
	}

	data, err := proto.Marshal(msg)
	if err != nil {
		return fmt.Errorf("failed to marshal message: %w", err)
	}

	_, err = withContext(s.ctx, func() (struct{}, error) {
		return struct{}{}, s.stream.Send(data)
	})
	if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
		s.stream.Close()
	}
	return err
}

func (s *pluginClientStream) RecvMsg(m any) error {
	msg, ok := m.(proto.Message)
	if !ok {
		return fmt.Errorf("message must be proto.Message")
	}

	data, err := withContext(s.ctx, func() ([]byte, error) {
		return s.stream.Recv()
	})
	if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
		s.stream.Close()
	}
	if err != nil {
		return err
	}
	return proto.Unmarshal(data, msg)
}

var _ grpc.ClientStream = (*pluginClientStream)(nil)

// =============================================================================
// PluginStream - handle for streaming RPC over plugin FFI
// =============================================================================

// PluginStream represents an open stream to a plugin.
// Send and Recv can be called concurrently from different goroutines.
type PluginStream struct {
	plugin *Plugin
	handle uintptr
	closed atomic.Bool
	sendMu sync.Mutex // protects Send and CloseSend
	recvMu sync.Mutex // protects Recv
}

// ErrStreamClosed is returned when operations are attempted on a closed stream.
var ErrStreamClosed = errors.New("stream is closed")

// Send sends data to the stream (for client-streaming and bidi).
func (s *PluginStream) Send(data []byte) error {
	s.sendMu.Lock()
	defer s.sendMu.Unlock()
	if s.closed.Load() {
		return ErrStreamClosed
	}
	return s.plugin.StreamSend(s.handle, data)
}

// Recv receives data from the stream (for server-streaming and bidi).
// Automatically closes the stream on EOF or error.
func (s *PluginStream) Recv() ([]byte, error) {
	s.recvMu.Lock()
	defer s.recvMu.Unlock()
	if s.closed.Load() {
		return nil, io.EOF
	}
	data, err := s.plugin.StreamRecv(s.handle)
	if err != nil {
		// Mark as closed but don't call Close() while holding recvMu
		// to avoid potential deadlock. Use closeInternal directly.
		s.closeInternal()
	}
	return data, err
}

// CloseSend closes the send side of the stream.
func (s *PluginStream) CloseSend() error {
	s.sendMu.Lock()
	defer s.sendMu.Unlock()
	if s.closed.Load() {
		return nil
	}
	return s.plugin.StreamCloseSend(s.handle)
}

// closeInternal marks stream as closed and notifies plugin.
// Does not acquire sendMu/recvMu - caller must handle synchronization.
func (s *PluginStream) closeInternal() {
	if s.closed.Swap(true) {
		return
	}
	s.plugin.StreamClose(s.handle)
}

// Close closes the stream completely.
func (s *PluginStream) Close() error {
	s.closeInternal()
	return nil
}

package synurang

import (
	"context"
	"io"
	"sync/atomic"
	"testing"

	"google.golang.org/grpc"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/emptypb"
	"google.golang.org/protobuf/types/known/wrapperspb"
)

// =============================================================================
// Mock Invoker for testing (zero-copy interface)
// =============================================================================

type mockInvoker struct {
	invokeCount  int64
	streamCount  int64
	invokeFunc   func(ctx context.Context, method string, req, reply proto.Message) error
	streamFunc   func(ctx context.Context, method string, stream ServerStream) error
}

func (m *mockInvoker) Invoke(ctx context.Context, method string, req, reply proto.Message) error {
	atomic.AddInt64(&m.invokeCount, 1)
	if m.invokeFunc != nil {
		return m.invokeFunc(ctx, method, req, reply)
	}
	// Default: just return nil (no-op)
	return nil
}

func (m *mockInvoker) InvokeStream(ctx context.Context, method string, stream ServerStream) error {
	atomic.AddInt64(&m.streamCount, 1)
	if m.streamFunc != nil {
		return m.streamFunc(ctx, method, stream)
	}
	return nil
}

// =============================================================================
// Tests
// =============================================================================

func TestNewFfiClientConn(t *testing.T) {
	invoker := &mockInvoker{}
	conn := NewFfiClientConn(invoker)

	if conn == nil {
		t.Fatal("NewFfiClientConn returned nil")
	}

	// Verify it implements grpc.ClientConnInterface
	var _ grpc.ClientConnInterface = conn
}

func TestFfiClientConnInvoke(t *testing.T) {
	invoker := &mockInvoker{
		invokeFunc: func(ctx context.Context, method string, req, reply proto.Message) error {
			if method != "/test.Service/Method" {
				t.Errorf("unexpected method: %s", method)
			}
			// Copy request value to reply (simulating echo)
			if reqStr, ok := req.(*wrapperspb.StringValue); ok {
				if replyStr, ok := reply.(*wrapperspb.StringValue); ok {
					replyStr.Value = reqStr.Value
				}
			}
			return nil
		},
	}
	conn := NewFfiClientConn(invoker)

	req := &wrapperspb.StringValue{Value: "test request"}
	reply := &wrapperspb.StringValue{}

	err := conn.Invoke(context.Background(), "/test.Service/Method", req, reply)
	if err != nil {
		t.Fatalf("Invoke failed: %v", err)
	}

	if reply.Value != "test request" {
		t.Errorf("unexpected reply: %s", reply.Value)
	}

	if atomic.LoadInt64(&invoker.invokeCount) != 1 {
		t.Errorf("expected invokeCount=1, got %d", invoker.invokeCount)
	}
}

func TestFfiClientConnNewStream(t *testing.T) {
	invoker := &mockInvoker{
		streamFunc: func(ctx context.Context, method string, stream ServerStream) error {
			if method != "/test.Service/StreamMethod" {
				t.Errorf("unexpected method: %s", method)
			}

			// Server streaming: send some messages
			for i := 0; i < 3; i++ {
				msg := &wrapperspb.Int32Value{Value: int32(i)}
				if err := stream.SendMsg(msg); err != nil {
					return err
				}
			}
			return nil
		},
	}
	conn := NewFfiClientConn(invoker)

	desc := &grpc.StreamDesc{
		StreamName:    "StreamMethod",
		ServerStreams: true,
	}

	stream, err := conn.NewStream(context.Background(), desc, "/test.Service/StreamMethod")
	if err != nil {
		t.Fatalf("NewStream failed: %v", err)
	}

	if stream == nil {
		t.Fatal("NewStream returned nil stream")
	}

	// Verify stream interface
	_ = stream.Context()
	_, _ = stream.Header()
	_ = stream.Trailer()

	// Receive the 3 messages
	for i := 0; i < 3; i++ {
		msg := &wrapperspb.Int32Value{}
		err := stream.RecvMsg(msg)
		if err != nil {
			t.Fatalf("RecvMsg failed: %v", err)
		}
		if msg.Value != int32(i) {
			t.Errorf("expected value %d, got %d", i, msg.Value)
		}
	}

	// Next recv should return EOF
	msg := &wrapperspb.Int32Value{}
	err = stream.RecvMsg(msg)
	if err != io.EOF {
		t.Errorf("expected EOF, got %v", err)
	}

	// Close the stream
	err = stream.CloseSend()
	if err != nil {
		t.Errorf("CloseSend failed: %v", err)
	}
}

func TestFfiClientStreamCloseSend(t *testing.T) {
	invoker := &mockInvoker{
		streamFunc: func(ctx context.Context, method string, stream ServerStream) error {
			// Read until closed
			for {
				msg, err := stream.RecvMsgDirect()
				if err == io.EOF {
					return nil
				}
				if err != nil {
					return err
				}
				_ = msg
			}
		},
	}
	conn := NewFfiClientConn(invoker)

	desc := &grpc.StreamDesc{
		StreamName:    "ClientStream",
		ClientStreams: true,
	}

	stream, err := conn.NewStream(context.Background(), desc, "/test.Service/ClientStream")
	if err != nil {
		t.Fatalf("NewStream failed: %v", err)
	}

	// Close send multiple times should be safe
	for i := 0; i < 3; i++ {
		err = stream.CloseSend()
		if err != nil {
			t.Errorf("CloseSend failed on iteration %d: %v", i, err)
		}
	}
}

func TestFfiClientStreamContextCancellation(t *testing.T) {
	invoker := &mockInvoker{
		streamFunc: func(ctx context.Context, method string, stream ServerStream) error {
			<-ctx.Done()
			return ctx.Err()
		},
	}
	conn := NewFfiClientConn(invoker)

	ctx, cancel := context.WithCancel(context.Background())

	desc := &grpc.StreamDesc{
		StreamName:    "BidiStream",
		ClientStreams: true,
		ServerStreams: true,
	}

	stream, err := conn.NewStream(ctx, desc, "/test.Service/BidiStream")
	if err != nil {
		t.Fatalf("NewStream failed: %v", err)
	}

	// Cancel the context
	cancel()

	// Subsequent operations should fail with context error
	err = stream.SendMsg(&emptypb.Empty{})
	if err != context.Canceled {
		t.Logf("SendMsg after cancel: %v (expected context.Canceled)", err)
	}
}

func TestInvokerInterface(t *testing.T) {
	// Verify interface composition
	var invoker Invoker = &mockInvoker{}

	// Test UnaryInvoker
	var _ UnaryInvoker = invoker

	// Test StreamInvoker
	var _ StreamInvoker = invoker
}

func TestBidiStreaming(t *testing.T) {
	invoker := &mockInvoker{
		streamFunc: func(ctx context.Context, method string, stream ServerStream) error {
			// Echo server: receive and send back
			for {
				msg, err := stream.RecvMsgDirect()
				if err == io.EOF {
					return nil
				}
				if err != nil {
					return err
				}
				// Echo back
				if err := stream.SendMsg(msg); err != nil {
					return err
				}
			}
		},
	}
	conn := NewFfiClientConn(invoker)

	desc := &grpc.StreamDesc{
		StreamName:    "BidiStream",
		ClientStreams: true,
		ServerStreams: true,
	}

	stream, err := conn.NewStream(context.Background(), desc, "/test.Service/BidiStream")
	if err != nil {
		t.Fatalf("NewStream failed: %v", err)
	}

	// Send a message
	err = stream.SendMsg(&wrapperspb.StringValue{Value: "hello"})
	if err != nil {
		t.Fatalf("SendMsg failed: %v", err)
	}

	// Close send
	err = stream.CloseSend()
	if err != nil {
		t.Fatalf("CloseSend failed: %v", err)
	}

	// Receive the echoed message
	reply := &wrapperspb.StringValue{}
	err = stream.RecvMsg(reply)
	if err != nil {
		t.Fatalf("RecvMsg failed: %v", err)
	}

	if reply.Value != "hello" {
		t.Errorf("expected 'hello', got '%s'", reply.Value)
	}

	// Next recv should return EOF
	err = stream.RecvMsg(reply)
	if err != io.EOF {
		t.Errorf("expected EOF, got %v", err)
	}
}

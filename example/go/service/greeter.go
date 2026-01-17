package service

import (
	"context"
	"fmt"
	"io"
	"log"
	"runtime"
	"strings"
	"sync"
	"time"

	pb "synurang/example/pkg/api"
	core_service "synurang/pkg/service"

	"google.golang.org/grpc"
	"google.golang.org/grpc/peer"
	"google.golang.org/protobuf/proto"

	"google.golang.org/protobuf/types/known/timestamppb"
)

// GreeterServiceServer implements the GoGreeterService
type GreeterServiceServer struct {
	pb.UnimplementedGoGreeterServiceServer
	pb.UnimplementedDartGreeterServiceServer // if we want to stub it?
	// We need access to the Core machinery to call Dart
	Core *core_service.CoreServiceServer

	mu                 sync.Mutex
	lastGoroutineCount int
	callCount          int64
}

// NewGreeterServiceServer creates a new GreeterServiceServer
func NewGreeterServiceServer(core *core_service.CoreServiceServer) *GreeterServiceServer {
	return &GreeterServiceServer{Core: core}
}

// =============================================================================
// GoGreeterService Implementation (Go-side server, Dart calls this)
// =============================================================================

// GetGoroutines returns the number of running goroutines and optional stack trace
func (s *GreeterServiceServer) GetGoroutines(ctx context.Context, req *pb.GoroutinesRequest) (*pb.GoroutinesResponse, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	current := runtime.NumGoroutine()
	diff := current - s.lastGoroutineCount
	s.callCount++

	if s.callCount > 1 {
		log.Printf("Goroutines diff: %+d", diff)
	}

	if s.callCount%10 == 0 {
		log.Printf("Total Goroutines: %d", current)
	}

	s.lastGoroutineCount = current

	resp := &pb.GoroutinesResponse{
		Count: int32(current),
	}

	if req.AsString {
		buf := make([]byte, 2<<20) // 2MB buffer
		len := runtime.Stack(buf, true)
		resp.Message = string(buf[:len])
	}

	return resp, nil
}

// getTransport returns the transport type based on the context peer
func getTransport(ctx context.Context) string {
	p, ok := peer.FromContext(ctx)
	if !ok {
		return "FFI"
	}
	if p.Addr.Network() == "unix" {
		return "UDS"
	}
	if p.Addr.Network() == "tcp" {
		return "TCP"
	}
	return p.Addr.Network()
}

// Bar handles a simple RPC - single request, single response
func (s *GreeterServiceServer) Bar(ctx context.Context, req *pb.HelloRequest) (*pb.HelloResponse, error) {
	log.Printf("Go: Bar called [Transport: %s] with name=%s", getTransport(ctx), req.Name)

	greeting := getGreeting(req.Language, req.Name)

	return &pb.HelloResponse{
		Message:   greeting,
		From:      "go",
		Timestamp: timestamppb.Now(),
	}, nil
}

// BarServerStream handles server-side streaming RPC - sends multiple responses
func (s *GreeterServiceServer) BarServerStream(req *pb.HelloRequest, stream grpc.ServerStreamingServer[pb.HelloResponse]) error {
	log.Printf("Go: BarServerStream called [Transport: %s] with name=%s", getTransport(stream.Context()), req.Name)

	languages := []string{"ko", "en", "zh", "jp", "hi"}

	for i, lang := range languages {
		greeting := getGreeting(lang, req.Name)
		resp := &pb.HelloResponse{
			Message:   fmt.Sprintf("[%d/5] %s", i+1, greeting),
			From:      "go",
			Timestamp: timestamppb.Now(),
		}
		if err := stream.Send(resp); err != nil {
			return err
		}
		time.Sleep(300 * time.Millisecond)
	}

	return nil
}

// BarClientStream handles client-side streaming RPC - receives multiple requests
func (s *GreeterServiceServer) BarClientStream(stream grpc.ClientStreamingServer[pb.HelloRequest, pb.HelloResponse]) error {
	log.Printf("Go: BarClientStream called [Transport: %s]", getTransport(stream.Context()))

	var names []string

	for {
		req, err := stream.Recv()
		if err == io.EOF {
			// Client finished sending
			greeting := fmt.Sprintf("Hello to all: %s!", strings.Join(names, ", "))
			return stream.SendAndClose(&pb.HelloResponse{
				Message:   greeting,
				From:      "go",
				Timestamp: timestamppb.Now(),
			})
		}
		if err != nil {
			return err
		}
		log.Printf("Go: BarClientStream received name=%s", req.Name)
		names = append(names, req.Name)
	}
}

// BarBidiStream handles bidirectional streaming RPC - both sides stream
func (s *GreeterServiceServer) BarBidiStream(stream grpc.BidiStreamingServer[pb.HelloRequest, pb.HelloResponse]) error {
	log.Printf("Go: BarBidiStream called [Transport: %s]", getTransport(stream.Context()))

	for {
		req, err := stream.Recv()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}

		log.Printf("Go: BarBidiStream received name=%s", req.Name)

		// Echo back a greeting immediately
		greeting := getGreeting(req.Language, req.Name)
		resp := &pb.HelloResponse{
			Message:   greeting,
			From:      "go",
			Timestamp: timestamppb.Now(),
		}
		if err := stream.Send(resp); err != nil {
			return err
		}
	}
}

// Trigger handles the generic trigger request to initiate Go -> Dart calls
func (s *GreeterServiceServer) Trigger(ctx context.Context, req *pb.TriggerRequest) (*pb.HelloResponse, error) {
	log.Printf("Go: Trigger called with action=%v", req.Action)

	switch req.Action {
	case pb.TriggerRequest_UNARY:
		return s.CallDartFoo(req.Payload.Name, req.Payload.Language)
	case pb.TriggerRequest_SERVER_STREAM:
		return s.CallDartFooServerStream(req.Payload.Name)
	case pb.TriggerRequest_CLIENT_STREAM:
		return s.CallDartFooClientStream(req.Payload.Name)
	case pb.TriggerRequest_BIDI_STREAM:
		return s.CallDartFooBidiStream(req.Payload.Name)
	case pb.TriggerRequest_UPLOAD_FILE:
		return s.CallDartUploadFile(req.FileSize)
	case pb.TriggerRequest_DOWNLOAD_FILE:
		return s.CallDartDownloadFile(req.FileSize)
	case pb.TriggerRequest_BIDI_FILE:
		return s.CallDartBidiFile(req.FileSize)
	default:
		return nil, fmt.Errorf("action %v not supported", req.Action)
	}
}

// CallDartFooServerStream calls Dart's FooServerStream method
func (s *GreeterServiceServer) CallDartFooServerStream(name string) (*pb.HelloResponse, error) {
	req := &pb.HelloRequest{Name: name}

	responses, err := s.Core.InvokeDartStream(
		DartGreeterService_FooServerStream_FullMethodName,
		req,
		func() proto.Message { return &pb.HelloResponse{} },
	)
	if err != nil {
		return nil, err
	}

	// Aggregate responses
	msg := fmt.Sprintf("Received %d messages:", len(responses))
	for _, r := range responses {
		msg += "\n " + r.(*pb.HelloResponse).Message
	}

	return &pb.HelloResponse{
		Message:   msg,
		From:      "dart",
		Timestamp: timestamppb.Now(),
	}, nil
}

// CallDartFooClientStream calls Dart's FooClientStream method
func (s *GreeterServiceServer) CallDartFooClientStream(name string) (*pb.HelloResponse, error) {
	reqs := []proto.Message{
		&pb.HelloRequest{Name: name + "-1"},
		&pb.HelloRequest{Name: name + "-2"},
		&pb.HelloRequest{Name: name + "-3"},
	}

	resp, err := s.Core.InvokeDartClientStream(
		DartGreeterService_FooClientStream_FullMethodName,
		reqs,
		func() proto.Message { return &pb.HelloResponse{} },
	)
	if err != nil {
		return nil, err
	}

	return resp.(*pb.HelloResponse), nil
}

// CallDartFooBidiStream calls Dart's FooBidiStream method
func (s *GreeterServiceServer) CallDartFooBidiStream(name string) (*pb.HelloResponse, error) {
	reqs := []proto.Message{
		&pb.HelloRequest{Name: name + "-A", Language: "en"},
		&pb.HelloRequest{Name: name + "-B", Language: "ko"},
	}

	responses, err := s.Core.InvokeDartBidiStream(
		DartGreeterService_FooBidiStream_FullMethodName,
		reqs,
		func() proto.Message { return &pb.HelloResponse{} },
	)
	if err != nil {
		return nil, err
	}

	msg := fmt.Sprintf("Bidi exchanged %d messages:", len(responses))
	for _, r := range responses {
		msg += "\n " + r.(*pb.HelloResponse).Message
	}

	return &pb.HelloResponse{
		Message:   msg,
		From:      "dart",
		Timestamp: timestamppb.Now(),
	}, nil
}

// getGreeting returns a greeting in the specified language
// Order: Korean (1st), English (default), Chinese, Spanish, Hindi
func getGreeting(language, name string) string {
	switch language {
	case "ko":
		return fmt.Sprintf("안녕하세요, %s님!", name)
	case "zh":
		return fmt.Sprintf("你好, %s!", name)
	case "jp":
		return fmt.Sprintf("こんにちは、%sさん!", name)
	case "hi":
		return fmt.Sprintf("नमस्ते, %s!", name)
	default:
		return fmt.Sprintf("Hello, %s!", name)
	}
}

// =============================================================================
// DartGreeterService Client - Calling Dart from Go
// =============================================================================

// CallDartFoo calls Dart's Foo method (simple RPC)
func (s *GreeterServiceServer) CallDartFoo(name string, language string) (*pb.HelloResponse, error) {
	req := &pb.HelloRequest{
		Name:     name,
		Language: language,
	}

	resp := &pb.HelloResponse{}
	// Core.InvokeDart takes (method, req, resp)
	if err := s.Core.InvokeDart(DartGreeterService_Foo_FullMethodName, req, resp); err != nil {
		return nil, err
	}

	return resp, nil
}

// DartGreeterService method name constants
const (
	DartGreeterService_Foo_FullMethodName             = "/example.v1.DartGreeterService/Foo"
	DartGreeterService_FooServerStream_FullMethodName = "/example.v1.DartGreeterService/FooServerStream"
	DartGreeterService_FooClientStream_FullMethodName = "/example.v1.DartGreeterService/FooClientStream"
	DartGreeterService_FooBidiStream_FullMethodName   = "/example.v1.DartGreeterService/FooBidiStream"
)

// =============================================================================
// FfiServer Internal Methods (for FFI calls - streaming converted to unary)
// =============================================================================

// BarServerStreamInternal - FFI shim for BarServerStream (returns first greeting only)
func (s *GreeterServiceServer) BarServerStreamInternal(ctx context.Context, req *pb.HelloRequest) (*pb.HelloResponse, error) {
	greeting := getGreeting(req.Language, req.Name)
	return &pb.HelloResponse{
		Message:   greeting,
		From:      "go",
		Timestamp: timestamppb.Now(),
	}, nil
}

// BarClientStreamInternal - FFI shim for BarClientStream
func (s *GreeterServiceServer) BarClientStreamInternal(ctx context.Context, req *pb.HelloRequest) (*pb.HelloResponse, error) {
	// For FFI, we just return greeting for the single request
	greeting := getGreeting(req.Language, req.Name)
	return &pb.HelloResponse{
		Message:   greeting,
		From:      "go",
		Timestamp: timestamppb.Now(),
	}, nil
}

// BarBidiStreamInternal - FFI shim for BarBidiStream
func (s *GreeterServiceServer) BarBidiStreamInternal(ctx context.Context, req *pb.HelloRequest) (*pb.HelloResponse, error) {
	greeting := getGreeting(req.Language, req.Name)
	return &pb.HelloResponse{
		Message:   greeting,
		From:      "go",
		Timestamp: timestamppb.Now(),
	}, nil
}

// =============================================================================
// DartGreeterService stubs (Go doesn't implement these - Dart does)
// These are required to satisfy FfiServer interface if generated Invoke includes them
// =============================================================================

func (s *GreeterServiceServer) Foo(ctx context.Context, req *pb.HelloRequest) (*pb.HelloResponse, error) {
	return nil, fmt.Errorf("Foo should be handled by Dart")
}

func (s *GreeterServiceServer) FooServerStream(req *pb.HelloRequest, stream grpc.ServerStreamingServer[pb.HelloResponse]) error {
	return fmt.Errorf("FooServerStream should be handled by Dart")
}

func (s *GreeterServiceServer) FooClientStream(stream grpc.ClientStreamingServer[pb.HelloRequest, pb.HelloResponse]) error {
	return fmt.Errorf("FooClientStream should be handled by Dart")
}

func (s *GreeterServiceServer) FooBidiStream(stream grpc.BidiStreamingServer[pb.HelloRequest, pb.HelloResponse]) error {
	return fmt.Errorf("FooBidiStream should be handled by Dart")
}

func (s *GreeterServiceServer) FooServerStreamInternal(ctx context.Context, req *pb.HelloRequest) (*pb.HelloResponse, error) {
	return nil, fmt.Errorf("FooServerStreamInternal should be handled by Dart")
}

func (s *GreeterServiceServer) FooClientStreamInternal(ctx context.Context, req *pb.HelloRequest) (*pb.HelloResponse, error) {
	return nil, fmt.Errorf("FooClientStreamInternal should be handled by Dart")
}

func (s *GreeterServiceServer) FooBidiStreamInternal(ctx context.Context, req *pb.HelloRequest) (*pb.HelloResponse, error) {
	return nil, fmt.Errorf("FooBidiStreamInternal should be handled by Dart")
}

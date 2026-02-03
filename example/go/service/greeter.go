// Package service provides the shared greeter service implementation
// used by both plugin and process modes.
package service

import (
	"context"
	"io"

	"github.com/ivere27/synurang/example/go/logic"
	pb "github.com/ivere27/synurang/example/pkg/api"
	core_service "github.com/ivere27/synurang/pkg/service"
	"google.golang.org/grpc"
)

// GreeterServiceServer implements GoGreeterService for both plugin and process modes.
// This serves as the core business logic shared across all transport modes.
type GreeterServiceServer struct {
	pb.UnimplementedGoGreeterServiceServer
	logic *logic.GreeterLogic
	core  *core_service.CoreServiceServer
}

// NewGreeterServiceServer creates a new GreeterServiceServer with the given core service.
func NewGreeterServiceServer(core *core_service.CoreServiceServer) *GreeterServiceServer {
	return &GreeterServiceServer{
		logic: logic.NewGreeterLogic("go"),
		core:  core,
	}
}

// NewGreeterServiceServerWithSource creates a GreeterServiceServer with a custom source identifier.
func NewGreeterServiceServerWithSource(source string) *GreeterServiceServer {
	return &GreeterServiceServer{
		logic: logic.NewGreeterLogic(source),
	}
}

// Bar handles unary RPC
func (s *GreeterServiceServer) Bar(ctx context.Context, req *pb.HelloRequest) (*pb.HelloResponse, error) {
	msg, from := s.logic.Bar(req.Name)
	return &pb.HelloResponse{
		Message: msg,
		From:    from,
	}, nil
}

// BarServerStream handles server streaming RPC
func (s *GreeterServiceServer) BarServerStream(req *pb.HelloRequest, stream grpc.ServerStreamingServer[pb.HelloResponse]) error {
	s.logic.BarServerStream(req.Name, func(message, from string, index, total int) bool {
		err := stream.Send(&pb.HelloResponse{
			Message: message,
			From:    from,
		})
		return err == nil
	})
	return nil
}

// BarClientStream handles client streaming RPC
func (s *GreeterServiceServer) BarClientStream(stream grpc.ClientStreamingServer[pb.HelloRequest, pb.HelloResponse]) error {
	var names []string
	for {
		req, err := stream.Recv()
		if err == io.EOF {
			msg, from := s.logic.BarClientStream(names)
			return stream.SendAndClose(&pb.HelloResponse{
				Message: msg,
				From:    from,
			})
		}
		if err != nil {
			return err
		}
		names = append(names, req.Name)
	}
}

// BarBidiStream handles bidirectional streaming RPC
func (s *GreeterServiceServer) BarBidiStream(stream grpc.BidiStreamingServer[pb.HelloRequest, pb.HelloResponse]) error {
	for {
		req, err := stream.Recv()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}
		msg, from := s.logic.BarBidiStream(req.Name, req.Language)
		if err := stream.Send(&pb.HelloResponse{
			Message: msg,
			From:    from,
		}); err != nil {
			return err
		}
	}
}

// Trigger handles alert triggering
func (s *GreeterServiceServer) Trigger(ctx context.Context, req *pb.TriggerRequest) (*pb.HelloResponse, error) {
	msg, from := s.logic.Trigger()
	return &pb.HelloResponse{Message: msg, From: from}, nil
}

// GetGoroutines returns goroutine info
func (s *GreeterServiceServer) GetGoroutines(ctx context.Context, req *pb.GoroutinesRequest) (*pb.GoroutinesResponse, error) {
	count, message := s.logic.GetGoroutines()
	return &pb.GoroutinesResponse{Count: count, Message: message}, nil
}

// getTransport extracts transport info from context (for logging)
func getTransport(ctx context.Context) string {
	// Simplified - can be extended to detect FFI vs gRPC
	return "grpc"
}

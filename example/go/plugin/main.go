// Plugin mode entry point - FFI shared library
// This uses the test/plugin/api package which has the FFI plugin interface.
package main

import "C"

import (
	"context"
	"io"

	"github.com/ivere27/synurang/example/go/logic"
	pb "github.com/ivere27/synurang/test/plugin/api"
	"google.golang.org/protobuf/types/known/timestamppb"
)

// PluginServer implements GoGreeterServicePlugin for FFI mode
type PluginServer struct {
	logic *logic.GreeterLogic
}

// NewPluginServer creates a new PluginServer with shared logic
func NewPluginServer() *PluginServer {
	return &PluginServer{
		logic: logic.NewGreeterLogic("go-plugin"),
	}
}

// Unary methods
func (s *PluginServer) Bar(ctx context.Context, req *pb.HelloRequest) (*pb.HelloResponse, error) {
	msg, from := s.logic.Bar(req.Name)
	return &pb.HelloResponse{
		Message:   msg,
		From:      from,
		Timestamp: timestamppb.Now(),
	}, nil
}

func (s *PluginServer) Trigger(ctx context.Context, req *pb.TriggerRequest) (*pb.HelloResponse, error) {
	msg, from := s.logic.Trigger()
	return &pb.HelloResponse{Message: msg, From: from}, nil
}

func (s *PluginServer) GetGoroutines(ctx context.Context, req *pb.GoroutinesRequest) (*pb.GoroutinesResponse, error) {
	count, message := s.logic.GetGoroutines()
	return &pb.GoroutinesResponse{Count: count, Message: message}, nil
}

// Server streaming
func (s *PluginServer) BarServerStream(req *pb.HelloRequest, stream pb.GoGreeterService_BarServerStreamServer) error {
	s.logic.BarServerStream(req.Name, func(message, from string, index, total int) bool {
		err := stream.Send(&pb.HelloResponse{
			Message: message,
			From:    from,
		})
		return err == nil
	})
	return nil
}

// Client streaming
func (s *PluginServer) BarClientStream(stream pb.GoGreeterService_BarClientStreamServer) (*pb.HelloResponse, error) {
	var names []string
	for {
		req, err := stream.Recv()
		if err == io.EOF {
			msg, from := s.logic.BarClientStream(names)
			return &pb.HelloResponse{
				Message: msg,
				From:    from,
			}, nil
		}
		if err != nil {
			return nil, err
		}
		names = append(names, req.Name)
	}
}

// Bidi streaming
func (s *PluginServer) BarBidiStream(stream pb.GoGreeterService_BarBidiStreamServer) error {
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

// Stub implementations for file operations
func (s *PluginServer) UploadFile(stream pb.GoGreeterService_UploadFileServer) (*pb.FileStatus, error) {
	return &pb.FileStatus{}, nil
}

func (s *PluginServer) DownloadFile(req *pb.DownloadFileRequest, stream pb.GoGreeterService_DownloadFileServer) error {
	return nil
}

func (s *PluginServer) BidiFile(stream pb.GoGreeterService_BidiFileServer) error {
	return nil
}

func init() {
	pb.RegisterGoGreeterServicePlugin(NewPluginServer())
}

func main() {} // Required for -buildmode=c-shared

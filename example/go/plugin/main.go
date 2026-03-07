// Plugin mode entry point - FFI shared library
// This uses the test/plugin/api package which has the FFI plugin interface.
package main

import "C"

import (
	"context"
	"io"

	"github.com/ivere27/synurang/example/go/logic"
	"github.com/ivere27/synurang/pkg/ffierror"
	pb "github.com/ivere27/synurang/test/plugin/api"
	"google.golang.org/protobuf/types/known/timestamppb"
)

const errorTriggerName = "trigger_error"

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

func ffiTestError(code int32, message string) error {
	return ffierror.New(code, message, 10)
}

// Unary methods
func (s *PluginServer) Bar(ctx context.Context, req *pb.HelloRequest) (*pb.HelloResponse, error) {
	if req.Name == errorTriggerName {
		return nil, ffiTestError(4101, "go unary ffi error")
	}
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
func (s *PluginServer) BarServerStream(req *pb.HelloRequest, stream pb.GoGreeterService_BarServerStreamPluginStream) error {
	if req.Name == errorTriggerName {
		return ffiTestError(4102, "go server stream ffi error")
	}
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
func (s *PluginServer) BarClientStream(stream pb.GoGreeterService_BarClientStreamPluginStream) (*pb.HelloResponse, error) {
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
		if req.Name == errorTriggerName {
			return nil, ffiTestError(4103, "go client stream ffi error")
		}
		names = append(names, req.Name)
	}
}

// Bidi streaming
func (s *PluginServer) BarBidiStream(stream pb.GoGreeterService_BarBidiStreamPluginStream) error {
	for {
		req, err := stream.Recv()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}
		if req.Name == errorTriggerName {
			return ffiTestError(4104, "go bidi stream ffi error")
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
func (s *PluginServer) UploadFile(stream pb.GoGreeterService_UploadFilePluginStream) (*pb.FileStatus, error) {
	return &pb.FileStatus{}, nil
}

func (s *PluginServer) DownloadFile(req *pb.DownloadFileRequest, stream pb.GoGreeterService_DownloadFilePluginStream) error {
	return nil
}

func (s *PluginServer) BidiFile(stream pb.GoGreeterService_BidiFilePluginStream) error {
	return nil
}

func init() {
	pb.RegisterGoGreeterServicePlugin(NewPluginServer())
}

func main() {} // Required for -buildmode=c-shared

package main

import (
	"context"
	"fmt"
	"io"

	"github.com/ivere27/synurang/example/go/logic"
	pb "github.com/ivere27/synurang/test/plugin/api"
	"google.golang.org/protobuf/types/known/timestamppb"
)

// Server implements GoGreeterServicePlugin using shared logic
type Server struct {
	logic *logic.GreeterLogic
}

// NewServer creates a new Server with shared logic
func NewServer() *Server {
	return &Server{
		logic: logic.NewGreeterLogic("test-plugin"),
	}
}

// Unary methods
func (s *Server) Bar(ctx context.Context, req *pb.HelloRequest) (*pb.HelloResponse, error) {
	msg, from := s.logic.Bar(req.Name)
	return &pb.HelloResponse{
		Message:   msg,
		From:      from,
		Timestamp: timestamppb.Now(),
	}, nil
}

func (s *Server) Trigger(ctx context.Context, req *pb.TriggerRequest) (*pb.HelloResponse, error) {
	msg, from := s.logic.Trigger()
	return &pb.HelloResponse{Message: msg, From: from}, nil
}

func (s *Server) GetGoroutines(ctx context.Context, req *pb.GoroutinesRequest) (*pb.GoroutinesResponse, error) {
	count, message := s.logic.GetGoroutines()
	return &pb.GoroutinesResponse{Count: count, Message: message}, nil
}

// Server streaming: single request, stream of responses
func (s *Server) BarServerStream(req *pb.HelloRequest, stream pb.GoGreeterService_BarServerStreamServer) error {
	s.logic.BarServerStream(req.Name, func(message, from string, index, total int) bool {
		err := stream.Send(&pb.HelloResponse{
			Message:   message,
			From:      from,
			Timestamp: timestamppb.Now(),
		})
		return err == nil
	})
	return nil
}

// Client streaming: stream of requests, single response
func (s *Server) BarClientStream(stream pb.GoGreeterService_BarClientStreamServer) (*pb.HelloResponse, error) {
	var names []string
	for {
		req, err := stream.Recv()
		if err == io.EOF {
			msg, from := s.logic.BarClientStream(names)
			return &pb.HelloResponse{
				Message:   msg,
				From:      from,
				Timestamp: timestamppb.Now(),
			}, nil
		}
		if err != nil {
			return nil, err
		}
		names = append(names, req.Name)
	}
}

// Bidi streaming: stream of requests, stream of responses
func (s *Server) BarBidiStream(stream pb.GoGreeterService_BarBidiStreamServer) error {
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
			Message:   msg,
			From:      from,
			Timestamp: timestamppb.Now(),
		}); err != nil {
			return err
		}
	}
}

// File upload (client streaming)
func (s *Server) UploadFile(stream pb.GoGreeterService_UploadFileServer) (*pb.FileStatus, error) {
	fmt.Println("[test-plugin] UploadFile started")
	var totalSize int64
	for {
		chunk, err := stream.Recv()
		if err == io.EOF {
			return &pb.FileStatus{SizeReceived: totalSize}, nil
		}
		if err != nil {
			return nil, err
		}
		totalSize += int64(len(chunk.Content))
	}
}

// File download (server streaming)
func (s *Server) DownloadFile(req *pb.DownloadFileRequest, stream pb.GoGreeterService_DownloadFileServer) error {
	fmt.Printf("[test-plugin] DownloadFile requested size: %d\n", req.Size)
	chunkSize := int64(1024)
	remaining := req.Size
	for remaining > 0 {
		size := chunkSize
		if remaining < chunkSize {
			size = remaining
		}
		if err := stream.Send(&pb.FileChunk{Content: make([]byte, size)}); err != nil {
			return err
		}
		remaining -= size
	}
	return nil
}

// Bidi file streaming
func (s *Server) BidiFile(stream pb.GoGreeterService_BidiFileServer) error {
	fmt.Println("[test-plugin] BidiFile started")
	for {
		chunk, err := stream.Recv()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}
		// Echo back the chunk
		if err := stream.Send(chunk); err != nil {
			return err
		}
	}
}

func init() {
	fmt.Println("[test-plugin] Initializing with shared logic...")
	pb.RegisterGoGreeterServicePlugin(NewServer())
}

func main() {} // Required for -buildmode=c-shared

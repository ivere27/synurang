package main

import (
	"context"
	"fmt"
	"io"

	"google.golang.org/protobuf/types/known/timestamppb"

	pb "github.com/ivere27/synurang/test/plugin/api"
)

// Server implements only GoGreeterServicePlugin - clean interface!
type Server struct{}

// Unary methods
func (s *Server) Bar(ctx context.Context, req *pb.HelloRequest) (*pb.HelloResponse, error) {
	fmt.Printf("[Plugin] Received Bar request: %s\n", req.Name)
	return &pb.HelloResponse{
		Message:   "Hello from Plugin (SO)! " + req.Name,
		From:      "plugin",
		Timestamp: timestamppb.Now(),
	}, nil
}

func (s *Server) Trigger(ctx context.Context, req *pb.TriggerRequest) (*pb.HelloResponse, error) {
	return &pb.HelloResponse{Message: "Trigger called"}, nil
}

func (s *Server) GetGoroutines(ctx context.Context, req *pb.GoroutinesRequest) (*pb.GoroutinesResponse, error) {
	return &pb.GoroutinesResponse{Count: 1, Message: "Plugin goroutines"}, nil
}

// Server streaming: single request, stream of responses
func (s *Server) BarServerStream(req *pb.HelloRequest, stream pb.GoGreeterService_BarServerStreamServer) error {
	fmt.Printf("[Plugin] BarServerStream for: %s\n", req.Name)
	for i := 0; i < 3; i++ {
		if err := stream.Send(&pb.HelloResponse{
			Message:   fmt.Sprintf("Stream response %d for %s", i, req.Name),
			From:      "plugin",
			Timestamp: timestamppb.Now(),
		}); err != nil {
			return err
		}
	}
	return nil
}

// Client streaming: stream of requests, single response
func (s *Server) BarClientStream(stream pb.GoGreeterService_BarClientStreamServer) (*pb.HelloResponse, error) {
	fmt.Println("[Plugin] BarClientStream started")
	count := 0
	for {
		req, err := stream.Recv()
		if err == io.EOF {
			return &pb.HelloResponse{
				Message:   fmt.Sprintf("Received %d messages", count),
				From:      "plugin",
				Timestamp: timestamppb.Now(),
			}, nil
		}
		if err != nil {
			return nil, err
		}
		fmt.Printf("[Plugin] BarClientStream received: %s\n", req.Name)
		count++
	}
}

// Bidi streaming: stream of requests, stream of responses
func (s *Server) BarBidiStream(stream pb.GoGreeterService_BarBidiStreamServer) error {
	fmt.Println("[Plugin] BarBidiStream started")
	for {
		req, err := stream.Recv()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}
		fmt.Printf("[Plugin] BarBidiStream received: %s\n", req.Name)
		if err := stream.Send(&pb.HelloResponse{
			Message:   "Echo: " + req.Name,
			From:      "plugin",
			Timestamp: timestamppb.Now(),
		}); err != nil {
			return err
		}
	}
}

// File upload (client streaming)
func (s *Server) UploadFile(stream pb.GoGreeterService_UploadFileServer) (*pb.FileStatus, error) {
	fmt.Println("[Plugin] UploadFile started")
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
	fmt.Printf("[Plugin] DownloadFile requested size: %d\n", req.Size)
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
	fmt.Println("[Plugin] BidiFile started")
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
	fmt.Println("[Plugin] Initializing...")
	// Per-service registration - only register the service we implement
	pb.RegisterGoGreeterServicePlugin(&Server{})
}

func main() {} // Required for -buildmode=c-shared

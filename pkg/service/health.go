package service

import (
	"context"

	empty "github.com/golang/protobuf/ptypes/empty"
	pb "github.com/ivere27/synurang/pkg/api"

	"google.golang.org/protobuf/types/known/timestamppb"
)

// =============================================================================
// HealthService Implementation
// =============================================================================

// Ping returns current timestamp
func (s *CoreServiceServer) Ping(ctx context.Context, req *empty.Empty) (*pb.PingResponse, error) {
	return &pb.PingResponse{
		Timestamp: timestamppb.Now(),
		Version:   "0.1.0",
	}, nil
}

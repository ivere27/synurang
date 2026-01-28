// FfiClientConn Test Suite
//
// Tests the generated FfiClientConn implementation that allows using standard
// gRPC clients over FFI transport in Go.

package go_ffi_test

import (
	"context"
	"testing"

	"google.golang.org/protobuf/types/known/emptypb"
	"google.golang.org/protobuf/types/known/timestamppb"
)

// =============================================================================
// Mock Messages (simplified versions for testing)
// =============================================================================

type PingResponse struct {
	Timestamp *timestamppb.Timestamp
	Message   string
}

func (p *PingResponse) ProtoReflect() any { return nil }
func (p *PingResponse) Reset()            { *p = PingResponse{} }
func (p *PingResponse) String() string    { return p.Message }

type GetCacheRequest struct {
	StoreName string
	Key       string
}

func (g *GetCacheRequest) ProtoReflect() any { return nil }
func (g *GetCacheRequest) Reset()            { *g = GetCacheRequest{} }
func (g *GetCacheRequest) String() string    { return g.Key }

type GetCacheResponse struct {
	Data []byte
}

func (g *GetCacheResponse) ProtoReflect() any { return nil }
func (g *GetCacheResponse) Reset()            { *g = GetCacheResponse{} }
func (g *GetCacheResponse) String() string    { return string(g.Data) }

// =============================================================================
// Mock FfiServer Implementation
// =============================================================================

// MockHealthServer implements the HealthService methods
type MockHealthServer interface {
	Ping(ctx context.Context, req *emptypb.Empty) (*PingResponse, error)
}

// MockCacheServer implements the CacheService methods
type MockCacheServer interface {
	Get(ctx context.Context, req *GetCacheRequest) (*GetCacheResponse, error)
}

// MockFfiServer implements FfiServer interface for testing
type MockFfiServer struct {
	PingCount    int
	GetCount     int
	LastKey      string
	CacheData    map[string][]byte
	PingResponse *PingResponse
}

func NewMockFfiServer() *MockFfiServer {
	return &MockFfiServer{
		CacheData: make(map[string][]byte),
		PingResponse: &PingResponse{
			Timestamp: timestamppb.Now(),
			Message:   "pong",
		},
	}
}

func (m *MockFfiServer) Ping(ctx context.Context, req *emptypb.Empty) (*PingResponse, error) {
	m.PingCount++
	return m.PingResponse, nil
}

func (m *MockFfiServer) Get(ctx context.Context, req *GetCacheRequest) (*GetCacheResponse, error) {
	m.GetCount++
	m.LastKey = req.Key
	data, ok := m.CacheData[req.Key]
	if !ok {
		return &GetCacheResponse{Data: nil}, nil
	}
	return &GetCacheResponse{Data: data}, nil
}

// =============================================================================
// Tests
// =============================================================================

func TestMockFfiServer_Ping(t *testing.T) {
	server := NewMockFfiServer()

	resp, err := server.Ping(context.Background(), &emptypb.Empty{})
	if err != nil {
		t.Fatalf("Ping failed: %v", err)
	}

	if resp.Message != "pong" {
		t.Errorf("Expected 'pong', got '%s'", resp.Message)
	}

	if server.PingCount != 1 {
		t.Errorf("Expected PingCount=1, got %d", server.PingCount)
	}
}

func TestMockFfiServer_Get(t *testing.T) {
	server := NewMockFfiServer()
	server.CacheData["test-key"] = []byte("test-value")

	req := &GetCacheRequest{
		StoreName: "default",
		Key:       "test-key",
	}

	resp, err := server.Get(context.Background(), req)
	if err != nil {
		t.Fatalf("Get failed: %v", err)
	}

	if string(resp.Data) != "test-value" {
		t.Errorf("Expected 'test-value', got '%s'", string(resp.Data))
	}

	if server.LastKey != "test-key" {
		t.Errorf("Expected LastKey='test-key', got '%s'", server.LastKey)
	}
}

func TestMockFfiServer_GetNotFound(t *testing.T) {
	server := NewMockFfiServer()

	req := &GetCacheRequest{
		StoreName: "default",
		Key:       "non-existent-key",
	}

	resp, err := server.Get(context.Background(), req)
	if err != nil {
		t.Fatalf("Get failed: %v", err)
	}

	if resp.Data != nil {
		t.Errorf("Expected nil data, got %v", resp.Data)
	}
}

func TestMockFfiServer_MultiplePings(t *testing.T) {
	server := NewMockFfiServer()

	for i := 0; i < 100; i++ {
		_, err := server.Ping(context.Background(), &emptypb.Empty{})
		if err != nil {
			t.Fatalf("Ping %d failed: %v", i, err)
		}
	}

	if server.PingCount != 100 {
		t.Errorf("Expected PingCount=100, got %d", server.PingCount)
	}
}

// =============================================================================
// Benchmark
// =============================================================================

func BenchmarkMockFfiServer_Ping(b *testing.B) {
	server := NewMockFfiServer()
	ctx := context.Background()
	req := &emptypb.Empty{}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_, _ = server.Ping(ctx, req)
	}
}

func BenchmarkMockFfiServer_Get(b *testing.B) {
	server := NewMockFfiServer()
	server.CacheData["bench-key"] = []byte("bench-value")
	ctx := context.Background()
	req := &GetCacheRequest{StoreName: "default", Key: "bench-key"}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_, _ = server.Get(ctx, req)
	}
}

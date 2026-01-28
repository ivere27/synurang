package api

// ffi_client_conn_test.go
//
// Integration tests for Go-to-Go FFI communication using FfiClientConn
// as a drop-in replacement for grpc.ClientConn.

import (
	"context"
	"fmt"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	empty "github.com/golang/protobuf/ptypes/empty"
	timestamp "github.com/golang/protobuf/ptypes/timestamp"
	wrappers "github.com/golang/protobuf/ptypes/wrappers"
)

// =============================================================================
// Mock FfiServer Implementation
// =============================================================================

// MockFfiServer implements FfiServer for testing Go-to-Go FFI calls.
type MockFfiServer struct {
	UnimplementedHealthServiceServer
	UnimplementedCacheServiceServer

	pingCount     int64
	getCount      int64
	putCount      int64
	deleteCount   int64
	clearCount    int64
	containsCount int64

	mu    sync.RWMutex
	cache map[string][]byte
}

func NewMockFfiServer() *MockFfiServer {
	return &MockFfiServer{
		cache: make(map[string][]byte),
	}
}

// HealthService methods

func (s *MockFfiServer) Ping(ctx context.Context, req *empty.Empty) (*PingResponse, error) {
	atomic.AddInt64(&s.pingCount, 1)
	now := time.Now()
	return &PingResponse{
		Timestamp: &timestamp.Timestamp{
			Seconds: now.Unix(),
			Nanos:   int32(now.Nanosecond()),
		},
		Version: "test-1.0.0",
	}, nil
}

// CacheService methods

func (s *MockFfiServer) Get(ctx context.Context, req *GetCacheRequest) (*GetCacheResponse, error) {
	atomic.AddInt64(&s.getCount, 1)
	s.mu.RLock()
	defer s.mu.RUnlock()

	key := fmt.Sprintf("%s:%s", req.StoreName, req.Key)
	data, exists := s.cache[key]
	if !exists {
		return &GetCacheResponse{Value: nil}, nil
	}
	return &GetCacheResponse{Value: data}, nil
}

func (s *MockFfiServer) Put(ctx context.Context, req *PutCacheRequest) (*empty.Empty, error) {
	atomic.AddInt64(&s.putCount, 1)
	s.mu.Lock()
	defer s.mu.Unlock()

	key := fmt.Sprintf("%s:%s", req.StoreName, req.Key)
	s.cache[key] = req.Value
	return &empty.Empty{}, nil
}

func (s *MockFfiServer) Delete(ctx context.Context, req *DeleteCacheRequest) (*empty.Empty, error) {
	atomic.AddInt64(&s.deleteCount, 1)
	s.mu.Lock()
	defer s.mu.Unlock()

	key := fmt.Sprintf("%s:%s", req.StoreName, req.Key)
	delete(s.cache, key)
	return &empty.Empty{}, nil
}

func (s *MockFfiServer) Clear(ctx context.Context, req *ClearCacheRequest) (*empty.Empty, error) {
	atomic.AddInt64(&s.clearCount, 1)
	s.mu.Lock()
	defer s.mu.Unlock()

	prefix := req.StoreName + ":"
	for k := range s.cache {
		if len(k) > len(prefix) && k[:len(prefix)] == prefix {
			delete(s.cache, k)
		}
	}
	return &empty.Empty{}, nil
}

func (s *MockFfiServer) Contains(ctx context.Context, req *GetCacheRequest) (*wrappers.BoolValue, error) {
	atomic.AddInt64(&s.containsCount, 1)
	s.mu.RLock()
	defer s.mu.RUnlock()

	key := fmt.Sprintf("%s:%s", req.StoreName, req.Key)
	_, exists := s.cache[key]
	return &wrappers.BoolValue{Value: exists}, nil
}

// =============================================================================
// FfiClientConn Tests - Go-to-Go FFI Communication
// =============================================================================

func TestFfiClientConn_Ping(t *testing.T) {
	server := NewMockFfiServer()
	conn := NewFfiClientConn(server)

	client := NewHealthServiceClient(conn)
	resp, err := client.Ping(context.Background(), &empty.Empty{})

	if err != nil {
		t.Fatalf("Ping failed: %v", err)
	}
	if resp.Version != "test-1.0.0" {
		t.Errorf("expected version 'test-1.0.0', got '%s'", resp.Version)
	}
	if resp.Timestamp == nil {
		t.Error("expected non-nil timestamp")
	}
	if atomic.LoadInt64(&server.pingCount) != 1 {
		t.Errorf("expected ping count 1, got %d", server.pingCount)
	}
}

func TestFfiClientConn_CachePutAndGet(t *testing.T) {
	server := NewMockFfiServer()
	conn := NewFfiClientConn(server)

	client := NewCacheServiceClient(conn)
	ctx := context.Background()

	// Put
	_, err := client.Put(ctx, &PutCacheRequest{
		StoreName:  "test-store",
		Key:        "test-key",
		Value:      []byte("test-value"),
		TtlSeconds: 60,
	})
	if err != nil {
		t.Fatalf("Put failed: %v", err)
	}

	// Get
	getResp, err := client.Get(ctx, &GetCacheRequest{
		StoreName: "test-store",
		Key:       "test-key",
	})
	if err != nil {
		t.Fatalf("Get failed: %v", err)
	}
	if string(getResp.Value) != "test-value" {
		t.Errorf("expected 'test-value', got '%s'", string(getResp.Value))
	}
}

func TestFfiClientConn_CacheContains(t *testing.T) {
	server := NewMockFfiServer()
	conn := NewFfiClientConn(server)

	client := NewCacheServiceClient(conn)
	ctx := context.Background()

	// Should not exist
	resp, err := client.Contains(ctx, &GetCacheRequest{
		StoreName: "test-store",
		Key:       "non-existent",
	})
	if err != nil {
		t.Fatalf("Contains failed: %v", err)
	}
	if resp.Value {
		t.Error("expected key not to exist")
	}

	// Put a value
	_, err = client.Put(ctx, &PutCacheRequest{
		StoreName: "test-store",
		Key:       "exists-key",
		Value:     []byte("value"),
	})
	if err != nil {
		t.Fatalf("Put failed: %v", err)
	}

	// Should exist
	resp, err = client.Contains(ctx, &GetCacheRequest{
		StoreName: "test-store",
		Key:       "exists-key",
	})
	if err != nil {
		t.Fatalf("Contains failed: %v", err)
	}
	if !resp.Value {
		t.Error("expected key to exist")
	}
}

func TestFfiClientConn_CacheDelete(t *testing.T) {
	server := NewMockFfiServer()
	conn := NewFfiClientConn(server)

	client := NewCacheServiceClient(conn)
	ctx := context.Background()

	// Put
	_, err := client.Put(ctx, &PutCacheRequest{
		StoreName: "test-store",
		Key:       "delete-key",
		Value:     []byte("value"),
	})
	if err != nil {
		t.Fatalf("Put failed: %v", err)
	}

	// Delete
	_, err = client.Delete(ctx, &DeleteCacheRequest{
		StoreName: "test-store",
		Key:       "delete-key",
	})
	if err != nil {
		t.Fatalf("Delete failed: %v", err)
	}

	// Should not exist
	containsResp, err := client.Contains(ctx, &GetCacheRequest{
		StoreName: "test-store",
		Key:       "delete-key",
	})
	if err != nil {
		t.Fatalf("Contains failed: %v", err)
	}
	if containsResp.Value {
		t.Error("expected key to not exist after delete")
	}
}

func TestFfiClientConn_CacheClear(t *testing.T) {
	server := NewMockFfiServer()
	conn := NewFfiClientConn(server)

	client := NewCacheServiceClient(conn)
	ctx := context.Background()

	// Put multiple values
	for i := 0; i < 5; i++ {
		_, err := client.Put(ctx, &PutCacheRequest{
			StoreName: "clear-store",
			Key:       fmt.Sprintf("key-%d", i),
			Value:     []byte(fmt.Sprintf("value-%d", i)),
		})
		if err != nil {
			t.Fatalf("Put failed: %v", err)
		}
	}

	// Clear
	_, err := client.Clear(ctx, &ClearCacheRequest{
		StoreName: "clear-store",
	})
	if err != nil {
		t.Fatalf("Clear failed: %v", err)
	}

	// Verify all cleared
	for i := 0; i < 5; i++ {
		resp, err := client.Contains(ctx, &GetCacheRequest{
			StoreName: "clear-store",
			Key:       fmt.Sprintf("key-%d", i),
		})
		if err != nil {
			t.Fatalf("Contains failed: %v", err)
		}
		if resp.Value {
			t.Errorf("key-%d should have been cleared", i)
		}
	}
}

func TestFfiClientConn_MultipleSequentialCalls(t *testing.T) {
	server := NewMockFfiServer()
	conn := NewFfiClientConn(server)

	client := NewHealthServiceClient(conn)
	ctx := context.Background()

	for i := 0; i < 100; i++ {
		resp, err := client.Ping(ctx, &empty.Empty{})
		if err != nil {
			t.Fatalf("Ping %d failed: %v", i, err)
		}
		if resp.Version != "test-1.0.0" {
			t.Errorf("Ping %d: expected version 'test-1.0.0', got '%s'", i, resp.Version)
		}
	}

	if atomic.LoadInt64(&server.pingCount) != 100 {
		t.Errorf("expected ping count 100, got %d", server.pingCount)
	}
}

func TestFfiClientConn_ConcurrentCalls(t *testing.T) {
	server := NewMockFfiServer()
	conn := NewFfiClientConn(server)

	client := NewHealthServiceClient(conn)
	ctx := context.Background()

	var wg sync.WaitGroup
	errChan := make(chan error, 100)

	for i := 0; i < 10; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < 10; j++ {
				_, err := client.Ping(ctx, &empty.Empty{})
				if err != nil {
					errChan <- err
				}
			}
		}()
	}

	wg.Wait()
	close(errChan)

	for err := range errChan {
		t.Errorf("concurrent call failed: %v", err)
	}

	if atomic.LoadInt64(&server.pingCount) != 100 {
		t.Errorf("expected ping count 100, got %d", server.pingCount)
	}
}

func TestFfiClientConn_MultipleClients(t *testing.T) {
	server := NewMockFfiServer()

	// Create multiple clients sharing the same server
	conn1 := NewFfiClientConn(server)
	conn2 := NewFfiClientConn(server)

	client1 := NewHealthServiceClient(conn1)
	client2 := NewHealthServiceClient(conn2)

	ctx := context.Background()

	// Both clients should work
	resp1, err := client1.Ping(ctx, &empty.Empty{})
	if err != nil {
		t.Fatalf("client1 Ping failed: %v", err)
	}
	resp2, err := client2.Ping(ctx, &empty.Empty{})
	if err != nil {
		t.Fatalf("client2 Ping failed: %v", err)
	}

	if resp1.Version != resp2.Version {
		t.Errorf("versions should match: %s vs %s", resp1.Version, resp2.Version)
	}

	if atomic.LoadInt64(&server.pingCount) != 2 {
		t.Errorf("expected ping count 2, got %d", server.pingCount)
	}
}

func TestFfiClientConn_ContextTimeout(t *testing.T) {
	server := NewMockFfiServer()
	conn := NewFfiClientConn(server)

	client := NewHealthServiceClient(conn)

	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()

	// This should complete before timeout
	resp, err := client.Ping(ctx, &empty.Empty{})
	if err != nil {
		t.Fatalf("Ping failed: %v", err)
	}
	if resp.Version != "test-1.0.0" {
		t.Errorf("expected version 'test-1.0.0', got '%s'", resp.Version)
	}
}

func TestFfiClientConn_LargePayload(t *testing.T) {
	server := NewMockFfiServer()
	conn := NewFfiClientConn(server)

	client := NewCacheServiceClient(conn)
	ctx := context.Background()

	// Create a large payload (1MB)
	largeValue := make([]byte, 1024*1024)
	for i := range largeValue {
		largeValue[i] = byte(i % 256)
	}

	// Put large value
	_, err := client.Put(ctx, &PutCacheRequest{
		StoreName: "large-store",
		Key:       "large-key",
		Value:     largeValue,
	})
	if err != nil {
		t.Fatalf("Put large value failed: %v", err)
	}

	// Get large value
	getResp, err := client.Get(ctx, &GetCacheRequest{
		StoreName: "large-store",
		Key:       "large-key",
	})
	if err != nil {
		t.Fatalf("Get large value failed: %v", err)
	}

	if len(getResp.Value) != len(largeValue) {
		t.Errorf("expected length %d, got %d", len(largeValue), len(getResp.Value))
	}

	// Verify content
	for i := 0; i < len(largeValue); i++ {
		if getResp.Value[i] != largeValue[i] {
			t.Errorf("mismatch at index %d: expected %d, got %d", i, largeValue[i], getResp.Value[i])
			break
		}
	}
}

func TestFfiClientConn_EmptyResponse(t *testing.T) {
	server := NewMockFfiServer()
	conn := NewFfiClientConn(server)

	client := NewCacheServiceClient(conn)
	ctx := context.Background()

	// Get non-existent key
	getResp, err := client.Get(ctx, &GetCacheRequest{
		StoreName: "test-store",
		Key:       "non-existent-key",
	})
	if err != nil {
		t.Fatalf("Get failed: %v", err)
	}
	if len(getResp.Value) != 0 {
		t.Errorf("expected empty value, got %v", getResp.Value)
	}
}

func TestFfiClientConn_DropInReplacement(t *testing.T) {
	// This test demonstrates that FfiClientConn is a drop-in replacement
	// for grpc.ClientConn - you can use the same generated client code
	server := NewMockFfiServer()
	conn := NewFfiClientConn(server)

	// Use standard generated client - same API as with real gRPC
	healthClient := NewHealthServiceClient(conn)
	cacheClient := NewCacheServiceClient(conn)

	ctx := context.Background()

	// Test health check
	pingResp, err := healthClient.Ping(ctx, &empty.Empty{})
	if err != nil {
		t.Fatalf("Ping failed: %v", err)
	}
	t.Logf("Ping response: version=%s, timestamp=%v", pingResp.Version, pingResp.Timestamp)

	// Test cache operations
	_, err = cacheClient.Put(ctx, &PutCacheRequest{
		StoreName:  "my-store",
		Key:        "my-key",
		Value:      []byte("my-value"),
		TtlSeconds: 3600,
	})
	if err != nil {
		t.Fatalf("Put failed: %v", err)
	}

	getResp, err := cacheClient.Get(ctx, &GetCacheRequest{
		StoreName: "my-store",
		Key:       "my-key",
	})
	if err != nil {
		t.Fatalf("Get failed: %v", err)
	}
	if string(getResp.Value) != "my-value" {
		t.Errorf("expected 'my-value', got '%s'", string(getResp.Value))
	}

	t.Log("FfiClientConn works as a drop-in replacement for grpc.ClientConn!")
}

// =============================================================================
// Benchmark Tests
// =============================================================================

func BenchmarkFfiClientConn_Ping(b *testing.B) {
	server := NewMockFfiServer()
	conn := NewFfiClientConn(server)

	client := NewHealthServiceClient(conn)
	ctx := context.Background()

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_, err := client.Ping(ctx, &empty.Empty{})
		if err != nil {
			b.Fatalf("Ping failed: %v", err)
		}
	}
}

func BenchmarkFfiClientConn_CachePutGet(b *testing.B) {
	server := NewMockFfiServer()
	conn := NewFfiClientConn(server)

	client := NewCacheServiceClient(conn)
	ctx := context.Background()

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		key := fmt.Sprintf("key-%d", i)
		value := []byte(fmt.Sprintf("value-%d", i))

		_, err := client.Put(ctx, &PutCacheRequest{
			StoreName: "bench-store",
			Key:       key,
			Value:     value,
		})
		if err != nil {
			b.Fatalf("Put failed: %v", err)
		}

		_, err = client.Get(ctx, &GetCacheRequest{
			StoreName: "bench-store",
			Key:       key,
		})
		if err != nil {
			b.Fatalf("Get failed: %v", err)
		}
	}
}

func BenchmarkFfiClientConn_Parallel(b *testing.B) {
	server := NewMockFfiServer()
	conn := NewFfiClientConn(server)

	client := NewHealthServiceClient(conn)
	ctx := context.Background()

	b.ResetTimer()
	b.RunParallel(func(pb *testing.PB) {
		for pb.Next() {
			_, err := client.Ping(ctx, &empty.Empty{})
			if err != nil {
				b.Errorf("Ping failed: %v", err)
			}
		}
	})
}

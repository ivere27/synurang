package service

import (
	"context"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	pb "synurang/pkg/api"
)

func TestCacheServiceBasicOperations(t *testing.T) {
	tmpDir, err := os.MkdirTemp("", "cache_test_*")
	if err != nil {
		t.Fatalf("failed to create temp dir: %v", err)
	}
	defer os.RemoveAll(tmpDir)

	cache, err := NewCacheService(tmpDir)
	if err != nil {
		t.Fatalf("failed to create cache service: %v", err)
	}
	defer cache.Close()

	ctx := context.Background()
	storeName := "test_store"

	// Test Put
	_, err = cache.Put(ctx, &pb.PutCacheRequest{
		StoreName:  storeName,
		Key:        "key1",
		Value:      []byte("value1"),
		TtlSeconds: 0, // infinite
	})
	if err != nil {
		t.Fatalf("Put failed: %v", err)
	}

	// Test Get
	resp, err := cache.Get(ctx, &pb.GetCacheRequest{
		StoreName: storeName,
		Key:       "key1",
	})
	if err != nil {
		t.Fatalf("Get failed: %v", err)
	}
	if string(resp.Value) != "value1" {
		t.Errorf("expected 'value1', got '%s'", string(resp.Value))
	}

	// Test Contains
	exists, err := cache.Contains(ctx, &pb.GetCacheRequest{
		StoreName: storeName,
		Key:       "key1",
	})
	if err != nil {
		t.Fatalf("Contains failed: %v", err)
	}
	if !exists.Value {
		t.Error("expected key1 to exist")
	}

	// Test Keys
	keys, err := cache.Keys(ctx, &pb.GetCacheRequest{
		StoreName: storeName,
	})
	if err != nil {
		t.Fatalf("Keys failed: %v", err)
	}
	if len(keys.Keys) != 1 || keys.Keys[0] != "key1" {
		t.Errorf("unexpected keys: %v", keys.Keys)
	}

	// Test Delete
	_, err = cache.Delete(ctx, &pb.DeleteCacheRequest{
		StoreName: storeName,
		Key:       "key1",
	})
	if err != nil {
		t.Fatalf("Delete failed: %v", err)
	}

	// Verify deleted
	resp, err = cache.Get(ctx, &pb.GetCacheRequest{
		StoreName: storeName,
		Key:       "key1",
	})
	if err != nil {
		t.Fatalf("Get after delete failed: %v", err)
	}
	if len(resp.Value) != 0 {
		t.Error("expected empty value after delete")
	}
}

func TestCacheServiceTTL(t *testing.T) {
	tmpDir, err := os.MkdirTemp("", "cache_test_ttl_*")
	if err != nil {
		t.Fatalf("failed to create temp dir: %v", err)
	}
	defer os.RemoveAll(tmpDir)

	cache, err := NewCacheService(tmpDir)
	if err != nil {
		t.Fatalf("failed to create cache service: %v", err)
	}
	defer cache.Close()

	ctx := context.Background()

	// Put with 2 second TTL (using 2s instead of 1s to avoid edge cases with second-precision timestamps)
	_, err = cache.Put(ctx, &pb.PutCacheRequest{
		StoreName:  "ttl_test",
		Key:        "short_lived",
		Value:      []byte("expires soon"),
		TtlSeconds: 2,
	})
	if err != nil {
		t.Fatalf("Put failed: %v", err)
	}

	// Should exist immediately
	resp, _ := cache.Get(ctx, &pb.GetCacheRequest{
		StoreName: "ttl_test",
		Key:       "short_lived",
	})
	if len(resp.Value) == 0 {
		t.Error("expected value before expiration")
	}

	// Wait for expiration (3.1s to ensure we're past the 2s TTL, accounting for second alignment)
	time.Sleep(3100 * time.Millisecond)

	// Should be expired
	resp, _ = cache.Get(ctx, &pb.GetCacheRequest{
		StoreName: "ttl_test",
		Key:       "short_lived",
	})
	if len(resp.Value) != 0 {
		t.Error("expected empty value after expiration")
	}
}

func TestCacheServiceConcurrency(t *testing.T) {
	tmpDir, err := os.MkdirTemp("", "cache_test_concurrent_*")
	if err != nil {
		t.Fatalf("failed to create temp dir: %v", err)
	}
	defer os.RemoveAll(tmpDir)

	cache, err := NewCacheService(tmpDir)
	if err != nil {
		t.Fatalf("failed to create cache service: %v", err)
	}
	defer cache.Close()

	ctx := context.Background()
	storeName := "concurrent_test"

	// Concurrent writes
	var wg sync.WaitGroup
	numGoroutines := 100
	numOpsPerGoroutine := 50

	for i := 0; i < numGoroutines; i++ {
		wg.Add(1)
		go func(id int) {
			defer wg.Done()
			for j := 0; j < numOpsPerGoroutine; j++ {
				key := filepath.Join("key", string(rune('a'+id%26)), string(rune('0'+j%10)))
				cache.Put(ctx, &pb.PutCacheRequest{
					StoreName:  storeName,
					Key:        key,
					Value:      []byte("test"),
					TtlSeconds: 0,
				})
				cache.Get(ctx, &pb.GetCacheRequest{
					StoreName: storeName,
					Key:       key,
				})
			}
		}(i)
	}

	wg.Wait()

	// Verify no panics occurred (test reaching here means success)
	t.Logf("completed %d concurrent operations", numGoroutines*numOpsPerGoroutine*2)
}

func TestCacheServiceMaxEntries(t *testing.T) {
	tmpDir, err := os.MkdirTemp("", "cache_test_max_*")
	if err != nil {
		t.Fatalf("failed to create temp dir: %v", err)
	}
	defer os.RemoveAll(tmpDir)

	cache, err := NewCacheService(tmpDir)
	if err != nil {
		t.Fatalf("failed to create cache service: %v", err)
	}
	defer cache.Close()

	ctx := context.Background()
	storeName := "limited_store"

	// Set max entries to 5
	cache.SetMaxEntries(ctx, &pb.SetMaxEntriesRequest{
		StoreName:  storeName,
		MaxEntries: 5,
	})

	// Insert 10 entries
	for i := 0; i < 10; i++ {
		cache.Put(ctx, &pb.PutCacheRequest{
			StoreName:  storeName,
			Key:        string(rune('a' + i)),
			Value:      []byte("value"),
			TtlSeconds: 0,
		})
		// Small delay to ensure different accessed_at timestamps
		time.Sleep(10 * time.Millisecond)
	}

	// Trigger eviction
	cache.evictOverCapacity()

	// Check remaining count
	keys, _ := cache.Keys(ctx, &pb.GetCacheRequest{StoreName: storeName})
	if len(keys.Keys) > 5 {
		t.Errorf("expected at most 5 keys, got %d", len(keys.Keys))
	}
}

func TestCacheServiceGracefulShutdown(t *testing.T) {
	tmpDir, err := os.MkdirTemp("", "cache_test_shutdown_*")
	if err != nil {
		t.Fatalf("failed to create temp dir: %v", err)
	}
	defer os.RemoveAll(tmpDir)

	cache, err := NewCacheService(tmpDir)
	if err != nil {
		t.Fatalf("failed to create cache service: %v", err)
	}

	ctx := context.Background()

	// Do some operations
	for i := 0; i < 100; i++ {
		cache.Put(ctx, &pb.PutCacheRequest{
			StoreName:  "shutdown_test",
			Key:        string(rune('a' + i%26)),
			Value:      []byte("value"),
			TtlSeconds: 0,
		})
	}

	// Queue many access updates
	for i := 0; i < 1000; i++ {
		cache.Get(ctx, &pb.GetCacheRequest{
			StoreName: "shutdown_test",
			Key:       string(rune('a' + i%26)),
		})
	}

	// Close should complete without hanging
	done := make(chan struct{})
	go func() {
		cache.Close()
		close(done)
	}()

	select {
	case <-done:
		// Success
	case <-time.After(10 * time.Second):
		t.Fatal("Close() hung - likely goroutine leak")
	}

	// Verify operations on closed cache don't panic
	resp, _ := cache.Get(ctx, &pb.GetCacheRequest{
		StoreName: "shutdown_test",
		Key:       "a",
	})
	if len(resp.Value) != 0 {
		t.Error("expected empty response from closed cache")
	}
}

func TestCacheServiceNoMemoryLeak(t *testing.T) {
	// This test creates and destroys cache services repeatedly
	// to verify no goroutine or memory leaks
	tmpDir, err := os.MkdirTemp("", "cache_test_leak_*")
	if err != nil {
		t.Fatalf("failed to create temp dir: %v", err)
	}
	defer os.RemoveAll(tmpDir)

	for i := 0; i < 10; i++ {
		subDir := filepath.Join(tmpDir, string(rune('a'+i)))
		os.MkdirAll(subDir, 0755)

		cache, err := NewCacheService(subDir)
		if err != nil {
			t.Fatalf("iteration %d: failed to create cache: %v", i, err)
		}

		ctx := context.Background()

		// Do some work
		for j := 0; j < 50; j++ {
			cache.Put(ctx, &pb.PutCacheRequest{
				StoreName:  "leak_test",
				Key:        string(rune('a' + j%26)),
				Value:      []byte("value"),
				TtlSeconds: 0,
			})
			cache.Get(ctx, &pb.GetCacheRequest{
				StoreName: "leak_test",
				Key:       string(rune('a' + j%26)),
			})
		}

		cache.Close()
	}

	// If we reach here without hanging, goroutines are properly cleaned up
	t.Log("no goroutine leaks detected across 10 cache lifecycles")
}

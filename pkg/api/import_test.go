package api

// import_test.go
//
// Test that proto imports work correctly in Go.
// Verifies that well-known types (timestamp, empty, wrappers, etc.) are properly
// imported from the standard protobuf packages.

import (
	"testing"
	"time"

	duration "github.com/golang/protobuf/ptypes/duration"
	empty "github.com/golang/protobuf/ptypes/empty"
	timestamp "github.com/golang/protobuf/ptypes/timestamp"
	wrappers "github.com/golang/protobuf/ptypes/wrappers"
	"google.golang.org/protobuf/proto"
)

func TestTimestampImport(t *testing.T) {
	// Create a Timestamp using the imported package
	ts := &timestamp.Timestamp{
		Seconds: 1234567890,
		Nanos:   123456789,
	}

	if ts.Seconds != 1234567890 {
		t.Errorf("Expected seconds 1234567890, got %d", ts.Seconds)
	}
	if ts.Nanos != 123456789 {
		t.Errorf("Expected nanos 123456789, got %d", ts.Nanos)
	}
}

func TestEmptyImport(t *testing.T) {
	// Create an Empty message
	emptyMsg := &empty.Empty{}

	// Verify it's not nil
	if emptyMsg == nil {
		t.Error("Empty message should not be nil")
	}

	// Verify it serializes correctly (should be empty bytes)
	data, err := proto.Marshal(emptyMsg)
	if err != nil {
		t.Fatalf("Failed to marshal empty: %v", err)
	}
	if len(data) != 0 {
		t.Errorf("Expected empty bytes, got %d bytes", len(data))
	}
}

func TestWrappersImport(t *testing.T) {
	// Test BoolValue
	boolVal := &wrappers.BoolValue{Value: true}
	if !boolVal.Value {
		t.Error("Expected BoolValue to be true")
	}

	// Test StringValue
	stringVal := &wrappers.StringValue{Value: "hello"}
	if stringVal.Value != "hello" {
		t.Errorf("Expected 'hello', got '%s'", stringVal.Value)
	}

	// Test Int32Value
	int32Val := &wrappers.Int32Value{Value: 42}
	if int32Val.Value != 42 {
		t.Errorf("Expected 42, got %d", int32Val.Value)
	}

	// Test Int64Value
	int64Val := &wrappers.Int64Value{Value: 9876543210}
	if int64Val.Value != 9876543210 {
		t.Errorf("Expected 9876543210, got %d", int64Val.Value)
	}

	// Test DoubleValue
	doubleVal := &wrappers.DoubleValue{Value: 3.14159}
	if doubleVal.Value < 3.14 || doubleVal.Value > 3.15 {
		t.Errorf("Expected ~3.14159, got %f", doubleVal.Value)
	}

	// Test BytesValue
	bytesVal := &wrappers.BytesValue{Value: []byte{1, 2, 3, 4, 5}}
	if len(bytesVal.Value) != 5 {
		t.Errorf("Expected 5 bytes, got %d", len(bytesVal.Value))
	}
}

func TestDurationImport(t *testing.T) {
	// Create a Duration (5 seconds and 500ms)
	dur := &duration.Duration{
		Seconds: 5,
		Nanos:   500000000,
	}

	if dur.Seconds != 5 {
		t.Errorf("Expected 5 seconds, got %d", dur.Seconds)
	}
	if dur.Nanos != 500000000 {
		t.Errorf("Expected 500000000 nanos, got %d", dur.Nanos)
	}
}

func TestPingResponseUsesImportedTimestamp(t *testing.T) {
	// PingResponse contains a google.protobuf.Timestamp field
	// Verify it uses the correct import
	now := time.Now()
	ts := &timestamp.Timestamp{
		Seconds: now.Unix(),
		Nanos:   int32(now.Nanosecond()),
	}

	response := &PingResponse{
		Timestamp: ts,
		Version:   "1.0.0",
	}

	if response.Timestamp == nil {
		t.Fatal("Timestamp should not be nil")
	}
	if response.Version != "1.0.0" {
		t.Errorf("Expected version '1.0.0', got '%s'", response.Version)
	}

	// Verify serialization/deserialization works
	data, err := proto.Marshal(response)
	if err != nil {
		t.Fatalf("Failed to marshal PingResponse: %v", err)
	}

	decoded := &PingResponse{}
	if err := proto.Unmarshal(data, decoded); err != nil {
		t.Fatalf("Failed to unmarshal PingResponse: %v", err)
	}

	if decoded.Version != response.Version {
		t.Errorf("Decoded version mismatch: got '%s', want '%s'", decoded.Version, response.Version)
	}
	if decoded.Timestamp.Seconds != response.Timestamp.Seconds {
		t.Errorf("Decoded timestamp seconds mismatch: got %d, want %d", decoded.Timestamp.Seconds, response.Timestamp.Seconds)
	}
}

func TestCacheServiceMessages(t *testing.T) {
	// Test messages that are part of CacheService (which uses empty return types)
	request := &GetCacheRequest{
		StoreName: "test-store",
		Key:       "test-key",
	}

	if request.StoreName != "test-store" {
		t.Errorf("Expected 'test-store', got '%s'", request.StoreName)
	}
	if request.Key != "test-key" {
		t.Errorf("Expected 'test-key', got '%s'", request.Key)
	}

	// Verify serialization roundtrip
	data, err := proto.Marshal(request)
	if err != nil {
		t.Fatalf("Failed to marshal GetCacheRequest: %v", err)
	}

	decoded := &GetCacheRequest{}
	if err := proto.Unmarshal(data, decoded); err != nil {
		t.Fatalf("Failed to unmarshal GetCacheRequest: %v", err)
	}

	if decoded.StoreName != request.StoreName {
		t.Errorf("StoreName mismatch: got '%s', want '%s'", decoded.StoreName, request.StoreName)
	}
	if decoded.Key != request.Key {
		t.Errorf("Key mismatch: got '%s', want '%s'", decoded.Key, request.Key)
	}
}

func TestPutCacheRequestSerializesCorrectly(t *testing.T) {
	// Test PutCacheRequest which is used with empty return type
	request := &PutCacheRequest{
		StoreName:  "cache1",
		Key:        "mykey",
		Value:      []byte{1, 2, 3, 4, 5},
		TtlSeconds: 3600,
		Cost:       100,
	}

	data, err := proto.Marshal(request)
	if err != nil {
		t.Fatalf("Failed to marshal PutCacheRequest: %v", err)
	}

	decoded := &PutCacheRequest{}
	if err := proto.Unmarshal(data, decoded); err != nil {
		t.Fatalf("Failed to unmarshal PutCacheRequest: %v", err)
	}

	if decoded.StoreName != "cache1" {
		t.Errorf("Expected 'cache1', got '%s'", decoded.StoreName)
	}
	if decoded.Key != "mykey" {
		t.Errorf("Expected 'mykey', got '%s'", decoded.Key)
	}
	if len(decoded.Value) != 5 {
		t.Errorf("Expected 5 bytes, got %d", len(decoded.Value))
	}
	if decoded.TtlSeconds != 3600 {
		t.Errorf("Expected 3600, got %d", decoded.TtlSeconds)
	}
	if decoded.Cost != 100 {
		t.Errorf("Expected 100, got %d", decoded.Cost)
	}
}

func TestInteroperabilityWithEmptyType(t *testing.T) {
	// Verify that empty.Empty from the imported package is the correct type
	// that can be used with gRPC services

	emptyMsg := &empty.Empty{}

	// Serialize
	data, err := proto.Marshal(emptyMsg)
	if err != nil {
		t.Fatalf("Failed to marshal empty: %v", err)
	}

	// Deserialize
	decoded := &empty.Empty{}
	if err := proto.Unmarshal(data, decoded); err != nil {
		t.Fatalf("Failed to unmarshal empty: %v", err)
	}

	// Both should be valid empty messages
	if emptyMsg == nil || decoded == nil {
		t.Error("Empty messages should not be nil")
	}
}

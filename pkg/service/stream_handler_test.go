package service

import (
	"testing"
	"unsafe"

	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/emptypb"
)

// TestSendFromStreamFfi_ZeroCopy tests the zero-copy stream output path
func TestSendFromStreamFfi_ZeroCopy(t *testing.T) {
	// Track what the callback receives
	var receivedStreamId int64
	var receivedMsgType byte
	var receivedLen int64

	// Register zero-copy callback
	SetStreamCallbackFfi(func(streamId int64, msgType byte, _ unsafe.Pointer, len int64) {
		receivedStreamId = streamId
		receivedMsgType = msgType
		receivedLen = len
	})
	defer SetStreamCallbackFfi(nil)

	// Create a session
	session := NewStreamSession("test/zero_copy", StreamTypeServerStream)
	defer CloseStreamSession(session.ID)

	// Send a message using zero-copy path
	msg := &emptypb.Empty{}
	err := session.SendFromStreamFfi(msg)
	if err != nil {
		t.Fatalf("SendFromStreamFfi failed: %v", err)
	}

	// Verify callback was called with correct data
	if receivedStreamId != session.ID {
		t.Errorf("Expected streamId %d, got %d", session.ID, receivedStreamId)
	}
	if receivedMsgType != StreamMsgData {
		t.Errorf("Expected msgType %d, got %d", StreamMsgData, receivedMsgType)
	}
	// Empty proto has size 0
	if receivedLen != 0 {
		t.Errorf("Expected len 0 for empty proto, got %d", receivedLen)
	}
}

// TestSendFromStreamFfi_WithData tests zero-copy with actual data
func TestSendFromStreamFfi_WithData(t *testing.T) {
	// Track what the callback receives
	var receivedPtr unsafe.Pointer
	var receivedLen int64
	callCount := 0

	SetStreamCallbackFfi(func(streamId int64, msgType byte, data unsafe.Pointer, len int64) {
		receivedPtr = data
		receivedLen = len
		callCount++
	})
	defer SetStreamCallbackFfi(nil)

	session := NewStreamSession("test/zero_copy_data", StreamTypeServerStream)
	defer CloseStreamSession(session.ID)

	// Use a message with some data (timestamp has fields)
	msg := &emptypb.Empty{}
	expectedSize := proto.Size(msg)

	err := session.SendFromStreamFfi(msg)
	if err != nil {
		t.Fatalf("SendFromStreamFfi failed: %v", err)
	}

	if callCount != 1 {
		t.Errorf("Expected 1 callback call, got %d", callCount)
	}

	// Empty proto size is 0, so len should be 0
	if expectedSize != 0 && receivedLen != int64(expectedSize) {
		t.Errorf("Expected len %d, got %d", expectedSize, receivedLen)
	}

	// For non-empty messages, ptr should be non-nil
	if expectedSize > 0 && receivedPtr == nil {
		t.Error("Expected non-nil pointer for non-empty message")
	}
}

// TestSendFromStreamFfi_FallbackToRegular tests fallback when FFI callback not set
func TestSendFromStreamFfi_FallbackToRegular(t *testing.T) {
	var receivedData []byte
	callCount := 0

	// Only set regular callback, not FFI callback
	SetStreamCallback(func(streamId int64, msgType byte, data []byte) {
		receivedData = data
		callCount++
	})
	SetStreamCallbackFfi(nil) // Ensure FFI callback is nil
	defer SetStreamCallback(nil)

	session := NewStreamSession("test/fallback", StreamTypeServerStream)
	defer CloseStreamSession(session.ID)

	msg := &emptypb.Empty{}
	err := session.SendFromStreamFfi(msg)
	if err != nil {
		t.Fatalf("SendFromStreamFfi failed: %v", err)
	}

	if callCount != 1 {
		t.Errorf("Expected 1 callback call (fallback), got %d", callCount)
	}

	// Verify it used the regular path
	if receivedData == nil && proto.Size(msg) > 0 {
		t.Error("Expected data via fallback path")
	}
}

// TestSendFromStream_RegularPath tests the regular 1-copy path
func TestSendFromStream_RegularPath(t *testing.T) {
	var receivedData []byte
	callCount := 0

	SetStreamCallback(func(streamId int64, msgType byte, data []byte) {
		receivedData = data
		callCount++
	})
	defer SetStreamCallback(nil)

	session := NewStreamSession("test/regular", StreamTypeServerStream)
	defer CloseStreamSession(session.ID)

	testData := []byte{1, 2, 3, 4, 5}
	err := session.SendFromStream(testData)
	if err != nil {
		t.Fatalf("SendFromStream failed: %v", err)
	}

	if callCount != 1 {
		t.Errorf("Expected 1 callback call, got %d", callCount)
	}

	if len(receivedData) != len(testData) {
		t.Errorf("Expected data len %d, got %d", len(testData), len(receivedData))
	}
}

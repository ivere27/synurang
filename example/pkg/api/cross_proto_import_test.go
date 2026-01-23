package api

// cross_proto_import_test.go
//
// Test that one proto file can import types from another proto file.
// example.proto imports core.proto and uses core.v1.Error and core.v1.PingResponse.

import (
	"testing"

	timestamp "github.com/golang/protobuf/ptypes/timestamp"
	"google.golang.org/protobuf/proto"
	coreapi "github.com/ivere27/synurang/pkg/api"
)

func TestCrossProtoImport_ErrorFromCoreProto(t *testing.T) {
	// Create an Error message from core.proto
	err := &coreapi.Error{
		Code:     500,
		Message:  "Internal Server Error",
		GrpcCode: 13, // INTERNAL
	}

	// Use it in CrossProtoTestMessage from example.proto
	msg := &CrossProtoTestMessage{
		Error:       err,
		Description: "Test message with imported Error type",
	}

	if msg.Error == nil {
		t.Fatal("Error should not be nil")
	}
	if msg.Error.Code != 500 {
		t.Errorf("Expected error code 500, got %d", msg.Error.Code)
	}
	if msg.Error.Message != "Internal Server Error" {
		t.Errorf("Expected 'Internal Server Error', got '%s'", msg.Error.Message)
	}
}

func TestCrossProtoImport_PingResponseFromCoreProto(t *testing.T) {
	// Create a PingResponse message from core.proto
	pingResp := &coreapi.PingResponse{
		Timestamp: &timestamp.Timestamp{
			Seconds: 1234567890,
			Nanos:   123456789,
		},
		Version: "1.0.0",
	}

	// Use it in CrossProtoTestMessage from example.proto
	msg := &CrossProtoTestMessage{
		PingResponse: pingResp,
		Description:  "Test message with imported PingResponse type",
	}

	if msg.PingResponse == nil {
		t.Fatal("PingResponse should not be nil")
	}
	if msg.PingResponse.Version != "1.0.0" {
		t.Errorf("Expected version '1.0.0', got '%s'", msg.PingResponse.Version)
	}
	if msg.PingResponse.Timestamp.Seconds != 1234567890 {
		t.Errorf("Expected timestamp seconds 1234567890, got %d", msg.PingResponse.Timestamp.Seconds)
	}
}

func TestCrossProtoImport_BothImportedTypes(t *testing.T) {
	// Create a message that uses both imported types
	msg := &CrossProtoTestMessage{
		Error: &coreapi.Error{
			Code:     404,
			Message:  "Not Found",
			GrpcCode: 5, // NOT_FOUND
		},
		PingResponse: &coreapi.PingResponse{
			Timestamp: &timestamp.Timestamp{
				Seconds: 9876543210,
				Nanos:   0,
			},
			Version: "2.0.0",
		},
		Description: "Combined test with both imported types",
	}

	// Verify all fields
	if msg.Error.Code != 404 {
		t.Errorf("Expected error code 404, got %d", msg.Error.Code)
	}
	if msg.PingResponse.Version != "2.0.0" {
		t.Errorf("Expected version '2.0.0', got '%s'", msg.PingResponse.Version)
	}
	if msg.Description != "Combined test with both imported types" {
		t.Errorf("Unexpected description: %s", msg.Description)
	}
}

func TestCrossProtoImport_Serialization(t *testing.T) {
	// Create a full message
	original := &CrossProtoTestMessage{
		Error: &coreapi.Error{
			Code:     400,
			Message:  "Bad Request",
			GrpcCode: 3, // INVALID_ARGUMENT
		},
		PingResponse: &coreapi.PingResponse{
			Timestamp: &timestamp.Timestamp{
				Seconds: 1111111111,
				Nanos:   222222222,
			},
			Version: "3.0.0-beta",
		},
		Description: "Serialization test",
	}

	// Serialize
	data, err := proto.Marshal(original)
	if err != nil {
		t.Fatalf("Failed to marshal: %v", err)
	}

	t.Logf("Serialized size: %d bytes", len(data))

	// Deserialize
	decoded := &CrossProtoTestMessage{}
	if err := proto.Unmarshal(data, decoded); err != nil {
		t.Fatalf("Failed to unmarshal: %v", err)
	}

	// Verify Error field
	if decoded.Error == nil {
		t.Fatal("Decoded Error should not be nil")
	}
	if decoded.Error.Code != original.Error.Code {
		t.Errorf("Error.Code mismatch: got %d, want %d", decoded.Error.Code, original.Error.Code)
	}
	if decoded.Error.Message != original.Error.Message {
		t.Errorf("Error.Message mismatch: got '%s', want '%s'", decoded.Error.Message, original.Error.Message)
	}
	if decoded.Error.GrpcCode != original.Error.GrpcCode {
		t.Errorf("Error.GrpcCode mismatch: got %d, want %d", decoded.Error.GrpcCode, original.Error.GrpcCode)
	}

	// Verify PingResponse field
	if decoded.PingResponse == nil {
		t.Fatal("Decoded PingResponse should not be nil")
	}
	if decoded.PingResponse.Version != original.PingResponse.Version {
		t.Errorf("PingResponse.Version mismatch: got '%s', want '%s'",
			decoded.PingResponse.Version, original.PingResponse.Version)
	}
	if decoded.PingResponse.Timestamp.Seconds != original.PingResponse.Timestamp.Seconds {
		t.Errorf("PingResponse.Timestamp.Seconds mismatch: got %d, want %d",
			decoded.PingResponse.Timestamp.Seconds, original.PingResponse.Timestamp.Seconds)
	}

	// Verify Description field
	if decoded.Description != original.Description {
		t.Errorf("Description mismatch: got '%s', want '%s'", decoded.Description, original.Description)
	}
}

func TestCrossProtoImport_TypeCompatibility(t *testing.T) {
	// Verify that the imported types are the same as the original types
	// by assigning between them

	// Create Error from core package
	coreErr := &coreapi.Error{
		Code:    123,
		Message: "Test",
	}

	// Create PingResponse from core package
	corePing := &coreapi.PingResponse{
		Version: "test",
	}

	// Use them in CrossProtoTestMessage - this proves type compatibility
	msg := &CrossProtoTestMessage{
		Error:        coreErr,
		PingResponse: corePing,
	}

	// Get them back and verify they're the same objects
	if msg.GetError() != coreErr {
		t.Error("Retrieved Error should be the same object")
	}
	if msg.GetPingResponse() != corePing {
		t.Error("Retrieved PingResponse should be the same object")
	}
}

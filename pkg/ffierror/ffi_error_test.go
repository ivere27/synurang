package ffierror

import (
	"errors"
	"testing"

	pb "github.com/ivere27/synurang/pkg/api"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

func TestMarshalRoundTrip(t *testing.T) {
	errBytes := Marshal(errors.New("plain failure"))

	pbErr, err := Unmarshal(errBytes)
	if err != nil {
		t.Fatalf("Unmarshal failed: %v", err)
	}
	if pbErr.Message != "plain failure" {
		t.Fatalf("expected message to round-trip, got %q", pbErr.Message)
	}
	if pbErr.GrpcCode != int32(codes.Unknown) {
		t.Fatalf("expected grpc_code=%d, got %d", codes.Unknown, pbErr.GrpcCode)
	}
}

func TestStructuredHelperPreserved(t *testing.T) {
	pbErr, err := Unmarshal(Marshal(New(40901, "conflict", 10)))
	if err != nil {
		t.Fatalf("Unmarshal failed: %v", err)
	}
	if pbErr.Code != 40901 || pbErr.Message != "conflict" || pbErr.GrpcCode != 10 {
		t.Fatalf("expected helper fields to survive, got %+v", pbErr)
	}
}

func TestStatusDetailPreserved(t *testing.T) {
	orig := &pb.Error{
		Code:     409,
		Message:  "conflict",
		GrpcCode: int32(codes.Aborted),
	}
	st, err := status.New(codes.Aborted, "wrapper").WithDetails(orig)
	if err != nil {
		t.Fatalf("WithDetails failed: %v", err)
	}

	pbErr, err := Unmarshal(Marshal(st.Err()))
	if err != nil {
		t.Fatalf("Unmarshal failed: %v", err)
	}
	if pbErr.Code != orig.Code || pbErr.Message != orig.Message || pbErr.GrpcCode != orig.GrpcCode {
		t.Fatalf("expected detail to survive, got %+v", pbErr)
	}
}

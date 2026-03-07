package ffierror

import (
	"reflect"

	pb "github.com/ivere27/synurang/pkg/api"
	"google.golang.org/protobuf/proto"
)

const (
	grpcCodeOK      int32 = 0
	grpcCodeUnknown int32 = 2
)

type protoCarrier interface {
	FfiErrorProto() *pb.Error
}

// Error is a protobuf-only structured FFI error.
// It mirrors core.v1.Error without requiring any gRPC package imports.
type Error struct {
	Code     int32
	Message  string
	GrpcCode int32
}

func New(code int32, message string, grpcCode int32) *Error {
	return &Error{
		Code:     code,
		Message:  message,
		GrpcCode: grpcCode,
	}
}

func FromProto(pbErr *pb.Error) *Error {
	if pbErr == nil {
		return nil
	}
	return &Error{
		Code:     pbErr.Code,
		Message:  pbErr.Message,
		GrpcCode: pbErr.GrpcCode,
	}
}

func (e *Error) Error() string {
	if e == nil {
		return ""
	}
	return e.Message
}

func (e *Error) FfiErrorProto() *pb.Error {
	if e == nil {
		return nil
	}
	return &pb.Error{
		Code:     e.Code,
		Message:  e.Message,
		GrpcCode: e.GrpcCode,
	}
}

func FromError(err error) *pb.Error {
	if err == nil {
		return nil
	}

	if carrier, ok := err.(protoCarrier); ok {
		if pbErr := carrier.FfiErrorProto(); pbErr != nil {
			return cloneProtoError(pbErr)
		}
	}

	if pbErr, ok := fromGrpcStatus(err); ok {
		return pbErr
	}

	return &pb.Error{
		Message:  err.Error(),
		GrpcCode: grpcCodeUnknown,
	}
}

func Marshal(err error) []byte {
	pbErr := FromError(err)
	if pbErr == nil {
		return nil
	}
	data, marshalErr := proto.Marshal(pbErr)
	if marshalErr != nil {
		fallback, _ := proto.Marshal(&pb.Error{
			Message:  err.Error(),
			GrpcCode: grpcCodeUnknown,
		})
		if len(fallback) == 0 {
			return []byte{0x12, 0x00}
		}
		return fallback
	}
	if len(data) == 0 {
		return []byte{0x12, 0x00}
	}
	return data
}

func Unmarshal(data []byte) (*pb.Error, error) {
	pbErr := &pb.Error{}
	if err := proto.Unmarshal(data, pbErr); err != nil {
		return nil, err
	}
	return pbErr, nil
}

func cloneProtoError(pbErr *pb.Error) *pb.Error {
	return proto.Clone(pbErr).(*pb.Error)
}

// fromGrpcStatus extracts a *pb.Error from an error that implements the
// google.golang.org/grpc/status.Status interface, using reflection to avoid
// a hard dependency on the grpc package.
//
// This relies on duck-typing the following method signatures:
//
//	err.GRPCStatus() → *status.Status   (returns the Status wrapper)
//	status.Message() → string
//	status.Code()    → codes.Code (convertible to int32)
//	status.Details() → []any
//
// If google.golang.org/grpc/status ever changes these signatures, this
// function will silently stop extracting the fields. Keep this in sync with
// upstream grpc-go releases.
func fromGrpcStatus(err error) (*pb.Error, bool) {
	statusValue, ok := callNoArgMethod(reflect.ValueOf(err), "GRPCStatus")
	if !ok {
		return nil, false
	}

	message, haveMessage := callStringMethod(statusValue, "Message")
	grpcCode, haveCode := callInt32Method(statusValue, "Code")
	details, haveDetails := callSliceMethod(statusValue, "Details")
	if haveDetails {
		for _, detail := range details {
			switch typed := detail.(type) {
			case *pb.Error:
				out := cloneProtoError(typed)
				if out.Message == "" && haveMessage {
					out.Message = message
				}
				if out.GrpcCode == 0 && haveCode && grpcCode != grpcCodeOK {
					out.GrpcCode = grpcCode
				}
				return out, true
			case protoCarrier:
				if pbErr := typed.FfiErrorProto(); pbErr != nil {
					out := cloneProtoError(pbErr)
					if out.Message == "" && haveMessage {
						out.Message = message
					}
					if out.GrpcCode == 0 && haveCode && grpcCode != grpcCodeOK {
						out.GrpcCode = grpcCode
					}
					return out, true
				}
			}
		}
	}

	if !haveMessage && !haveCode {
		return nil, false
	}

	return &pb.Error{
		Message:  message,
		GrpcCode: grpcCode,
	}, true
}

func callNoArgMethod(value reflect.Value, name string) (reflect.Value, bool) {
	if !value.IsValid() {
		return reflect.Value{}, false
	}
	if value.Kind() == reflect.Interface {
		if value.IsNil() {
			return reflect.Value{}, false
		}
		value = value.Elem()
	}
	method := value.MethodByName(name)
	if !method.IsValid() || method.Type().NumIn() != 0 || method.Type().NumOut() != 1 {
		return reflect.Value{}, false
	}
	results := method.Call(nil)
	if len(results) != 1 {
		return reflect.Value{}, false
	}
	return results[0], true
}

func callStringMethod(value reflect.Value, name string) (string, bool) {
	result, ok := callNoArgMethod(value, name)
	if !ok {
		return "", false
	}
	if result.Kind() == reflect.Interface && !result.IsNil() {
		result = result.Elem()
	}
	if result.Kind() != reflect.String {
		return "", false
	}
	return result.String(), true
}

func callInt32Method(value reflect.Value, name string) (int32, bool) {
	result, ok := callNoArgMethod(value, name)
	if !ok {
		return 0, false
	}
	if result.Kind() == reflect.Interface && !result.IsNil() {
		result = result.Elem()
	}
	switch result.Kind() {
	case reflect.Int, reflect.Int8, reflect.Int16, reflect.Int32, reflect.Int64:
		return int32(result.Int()), true
	case reflect.Uint, reflect.Uint8, reflect.Uint16, reflect.Uint32, reflect.Uint64, reflect.Uintptr:
		return int32(result.Uint()), true
	default:
		return 0, false
	}
}

func callSliceMethod(value reflect.Value, name string) ([]any, bool) {
	result, ok := callNoArgMethod(value, name)
	if !ok {
		return nil, false
	}
	if result.Kind() == reflect.Interface && !result.IsNil() {
		result = result.Elem()
	}
	if result.Kind() != reflect.Slice {
		return nil, false
	}
	out := make([]any, 0, result.Len())
	for i := 0; i < result.Len(); i++ {
		out = append(out, result.Index(i).Interface())
	}
	return out, true
}

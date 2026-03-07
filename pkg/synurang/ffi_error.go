package synurang

import (
	"unicode/utf8"
)

// FfiError represents a structured error returned over a Synurang FFI boundary.
// It mirrors core.v1.Error and falls back to a plain message when the payload
// is not protobuf-encoded.
type FfiError struct {
	Message  string
	Code     int32
	GrpcCode int32
	Payload  []byte
}

func (e *FfiError) Error() string {
	return e.Message
}

func decodeFfiErrorPayload(payload []byte) *FfiError {
	var (
		index    int
		code     int32
		grpcCode int32
		message  string
		haveMsg  bool
	)
	for index < len(payload) {
		tag, next, ok := consumeVarint(payload, index)
		if !ok || tag == 0 {
			break
		}
		index = next
		field := tag >> 3
		wire := tag & 0x07
		switch {
		case field == 1 && wire == 0:
			value, n, ok := consumeVarint(payload, index)
			if !ok {
				index = len(payload)
				break
			}
			code = int32(value)
			index = n
		case field == 2 && wire == 2:
			size, n, ok := consumeVarint(payload, index)
			if !ok {
				index = len(payload)
				break
			}
			index = n
			end := index + int(size)
			if end > len(payload) {
				index = len(payload)
				break
			}
			message = string(payload[index:end])
			haveMsg = true
			index = end
		case field == 3 && wire == 0:
			value, n, ok := consumeVarint(payload, index)
			if !ok {
				index = len(payload)
				break
			}
			grpcCode = int32(value)
			index = n
		default:
			index = skipField(payload, index, wire)
		}
	}

	if !haveMsg {
		message = string(payload)
		if !utf8.Valid(payload) {
			message = string([]rune(string(payload)))
		}
	}
	return &FfiError{
		Message:  message,
		Code:     code,
		GrpcCode: grpcCode,
		Payload:  append([]byte(nil), payload...),
	}
}

func consumeVarint(data []byte, index int) (uint64, int, bool) {
	var value uint64
	var shift uint
	for index < len(data) && shift < 64 {
		b := data[index]
		index++
		value |= uint64(b&0x7f) << shift
		if (b & 0x80) == 0 {
			return value, index, true
		}
		shift += 7
	}
	return 0, index, false
}

func skipField(data []byte, index int, wire uint64) int {
	switch wire {
	case 0:
		_, next, ok := consumeVarint(data, index)
		if !ok {
			return len(data)
		}
		return next
	case 2:
		size, next, ok := consumeVarint(data, index)
		if !ok {
			return len(data)
		}
		end := next + int(size)
		if end > len(data) {
			return len(data)
		}
		return end
	default:
		return len(data)
	}
}

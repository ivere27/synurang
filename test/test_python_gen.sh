#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/synurang-python-gen.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

PROTO_DIR="$TMP_DIR/proto"
OUT_DIR="$TMP_DIR/out"
TARGET_DIR="$TMP_DIR/target"
mkdir -p "$PROTO_DIR/common" "$PROTO_DIR/nested" "$OUT_DIR"

cat > "$PROTO_DIR/common/types.proto" <<'PROTO'
syntax = "proto3";
package common.v1;

enum CommonKind {
  COMMON_KIND_UNSPECIFIED = 0;
  COMMON_KIND_FIRST = 1;
}

message Request {
  string value = 1;
}

message Response {
  string value = 1;
}
PROTO

cat > "$PROTO_DIR/nested/python_service.proto" <<'PROTO'
syntax = "proto3";
package python.test.v1;

import "common/types.proto";
import "google/protobuf/timestamp.proto";

enum State {
  STATE_UNSPECIFIED = 0;
  STATE_READY = 1;
}

service PythonService {
  rpc Unary(common.v1.Request) returns (common.v1.Response);
  rpc NestedUnary(Envelope.Nested) returns (Envelope.Nested);
  rpc ServerStream(common.v1.Request) returns (stream common.v1.Response);
  rpc ClientStream(stream common.v1.Request) returns (common.v1.Response);
  rpc BidiStream(stream common.v1.Request) returns (stream common.v1.Response);
  rpc BidiEarly(stream common.v1.Request) returns (stream common.v1.Response);
  rpc From(None) returns (None);
  rpc GetURL(common.v1.Request) returns (common.v1.Response);
}

enum KeywordEnum {
  False = 0;
  True = 1;
}

message None {
  message True {
    string value = 1;
  }
  string class = 1;
  True child = 2;
}

message Envelope {
  enum Level {
    LEVEL_UNSPECIFIED = 0;
    LEVEL_HIGH = 1;
  }

  message Nested {
    string value = 1;
    Level level = 2;
  }

  Nested nested = 1;
}

message FeatureMessage {
  int32 int32_value = 1;
  sint32 sint32_value = 2;
  sfixed32 sfixed32_value = 3;
  int64 int64_value = 4;
  sint64 sint64_value = 5;
  sfixed64 sfixed64_value = 6;
  uint32 uint32_value = 7;
  fixed32 fixed32_value = 8;
  uint64 uint64_value = 9;
  fixed64 fixed64_value = 10;
  float float_value = 11;
  double double_value = 12;
  bool bool_value = 13;
  string string_value = 14;
  bytes bytes_value = 15;
  State state = 16;
  repeated int32 packed_values = 17;
  repeated string names = 18;
  map<string, int32> labels = 19;
  map<int32, Envelope.Nested> nested_map = 20;
  optional int32 optional_count = 21;
  oneof choice {
    string choice_text = 22;
    int64 choice_id = 23;
  }
  Envelope.Nested nested = 24;
  common.v1.Request imported = 25;
  google.protobuf.Timestamp timestamp = 26;
}
PROTO

CARGO_TARGET_DIR="$TARGET_DIR" cargo build --quiet \
    --manifest-path "$ROOT_DIR/cmd/protoc-gen-synurang-ffi/Cargo.toml"

PLUGIN="$TARGET_DIR/debug/protoc-gen-synurang-ffi"
test -x "$PLUGIN"

protoc -I"$PROTO_DIR" -I/usr/include \
    --experimental_allow_proto3_optional \
    --plugin=protoc-gen-synurang-ffi="$PLUGIN" \
    --synurang-ffi_out="$OUT_DIR" \
    --synurang-ffi_opt=lang=python \
    common/types.proto nested/python_service.proto

GENERATED_FILE="$(find "$OUT_DIR" -type f -name 'python_service_ffi.py' -print -quit)"
if [[ -z "$GENERATED_FILE" ]]; then
    echo "Python generator did not produce python_service_ffi.py" >&2
    exit 1
fi
test -f "$OUT_DIR/python_service_lite.py"
test -f "$OUT_DIR/types_lite.py"
if find "$OUT_DIR" -type f -name '*_pb2.py' -print -quit | grep -q .; then
    echo "Python lite generation unexpectedly produced *_pb2.py" >&2
    exit 1
fi

python3 -m py_compile "$GENERATED_FILE"

PYTHONPATH="$ROOT_DIR/python:$OUT_DIR${PYTHONPATH:+:$PYTHONPATH}" \
PYTHONDONTWRITEBYTECODE=1 \
SYNURANG_GENERATED_PYTHON="$GENERATED_FILE" \
SYNURANG_GENERATED_OUT="$OUT_DIR" \
python3 "$ROOT_DIR/test/python/generated_client_check.py"

if python3 -c 'import grpc' >/dev/null 2>&1; then
    PYTHONPATH="$ROOT_DIR/python:$OUT_DIR${PYTHONPATH:+:$PYTHONPATH}" \
    PYTHONDONTWRITEBYTECODE=1 \
    SYNURANG_GENERATED_OUT="$OUT_DIR" \
    python3 "$ROOT_DIR/test/python/generated_grpc_check.py"
elif [[ "${SYNURANG_REQUIRE_GRPC_TEST:-0}" == "1" ]]; then
    echo "grpcio is required for the Python remote transport test" >&2
    exit 1
else
    echo "grpcio not installed; skipping optional remote gRPC integration check"
fi

LITE_OUT="$TMP_DIR/lite-out"
mkdir -p "$LITE_OUT"
protoc -I"$PROTO_DIR" -I/usr/include \
    --experimental_allow_proto3_optional \
    --plugin=protoc-gen-synurang-ffi="$PLUGIN" \
    --synurang-ffi_out="$LITE_OUT" \
    --synurang-ffi_opt=lang=python,mode=lite \
    common/types.proto nested/python_service.proto
test -f "$LITE_OUT/python_service_lite.py"
test -f "$LITE_OUT/types_lite.py"
if find "$LITE_OUT" -type f -name '*_ffi.py' -print -quit | grep -q .; then
    echo "Python mode=lite unexpectedly produced an FFI client" >&2
    exit 1
fi

cat > "$PROTO_DIR/legacy.proto" <<'PROTO'
syntax = "proto2";
package legacy.v1;
message Legacy { optional int32 value = 1 [default = 7]; }
PROTO

if output="$(protoc -I"$PROTO_DIR" \
    --plugin=protoc-gen-synurang-ffi="$PLUGIN" \
    --synurang-ffi_out="$LITE_OUT" \
    --synurang-ffi_opt=lang=python,mode=lite \
    legacy.proto 2>&1)"; then
    echo "Python lite generation unexpectedly accepted a proto2 schema" >&2
    exit 1
fi
if ! grep -Fq 'supports proto3 schemas only' <<<"$output"; then
    echo "Python proto2 rejection returned an unexpected error: $output" >&2
    exit 1
fi

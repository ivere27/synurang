#!/bin/bash
set -e

# Directory setup
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."
BIN_DIR="$ROOT_DIR/bin"
PLUGIN="$BIN_DIR/protoc-gen-synurang-ffi"

# Ensure clean state
rm -rf "$ROOT_DIR/test/generated_csharp"
mkdir -p "$ROOT_DIR/test/generated_csharp"

echo "Building plugin..."
cd "$ROOT_DIR"
go build -o "$PLUGIN" ./cmd/protoc-gen-synurang-ffi

echo "Generating C# code from core.proto..."
protoc -Iapi -I/usr/include \
    --plugin=protoc-gen-synurang-ffi="$PLUGIN" \
    --synurang-ffi_out="$ROOT_DIR/test/generated_csharp" \
    --synurang-ffi_opt=lang=csharp \
    core.proto

echo "Verifying core_ffi.cs..."
CORE_FFI="$ROOT_DIR/test/generated_csharp/core_ffi.cs"
if [ ! -f "$CORE_FFI" ]; then
    echo "Error: core_ffi.cs was not generated!"
    exit 1
fi

if ! grep -q 'namespace Core.V1;' "$CORE_FFI"; then
    echo "Error: core_ffi.cs missing namespace Core.V1!"
    exit 1
fi

if ! grep -q 'class.*Ffi' "$CORE_FFI"; then
    echo "Error: core_ffi.cs missing Ffi class!"
    exit 1
fi

if ! grep -q 'using Synurang;' "$CORE_FFI"; then
    echo "Error: core_ffi.cs missing Synurang import!"
    exit 1
fi

echo "Generating C# code from example.proto..."
protoc -Iexample/api -Iapi -I/usr/include \
    --plugin=protoc-gen-synurang-ffi="$PLUGIN" \
    --synurang-ffi_out="$ROOT_DIR/test/generated_csharp" \
    --synurang-ffi_opt=lang=csharp \
    example.proto

echo "Verifying example_ffi.cs..."
EXAMPLE_FFI="$ROOT_DIR/test/generated_csharp/example_ffi.cs"
if [ ! -f "$EXAMPLE_FFI" ]; then
    echo "Error: example_ffi.cs was not generated!"
    exit 1
fi

if ! grep -q 'class GoGreeterServiceFfi' "$EXAMPLE_FFI"; then
    echo "Error: example_ffi.cs missing GoGreeterServiceFfi class!"
    exit 1
fi

if ! grep -q '"/example.v1.GoGreeterService/Bar"' "$EXAMPLE_FFI"; then
    echo "Error: example_ffi.cs missing Bar method dispatch!"
    exit 1
fi

if ! grep -q 'IEnumerable<' "$EXAMPLE_FFI"; then
    echo "Error: example_ffi.cs missing streaming methods!"
    exit 1
fi

if ! grep -q 'BidiStream<' "$EXAMPLE_FFI"; then
    echo "Error: example_ffi.cs missing bidi stream method!"
    exit 1
fi

echo "Generating C# code from service_name_case.proto..."
SERVICE_CASE_PROTO="$ROOT_DIR/test/generated_csharp/service_name_case.proto"
cat > "$SERVICE_CASE_PROTO" <<'EOF'
syntax = "proto3";
package service.case.v1;
option go_package = "github.com/ivere27/synurang/test/generated/service_case;servicecase";

message PingRequest {}
message PingResponse {}

service my_service_name {
  rpc Ping(PingRequest) returns (PingResponse);
}
EOF

protoc -I"$ROOT_DIR/test/generated_csharp" \
    --plugin=protoc-gen-synurang-ffi="$PLUGIN" \
    --synurang-ffi_out="$ROOT_DIR/test/generated_csharp" \
    --synurang-ffi_opt=lang=csharp \
    service_name_case.proto

echo "Verifying service_name_case_ffi.cs..."
SERVICE_CASE_FFI="$ROOT_DIR/test/generated_csharp/service_name_case_ffi.cs"
if [ ! -f "$SERVICE_CASE_FFI" ]; then
    echo "Error: service_name_case_ffi.cs was not generated!"
    exit 1
fi

if ! grep -q 'class MyServiceNameFfi' "$SERVICE_CASE_FFI"; then
    echo "Error: service_name_case_ffi.cs missing MyServiceNameFfi class!"
    exit 1
fi

if ! grep -q '_host.Invoke("MyServiceName"' "$SERVICE_CASE_FFI"; then
    echo "Error: service_name_case_ffi.cs must use Go-style service symbol name!"
    exit 1
fi

echo "Generating C# lite code from packed_repeated_case.proto..."
PACKED_REPEATED_PROTO="$ROOT_DIR/test/generated_csharp/packed_repeated_case.proto"
cat > "$PACKED_REPEATED_PROTO" <<'EOF'
syntax = "proto3";
package packed.case.v1;
option go_package = "github.com/ivere27/synurang/test/generated/packed_case;packedcase";

enum ValueKind {
  VALUE_KIND_UNSPECIFIED = 0;
  VALUE_KIND_ONE = 1;
}

message PackedRepeatedCase {
  repeated int32 ids = 1;
  repeated float times = 2;
  repeated bool flags = 3;
  repeated ValueKind kinds = 4;
}
EOF

protoc -I"$ROOT_DIR/test/generated_csharp" \
    --plugin=protoc-gen-synurang-ffi="$PLUGIN" \
    --synurang-ffi_out="$ROOT_DIR/test/generated_csharp" \
    --synurang-ffi_opt=lang=csharp,mode=lite \
    packed_repeated_case.proto

echo "Verifying packed_repeated_case_lite.cs..."
PACKED_REPEATED_LITE="$ROOT_DIR/test/generated_csharp/packed_repeated_case_lite.cs"
if [ ! -f "$PACKED_REPEATED_LITE" ]; then
    echo "Error: packed_repeated_case_lite.cs was not generated!"
    exit 1
fi

if ! grep -q 'if (wire == ProtoWireType.LengthDelimited)' "$PACKED_REPEATED_LITE"; then
    echo "Error: packed_repeated_case_lite.cs missing packed repeated scalar parsing!"
    exit 1
fi

if ! grep -q 'msg.Ids.Add(packed.ReadInt32())' "$PACKED_REPEATED_LITE"; then
    echo "Error: packed_repeated_case_lite.cs missing packed int32 parsing!"
    exit 1
fi

if ! grep -q 'msg.Times.Add(packed.ReadFloat())' "$PACKED_REPEATED_LITE"; then
    echo "Error: packed_repeated_case_lite.cs missing packed float parsing!"
    exit 1
fi

if ! grep -q 'msg.Flags.Add(packed.ReadBool())' "$PACKED_REPEATED_LITE"; then
    echo "Error: packed_repeated_case_lite.cs missing packed bool parsing!"
    exit 1
fi

if ! grep -q 'msg.Kinds.Add((ValueKind)packed.ReadInt32())' "$PACKED_REPEATED_LITE"; then
    echo "Error: packed_repeated_case_lite.cs missing packed enum parsing!"
    exit 1
fi

echo "C# Generation Test Passed!"
rm -rf "$ROOT_DIR/test/generated_csharp"

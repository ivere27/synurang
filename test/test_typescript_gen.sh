#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."
BIN_DIR="$ROOT_DIR/bin"
PLUGIN="$BIN_DIR/protoc-gen-synurang-ffi"
OUT_DIR="$ROOT_DIR/test/generated_typescript"

assert_contains() {
    local file="$1"
    local pattern="$2"
    local message="$3"
    if ! grep -q "$pattern" "$file"; then
        echo "Error: $message"
        exit 1
    fi
}

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

echo "Building plugin..."
cd "$ROOT_DIR"
go build -o "$PLUGIN" ./cmd/protoc-gen-synurang-ffi

echo "Generating TypeScript code from example.proto..."
protoc -Iexample/api -Iapi -I/usr/include \
    --plugin=protoc-gen-synurang-ffi="$PLUGIN" \
    --synurang-ffi_out="$OUT_DIR" \
    --synurang-ffi_opt=lang=typescript \
    example.proto

EXAMPLE_TS="$OUT_DIR/example_ffi.ts"
if [ ! -f "$EXAMPLE_TS" ]; then
    echo "Error: example_ffi.ts was not generated!"
    exit 1
fi

assert_contains "$EXAMPLE_TS" 'export const PROTO_PACKAGE = "example.v1" as const;' "example_ffi.ts missing package constant"
assert_contains "$EXAMPLE_TS" 'export enum TriggerRequest_Action' "example_ffi.ts missing nested enum"
assert_contains "$EXAMPLE_TS" 'UPLOAD_FILE = 4' "example_ffi.ts missing nested enum value"
assert_contains "$EXAMPLE_TS" 'export const HelloResponseFields = {' "example_ffi.ts missing message field map"
assert_contains "$EXAMPLE_TS" '"timestamp": 3' "example_ffi.ts missing HelloResponse field number"
assert_contains "$EXAMPLE_TS" 'export const GoGreeterServiceMethods = {' "example_ffi.ts missing service method map"
assert_contains "$EXAMPLE_TS" 'Bar: "/example.v1.GoGreeterService/Bar"' "example_ffi.ts missing method path"

SCHEMA_PROTO="$OUT_DIR/schema_types.proto"
cat > "$SCHEMA_PROTO" <<'EOF'
syntax = "proto3";
package schema.types.v1;
option go_package = "github.com/ivere27/synurang/test/generated/typescript;schematypes";

enum CellHitArea {
  HIT_CELL = 0;
  HIT_TEXT = 1;
}

message ClickEvent {
  enum Interaction {
    NONE = 0;
    LINK = 1;
  }

  int32 row = 1;
  int32 col = 2;
  CellHitArea hit_area = 3;
  Interaction interaction = 4;
}

service DemoService {
  rpc Click(ClickEvent) returns (ClickEvent);
}
EOF

echo "Generating TypeScript code from schema_types.proto..."
protoc -I"$OUT_DIR" \
    --plugin=protoc-gen-synurang-ffi="$PLUGIN" \
    --synurang-ffi_out="$OUT_DIR" \
    --synurang-ffi_opt=lang=typescript \
    schema_types.proto

SCHEMA_TS="$OUT_DIR/schema_types_ffi.ts"
if [ ! -f "$SCHEMA_TS" ]; then
    echo "Error: schema_types_ffi.ts was not generated!"
    exit 1
fi

assert_contains "$SCHEMA_TS" 'export enum CellHitArea' "schema_types_ffi.ts missing top-level enum"
assert_contains "$SCHEMA_TS" 'HIT_TEXT = 1' "schema_types_ffi.ts missing top-level enum value"
assert_contains "$SCHEMA_TS" 'export enum ClickEvent_Interaction' "schema_types_ffi.ts missing nested enum"
assert_contains "$SCHEMA_TS" 'export const ClickEventFields = {' "schema_types_ffi.ts missing message field map"
assert_contains "$SCHEMA_TS" '"hit_area": 3' "schema_types_ffi.ts missing field number"
assert_contains "$SCHEMA_TS" 'Click: "/schema.types.v1.DemoService/Click"' "schema_types_ffi.ts missing service method path"

echo "TypeScript Generation Test Passed!"
rm -rf "$OUT_DIR"

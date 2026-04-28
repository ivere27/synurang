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

echo "Generating TypeScript lite code from example.proto..."
protoc -Iexample/api -Iapi -I/usr/include \
    --plugin=protoc-gen-synurang-ffi="$PLUGIN" \
    --synurang-ffi_out="$OUT_DIR" \
    --synurang-ffi_opt=lang=typescript,mode=lite \
    example.proto

EXAMPLE_LITE_TS="$OUT_DIR/example_lite.ts"
if [ ! -f "$EXAMPLE_LITE_TS" ]; then
    echo "Error: example_lite.ts was not generated!"
    exit 1
fi
tsc --target ES2020 --module ES2020 --strict --noEmit "$EXAMPLE_LITE_TS"

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
  optional string note = 5;
  repeated int32 ids = 6;
  bytes raw = 7;
}

message NestedPayload {
  string label = 1;
  int32 count = 2;
  bytes data = 3;
}

message ScalarTypes {
  double double_value = 1;
  float float_value = 2;
  int32 int32_value = 3;
  int64 int64_value = 4;
  uint32 uint32_value = 5;
  uint64 uint64_value = 6;
  sint32 sint32_value = 7;
  sint64 sint64_value = 8;
  fixed32 fixed32_value = 9;
  fixed64 fixed64_value = 10;
  sfixed32 sfixed32_value = 11;
  sfixed64 sfixed64_value = 12;
  bool bool_value = 13;
  string string_value = 14;
  bytes bytes_value = 15;
  CellHitArea enum_value = 16;
  NestedPayload nested_value = 17;
  repeated double repeated_double = 18;
  repeated float repeated_float = 19;
  repeated int32 repeated_int32 = 20;
  repeated int64 repeated_int64 = 21;
  repeated uint32 repeated_uint32 = 22;
  repeated uint64 repeated_uint64 = 23;
  repeated sint32 repeated_sint32 = 24;
  repeated sint64 repeated_sint64 = 25;
  repeated fixed32 repeated_fixed32 = 26;
  repeated fixed64 repeated_fixed64 = 27;
  repeated sfixed32 repeated_sfixed32 = 28;
  repeated sfixed64 repeated_sfixed64 = 29;
  repeated bool repeated_bool = 30;
  repeated string repeated_string = 31;
  repeated bytes repeated_bytes = 32;
  repeated CellHitArea repeated_enum = 33;
  repeated NestedPayload repeated_nested = 34;
}

message GridEvent {
  int64 event_id = 100;
  oneof event {
    ClickEvent click = 42;
  }
}

message MixedTypes {
  string id = 1;
  ScalarTypes scalars = 2;
  GridEvent grid = 3;
  repeated ScalarTypes history = 4;
}

service DemoService {
  rpc Click(ClickEvent) returns (ClickEvent);
}
EOF

echo "Generating TypeScript code from schema_types.proto..."
protoc -I"$OUT_DIR" \
    --experimental_allow_proto3_optional \
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

echo "Generating TypeScript lite code from schema_types.proto..."
protoc -I"$OUT_DIR" \
    --experimental_allow_proto3_optional \
    --plugin=protoc-gen-synurang-ffi="$PLUGIN" \
    --synurang-ffi_out="$OUT_DIR" \
    --synurang-ffi_opt=lang=typescript,mode=lite \
    schema_types.proto

SCHEMA_LITE_TS="$OUT_DIR/schema_types_lite.ts"
if [ ! -f "$SCHEMA_LITE_TS" ]; then
    echo "Error: schema_types_lite.ts was not generated!"
    exit 1
fi

assert_contains "$SCHEMA_LITE_TS" 'export class ClickEvent' "schema_types_lite.ts missing ClickEvent class"
assert_contains "$SCHEMA_LITE_TS" 'static fromBinary(data: Uint8Array): ClickEvent' "schema_types_lite.ts missing fromBinary"
assert_contains "$SCHEMA_LITE_TS" 'toJson(): ProtoJsonObject' "schema_types_lite.ts missing toJson"
assert_contains "$SCHEMA_LITE_TS" 'export enum GridEventEventOneofCase' "schema_types_lite.ts missing oneof case enum"
assert_contains "$SCHEMA_LITE_TS" 'oneof: "eventCase"' "schema_types_lite.ts missing oneof metadata"
assert_contains "$SCHEMA_LITE_TS" 'eventId: bigint = 0n' "schema_types_lite.ts missing int64 bigint field"
assert_contains "$SCHEMA_LITE_TS" 'export class ScalarTypes' "schema_types_lite.ts missing ScalarTypes class"
assert_contains "$SCHEMA_LITE_TS" 'kind: "sint32"' "schema_types_lite.ts missing sint32 wire kind"
assert_contains "$SCHEMA_LITE_TS" 'kind: "fixed64"' "schema_types_lite.ts missing fixed64 wire kind"
assert_contains "$SCHEMA_LITE_TS" 'kind: "sfixed32"' "schema_types_lite.ts missing sfixed32 wire kind"
tsc --target ES2020 --module ES2020 --strict --noEmit "$SCHEMA_LITE_TS"

echo "Validating TypeScript lite wire compatibility with protobuf-es..."
cat > "$OUT_DIR/package.json" <<'EOF'
{
  "private": true,
  "type": "module",
  "dependencies": {
    "@bufbuild/protobuf": "2.11.0"
  },
  "devDependencies": {
    "@bufbuild/protoc-gen-es": "2.11.0",
    "typescript": "^5.6.0"
  }
}
EOF
npm install --prefix "$OUT_DIR" --no-audit --no-fund --silent

PROTOBUF_ES_OUT="$OUT_DIR/protobuf_es"
mkdir -p "$PROTOBUF_ES_OUT"
protoc -I"$OUT_DIR" \
    --experimental_allow_proto3_optional \
    --plugin=protoc-gen-es="$OUT_DIR/node_modules/.bin/protoc-gen-es" \
    --es_out="$PROTOBUF_ES_OUT" \
    --es_opt=target=ts \
    schema_types.proto

cat > "$OUT_DIR/protobuf_es_roundtrip.ts" <<'EOF'
import { create, fromBinary, toBinary } from "@bufbuild/protobuf";
import {
  CellHitArea,
  ClickEvent,
  ClickEvent_Interaction,
  GridEvent,
  GridEventEventOneofCase,
  MixedTypes,
  ScalarTypes,
} from "./schema_types_lite.js";
import {
  CellHitArea as EsCellHitArea,
  ClickEvent_Interaction as EsClickEventInteraction,
  ClickEventSchema,
  GridEventSchema,
  MixedTypesSchema,
  ScalarTypesSchema,
} from "./protobuf_es/schema_types_pb.js";

function assertEqual<T>(actual: T, expected: T, label: string): void {
  if (actual !== expected) {
    throw new Error(`${label}: expected ${String(expected)}, got ${String(actual)}`);
  }
}

function assertClose(actual: number, expected: number, label: string): void {
  if (Math.abs(actual - expected) > 0.000001) {
    throw new Error(`${label}: expected ${expected}, got ${actual}`);
  }
}

function assertBytes(actual: Uint8Array | undefined, expected: Uint8Array, label: string): void {
  if (actual == null) {
    throw new Error(`${label}: expected bytes, got undefined`);
  }
  if (actual.byteLength !== expected.byteLength) {
    throw new Error(`${label}: expected ${expected.byteLength} bytes, got ${actual.byteLength}`);
  }
  for (let i = 0; i < actual.byteLength; i++) {
    if (actual[i] !== expected[i]) {
      throw new Error(`${label}: byte ${i} expected ${expected[i]}, got ${actual[i]}`);
    }
  }
}

function assertNumberArray(actual: readonly number[], expected: readonly number[], label: string): void {
  assertEqual(actual.length, expected.length, `${label}.length`);
  for (let i = 0; i < expected.length; i++) {
    assertClose(actual[i], expected[i], `${label}[${i}]`);
  }
}

function assertBigintArray(actual: readonly bigint[], expected: readonly bigint[], label: string): void {
  assertEqual(actual.length, expected.length, `${label}.length`);
  for (let i = 0; i < expected.length; i++) {
    assertEqual(actual[i], expected[i], `${label}[${i}]`);
  }
}

function assertBooleanArray(actual: readonly boolean[], expected: readonly boolean[], label: string): void {
  assertEqual(actual.length, expected.length, `${label}.length`);
  for (let i = 0; i < expected.length; i++) {
    assertEqual(actual[i], expected[i], `${label}[${i}]`);
  }
}

function assertStringArray(actual: readonly string[], expected: readonly string[], label: string): void {
  assertEqual(actual.length, expected.length, `${label}.length`);
  for (let i = 0; i < expected.length; i++) {
    assertEqual(actual[i], expected[i], `${label}[${i}]`);
  }
}

function assertBytesArray(actual: readonly Uint8Array[], expected: readonly Uint8Array[], label: string): void {
  assertEqual(actual.length, expected.length, `${label}.length`);
  for (let i = 0; i < expected.length; i++) {
    assertBytes(actual[i], expected[i], `${label}[${i}]`);
  }
}

function assertClickEvent(actual: ClickEvent, label: string): void {
  assertEqual(actual.row, 123, `${label}.row`);
  assertEqual(actual.col, -45, `${label}.col`);
  assertEqual(actual.hitArea, CellHitArea.HIT_TEXT, `${label}.hitArea`);
  assertEqual(actual.interaction, ClickEvent_Interaction.LINK, `${label}.interaction`);
  assertEqual(actual.note, "hello from protobuf-es", `${label}.note`);
  assertEqual(actual.ids.join(","), "1,128,-7", `${label}.ids`);
  assertBytes(actual.raw, rawBytes, `${label}.raw`);
}

const rawBytes = new Uint8Array([0, 1, 2, 127, 128, 255]);
const scalarBytes = new Uint8Array([9, 8, 7, 6]);
const nestedBytes = new Uint8Array([5, 4, 3]);
const repeatedByteA = new Uint8Array([1, 3, 5]);
const repeatedByteB = new Uint8Array([2, 4, 6, 8]);
const nestedPayload = { label: "nested payload", count: -11, data: nestedBytes };
const repeatedNestedPayloads = [
  { label: "first", count: 1, data: new Uint8Array([10]) },
  { label: "second", count: -2, data: new Uint8Array([20, 21]) },
];

function assertScalarTypes(actual: any, label: string): void {
  if (actual == null) {
    throw new Error(`${label}: expected ScalarTypes, got nullish`);
  }
  assertClose(actual.doubleValue, -12345.125, `${label}.doubleValue`);
  assertClose(actual.floatValue, 123.5, `${label}.floatValue`);
  assertEqual(actual.int32Value, -2147483648, `${label}.int32Value`);
  assertEqual(actual.int64Value, -9007199254740991n, `${label}.int64Value`);
  assertEqual(actual.uint32Value, 4294967295, `${label}.uint32Value`);
  assertEqual(actual.uint64Value, 9007199254740993n, `${label}.uint64Value`);
  assertEqual(actual.sint32Value, -123456, `${label}.sint32Value`);
  assertEqual(actual.sint64Value, -9007199254740993n, `${label}.sint64Value`);
  assertEqual(actual.fixed32Value, 4000000000, `${label}.fixed32Value`);
  assertEqual(actual.fixed64Value, 9007199254740995n, `${label}.fixed64Value`);
  assertEqual(actual.sfixed32Value, -2000000000, `${label}.sfixed32Value`);
  assertEqual(actual.sfixed64Value, -1234567890123456789n, `${label}.sfixed64Value`);
  assertEqual(actual.boolValue, true, `${label}.boolValue`);
  assertEqual(actual.stringValue, "plain string", `${label}.stringValue`);
  assertBytes(actual.bytesValue, scalarBytes, `${label}.bytesValue`);
  assertEqual(actual.enumValue, CellHitArea.HIT_TEXT, `${label}.enumValue`);
  assertEqual(actual.nestedValue?.label, nestedPayload.label, `${label}.nestedValue.label`);
  assertEqual(actual.nestedValue?.count, nestedPayload.count, `${label}.nestedValue.count`);
  assertBytes(actual.nestedValue?.data, nestedBytes, `${label}.nestedValue.data`);
  assertNumberArray(actual.repeatedDouble, [1.25, -2.5], `${label}.repeatedDouble`);
  assertNumberArray(actual.repeatedFloat, [3.5, -4.25], `${label}.repeatedFloat`);
  assertNumberArray(actual.repeatedInt32, [0, -1, 2147483647], `${label}.repeatedInt32`);
  assertBigintArray(actual.repeatedInt64, [0n, -1n, 9007199254740991n], `${label}.repeatedInt64`);
  assertNumberArray(actual.repeatedUint32, [0, 1, 4294967295], `${label}.repeatedUint32`);
  assertBigintArray(actual.repeatedUint64, [0n, 1n, 9007199254740993n], `${label}.repeatedUint64`);
  assertNumberArray(actual.repeatedSint32, [0, -1, 123456], `${label}.repeatedSint32`);
  assertBigintArray(actual.repeatedSint64, [0n, -1n, 9007199254740993n], `${label}.repeatedSint64`);
  assertNumberArray(actual.repeatedFixed32, [0, 123, 4000000000], `${label}.repeatedFixed32`);
  assertBigintArray(actual.repeatedFixed64, [0n, 123n, 9007199254740995n], `${label}.repeatedFixed64`);
  assertNumberArray(actual.repeatedSfixed32, [0, -123, 2000000000], `${label}.repeatedSfixed32`);
  assertBigintArray(actual.repeatedSfixed64, [0n, -123n, 1234567890123456789n], `${label}.repeatedSfixed64`);
  assertBooleanArray(actual.repeatedBool, [true, false, true], `${label}.repeatedBool`);
  assertStringArray(actual.repeatedString, ["alpha", "beta"], `${label}.repeatedString`);
  assertBytesArray(actual.repeatedBytes, [repeatedByteA, repeatedByteB], `${label}.repeatedBytes`);
  assertNumberArray(actual.repeatedEnum, [CellHitArea.HIT_CELL, CellHitArea.HIT_TEXT], `${label}.repeatedEnum`);
  assertEqual(actual.repeatedNested.length, repeatedNestedPayloads.length, `${label}.repeatedNested.length`);
  for (let i = 0; i < repeatedNestedPayloads.length; i++) {
    assertEqual(actual.repeatedNested[i].label, repeatedNestedPayloads[i].label, `${label}.repeatedNested[${i}].label`);
    assertEqual(actual.repeatedNested[i].count, repeatedNestedPayloads[i].count, `${label}.repeatedNested[${i}].count`);
    assertBytes(actual.repeatedNested[i].data, repeatedNestedPayloads[i].data, `${label}.repeatedNested[${i}].data`);
  }
}

const scalarInit = {
  doubleValue: -12345.125,
  floatValue: 123.5,
  int32Value: -2147483648,
  int64Value: -9007199254740991n,
  uint32Value: 4294967295,
  uint64Value: 9007199254740993n,
  sint32Value: -123456,
  sint64Value: -9007199254740993n,
  fixed32Value: 4000000000,
  fixed64Value: 9007199254740995n,
  sfixed32Value: -2000000000,
  sfixed64Value: -1234567890123456789n,
  boolValue: true,
  stringValue: "plain string",
  bytesValue: scalarBytes,
  enumValue: EsCellHitArea.HIT_TEXT,
  nestedValue: nestedPayload,
  repeatedDouble: [1.25, -2.5],
  repeatedFloat: [3.5, -4.25],
  repeatedInt32: [0, -1, 2147483647],
  repeatedInt64: [0n, -1n, 9007199254740991n],
  repeatedUint32: [0, 1, 4294967295],
  repeatedUint64: [0n, 1n, 9007199254740993n],
  repeatedSint32: [0, -1, 123456],
  repeatedSint64: [0n, -1n, 9007199254740993n],
  repeatedFixed32: [0, 123, 4000000000],
  repeatedFixed64: [0n, 123n, 9007199254740995n],
  repeatedSfixed32: [0, -123, 2000000000],
  repeatedSfixed64: [0n, -123n, 1234567890123456789n],
  repeatedBool: [true, false, true],
  repeatedString: ["alpha", "beta"],
  repeatedBytes: [repeatedByteA, repeatedByteB],
  repeatedEnum: [EsCellHitArea.HIT_CELL, EsCellHitArea.HIT_TEXT],
  repeatedNested: repeatedNestedPayloads,
};

const esScalars = create(ScalarTypesSchema, scalarInit);
const liteScalarsFromEs = ScalarTypes.fromBinary(toBinary(ScalarTypesSchema, esScalars));
assertScalarTypes(liteScalarsFromEs, "lite decoded protobuf-es ScalarTypes");

const esScalarsFromLite = fromBinary(ScalarTypesSchema, liteScalarsFromEs.toBinary());
assertScalarTypes(esScalarsFromLite, "protobuf-es decoded lite ScalarTypes");

const esClick = create(ClickEventSchema, {
  row: 123,
  col: -45,
  hitArea: EsCellHitArea.HIT_TEXT,
  interaction: EsClickEventInteraction.LINK,
  note: "hello from protobuf-es",
  ids: [1, 128, -7],
  raw: rawBytes,
});

const liteClickFromEs = ClickEvent.fromBinary(toBinary(ClickEventSchema, esClick));
assertClickEvent(liteClickFromEs, "lite decoded protobuf-es ClickEvent");

const esClickFromLite = fromBinary(ClickEventSchema, liteClickFromEs.toBinary());
assertEqual(esClickFromLite.row, 123, "protobuf-es decoded lite ClickEvent.row");
assertEqual(esClickFromLite.col, -45, "protobuf-es decoded lite ClickEvent.col");
assertEqual(esClickFromLite.hitArea, EsCellHitArea.HIT_TEXT, "protobuf-es decoded lite ClickEvent.hitArea");
assertEqual(
  esClickFromLite.interaction,
  EsClickEventInteraction.LINK,
  "protobuf-es decoded lite ClickEvent.interaction",
);
assertEqual(esClickFromLite.note, "hello from protobuf-es", "protobuf-es decoded lite ClickEvent.note");
assertEqual(esClickFromLite.ids.join(","), "1,128,-7", "protobuf-es decoded lite ClickEvent.ids");
assertBytes(esClickFromLite.raw, rawBytes, "protobuf-es decoded lite ClickEvent.raw");

const esGrid = create(GridEventSchema, {
  eventId: 9007199254740993n,
  event: {
    case: "click",
    value: esClick,
  },
});
const liteGridFromEs = GridEvent.fromBinary(toBinary(GridEventSchema, esGrid));
assertEqual(liteGridFromEs.eventId, 9007199254740993n, "lite decoded protobuf-es GridEvent.eventId");
assertEqual(liteGridFromEs.eventCase, GridEventEventOneofCase.Click, "lite decoded protobuf-es GridEvent.eventCase");
if (!(liteGridFromEs.click instanceof ClickEvent)) {
  throw new Error("lite decoded protobuf-es GridEvent.click is not a ClickEvent");
}
assertClickEvent(liteGridFromEs.click, "lite decoded protobuf-es GridEvent.click");

const esGridFromLite = fromBinary(GridEventSchema, liteGridFromEs.toBinary());
assertEqual(esGridFromLite.eventId, 9007199254740993n, "protobuf-es decoded lite GridEvent.eventId");
assertEqual(esGridFromLite.event.case, "click", "protobuf-es decoded lite GridEvent.event.case");
if (esGridFromLite.event.case !== "click") {
  throw new Error("protobuf-es decoded lite GridEvent.click is missing");
}
assertEqual(esGridFromLite.event.value.row, 123, "protobuf-es decoded lite GridEvent.click.row");
assertEqual(esGridFromLite.event.value.note, "hello from protobuf-es", "protobuf-es decoded lite GridEvent.click.note");
assertBytes(esGridFromLite.event.value.raw, rawBytes, "protobuf-es decoded lite GridEvent.click.raw");

const esMixed = create(MixedTypesSchema, {
  id: "mixed message",
  scalars: esScalars,
  grid: esGrid,
  history: [esScalars],
});
const liteMixedFromEs = MixedTypes.fromBinary(toBinary(MixedTypesSchema, esMixed));
assertEqual(liteMixedFromEs.id, "mixed message", "lite decoded protobuf-es MixedTypes.id");
assertScalarTypes(liteMixedFromEs.scalars, "lite decoded protobuf-es MixedTypes.scalars");
assertEqual(liteMixedFromEs.grid?.eventId, 9007199254740993n, "lite decoded protobuf-es MixedTypes.grid.eventId");
assertEqual(liteMixedFromEs.history.length, 1, "lite decoded protobuf-es MixedTypes.history.length");
assertScalarTypes(liteMixedFromEs.history[0], "lite decoded protobuf-es MixedTypes.history[0]");

const esMixedFromLite = fromBinary(MixedTypesSchema, liteMixedFromEs.toBinary());
assertEqual(esMixedFromLite.id, "mixed message", "protobuf-es decoded lite MixedTypes.id");
assertScalarTypes(esMixedFromLite.scalars, "protobuf-es decoded lite MixedTypes.scalars");
assertEqual(esMixedFromLite.grid?.eventId, 9007199254740993n, "protobuf-es decoded lite MixedTypes.grid.eventId");
assertEqual(esMixedFromLite.history.length, 1, "protobuf-es decoded lite MixedTypes.history.length");
assertScalarTypes(esMixedFromLite.history[0], "protobuf-es decoded lite MixedTypes.history[0]");
EOF

"$OUT_DIR/node_modules/.bin/tsc" --target ES2020 \
    --module NodeNext \
    --moduleResolution NodeNext \
    --strict \
    --skipLibCheck \
    --outDir "$OUT_DIR/dist" \
    "$SCHEMA_LITE_TS" \
    "$PROTOBUF_ES_OUT/schema_types_pb.ts" \
    "$OUT_DIR/protobuf_es_roundtrip.ts"
node "$OUT_DIR/dist/protobuf_es_roundtrip.js"

echo "TypeScript Generation Test Passed!"
rm -rf "$OUT_DIR"

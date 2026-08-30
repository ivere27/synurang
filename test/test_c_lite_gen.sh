#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."
PLUGIN="$ROOT_DIR/bin/protoc-gen-synurang-ffi"
WORK_DIR="$(mktemp -d /tmp/synurang-c-lite.XXXXXX)"
PROTO_DIR="$WORK_DIR/proto"
OUT_DIR="$WORK_DIR/out"

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

mkdir -p "$PROTO_DIR" "$OUT_DIR"

cat > "$PROTO_DIR/dependency.proto" <<'PROTO'
syntax = "proto3";
package dependency.v1;

enum ImportedKind {
  IMPORTED_KIND_UNSPECIFIED = 0;
  IMPORTED_KIND_READY = 8;
}

message Imported {
  string note = 1;
  ImportedKind kind = 2;
  Imported child = 3;
  repeated Imported children = 4;
  map<int32, Imported> objects = 5;
}
PROTO

cat > "$PROTO_DIR/c_lite_fixture.proto" <<'PROTO'
syntax = "proto3";
package c.lite.v1;

import "dependency.proto";
import "google/protobuf/empty.proto";

enum Kind {
  option allow_alias = true;
  KIND_UNSPECIFIED = 0;
  KIND_NEGATIVE = -3;
  KIND_READY = 7;
  KIND_READY_ALIAS = 7;
}

message Nested {
  int32 value = 1;
}

message Recursive {
  Recursive child = 1;
  repeated Recursive children = 2;
  map<int32, Recursive> objects = 3;
}

message Packing {
  repeated int32 default_packed = 1;
  repeated int32 explicit_unpacked = 2 [packed = false];
}

message Everything {
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
  string text = 14;
  bytes blob = 15;
  repeated sint32 numbers = 16;
  repeated string tags = 17;
  repeated Nested children = 18;
  map<string, int32> counts = 19;
  map<int32, Nested> objects = 20;
  optional string optional_text = 21;
  Kind kind = 22;
  Nested nested = 23;
  dependency.v1.Imported imported = 24;
  google.protobuf.Empty empty = 25;

  oneof selection {
    string selected_text = 26;
    int64 selected_id = 27;
    Nested selected_nested = 28;
  }
  Recursive recursive = 29;
  repeated dependency.v1.Imported imported_children = 30;
  map<int32, dependency.v1.Imported> imported_objects = 31;
}

service MustNotAppear {
  rpc Call(Everything) returns (Everything);
}
PROTO

cd "$ROOT_DIR"
make build_plugin >/dev/null

protoc -I"$PROTO_DIR" -I/usr/include \
    --experimental_allow_proto3_optional \
    --plugin=protoc-gen-synurang-ffi="$PLUGIN" \
    --synurang-ffi_out="$OUT_DIR" \
    --synurang-ffi_opt=lang=c,mode=lite \
    dependency.proto c_lite_fixture.proto

expected=(
    c_lite_fixture_lite.c
    c_lite_fixture_lite.h
    dependency_lite.c
    dependency_lite.h
)
mapfile -t actual < <(find "$OUT_DIR" -maxdepth 1 -type f -printf '%f\n' | sort)
if [[ "${actual[*]}" != "${expected[*]}" ]]; then
    echo "Error: unexpected C lite outputs: ${actual[*]}" >&2
    exit 1
fi

HEADER="$OUT_DIR/c_lite_fixture_lite.h"
SOURCE="$OUT_DIR/c_lite_fixture_lite.c"
grep -Fq 'typedef struct CLiteV1Everything CLiteV1Everything;' "$HEADER"
grep -Fq 'SynurangLiteStatus c_lite_v1_everything_encode(' "$HEADER"
grep -Fq 'const char* c_lite_v1_kind_name(' "$HEADER"
grep -Fq '#include "dependency_lite.h"' "$HEADER"
if grep -Fq 'MustNotAppear' "$HEADER" || grep -Fq 'MustNotAppear' "$SOURCE"; then
    echo "Error: service declarations leaked into C lite output" >&2
    exit 1
fi

cat > "$WORK_DIR/check.c" <<'C'
#include "c_lite_fixture_lite.h"

#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define CHECK(condition, code) do { if (!(condition)) return (code); } while (0)

static int bytes_equal(const SynurangLiteBytes* value, const char* expected) {
    size_t len = strlen(expected);
    return value->len == len && (len == 0 || memcmp(value->data, expected, len) == 0);
}

typedef struct TestBuffer {
    uint8_t* data;
    size_t len;
} TestBuffer;

static size_t varint_size(uint64_t value) {
    size_t len = 1;
    while (value >= UINT64_C(0x80)) {
        value >>= 7;
        ++len;
    }
    return len;
}

static size_t write_varint(uint8_t* output, uint64_t value) {
    size_t len = 0;
    do {
        uint8_t byte = (uint8_t)(value & UINT64_C(0x7f));
        value >>= 7;
        output[len++] = value ? (uint8_t)(byte | UINT8_C(0x80)) : byte;
    } while (value);
    return len;
}

/* Consumes child and wraps it as a length-delimited field. */
static TestBuffer wrap_message(uint32_t field_number, TestBuffer child) {
    TestBuffer result = {NULL, 0};
    uint64_t tag = (uint64_t)field_number << 3 | UINT64_C(2);
    size_t tag_len = varint_size(tag);
    size_t size_len = varint_size((uint64_t)child.len);
    result.len = tag_len + size_len + child.len;
    result.data = (uint8_t*)malloc(result.len);
    if (result.data) {
        size_t position = write_varint(result.data, tag);
        position += write_varint(result.data + position, (uint64_t)child.len);
        if (child.len) memcpy(result.data + position, child.data, child.len);
    }
    free(child.data);
    return result;
}

static TestBuffer recursive_chain(
    unsigned int edges, uint32_t field_number, int through_map) {
    TestBuffer result = {NULL, 0};
    unsigned int i;
    for (i = 0; i < edges; ++i) {
        if (through_map) result = wrap_message(2, result);
        result = wrap_message(field_number, result);
    }
    return result;
}

int main(void) {
    CLiteV1Everything source;
    CLiteV1Everything decoded;
    uint8_t* encoded = NULL;
    size_t encoded_len = 0;
    uint8_t* with_unknown;
    SynurangLiteStatus status;
    static const uint8_t blob[] = {0, 1, 0xff};
    static const uint8_t unpacked_numbers[] = {0x80, 0x01, 0x05, 0x80, 0x01, 0x06};
    static const uint8_t truncated[] = {0x08, 0x80};
    static const uint8_t bad_length[] = {0x72, 0x05, 'x'};
    static const uint8_t empty_unknowns[] = {0x08, 0x01, 0x12, 0x01, 'x'};
    static const uint8_t oversized_field_number[] = {
        0x88, 0x80, 0x80, 0x80, 0x80, 0x01, 0x00
    };
    static const uint8_t imported_note[] = {0x0a, 0x05, 'f', 'i', 'r', 's', 't'};
    static const uint8_t imported_kind[] = {0x10, 0x08};
    static const uint8_t repeated_imported[] = {
        0xc2, 0x01, 0x07, 0x0a, 0x05, 'f', 'i', 'r', 's', 't',
        0xc2, 0x01, 0x02, 0x10, 0x08
    };
    CLiteV1Everything unpacked;
    SynurangProtobufEmpty standalone_empty;
    DependencyV1Imported merged_imported;
    CLiteV1Recursive recursive;
    CLiteV1Packing packing;
    CLiteV1Everything overflow_probe;
    TestBuffer recursion;

    c_lite_v1_everything_init(&source);
    c_lite_v1_everything_init(&decoded);
    c_lite_v1_everything_init(&unpacked);
    synurang_protobuf_empty_init(&standalone_empty);
    dependency_v1_imported_init(&merged_imported);
    c_lite_v1_recursive_init(&recursive);
    c_lite_v1_packing_init(&packing);
    c_lite_v1_everything_init(&overflow_probe);
    overflow_probe.field_children.cap =
        SIZE_MAX / sizeof(CLiteV1Nested) + 1u;
    overflow_probe.field_children.len = overflow_probe.field_children.cap;
    CHECK(c_lite_v1_everything_add_children(&overflow_probe) == NULL, 78);
    overflow_probe.field_children.len = 0u;
    overflow_probe.field_children.cap = 0u;
    CHECK(synurang_protobuf_empty_decode(
        &standalone_empty, empty_unknowns, sizeof(empty_unknowns)) == SYNURANG_LITE_OK, 51);
    CHECK(synurang_protobuf_empty_decode(
        &standalone_empty, oversized_field_number, sizeof(oversized_field_number)) ==
        SYNURANG_LITE_MALFORMED, 52);

    source.field_int32_value = -123;
    source.field_sint32_value = -456;
    source.field_sfixed32_value = INT32_MIN + 7;
    source.field_int64_value = INT64_C(-1234567890123);
    source.field_sint64_value = INT64_C(-9000000000);
    source.field_sfixed64_value = INT64_MIN + 9;
    source.field_uint32_value = UINT32_C(4000000000);
    source.field_fixed32_value = UINT32_C(0xfedcba98);
    source.field_uint64_value = UINT64_C(0xfedcba9876543210);
    source.field_fixed64_value = UINT64_C(0x8877665544332211);
    source.field_float_value = 1.25f;
    source.field_double_value = -2.5;
    source.field_bool_value = 1;
    CHECK(synurang_lite_bytes_assign(source._allocator, &source.field_text, "hello", 5) == 0, 1);
    CHECK(synurang_lite_bytes_assign(source._allocator, &source.field_blob, blob, sizeof(blob)) == 0, 2);

    source.field_numbers.data = (int32_t*)malloc(3 * sizeof(int32_t));
    CHECK(source.field_numbers.data != NULL, 3);
    source.field_numbers.len = source.field_numbers.cap = 3;
    source.field_numbers.data[0] = -1;
    source.field_numbers.data[1] = 0;
    source.field_numbers.data[2] = 300;

    source.field_tags.data = (SynurangLiteBytes*)calloc(2, sizeof(SynurangLiteBytes));
    CHECK(source.field_tags.data != NULL, 4);
    source.field_tags.len = source.field_tags.cap = 2;
    CHECK(synurang_lite_bytes_assign(source._allocator, &source.field_tags.data[0], "a", 1) == 0, 5);
    CHECK(synurang_lite_bytes_assign(source._allocator, &source.field_tags.data[1], "bc", 2) == 0, 6);

    source.field_children.data = (CLiteV1Nested*)calloc(1, sizeof(CLiteV1Nested));
    CHECK(source.field_children.data != NULL, 7);
    source.field_children.len = source.field_children.cap = 1;
    c_lite_v1_nested_init_with_allocator(&source.field_children.data[0], source._allocator);
    source.field_children.data[0].field_value = 91;

    source.field_counts.data = (CLiteV1Everything_counts_entry*)calloc(
        2, sizeof(CLiteV1Everything_counts_entry));
    CHECK(source.field_counts.data != NULL, 8);
    source.field_counts.len = source.field_counts.cap = 2;
    CHECK(synurang_lite_bytes_assign(
        source._allocator, &source.field_counts.data[0].key, "receipts", 8) == 0, 9);
    source.field_counts.data[0].value = 12;
    CHECK(synurang_lite_bytes_assign(
        source._allocator, &source.field_counts.data[1].key, "receipts", 8) == 0, 9);
    source.field_counts.data[1].value = 99; /* map decoding keeps the last value */

    source.field_objects.data = (CLiteV1Everything_objects_entry*)calloc(
        1, sizeof(CLiteV1Everything_objects_entry));
    CHECK(source.field_objects.data != NULL, 10);
    source.field_objects.len = source.field_objects.cap = 1;
    source.field_objects.data[0].key = 4;
    source.field_objects.data[0].value = (CLiteV1Nested*)malloc(sizeof(CLiteV1Nested));
    CHECK(source.field_objects.data[0].value != NULL, 11);
    c_lite_v1_nested_init_with_allocator(source.field_objects.data[0].value, source._allocator);
    source.field_objects.data[0].value->field_value = 44;

    source.has_optional_text = 1;
    CHECK(synurang_lite_bytes_assign(
        source._allocator, &source.field_optional_text, "present", 7) == 0, 12);
    source.field_kind = C_LITE_V1_KIND_KIND_READY_ALIAS;

    source.field_nested = (CLiteV1Nested*)malloc(sizeof(CLiteV1Nested));
    CHECK(source.field_nested != NULL, 13);
    c_lite_v1_nested_init_with_allocator(source.field_nested, source._allocator);
    source.field_nested->field_value = 71;

    source.field_imported = (DependencyV1Imported*)malloc(sizeof(DependencyV1Imported));
    CHECK(source.field_imported != NULL, 14);
    dependency_v1_imported_init_with_allocator(source.field_imported, source._allocator);
    CHECK(synurang_lite_bytes_assign(
        source._allocator, &source.field_imported->field_note, "dep", 3) == 0, 15);
    source.field_imported->field_kind = DEPENDENCY_V1_IMPORTED_KIND_IMPORTED_KIND_READY;

    source.field_empty = (SynurangProtobufEmpty*)malloc(sizeof(SynurangProtobufEmpty));
    CHECK(source.field_empty != NULL, 16);
    synurang_protobuf_empty_init_with_allocator(source.field_empty, source._allocator);

    source.which_selection = 26;
    CHECK(synurang_lite_bytes_assign(
        source._allocator, &source.field_selected_text, "chosen", 6) == 0, 17);

    CHECK(strcmp(c_lite_v1_kind_name(C_LITE_V1_KIND_KIND_READY_ALIAS), "KIND_READY") == 0, 18);
    {
        CLiteV1Kind parsed = 0;
        CHECK(c_lite_v1_kind_parse("KIND_READY_ALIAS", &parsed) && parsed == 7, 19);
    }

    status = c_lite_v1_everything_encode(&source, &encoded, &encoded_len);
    CHECK(status == SYNURANG_LITE_OK && encoded_len > 0, 20);

    with_unknown = (uint8_t*)realloc(encoded, encoded_len + 6);
    CHECK(with_unknown != NULL, 21);
    encoded = NULL;
    /* unknown field 100 (varint 99), then field 101 (two byte payload) */
    with_unknown[encoded_len + 0] = 0xa0;
    with_unknown[encoded_len + 1] = 0x06;
    with_unknown[encoded_len + 2] = 0x63;
    with_unknown[encoded_len + 3] = 0xaa;
    with_unknown[encoded_len + 4] = 0x06;
    with_unknown[encoded_len + 5] = 0x00;
    status = c_lite_v1_everything_decode(&decoded, with_unknown, encoded_len + 6);
    free(with_unknown);
    CHECK(status == SYNURANG_LITE_OK, 22);
    CHECK(decoded.field_int32_value == -123, 23);
    CHECK(decoded.field_sint32_value == -456, 24);
    CHECK(decoded.field_sfixed32_value == INT32_MIN + 7, 25);
    CHECK(decoded.field_int64_value == INT64_C(-1234567890123), 26);
    CHECK(decoded.field_sint64_value == INT64_C(-9000000000), 27);
    CHECK(decoded.field_sfixed64_value == INT64_MIN + 9, 28);
    CHECK(decoded.field_uint32_value == UINT32_C(4000000000), 29);
    CHECK(decoded.field_fixed32_value == UINT32_C(0xfedcba98), 30);
    CHECK(decoded.field_uint64_value == UINT64_C(0xfedcba9876543210), 31);
    CHECK(decoded.field_fixed64_value == UINT64_C(0x8877665544332211), 32);
    CHECK(fabsf(decoded.field_float_value - 1.25f) < 0.0001f, 33);
    CHECK(fabs(decoded.field_double_value + 2.5) < 0.0001, 34);
    CHECK(decoded.field_bool_value == 1 && bytes_equal(&decoded.field_text, "hello"), 35);
    CHECK(decoded.field_blob.len == sizeof(blob) && memcmp(decoded.field_blob.data, blob, sizeof(blob)) == 0, 36);
    CHECK(decoded.field_numbers.len == 3 && decoded.field_numbers.data[0] == -1 && decoded.field_numbers.data[2] == 300, 37);
    CHECK(decoded.field_tags.len == 2 && bytes_equal(&decoded.field_tags.data[1], "bc"), 38);
    CHECK(decoded.field_children.len == 1 && decoded.field_children.data[0].field_value == 91, 39);
    CHECK(decoded.field_counts.len == 1 && bytes_equal(&decoded.field_counts.data[0].key, "receipts") && decoded.field_counts.data[0].value == 99, 40);
    CHECK(decoded.field_objects.len == 1 && decoded.field_objects.data[0].value && decoded.field_objects.data[0].value->field_value == 44, 41);
    CHECK(decoded.has_optional_text && bytes_equal(&decoded.field_optional_text, "present"), 42);
    CHECK(decoded.field_kind == 7 && decoded.field_nested && decoded.field_nested->field_value == 71, 43);
    CHECK(decoded.field_imported && bytes_equal(&decoded.field_imported->field_note, "dep"), 44);
    CHECK(decoded.field_empty != NULL, 45);
    CHECK(decoded.which_selection == 26 && bytes_equal(&decoded.field_selected_text, "chosen"), 46);

    CHECK(c_lite_v1_everything_decode(
        &unpacked, unpacked_numbers, sizeof(unpacked_numbers)) == SYNURANG_LITE_OK, 47);
    CHECK(unpacked.field_numbers.len == 2 && unpacked.field_numbers.data[0] == -3 && unpacked.field_numbers.data[1] == 3, 48);

    CHECK(c_lite_v1_everything_decode(
        &unpacked, truncated, sizeof(truncated)) == SYNURANG_LITE_MALFORMED, 49);
    CHECK(c_lite_v1_everything_decode(
        &unpacked, bad_length, sizeof(bad_length)) == SYNURANG_LITE_MALFORMED, 50);
    CHECK(c_lite_v1_everything_decode(
        &unpacked, oversized_field_number, sizeof(oversized_field_number)) ==
        SYNURANG_LITE_MALFORMED, 53);
    CHECK(c_lite_v1_everything_decode(
        &unpacked, repeated_imported, sizeof(repeated_imported)) == SYNURANG_LITE_OK, 54);
    CHECK(unpacked.field_imported && bytes_equal(&unpacked.field_imported->field_note, "first") &&
        unpacked.field_imported->field_kind == DEPENDENCY_V1_IMPORTED_KIND_IMPORTED_KIND_READY, 55);
    CHECK(dependency_v1_imported_merge(
        &merged_imported, imported_note, sizeof(imported_note)) == SYNURANG_LITE_OK, 56);
    CHECK(dependency_v1_imported_merge(
        &merged_imported, imported_kind, sizeof(imported_kind)) == SYNURANG_LITE_OK, 57);
    CHECK(bytes_equal(&merged_imported.field_note, "first") &&
        merged_imported.field_kind == DEPENDENCY_V1_IMPORTED_KIND_IMPORTED_KIND_READY, 58);

    {
        static const uint8_t expected_packing[] = {
            0x0a, 0x02, 0x01, 0x02, 0x10, 0x03, 0x10, 0x04
        };
        uint8_t* packing_bytes = NULL;
        size_t packing_len = 0;
        packing.field_default_packed.data = (int32_t*)malloc(2 * sizeof(int32_t));
        packing.field_explicit_unpacked.data = (int32_t*)malloc(2 * sizeof(int32_t));
        CHECK(packing.field_default_packed.data != NULL &&
            packing.field_explicit_unpacked.data != NULL, 75);
        packing.field_default_packed.len = packing.field_default_packed.cap = 2;
        packing.field_explicit_unpacked.len = packing.field_explicit_unpacked.cap = 2;
        packing.field_default_packed.data[0] = 1;
        packing.field_default_packed.data[1] = 2;
        packing.field_explicit_unpacked.data[0] = 3;
        packing.field_explicit_unpacked.data[1] = 4;
        CHECK(c_lite_v1_packing_encode(
            &packing, &packing_bytes, &packing_len) == SYNURANG_LITE_OK, 76);
        CHECK(packing_len == sizeof(expected_packing) &&
            memcmp(packing_bytes, expected_packing, sizeof(expected_packing)) == 0, 77);
        synurang_lite_release(packing._allocator, packing_bytes);
    }

    /* A root message is depth zero, so exactly MAX nested message edges are
     * accepted and the next edge is rejected for every known-message shape. */
    recursion = recursive_chain(SYNURANG_LITE_MAX_MESSAGE_DEPTH, 1, 0);
    CHECK(recursion.data != NULL, 59);
    CHECK(c_lite_v1_recursive_decode(
        &recursive, recursion.data, recursion.len) == SYNURANG_LITE_OK, 60);
    free(recursion.data);
    recursion = recursive_chain(SYNURANG_LITE_MAX_MESSAGE_DEPTH + 1U, 1, 0);
    CHECK(recursion.data != NULL, 61);
    CHECK(c_lite_v1_recursive_decode(
        &recursive, recursion.data, recursion.len) == SYNURANG_LITE_MALFORMED, 62);
    free(recursion.data);
    recursion = recursive_chain(SYNURANG_LITE_MAX_MESSAGE_DEPTH + 1U, 2, 0);
    CHECK(recursion.data != NULL, 63);
    CHECK(c_lite_v1_recursive_decode(
        &recursive, recursion.data, recursion.len) == SYNURANG_LITE_MALFORMED, 64);
    free(recursion.data);
    recursion = recursive_chain(SYNURANG_LITE_MAX_MESSAGE_DEPTH + 1U, 3, 1);
    CHECK(recursion.data != NULL, 65);
    CHECK(c_lite_v1_recursive_decode(
        &recursive, recursion.data, recursion.len) == SYNURANG_LITE_MALFORMED, 66);
    free(recursion.data);

    /* The depth follows a known message into a separately generated file.
     * A 64-edge Imported is valid as a root but exceeds the limit when it is
     * nested in singular, repeated, or map fields of Everything. */
    recursion = recursive_chain(SYNURANG_LITE_MAX_MESSAGE_DEPTH, 3, 0);
    CHECK(recursion.data != NULL, 67);
    CHECK(dependency_v1_imported_decode(
        &merged_imported, recursion.data, recursion.len) == SYNURANG_LITE_OK, 68);
    recursion = wrap_message(24, recursion);
    CHECK(recursion.data != NULL, 69);
    CHECK(c_lite_v1_everything_decode(
        &unpacked, recursion.data, recursion.len) == SYNURANG_LITE_MALFORMED, 70);
    free(recursion.data);
    recursion = recursive_chain(SYNURANG_LITE_MAX_MESSAGE_DEPTH, 3, 0);
    recursion = wrap_message(30, recursion);
    CHECK(recursion.data != NULL, 71);
    CHECK(c_lite_v1_everything_decode(
        &unpacked, recursion.data, recursion.len) == SYNURANG_LITE_MALFORMED, 72);
    free(recursion.data);
    recursion = recursive_chain(SYNURANG_LITE_MAX_MESSAGE_DEPTH, 3, 0);
    recursion = wrap_message(2, recursion);
    recursion = wrap_message(31, recursion);
    CHECK(recursion.data != NULL, 73);
    CHECK(c_lite_v1_everything_decode(
        &unpacked, recursion.data, recursion.len) == SYNURANG_LITE_MALFORMED, 74);
    free(recursion.data);

    c_lite_v1_recursive_free(&recursive);
    c_lite_v1_packing_free(&packing);
    c_lite_v1_everything_free(&overflow_probe);
    dependency_v1_imported_free(&merged_imported);
    c_lite_v1_everything_free(&unpacked);
    c_lite_v1_everything_free(&decoded);
    c_lite_v1_everything_free(&source);
    return 0;
}
C

cat > "$WORK_DIR/check.cpp" <<'CPP'
#include "c_lite_fixture_lite.h"
#include "c_lite_fixture_lite.h"

#include <cstdint>

static_assert(sizeof(CLiteV1Kind) == sizeof(std::int32_t), "enum width");

int main() {
    CLiteV1Everything value;
    c_lite_v1_everything_init(&value);
    value.field_kind = C_LITE_V1_KIND_KIND_NEGATIVE;
    c_lite_v1_everything_free(&value);
    return 0;
}
CPP

CC_BIN="${CC:-cc}"
CXX_BIN="${CXX:-c++}"
"$CC_BIN" -std=c11 -Wall -Wextra -Werror -pedantic \
    -I"$OUT_DIR" \
    "$OUT_DIR/dependency_lite.c" "$OUT_DIR/c_lite_fixture_lite.c" \
    "$WORK_DIR/check.c" -lm -o "$WORK_DIR/check"
"$WORK_DIR/check"

"$CC_BIN" -std=c11 -Wall -Wextra -Werror -pedantic -I"$OUT_DIR" \
    -c "$OUT_DIR/dependency_lite.c" -o "$WORK_DIR/dependency.o"
"$CC_BIN" -std=c11 -Wall -Wextra -Werror -pedantic -I"$OUT_DIR" \
    -c "$OUT_DIR/c_lite_fixture_lite.c" -o "$WORK_DIR/fixture.o"
"$CXX_BIN" -std=c++17 -Wall -Wextra -Werror -pedantic -I"$OUT_DIR" \
    "$WORK_DIR/check.cpp" "$WORK_DIR/dependency.o" "$WORK_DIR/fixture.o" \
    -o "$WORK_DIR/check_cpp"
"$WORK_DIR/check_cpp"

types_output=""
if types_output="$(protoc -I"$PROTO_DIR" -I/usr/include \
    --experimental_allow_proto3_optional \
    --plugin=protoc-gen-synurang-ffi="$PLUGIN" \
    --synurang-ffi_out="$OUT_DIR" \
    --synurang-ffi_opt=lang=c,mode=types \
    c_lite_fixture.proto 2>&1)"; then
    echo "Error: obsolete C mode=types was accepted" >&2
    exit 1
fi
if ! grep -Fq 'unsupported lang/mode: c/types' <<<"$types_output"; then
    echo "Error: mode=types rejection was unclear: $types_output" >&2
    exit 1
fi

echo "C lite generation tests passed."

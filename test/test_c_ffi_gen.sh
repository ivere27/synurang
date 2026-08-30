#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."
PLUGIN="$ROOT_DIR/bin/protoc-gen-synurang-ffi"
WORK_DIR="$(mktemp -d /tmp/synurang-c-ffi.XXXXXX)"
FULL_OUT="$WORK_DIR/full"
LITE_OUT="$WORK_DIR/lite"
ALIAS_OUT="$WORK_DIR/native-alias"

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

mkdir -p "$FULL_OUT" "$LITE_OUT" "$ALIAS_OUT"

cd "$ROOT_DIR"
make build_plugin >/dev/null

generate() {
    local out_dir="$1"
    local options="$2"
    protoc -Itest \
        --experimental_allow_proto3_optional \
        --plugin=protoc-gen-synurang-ffi="$PLUGIN" \
        --synurang-ffi_out="$out_dir" \
        --synurang-ffi_opt="$options" \
        api/c_ffi/dependency.proto api/c_ffi/service.proto
}

assert_files() {
    local out_dir="$1"
    shift
    local expected=("$@")
    local actual=()
    mapfile -t actual < <(
        cd "$out_dir"
        find . -type f -printf '%P\n' | sort
    )
    if [[ "${actual[*]}" != "${expected[*]}" ]]; then
        echo "Error: unexpected files for $out_dir" >&2
        echo "  expected: ${expected[*]}" >&2
        echo "  actual:   ${actual[*]}" >&2
        exit 1
    fi
}

generate "$FULL_OUT" 'lang=c'
assert_files "$FULL_OUT" \
    api/c_ffi/dependency_lite.c \
    api/c_ffi/dependency_lite.h \
    api/c_ffi/service_ffi.c \
    api/c_ffi/service_ffi.h \
    api/c_ffi/service_lite.c \
    api/c_ffi/service_lite.h

generate "$LITE_OUT" 'lang=c,mode=lite'
assert_files "$LITE_OUT" \
    api/c_ffi/dependency_lite.c \
    api/c_ffi/dependency_lite.h \
    api/c_ffi/service_lite.c \
    api/c_ffi/service_lite.h

# mode=native remains a compatibility alias, but it must not bring the old
# three-file public surface back.
generate "$ALIAS_OUT" 'lang=c,mode=native'
assert_files "$ALIAS_OUT" \
    api/c_ffi/dependency_lite.c \
    api/c_ffi/dependency_lite.h \
    api/c_ffi/service_ffi.c \
    api/c_ffi/service_ffi.h \
    api/c_ffi/service_lite.c \
    api/c_ffi/service_lite.h

if find "$FULL_OUT" "$ALIAS_OUT" -type f \
    \( -name '*_ffi_native*' -o -name '*_native_server*' \) -print -quit |
    grep -q .; then
    echo 'Error: legacy native/server filenames leaked into the C API' >&2
    exit 1
fi

FFI_HEADER="$FULL_OUT/api/c_ffi/service_ffi.h"
LITE_HEADER="$FULL_OUT/api/c_ffi/service_lite.h"

grep -Fq '#include "service_lite.h"' "$FFI_HEADER"
grep -Fq '#include <synurang/c_runtime.h>' "$FFI_HEADER"
grep -Fq 'typedef struct TestServiceHandlers' "$FFI_HEADER"
grep -Fq 'test_register(' "$FFI_HEADER"

if grep -Fq 'TestServiceHandlers' "$LITE_HEADER" ||
    grep -Fq 'test_register(' "$LITE_HEADER"; then
    echo 'Error: service declarations leaked into the C lite header' >&2
    exit 1
fi

if command -v cc >/dev/null 2>&1; then
    printf '%s\n' '#include "api/c_ffi/service_ffi.h"' 'int main(void) { return 0; }' \
        >"$WORK_DIR/header_check.c"
    cc -std=c11 -pedantic -Wall -Wextra -Werror -Wstrict-prototypes \
        -I"$FULL_OUT" -I"$ROOT_DIR/include" \
        -fsyntax-only "$WORK_DIR/header_check.c"

    for source in \
        "$FULL_OUT/api/c_ffi/dependency_lite.c" \
        "$FULL_OUT/api/c_ffi/service_lite.c" \
        "$FULL_OUT/api/c_ffi/service_ffi.c"; do
        cc -std=c11 -pedantic -Wall -Wextra -Werror -Wstrict-prototypes \
            -I"$FULL_OUT" -I"$FULL_OUT/api/c_ffi" -I"$ROOT_DIR/include" \
            -c "$source" -o "$WORK_DIR/$(basename "$source").o"
    done

    cc -std=c11 -pedantic -Wall -Wextra -Werror -Wstrict-prototypes \
        -I"$FULL_OUT" -I"$FULL_OUT/api/c_ffi" -I"$ROOT_DIR/include" \
        "$FULL_OUT/api/c_ffi/dependency_lite.c" \
        "$FULL_OUT/api/c_ffi/service_lite.c" \
        "$FULL_OUT/api/c_ffi/service_ffi.c" \
        "$ROOT_DIR/src/c_runtime.c" \
        "$ROOT_DIR/test/c_runtime/generated_stream_test.c" \
        -pthread -o "$WORK_DIR/generated_stream_test"
    "$WORK_DIR/generated_stream_test"
fi

# ---------------------------------------------------------------------------
# Flattened unary signatures.
#
# native_test.proto is the schema that exercises every shape the flattening
# decision has to get right: empty requests, the full scalar set, an imported
# request type, a recursive message, and the oneof/repeated/map/mixed cases
# that must fall back to the `_pb` byte form instead. It also reaches
# google.protobuf.Timestamp through core.proto, so it doubles as the
# regression test for well-known types in the C lite codec.
# ---------------------------------------------------------------------------

FLAT_OUT="$WORK_DIR/flat"
mkdir -p "$FLAT_OUT"
protoc -Itest/api -Iapi -I/usr/include \
    --plugin=protoc-gen-synurang-ffi="$PLUGIN" \
    --synurang-ffi_out="$FLAT_OUT" \
    --synurang-ffi_opt=lang=c \
    native_test.proto core.proto

# nativePrefix("NativeTestService") strips "Service" -> "NativeTest" -> native_test
FLAT_HEADER="$FLAT_OUT/native_test_ffi.h"

assert_contains() {
    if ! grep -Fq "$2" "$1"; then
        echo "Error: $3" >&2
        echo "  expected $(basename "$1") to contain: $2" >&2
        exit 1
    fi
}

assert_missing() {
    if grep -Fq "$2" "$1"; then
        echo "Error: $3" >&2
        echo "  expected $(basename "$1") NOT to contain: $2" >&2
        exit 1
    fi
}

assert_contains "$FLAT_HEADER" 'native_test_ping(' 'empty request still emits a caller'
assert_missing "$FLAT_HEADER" 'native_test_ping(,' 'empty request must not leave a leading comma'
assert_contains "$FLAT_HEADER" 'native_test_no_op(void)' \
    'a request and response with no fields must use a strict (void) prototype'

for scalar in 'int32_t a' 'int64_t b' 'uint32_t c' 'uint64_t d' 'float e' 'double f'; do
    assert_contains "$FLAT_HEADER" "$scalar" "scalar field flattened as $scalar"
done
assert_contains "$FLAT_HEADER" 'const uint8_t* h, int32_t h_len' \
    'string/bytes fields flatten to a pointer and length pair'

assert_contains "$FLAT_HEADER" 'native_test_imported_input(' 'imported request type is flattened'
assert_contains "$FLAT_HEADER" 'int32_t code' 'imported core.v1.Error.code is flattened'
assert_contains "$FLAT_HEADER" 'const uint8_t* message, int32_t message_len' \
    'imported core.v1.Error.message is flattened with its length'

assert_contains "$FLAT_HEADER" 'native_test_tree_op(' 'recursive request type still generates'
assert_contains "$FLAT_HEADER" 'const uint8_t* child, int32_t child_len' \
    'a recursive nested message is carried as encoded bytes'

# oneof / repeated / map / mixed requests cannot be flattened into positional
# parameters, so each must route to the `_pb` byte form and emit no flat twin.
for method in oneof_input repeated_input mixed_input map_input; do
    assert_contains "$FLAT_HEADER" "native_test_${method}_pb(" \
        "$method must fall back to the _pb form"
    assert_missing "$FLAT_HEADER" "native_test_${method}(" \
        "$method must not also emit a flattened variant"
done

assert_contains "$FLAT_HEADER" 'native_test_free(' 'memory management function generated'

if command -v cc >/dev/null 2>&1; then
    for source in \
        "$FLAT_OUT/core_lite.c" \
        "$FLAT_OUT/core_ffi.c" \
        "$FLAT_OUT/native_test_lite.c" \
        "$FLAT_OUT/native_test_ffi.c"; do
        cc -std=c11 -pedantic -Wall -Wextra -Werror -Wstrict-prototypes \
            -I"$FLAT_OUT" -I"$ROOT_DIR/include" \
            -c "$source" -o "$WORK_DIR/$(basename "$source").o"
    done
fi

echo 'C default/full and lite generation checks passed.'

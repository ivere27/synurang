#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."
BIN_DIR="$ROOT_DIR/bin"
PLUGIN="$BIN_DIR/protoc-gen-synurang-ffi"
OUT_DIR="$ROOT_DIR/test/generated_native"
PASS=0
FAIL=0

cleanup() { rm -rf "$OUT_DIR"; }
trap cleanup EXIT

assert_contains() {
    local file="$1" pattern="$2" msg="$3"
    if grep -q "$pattern" "$file"; then
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $msg"
        echo "    expected pattern: $pattern"
        echo "    in file: $file"
        FAIL=$((FAIL + 1))
    fi
}

assert_not_contains() {
    local file="$1" pattern="$2" msg="$3"
    if ! grep -q "$pattern" "$file"; then
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $msg"
        echo "    unexpected pattern: $pattern"
        echo "    in file: $file"
        FAIL=$((FAIL + 1))
    fi
}

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

echo "Building plugin..."
cd "$ROOT_DIR"
go build -o "$PLUGIN" ./cmd/protoc-gen-synurang-ffi

# nativePrefix("NativeTestService") strips "Service" → "NativeTest" → "native_test"
PREFIX="native_test"

# =========================================================================
# Generate C native header
# =========================================================================
echo ""
echo "=== C Native Header (lang=c, mode=native) ==="
protoc -I"$SCRIPT_DIR/api" -Iapi -I/usr/include \
    --plugin=protoc-gen-synurang-ffi="$PLUGIN" \
    --synurang-ffi_out="$OUT_DIR" \
    --synurang-ffi_opt=lang=c,mode=native \
    native_test.proto

C_HDR="$OUT_DIR/native_test_ffi_native.h"
if [ ! -f "$C_HDR" ]; then
    echo "FAIL: native_test_ffi_native.h was not generated!"
    exit 1
fi

echo "--- Empty request (Ping) ---"
assert_contains "$C_HDR" "${PREFIX}_ping(" "Ping function exists"
# No leading comma before out_len
assert_not_contains "$C_HDR" 'ping(,' "Ping has no leading comma"

echo "--- Void prototype (NoOp) ---"
assert_contains "$C_HDR" "${PREFIX}_no_op(void)" "NoOp emits void for strict C prototype"

echo "--- uint64 field ---"
assert_contains "$C_HDR" 'uint64_t d' "uint64 field mapped to uint64_t"

echo "--- Imported input (core.v1.Error) ---"
assert_contains "$C_HDR" "${PREFIX}_imported_input(" "ImportedInput function exists"
assert_contains "$C_HDR" 'int32_t code' "imported Error.code field present"
assert_contains "$C_HDR" 'message, int32_t message_len' "imported Error.message field with length"

echo "--- Oneof request → _pb variant ---"
assert_contains "$C_HDR" "${PREFIX}_oneof_input_pb(" "OneofInput routes to _pb"
# The _pb function name also matches _pb(, so check there's no flat variant without _pb
assert_not_contains "$C_HDR" "${PREFIX}_oneof_input(" "OneofInput has no flat variant"

echo "--- Repeated request → _pb variant ---"
assert_contains "$C_HDR" "${PREFIX}_repeated_input_pb(" "RepeatedInput routes to _pb"

echo "--- Mixed request → _pb variant ---"
assert_contains "$C_HDR" "${PREFIX}_mixed_input_pb(" "MixedInput routes to _pb"

echo "--- Map request → _pb variant ---"
assert_contains "$C_HDR" "${PREFIX}_map_input_pb(" "MapInput routes to _pb"
assert_not_contains "$C_HDR" "${PREFIX}_map_input(" "MapInput has no flat variant"

echo "--- Recursive message (TreeOp) ---"
assert_contains "$C_HDR" "${PREFIX}_tree_op(" "TreeOp function exists (generator did not crash)"
assert_contains "$C_HDR" 'child, int32_t child_len' "recursive TreeNode.child serialized as bytes+len"

echo "--- All scalar types present ---"
assert_contains "$C_HDR" 'int32_t a' "int32 field"
assert_contains "$C_HDR" 'int64_t b' "int64 field"
assert_contains "$C_HDR" 'uint32_t c' "uint32 field"
assert_contains "$C_HDR" 'float e' "float field"
assert_contains "$C_HDR" 'double f' "double field"

echo "--- Memory management ---"
assert_contains "$C_HDR" "${PREFIX}_free(" "free function exists"

# =========================================================================
# Generate Rust native
# =========================================================================
echo ""
echo "=== Rust Native (lang=rust, mode=native) ==="
protoc -I"$SCRIPT_DIR/api" -Iapi -I/usr/include \
    --plugin=protoc-gen-synurang-ffi="$PLUGIN" \
    --synurang-ffi_out="$OUT_DIR" \
    --synurang-ffi_opt=lang=rust,mode=native \
    native_test.proto

RS_NATIVE="$OUT_DIR/native_test_ffi_native.rs"
if [ ! -f "$RS_NATIVE" ]; then
    echo "FAIL: native_test_ffi_native.rs was not generated!"
    exit 1
fi

echo "--- Empty request (Ping) ---"
assert_contains "$RS_NATIVE" "fn ${PREFIX}_ping(" "Ping function exists"

echo "--- Void prototype (NoOp) ---"
assert_contains "$RS_NATIVE" "fn ${PREFIX}_no_op(" "NoOp function exists"

echo "--- uint64 field ---"
assert_contains "$RS_NATIVE" 'd: u64' "uint64 field mapped to u64"

echo "--- Imported input ---"
assert_contains "$RS_NATIVE" "fn ${PREFIX}_imported_input(" "ImportedInput function exists"
assert_contains "$RS_NATIVE" 'code: i32' "imported Error.code field present"

echo "--- Oneof → _pb ---"
assert_contains "$RS_NATIVE" "fn ${PREFIX}_oneof_input_pb(" "OneofInput routes to _pb"

echo "--- Map → _pb ---"
assert_contains "$RS_NATIVE" "fn ${PREFIX}_map_input_pb(" "MapInput routes to _pb"

echo "--- Recursive message (TreeOp) ---"
assert_contains "$RS_NATIVE" "fn ${PREFIX}_tree_op(" "TreeOp function exists (no crash)"

echo "--- Plugin trait ---"
assert_contains "$RS_NATIVE" 'trait NativeTestServicePlugin' "plugin trait generated"

echo "--- Memory management ---"
assert_contains "$RS_NATIVE" "fn ${PREFIX}_free(" "free function exists"

echo "--- Error reset on success ---"
assert_contains "$RS_NATIVE" 'clear_last_error();' "native clears LAST_ERROR on success"

# =========================================================================
# Generate Rust WASM
# =========================================================================
echo ""
echo "=== Rust WASM (lang=rust, mode=wasm) ==="
protoc -I"$SCRIPT_DIR/api" -Iapi -I/usr/include \
    --plugin=protoc-gen-synurang-ffi="$PLUGIN" \
    --synurang-ffi_out="$OUT_DIR" \
    --synurang-ffi_opt=lang=rust,mode=wasm \
    native_test.proto

RS_WASM="$OUT_DIR/native_test_wasm.rs"
if [ ! -f "$RS_WASM" ]; then
    echo "FAIL: native_test_wasm.rs was not generated!"
    exit 1
fi

echo "--- Empty request (Ping) ---"
assert_contains "$RS_WASM" "fn ${PREFIX}_ping(" "Ping function exists"

echo "--- Void prototype (NoOp) ---"
assert_contains "$RS_WASM" "fn ${PREFIX}_no_op(" "NoOp function exists"

echo "--- uint64 field ---"
assert_contains "$RS_WASM" 'd: u64' "uint64 field mapped to u64"

echo "--- Oneof → _pb ---"
assert_contains "$RS_WASM" "fn ${PREFIX}_oneof_input_pb(" "OneofInput routes to _pb"

echo "--- Map → _pb ---"
assert_contains "$RS_WASM" "fn ${PREFIX}_map_input_pb(" "MapInput routes to _pb"

echo "--- wasm_bindgen ---"
assert_contains "$RS_WASM" 'wasm_bindgen' "wasm_bindgen attribute present"

echo "--- Error reset on success ---"
assert_contains "$RS_WASM" 'clear_last_error();' "wasm clears LAST_ERROR on success"

echo "--- WASM stream ABI ---"
assert_contains "$RS_WASM" 'trait PluginStreamSender' "WASM stream sender trait generated"
assert_contains "$RS_WASM" 'trait PluginStreamReceiver' "WASM stream receiver trait generated"
assert_contains "$RS_WASM" 'trait PluginStreamBidi' "WASM stream bidi trait generated"
assert_contains "$RS_WASM" 'fn server_stream(' "server-stream trait method generated"
assert_contains "$RS_WASM" 'fn client_stream(' "client-stream trait method generated"
assert_contains "$RS_WASM" 'fn bidi_stream(' "bidi-stream trait method generated"
assert_contains "$RS_WASM" "fn ${PREFIX}_stream_open(" "stream open export generated"
assert_contains "$RS_WASM" "fn ${PREFIX}_stream_send(" "stream send export generated"
assert_contains "$RS_WASM" "fn ${PREFIX}_stream_recv(" "stream recv export generated"
assert_contains "$RS_WASM" "fn ${PREFIX}_stream_close_send(" "stream close_send export generated"
assert_contains "$RS_WASM" "fn ${PREFIX}_stream_close(" "stream close export generated"

# =========================================================================
# Compilation checks
# =========================================================================
echo ""
echo "=== Compilation Checks ==="

echo "--- Fail-fast validation (native) ---"
assert_contains "$RS_NATIVE" 'from_utf8(' "native uses strict UTF-8 validation"
assert_not_contains "$RS_NATIVE" 'from_utf8_lossy' "native does not use lossy UTF-8"

echo "--- C header strict compile ---"
if command -v gcc >/dev/null 2>&1; then
    # Include the header from a .c file to avoid #pragma once warning
    COMPILE_TEST="$OUT_DIR/_compile_test.c"
    echo "#include \"$(basename "$C_HDR")\"" > "$COMPILE_TEST"
    if gcc -fsyntax-only -std=c11 -Wstrict-prototypes -Werror -I"$(dirname "$C_HDR")" "$COMPILE_TEST" 2>/dev/null; then
        PASS=$((PASS + 1))
    else
        echo "  FAIL: C header fails strict compilation"
        gcc -fsyntax-only -std=c11 -Wstrict-prototypes -Werror -I"$(dirname "$C_HDR")" "$COMPILE_TEST" 2>&1 | head -5
        FAIL=$((FAIL + 1))
    fi
else
    echo "  SKIP: gcc not found"
fi

echo "--- Rust cargo check (native + wasm) ---"
if [ "${SYNURANG_CARGO_CHECK:-}" = "1" ] && command -v cargo >/dev/null 2>&1; then
    CARGO_DIR="$OUT_DIR/rust_check"
    mkdir -p "$CARGO_DIR/src"

    cat > "$CARGO_DIR/Cargo.toml" <<'CARGOEOF'
[package]
name = "synurang-native-wasm-check"
version = "0.0.0"
edition = "2021"
publish = false

[dependencies]
prost = "0.13"
prost-types = "0.13"
wasm-bindgen = "0.2"

[build-dependencies]
prost-build = "0.13"
CARGOEOF

    cat > "$CARGO_DIR/build.rs" <<BUILDEOF
fn main() {
    prost_build::Config::new()
        .compile_protos(
            &["${SCRIPT_DIR}/api/native_test.proto"],
            &["${SCRIPT_DIR}/api", "${ROOT_DIR}/api"],
        )
        .unwrap();
}
BUILDEOF

    # Wrapper modules: strip inner attributes, add use super::*
    {
        echo 'use super::*;'
        grep -v '^#!\[' "$RS_NATIVE"
    } > "$CARGO_DIR/src/ffi_native.rs"

    {
        echo 'use super::*;'
        grep -v '^#!\[' "$RS_WASM"
    } > "$CARGO_DIR/src/ffi_wasm.rs"

    cat > "$CARGO_DIR/src/lib.rs" <<'LIBEOF'
#![allow(unused_imports, dead_code, clippy::missing_safety_doc)]

use prost::Message;

// google.protobuf.Empty (not in prost-types; FFI templates reference it by GoName)
#[derive(Clone, prost::Message)]
pub struct Empty {}

include!(concat!(env!("OUT_DIR"), "/nativetest.v1.rs"));
include!(concat!(env!("OUT_DIR"), "/core.v1.rs"));

mod ffi_native;
mod ffi_wasm;
LIBEOF

    CARGO_LOG="$OUT_DIR/cargo_check.log"
    if (cd "$CARGO_DIR" && cargo check --lib) > "$CARGO_LOG" 2>&1; then
        PASS=$((PASS + 1))
    else
        echo "  FAIL: Rust cargo check failed"
        tail -20 "$CARGO_LOG"
        FAIL=$((FAIL + 1))
    fi
elif [ "${SYNURANG_CARGO_CHECK:-}" != "1" ]; then
    echo "  SKIP: set SYNURANG_CARGO_CHECK=1 to enable (requires network)"
else
    echo "  SKIP: cargo not found"
fi

# =========================================================================
# Summary
# =========================================================================
echo ""
echo "=== Results ==="
TOTAL=$((PASS + FAIL))
echo "  $PASS/$TOTAL passed"
if [ "$FAIL" -gt 0 ]; then
    echo "  $FAIL FAILED"
    exit 1
fi
echo "  All tests passed!"

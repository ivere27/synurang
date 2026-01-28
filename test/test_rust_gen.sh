#!/bin/bash
set -e

# Directory setup
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."
BIN_DIR="$ROOT_DIR/bin"
PLUGIN="$BIN_DIR/protoc-gen-synurang-ffi"

# Ensure clean state
rm -rf "$ROOT_DIR/test/generated_rust"
mkdir -p "$ROOT_DIR/test/generated_rust"

echo "Building plugin..."
cd "$ROOT_DIR"
go build -o "$PLUGIN" ./cmd/protoc-gen-synurang-ffi

echo "Generating Rust code from core.proto..."
protoc -Iapi -I/usr/include \
    --plugin=protoc-gen-synurang-ffi="$PLUGIN" \
    --synurang-ffi_out="$ROOT_DIR/test/generated_rust" \
    --synurang-ffi_opt=lang=rust \
    core.proto

echo "Verifying core_ffi.rs..."
CORE_FFI="$ROOT_DIR/test/generated_rust/core_ffi.rs"
if [ ! -f "$CORE_FFI" ]; then
    echo "Error: core_ffi.rs was not generated!"
    exit 1
fi

if ! grep -q 'pub trait FfiServer' "$CORE_FFI"; then
    echo "Error: core_ffi.rs missing FfiServer trait!"
    exit 1
fi

if ! grep -q 'pub struct FfiChannel' "$CORE_FFI"; then
    echo "Error: core_ffi.rs missing FfiChannel struct!"
    exit 1
fi

if ! grep -q 'use prost::Message;' "$CORE_FFI"; then
    echo "Error: core_ffi.rs missing prost imports!"
    exit 1
fi

if ! grep -q 'pub fn invoke' "$CORE_FFI"; then
    echo "Error: core_ffi.rs missing invoke function!"
    exit 1
fi

echo "Generating Rust code from example.proto..."
protoc -Iexample/api -Iapi -I/usr/include \
    --plugin=protoc-gen-synurang-ffi="$PLUGIN" \
    --synurang-ffi_out="$ROOT_DIR/test/generated_rust" \
    --synurang-ffi_opt=lang=rust \
    example.proto

echo "Verifying example_ffi.rs..."
EXAMPLE_FFI="$ROOT_DIR/test/generated_rust/example_ffi.rs"
if [ ! -f "$EXAMPLE_FFI" ]; then
    echo "Error: example_ffi.rs was not generated!"
    exit 1
fi

if ! grep -q 'pub trait FfiServer' "$EXAMPLE_FFI"; then
    echo "Error: example_ffi.rs missing FfiServer trait!"
    exit 1
fi

if ! grep -q '"/example.v1.GoGreeterService/Bar"' "$EXAMPLE_FFI"; then
    echo "Error: example_ffi.rs missing Bar dispatch logic!"
    exit 1
fi

echo "Rust Generation Test Passed!"
rm -rf "$ROOT_DIR/test/generated_rust"

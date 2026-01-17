#!/bin/bash
set -e

# Directory setup
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."
BIN_DIR="$ROOT_DIR/bin"
PLUGIN="$BIN_DIR/protoc-gen-synurang-ffi"

# Ensure clean state
rm -rf "$ROOT_DIR/test/generated_cpp"
mkdir -p "$ROOT_DIR/test/generated_cpp"

echo "Building plugin..."
cd "$ROOT_DIR"
go build -o "$PLUGIN" ./cmd/protoc-gen-synurang-ffi

echo "Generating C++ code from core.proto..."
protoc -Iapi -I/usr/include \
    --plugin=protoc-gen-synurang-ffi="$PLUGIN" \
    --synurang-ffi_out="$ROOT_DIR/test/generated_cpp" \
    --synurang-ffi_opt=lang=cpp \
    core.proto

echo "Verifying core_ffi.cc..."
CORE_FFI="$ROOT_DIR/test/generated_cpp/core_ffi.cc"
if [ ! -f "$CORE_FFI" ]; then
    echo "Error: core_ffi.cc was not generated!"
    exit 1
fi

if ! grep -q '#include "synurang.hpp"' "$CORE_FFI"; then
    echo "Error: core_ffi.cc missing synurang.hpp include!"
    exit 1
fi

if ! grep -q 'class FfiDispatcher' "$CORE_FFI"; then
    echo "Error: core_ffi.cc missing FfiDispatcher class!"
    exit 1
fi

if ! grep -q 'namespace core::v1 {' "$CORE_FFI"; then
    echo "Error: core_ffi.cc missing namespace core::v1!"
    exit 1
fi

echo "Generating C++ code from example.proto..."
protoc -Iexample/api -Iapi -I/usr/include \
    --plugin=protoc-gen-synurang-ffi="$PLUGIN" \
    --synurang-ffi_out="$ROOT_DIR/test/generated_cpp" \
    --synurang-ffi_opt=lang=cpp \
    example.proto

echo "Verifying example_ffi.cc..."
EXAMPLE_FFI="$ROOT_DIR/test/generated_cpp/example_ffi.cc"
if [ ! -f "$EXAMPLE_FFI" ]; then
    echo "Error: example_ffi.cc was not generated!"
    exit 1
fi

if ! grep -q 'if (method == "/example.v1.GoGreeterService/Bar") {' "$EXAMPLE_FFI"; then
    echo "Error: example_ffi.cc missing Bar dispatch logic!"
    exit 1
fi

echo "C++ Generation Test Passed!"
rm -rf "$ROOT_DIR/test/generated_cpp"

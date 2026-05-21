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

echo "Verifying core_ffi.h..."
CORE_FFI="$ROOT_DIR/test/generated_cpp/core_ffi.h"
if [ ! -f "$CORE_FFI" ]; then
    echo "Error: core_ffi.h was not generated!"
    exit 1
fi

if ! grep -q '#include "core.pb.h"' "$CORE_FFI"; then
    echo "Error: core_ffi.h missing core.pb.h include!"
    exit 1
fi

if ! grep -q 'class HealthServiceFfiServer' "$CORE_FFI"; then
    echo "Error: core_ffi.h missing HealthServiceFfiServer class!"
    exit 1
fi

if ! grep -q 'namespace core::v1 {' "$CORE_FFI"; then
    echo "Error: core_ffi.h missing namespace core::v1!"
    exit 1
fi

echo "Generating C++ code from example.proto..."
protoc -Iexample/api -Iapi -I/usr/include \
    --plugin=protoc-gen-synurang-ffi="$PLUGIN" \
    --synurang-ffi_out="$ROOT_DIR/test/generated_cpp" \
    --synurang-ffi_opt=lang=cpp \
    example.proto

echo "Verifying example_ffi.h..."
EXAMPLE_FFI="$ROOT_DIR/test/generated_cpp/example_ffi.h"
if [ ! -f "$EXAMPLE_FFI" ]; then
    echo "Error: example_ffi.h was not generated!"
    exit 1
fi

if ! grep -q 'if (method == "/example.v1.GoGreeterService/Bar") {' "$EXAMPLE_FFI"; then
    echo "Error: example_ffi.h missing Bar dispatch logic!"
    exit 1
fi

echo "Generating C++ lite code from core/cache/native_test protos..."
protoc -Iapi -I/usr/include \
    --plugin=protoc-gen-synurang-ffi="$PLUGIN" \
    --synurang-ffi_out="$ROOT_DIR/test/generated_cpp" \
    --synurang-ffi_opt=lang=cpp,mode=lite \
    core.proto cache.proto

protoc -Itest/api -Iapi -I/usr/include \
    --plugin=protoc-gen-synurang-ffi="$PLUGIN" \
    --synurang-ffi_out="$ROOT_DIR/test/generated_cpp" \
    --synurang-ffi_opt=lang=cpp,mode=lite \
    native_test.proto

CORE_LITE="$ROOT_DIR/test/generated_cpp/core_lite.hpp"
CACHE_LITE="$ROOT_DIR/test/generated_cpp/cache_lite.hpp"
NATIVE_TEST_LITE="$ROOT_DIR/test/generated_cpp/native_test_lite.hpp"

if [ ! -f "$CORE_LITE" ] || [ ! -f "$CACHE_LITE" ] || [ ! -f "$NATIVE_TEST_LITE" ]; then
    echo "Error: C++ lite headers were not generated!"
    exit 1
fi

if ! grep -q '#ifndef CORE_LITE_H_' "$CORE_LITE"; then
    echo "Error: core_lite.hpp has the wrong include guard!"
    exit 1
fi

if ! grep -q 'std::shared_ptr<::synurang::lite::Timestamp> timestamp' "$CORE_LITE"; then
    echo "Error: core_lite.hpp missing WKT Timestamp field type!"
    exit 1
fi

if ! grep -q '::synurang::lite::BoolValue Contains' "$CACHE_LITE"; then
    echo "Error: cache_lite.hpp missing WKT BoolValue service return!"
    exit 1
fi

if ! grep -q '#include "core_lite.hpp"' "$NATIVE_TEST_LITE"; then
    echo "Error: native_test_lite.hpp missing imported lite header include!"
    exit 1
fi

if ! grep -q 'std::map<std::string, std::string> tags' "$NATIVE_TEST_LITE"; then
    echo "Error: native_test_lite.hpp missing map field generation!"
    exit 1
fi

if ! grep -q 'SynurangLiteBidiStream<ScalarRequest, ScalarResponse> BidiStream()' "$NATIVE_TEST_LITE"; then
    echo "Error: native_test_lite.hpp did not avoid BidiStream helper collision!"
    exit 1
fi

if command -v g++ >/dev/null 2>&1; then
    g++ -std=c++11 -I"$ROOT_DIR/cpp" -I"$ROOT_DIR/test/generated_cpp" -fsyntax-only -x c++ "$CORE_LITE"
    g++ -std=c++11 -I"$ROOT_DIR/cpp" -I"$ROOT_DIR/test/generated_cpp" -fsyntax-only -x c++ "$CACHE_LITE"
    g++ -std=c++11 -I"$ROOT_DIR/cpp" -I"$ROOT_DIR/test/generated_cpp" -fsyntax-only -x c++ "$NATIVE_TEST_LITE"
fi

echo "C++ Generation Test Passed!"
rm -rf "$ROOT_DIR/test/generated_cpp"

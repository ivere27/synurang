#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BUILD=${1:?Usage: test_python.sh BUILD_DIR MODULE...}
shift
GENERATOR=${SYNURANG_GENERATOR:-$ROOT/target/debug/protoc-gen-synurang-ffi}
mkdir -p "$BUILD/python-generated"
cc -std=c11 -shared -fPIC -I"$ROOT/include" "$ROOT/src/module_host.c" -ldl -o "$BUILD/libsynurang_module_host.so"
protoc -I"$ROOT/test/call" --plugin="protoc-gen-synurang-ffi=$GENERATOR" \
    --synurang-ffi_out="lang=python,mode=client:$BUILD/python-generated" "$ROOT/test/call/conformance.proto"
export SYNURANG_MODULE_HOST_LIBRARY="$BUILD/libsynurang_module_host.so"
export PYTHONPATH="$ROOT/python:$BUILD/python-generated${PYTHONPATH:+:$PYTHONPATH}"
cc -std=c11 -shared -fPIC -pthread -I"$ROOT/include" "$ROOT/test/call/release_module.c" \
    "$ROOT/src/call.c" "$ROOT/src/c_runtime.c" -o "$BUILD/release.so"
export SYNURANG_TEST_RELEASE_MODULE="$BUILD/release.so"
python3 "$ROOT/test/call/python_conformance.py" "$@"
python3 "$ROOT/test/call/python_generated_conformance.py" "$@"
cc -std=c11 -shared -fPIC -pthread -I"$ROOT/include" "$ROOT/test/call/early_module.c" \
    "$ROOT/src/call.c" "$ROOT/src/c_runtime.c" -o "$BUILD/early_python.so"
python3 "$ROOT/test/call/python_early_conformance.py" "$BUILD/early_python.so"

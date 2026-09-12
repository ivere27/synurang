#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$(realpath "${1:?Provide the output directory from test_call_runtime.sh}")"
SWIFT="${SWIFT:-swift}"
for tool in cargo cc c++ protoc protoc-gen-go protoc-gen-go-grpc go python3 cmake javac java dotnet dart "$SWIFT"; do
  command -v "$tool" >/dev/null || { echo "Required tool unavailable: $tool" >&2; exit 1; }
done
cd "$ROOT_DIR"
MODULES=("$OUT_DIR/c_module.so" "$OUT_DIR/cpp_module.so" "$OUT_DIR/rust_module.so" "$OUT_DIR/go_module.so")
export LD_LIBRARY_PATH="$OUT_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export SYNURANG_GENERATOR="${SYNURANG_GENERATOR:-$ROOT_DIR/target/debug/protoc-gen-synurang-ffi}"
export SYNURANG_TEST_RELEASE_MODULE="$OUT_DIR/release.so"
bash test/call/test_python.sh "$OUT_DIR" "${MODULES[@]}"
bash test/call/test_java.sh "$OUT_DIR" "${MODULES[@]}"
bash test/call/test_go.sh "${MODULES[@]}"
go test -race ./pkg/module

cc -std=c11 -Iinclude -c src/module_host.c -o "$OUT_DIR/cpp_host_loader.o"
c++ -std=c++17 -Wall -Wextra -Werror -pedantic -Iinclude test/call/cpp_host.cpp \
  "$OUT_DIR/cpp_host_loader.o" "$OUT_DIR/c_module.a" -ldl -pthread -o "$OUT_DIR/cpp_host_test"
"$OUT_DIR/cpp_host_test" "${MODULES[@]}"
SYNURANG_STATIC_MODULE_DIR="$OUT_DIR" cargo run --manifest-path test/call/rust_host/Cargo.toml -- "$OUT_DIR"

mkdir -p "$OUT_DIR/csharp-generated"
protoc -Itest/call --plugin="protoc-gen-synurang-ffi=$SYNURANG_GENERATOR" \
  --csharp_out="$OUT_DIR/csharp-generated" \
  --synurang-ffi_out="lang=csharp,mode=client:$OUT_DIR/csharp-generated" conformance.proto
dotnet run --project test/call/csharp/Conformance.csproj \
  -p:GeneratedDir="$OUT_DIR/csharp-generated" -- "${MODULES[@]}"
SWIFT="$SWIFT" bash test/call/swift_generated.sh "$OUT_DIR" "${MODULES[@]}"
bash test/test_dart_call_runtime.sh "$OUT_DIR"

#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${SYNURANG_CALL_TEST_OUT:-$(mktemp -d /tmp/synurang-call.XXXXXX)}"
WASM_CC="${WASM_CC:-${WASI_SDK_PATH:?Set WASI_SDK_PATH to the Clang WASI SDK}/bin/clang}"
WASM_CXX="${WASM_CXX:-${WASI_SDK_PATH:?Set WASI_SDK_PATH or WASM_CXX}/bin/clang++}"
cleanup() {
  if [[ "${SYNURANG_KEEP_TEST_OUTPUT:-0}" != 1 ]]; then rm -rf "$OUT_DIR"; fi
}
trap cleanup EXIT
for tool in cargo cc c++ ar protoc protoc-gen-go go node npm "$WASM_CC" "$WASM_CXX"; do
  command -v "$tool" >/dev/null || { echo "Required tool unavailable: $tool" >&2; exit 1; }
done
mkdir -p "$OUT_DIR"
cd "$ROOT_DIR"
cargo build --manifest-path cmd/protoc-gen-synurang-ffi/Cargo.toml
TARGET_DIR="$(cargo metadata --manifest-path cmd/protoc-gen-synurang-ffi/Cargo.toml --format-version 1 --no-deps | python3 -c 'import json,sys; print(json.load(sys.stdin)["target_directory"])')"
export SYNURANG_GENERATOR="$TARGET_DIR/debug/protoc-gen-synurang-ffi"
bash "$ROOT_DIR/test/test_module_codegen.sh"
protoc -Itest/call --plugin="protoc-gen-synurang-ffi=$SYNURANG_GENERATOR" \
  --synurang-ffi_out="lang=c,mode=module:$OUT_DIR" conformance.proto
mkdir -p "$OUT_DIR/cpp-generated"
protoc -Itest/call --plugin="protoc-gen-synurang-ffi=$SYNURANG_GENERATOR" \
  --synurang-ffi_out="lang=cpp,mode=module:$OUT_DIR/cpp-generated" conformance.proto
for file in conformance_lite.h conformance_lite.c conformance_ffi.h conformance_ffi.c; do
  cmp "$OUT_DIR/$file" "$OUT_DIR/cpp-generated/$file"
done
protoc -Itest/call --plugin="protoc-gen-synurang-ffi=$SYNURANG_GENERATOR" \
  --synurang-ffi_out="lang=typescript,mode=client,grpc=js:$OUT_DIR" conformance.proto

C_FLAGS=(-std=c11 -Wall -Wextra -Werror -Wstrict-prototypes -I"$ROOT_DIR/include" -I"$OUT_DIR")
C_SOURCES=(src/c_runtime.c src/call.c "$OUT_DIR/conformance_lite.c" "$OUT_DIR/conformance_ffi.c")
cc "${C_FLAGS[@]}" -pthread -fsanitize=address,undefined -fno-omit-frame-pointer \
  "${C_SOURCES[@]}" test/call/c_provider.c test/call/call_test.c -o "$OUT_DIR/call_test"
ASAN_OPTIONS=detect_leaks=1:halt_on_error=1 "$OUT_DIR/call_test"
cc "${C_FLAGS[@]}" -DSYNURANG_RUNTIME_NO_THREADS \
  "${C_SOURCES[@]}" test/call/c_provider.c test/call/call_test.c -o "$OUT_DIR/call_manual_test"
"$OUT_DIR/call_manual_test"

for source in "${C_SOURCES[@]}" test/call/c_provider.c; do
  object="$OUT_DIR/$(basename "${source%.*}").o"
  cc "${C_FLAGS[@]}" -O2 -fPIC -pthread -c "$source" -o "$object"
done
ar rcs "$OUT_DIR/c_module.a" "$OUT_DIR/c_runtime.o" "$OUT_DIR/call.o" \
  "$OUT_DIR/conformance_lite.o" "$OUT_DIR/conformance_ffi.o" "$OUT_DIR/c_provider.o"
cc -shared -pthread -Wl,--whole-archive "$OUT_DIR/c_module.a" -Wl,--no-whole-archive -o "$OUT_DIR/c_module.so"
NODE_INCLUDE="${NODE_INCLUDE:-/usr/include/node}"
cc "${C_FLAGS[@]}" -D_POSIX_C_SOURCE=200809L -fPIC -I"$NODE_INCLUDE" -c src/node.c -o "$OUT_DIR/node.o"
cc -shared -pthread "$OUT_DIR/node.o" "$OUT_DIR/c_module.a" -lm -o "$OUT_DIR/c_module.node"
cc "${C_FLAGS[@]}" -D_POSIX_C_SOURCE=200809L -DSYNURANG_NODE_DYNAMIC -fPIC -shared \
  -I"$NODE_INCLUDE" src/node.c src/module_host.c -ldl -o "$OUT_DIR/synurang_module_host.node"

WASM_FLAGS=(-O2 -mexec-model=reactor -DSYNURANG_RUNTIME_NO_THREADS -Iinclude -I"$OUT_DIR" -Wl,--export-memory)
"$WASM_CC" "${WASM_FLAGS[@]}" "${C_SOURCES[@]}" src/wasm.c test/call/c_provider.c -o "$OUT_DIR/c_module.wasm"

# C++ providers use the same generated contract and C runtime on both targets.
c++ -std=c++17 -Wall -Wextra -Werror -fPIC -Iinclude -I"$OUT_DIR" -x c++ \
  -c test/call/c_provider.c -o "$OUT_DIR/cpp_provider.o"
cc -shared -pthread "$OUT_DIR/cpp_provider.o" "$OUT_DIR/c_runtime.o" "$OUT_DIR/call.o" \
  "$OUT_DIR/conformance_lite.o" "$OUT_DIR/conformance_ffi.o" -o "$OUT_DIR/cpp_module.so"
"$WASM_CXX" -O2 -DSYNURANG_RUNTIME_NO_THREADS -Iinclude -I"$OUT_DIR" -x c++ \
  -c test/call/c_provider.c -o "$OUT_DIR/cpp_provider.wasm.o"
"$WASM_CC" "${WASM_FLAGS[@]}" "${C_SOURCES[@]}" src/wasm.c "$OUT_DIR/cpp_provider.wasm.o" -o "$OUT_DIR/cpp_module.wasm"

cargo build --manifest-path test/call/rust_provider/Cargo.toml
cargo build --manifest-path test/call/rust_provider/Cargo.toml --target wasm32-unknown-unknown
cp "$TARGET_DIR/debug/libsynurang_call_conformance.so" "$OUT_DIR/rust_module.so"
cp "$TARGET_DIR/wasm32-unknown-unknown/debug/synurang_call_conformance.wasm" "$OUT_DIR/rust_module.wasm"
cc -shared -pthread "$OUT_DIR/node.o" "$TARGET_DIR/debug/libsynurang_call_conformance.a" -ldl -lm -o "$OUT_DIR/rust_module.node"

protoc -Itest/call --go_out=paths=source_relative:test/call/pb \
  --plugin="protoc-gen-synurang-ffi=$SYNURANG_GENERATOR" \
  --synurang-ffi_out=lang=go,mode=module:test/call/pb conformance.proto
go build -tags synurang_call_conformance -buildmode=c-shared -o "$OUT_DIR/go_module.so" ./test/call/go_provider
go build -tags synurang_call_conformance -buildmode=c-archive -o "$OUT_DIR/go_module.a" ./test/call/go_provider
cc -shared -pthread "$OUT_DIR/node.o" "$OUT_DIR/go_module.a" -ldl -lm -o "$OUT_DIR/go_module.node"
GOOS=js GOARCH=wasm go build -tags synurang_call_conformance -o "$OUT_DIR/go_module.wasm" ./test/call/go_provider
GO_ROOT="$(go env GOROOT)"
if [[ -f "$GO_ROOT/lib/wasm/wasm_exec.js" ]]; then
  cp "$GO_ROOT/lib/wasm/wasm_exec.js" "$OUT_DIR/wasm_exec.js"
else
  cp "$GO_ROOT/misc/wasm/wasm_exec.js" "$OUT_DIR/wasm_exec.js"
fi
cc -std=c11 -Wall -Wextra -Werror -fPIC -shared -Iinclude src/module_host.c -ldl -o "$OUT_DIR/libsynurang_module_host.so"

npm ci --prefix typescript --no-audit --no-fund
"$ROOT_DIR/typescript/node_modules/.bin/playwright" install chromium
cp typescript/src/*.ts test/call/conformance.ts test/call/*.mjs test/call/browser.html "$OUT_DIR/"
cp typescript/package.json "$OUT_DIR/package.json"
ln -sfn "$ROOT_DIR/typescript/node_modules" "$OUT_DIR/node_modules"
"$ROOT_DIR/typescript/node_modules/.bin/tsc" --strict --skipLibCheck --target ES2022 \
  --module NodeNext --moduleResolution NodeNext --outDir "$OUT_DIR" "$OUT_DIR/"*.ts
node "$OUT_DIR/wasm_abi_test.mjs"
node "$OUT_DIR/wasm_modes.mjs"
node "$OUT_DIR/polling_conformance.mjs"
node "$OUT_DIR/worker_edges.mjs"
node "$OUT_DIR/go_bridge_edges.mjs"
node "$OUT_DIR/node_conformance.mjs"
node "$OUT_DIR/browser_conformance.mjs"
if [[ "${SYNURANG_CALL_HOSTS:-0}" == 1 ]]; then
  bash "$ROOT_DIR/test/test_call_hosts.sh" "$OUT_DIR"
fi

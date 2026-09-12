#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${1:?Usage: test_dart_call_runtime.sh EXISTING_CALL_TEST_OUTPUT}"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
cd "$ROOT_DIR"
for tool in dart protoc protoc-gen-dart cc node go; do
  command -v "$tool" >/dev/null || { echo "Required tool unavailable: $tool" >&2; exit 1; }
done
GENERATOR="${SYNURANG_GENERATOR:-$ROOT_DIR/target/debug/protoc-gen-synurang-ffi}"
[[ -x "$GENERATOR" ]] || { echo "Build protoc-gen-synurang-ffi first" >&2; exit 1; }
[[ -f .dart_tool/package_config.json ]] || { echo "Run flutter pub get first" >&2; exit 1; }
cc -std=c11 -Wall -Wextra -Werror -fPIC -shared -Iinclude \
  src/module_host.c -ldl -o "$OUT_DIR/libsynurang_module_host.so"
cc -std=c11 -shared -fPIC -pthread -Iinclude test/call/release_module.c \
  src/call.c src/c_runtime.c -o "$OUT_DIR/release.so"
export SYNURANG_TEST_RELEASE_MODULE="$OUT_DIR/release.so"
protoc -Itest/call --dart_out="$OUT_DIR" \
  --plugin="protoc-gen-synurang-ffi=$GENERATOR" \
  --synurang-ffi_out="lang=dart,mode=client:$OUT_DIR" conformance.proto
cp test/call/dart_*.dart test/call/dart_browser.html test/call/dart_browser.mjs \
  test/call/dart_go_worker.mjs "$OUT_DIR/"
GO_ROOT="$(go env GOROOT)"
if [[ -f "$GO_ROOT/lib/wasm/wasm_exec.js" ]]; then
  cp "$GO_ROOT/lib/wasm/wasm_exec.js" "$OUT_DIR/wasm_exec.js"
else
  cp "$GO_ROOT/misc/wasm/wasm_exec.js" "$OUT_DIR/wasm_exec.js"
fi
if [[ ! -f "$OUT_DIR/synurang_go.js" ]]; then
  "$ROOT_DIR/typescript/node_modules/.bin/tsc" -p typescript/tsconfig.json
  cp typescript/dist/synurang_go.js "$OUT_DIR/"
fi
dart analyze lib/module.dart lib/src/module
dart run test/call/dart_edges.dart
PROVIDERS=(c cpp rust)
if [[ -f "$OUT_DIR/go_module.so" ]]; then PROVIDERS+=(go); fi
dart --packages=.dart_tool/package_config.json "$OUT_DIR/dart_native.dart" \
  "$OUT_DIR" "$OUT_DIR/libsynurang_module_host.so" "${PROVIDERS[@]}"
dart compile js --packages=.dart_tool/package_config.json \
  -o "$OUT_DIR/dart_web.js" "$OUT_DIR/dart_web.dart"
dart compile wasm --packages=.dart_tool/package_config.json \
  -o "$OUT_DIR/dart_web.wasm" "$OUT_DIR/dart_web.dart"
node "$OUT_DIR/dart_browser.mjs"

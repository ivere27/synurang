#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="${1:-$ROOT/build/shared_memory}"
for tool in cargo protoc cc c++ python3; do
  command -v "$tool" >/dev/null || { echo "Required tool unavailable: $tool" >&2; exit 1; }
done
if [[ "$(uname -s)" != Linux ]]; then
  echo "This example build script targets Linux POSIX shared memory." >&2
  exit 1
fi
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
cargo build --manifest-path "$ROOT/cmd/protoc-gen-synurang-ffi/Cargo.toml"
TARGET="$(cargo metadata --manifest-path "$ROOT/cmd/protoc-gen-synurang-ffi/Cargo.toml" \
  --format-version 1 --no-deps | python3 -c 'import json,sys; print(json.load(sys.stdin)["target_directory"])')"
GENERATOR="$TARGET/debug/protoc-gen-synurang-ffi"
for mode in 'lang=c,mode=module' 'lang=python,mode=client'; do
  protoc -I"$ROOT/example/shared_memory" --plugin="protoc-gen-synurang-ffi=$GENERATOR" \
    --synurang-ffi_out="$mode:$OUT" shared_memory.proto frame_queue.proto
done
FLAGS=(-std=c11 -D_POSIX_C_SOURCE=200809L -O2 -Wall -Wextra -Werror -Wstrict-prototypes
  -fPIC -pthread -I"$ROOT/include" -I"$OUT")
cc "${FLAGS[@]}" -c "$OUT/shared_memory_lite.c" -o "$OUT/shared_memory_lite.o"
cc "${FLAGS[@]}" -c "$OUT/frame_queue_lite.c" -o "$OUT/frame_queue_lite.o"
cc "${FLAGS[@]}" -shared "$ROOT/src/c_runtime.c" "$ROOT/src/call.c" \
  "$OUT/shared_memory_lite.o" "$OUT/shared_memory_ffi.c" \
  "$OUT/frame_queue_lite.o" "$OUT/frame_queue_ffi.c" \
  "$ROOT/example/shared_memory/backend.c" "$ROOT/example/shared_memory/queue_backend.c" \
  -lrt -o "$OUT/backend.so"
cc "${FLAGS[@]}" -c "$ROOT/src/module_host.c" -o "$OUT/module_host.o"
cc -shared -pthread "$OUT/module_host.o" -ldl -o "$OUT/libsynurang_module_host.so"
c++ -std=c++17 -O2 -Wall -Wextra -Werror -pedantic -pthread \
  -I"$ROOT/include" -I"$OUT" "$ROOT/example/shared_memory/caller.cpp" \
  "$OUT/shared_memory_lite.o" "$OUT/module_host.o" -ldl -lrt -o "$OUT/cpp_caller"
c++ -std=c++17 -O2 -Wall -Wextra -Werror -pedantic -pthread \
  -I"$ROOT/include" -I"$OUT" "$ROOT/example/shared_memory/queue_caller.cpp" \
  "$OUT/frame_queue_lite.o" "$OUT/module_host.o" -ldl -lrt -o "$OUT/cpp_queue_caller"
echo "Built shared-memory example in $OUT"

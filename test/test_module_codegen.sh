#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GENERATOR="${SYNURANG_GENERATOR:-$ROOT_DIR/target/debug/protoc-gen-synurang-ffi}"
OUT_DIR="$(mktemp -d /tmp/synurang-module-names.XXXXXX)"
trap 'rm -rf "$OUT_DIR"' EXIT
mkdir -p "$OUT_DIR/src"
cat > "$OUT_DIR/names.proto" <<'PROTO'
syntax = "proto3";
package module.names;
option go_package = "example.org/names";
message Value { int32 value = 1; }
service Keywords {
  rpc Delete(Value) returns (Value);
  rpc Restrict(Value) returns (Value);
  rpc Type(Value) returns (Value);
  rpc Async(Value) returns (Value);
  rpc Self(Value) returns (Value);
}
PROTO
protoc -I"$OUT_DIR" --plugin="protoc-gen-synurang-ffi=$GENERATOR" \
  --synurang-ffi_out="lang=cpp,mode=module:$OUT_DIR" names.proto
cc -std=c11 -Wall -Wextra -Werror -I"$ROOT_DIR/include" -I"$OUT_DIR" \
  -c "$OUT_DIR/names_ffi.c" -o "$OUT_DIR/names.o"
printf '#include "names_ffi.h"\nint main() { KeywordsHandlers h{}; h.delete_.message = nullptr; h.restrict_.message = nullptr; return h.type.message != nullptr; }\n' > "$OUT_DIR/host.cpp"
c++ -std=c++17 -Wall -Wextra -Werror -I"$ROOT_DIR/include" -I"$OUT_DIR" \
  -c "$OUT_DIR/host.cpp" -o "$OUT_DIR/host.o"
protoc -I"$OUT_DIR" --plugin="protoc-gen-synurang-ffi=$GENERATOR" \
  --synurang-ffi_out="lang=rust,mode=module:$OUT_DIR/src" names.proto
python3 - "$ROOT_DIR" "$OUT_DIR" <<'PY'
import json, pathlib, sys
root, out = map(pathlib.Path, sys.argv[1:])
(out / 'Cargo.toml').write_text('[package]\nname="module-keyword-check"\nversion="0.0.0"\nedition="2021"\n[dependencies]\nprost="0.13.5"\nsynurang-call={path=' + json.dumps(str(root / 'crates/synurang-call')) + '}\n')
PY
cat > "$OUT_DIR/src/lib.rs" <<'RUST'
#[derive(Clone, PartialEq, prost::Message)]
pub struct Value { #[prost(int32, tag="1")] pub value: i32 }
include!("names_ffi.rs");
RUST
cargo clippy --quiet --manifest-path "$OUT_DIR/Cargo.toml" -- -D warnings
printf 'C/C++ and Rust module keyword generation compiled successfully\n'

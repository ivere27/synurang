#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$ROOT_DIR/cmd/protoc-gen-synurang-ffi/Cargo.toml"
PLUGIN="$ROOT_DIR/target/debug/protoc-gen-synurang-ffi"
WORK="$(mktemp -d /tmp/synurang-lite-edges.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

cargo build --quiet --locked --manifest-path "$MANIFEST"
mkdir -p "$WORK/schema/apps" "$WORK/schema/deps" "$WORK/out-c"

cat > "$WORK/schema/deps/a-b.proto" <<'PROTO'
syntax = "proto3";
package edge.dash;
message DashValue { string value = 1; }
PROTO
cat > "$WORK/schema/deps/a_b.proto" <<'PROTO'
syntax = "proto3";
package edge.underscore;
message UnderscoreValue { int32 value = 1; }
PROTO
cat > "$WORK/schema/bridge.proto" <<'PROTO'
syntax = "proto3";
package edge.bridge;
import public "deps/a-b.proto";
import public "deps/a_b.proto";
PROTO
cat > "$WORK/schema/apps/root-file.proto" <<'PROTO'
syntax = "proto3";
package edge.root;
import "bridge.proto";
message RootValue {
  edge.dash.DashValue dash = 1;
  edge.underscore.UnderscoreValue underscore = 2;
}
PROTO

generate() {
    local language="$1" output="$2"
    protoc -I"$WORK/schema" \
        --plugin=protoc-gen-synurang-ffi="$PLUGIN" \
        --synurang-ffi_out="$output" \
        --synurang-ffi_opt="lang=$language,mode=lite" \
        deps/a-b.proto deps/a_b.proto bridge.proto apps/root-file.proto
}
generate c "$WORK/out-c"

test -f "$WORK/out-c/apps/root-file_lite.h"
test -f "$WORK/out-c/apps/root-file_lite.c"
grep -Fq '#include "../deps/a-b_lite.h"' "$WORK/out-c/apps/root-file_lite.h"
grep -Fq '#include "../deps/a_b_lite.h"' "$WORK/out-c/apps/root-file_lite.h"
guard="$(sed -n 's/^#ifndef //p' "$WORK/out-c/apps/root-file_lite.h" | head -1)"
[[ "$guard" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]
cc -std=c11 -Wall -Wextra -Werror -pedantic -I"$WORK/out-c" \
    -c "$WORK/out-c/apps/root-file_lite.c" -o "$WORK/root.o"

cat > "$WORK/schema/proto2.proto" <<'PROTO'
syntax = "proto2";
package edge.legacy;
message Legacy { optional int32 value = 1; }
PROTO
cat > "$WORK/schema/timestamp.proto" <<'PROTO'
syntax = "proto3";
package edge.time;
import "google/protobuf/timestamp.proto";
message Timed { google.protobuf.Timestamp value = 1; }
PROTO

reject() {
    local language="$1" proto="$2" needle="$3" log="$WORK/reject.log"
    if protoc -I"$WORK/schema" -I/usr/include \
        --plugin=protoc-gen-synurang-ffi="$PLUGIN" \
        --synurang-ffi_out="$WORK/out-c" \
        --synurang-ffi_opt="lang=$language,mode=lite" "$proto" >"$log" 2>&1; then
        echo "unexpected success for $language $proto" >&2
        return 1
    fi
    grep -Fq "$needle" "$log"
}
reject c proto2.proto "supports proto3 schemas only"
reject c timestamp.proto "does not support protobuf type google.protobuf.Timestamp"

echo "C lite codegen edge checks passed."

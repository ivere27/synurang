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
import "google/protobuf/duration.proto";
message Timed {
  google.protobuf.Timestamp value = 1;
  google.protobuf.Duration span = 2;
}
PROTO
cat > "$WORK/schema/struct.proto" <<'PROTO'
syntax = "proto3";
package edge.unsupported;
import "google/protobuf/struct.proto";
message Boxed { google.protobuf.Struct value = 1; }
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
# A well-known type the shared C lite block does not define is still rejected
# up front, and the message names what is supported.
reject c struct.proto "does not support protobuf type google.protobuf.Struct"
reject c struct.proto "google.protobuf.Timestamp"

# Timestamp and Duration are supplied by the shared block, so they generate and
# compile with no protobuf runtime.
protoc -I"$WORK/schema" -I/usr/include \
    --plugin=protoc-gen-synurang-ffi="$PLUGIN" \
    --synurang-ffi_out="$WORK/out-c" \
    --synurang-ffi_opt=lang=c,mode=lite timestamp.proto
grep -Fq 'SynurangProtobufTimestamp* field_value;' "$WORK/out-c/timestamp_lite.h"
grep -Fq 'SynurangProtobufDuration* field_span;' "$WORK/out-c/timestamp_lite.h"
cc -std=c11 -Wall -Wextra -Werror -pedantic -I"$WORK/out-c" \
    -c "$WORK/out-c/timestamp_lite.c" -o "$WORK/timestamp.o"

# The direct WKT codecs round-trip without libprotobuf.  Decode is
# transactional: a payload that parses seconds and then fails in nanos must
# leave the caller's existing destination unchanged.
cat > "$WORK/wkt_runtime_test.c" <<'C'
#include "timestamp_lite.h"

#define CHECK(condition, code) \
    do {                       \
        if (!(condition)) return (code); \
    } while (0)

int main(void) {
    static const uint8_t malformed[] = {0x08, 0x07, 0x10, 0x80};
    SynurangProtobufTimestamp timestamp;
    SynurangProtobufTimestamp timestamp_out;
    SynurangProtobufDuration duration;
    SynurangProtobufDuration duration_out;
    uint8_t* wire = NULL;
    size_t wire_len = 0;

    synurang_protobuf_timestamp_init(&timestamp);
    synurang_protobuf_timestamp_init(&timestamp_out);
    timestamp.field_seconds = INT64_C(1700000000);
    timestamp.field_nanos = INT32_C(123456789);
    CHECK(synurang_protobuf_timestamp_encode(
              &timestamp, &wire, &wire_len) == SYNURANG_LITE_OK, 1);
    CHECK(wire != NULL && wire_len != 0, 2);
    CHECK(synurang_protobuf_timestamp_decode(
              &timestamp_out, wire, wire_len) == SYNURANG_LITE_OK, 3);
    CHECK(timestamp_out.field_seconds == timestamp.field_seconds &&
          timestamp_out.field_nanos == timestamp.field_nanos, 4);
    synurang_lite_release(timestamp._allocator, wire);

    timestamp_out.field_seconds = INT64_C(42);
    timestamp_out.field_nanos = INT32_C(9);
    CHECK(synurang_protobuf_timestamp_decode(
              &timestamp_out, malformed, sizeof(malformed)) ==
          SYNURANG_LITE_MALFORMED, 5);
    CHECK(timestamp_out.field_seconds == INT64_C(42) &&
          timestamp_out.field_nanos == INT32_C(9), 6);

    wire = NULL;
    wire_len = 0;
    synurang_protobuf_duration_init(&duration);
    synurang_protobuf_duration_init(&duration_out);
    duration.field_seconds = INT64_C(-123);
    duration.field_nanos = INT32_C(-456000000);
    CHECK(synurang_protobuf_duration_encode(
              &duration, &wire, &wire_len) == SYNURANG_LITE_OK, 7);
    CHECK(wire != NULL && wire_len != 0, 8);
    CHECK(synurang_protobuf_duration_decode(
              &duration_out, wire, wire_len) == SYNURANG_LITE_OK, 9);
    CHECK(duration_out.field_seconds == duration.field_seconds &&
          duration_out.field_nanos == duration.field_nanos, 10);
    synurang_lite_release(duration._allocator, wire);

    duration_out.field_seconds = INT64_C(-88);
    duration_out.field_nanos = INT32_C(-77);
    CHECK(synurang_protobuf_duration_decode(
              &duration_out, malformed, sizeof(malformed)) ==
          SYNURANG_LITE_MALFORMED, 11);
    CHECK(duration_out.field_seconds == INT64_C(-88) &&
          duration_out.field_nanos == INT32_C(-77), 12);
    return 0;
}
C
cc -std=c11 -Wall -Wextra -Werror -pedantic -I"$WORK/out-c" \
    "$WORK/wkt_runtime_test.c" "$WORK/out-c/timestamp_lite.c" \
    -o "$WORK/wkt_runtime_test"
"$WORK/wkt_runtime_test"

# Dependencies are commonly generated in a separate protoc invocation.  The
# root's enum_names option must not be projected onto an existing dependency:
# this dependency uses the default qualified spelling, while the short root
# independently produces the same final C macro from another enum.
mkdir -p "$WORK/schema/enum-style" "$WORK/out-enum-style"
cat > "$WORK/schema/enum-style/dependency.proto" <<'PROTO'
syntax = "proto3";
package pkg;
enum Foo { FOO_BAR = 0; }
message Request {}
message Response {}
PROTO
cat > "$WORK/schema/enum-style/root.proto" <<'PROTO'
syntax = "proto3";
package pkg;
import "enum-style/dependency.proto";
enum FooFoo { BAR = 0; }
message Root { Foo value = 1; }
PROTO
cat > "$WORK/schema/enum-style/root_service.proto" <<'PROTO'
syntax = "proto3";
package pkg;
import "enum-style/dependency.proto";
enum FooFoo { BAR = 0; }
service CollisionService {
  rpc Call(Request) returns (Response);
}
PROTO

protoc -I"$WORK/schema" \
    --plugin=protoc-gen-synurang-ffi="$PLUGIN" \
    --synurang-ffi_out="$WORK/out-enum-style" \
    --synurang-ffi_opt=lang=c,mode=lite enum-style/dependency.proto
grep -Fq '#define PKG_FOO_FOO_BAR ' \
    "$WORK/out-enum-style/enum-style/dependency_lite.h"

for mode in lite default; do
    log="$WORK/enum-style-$mode.log"
    if protoc -I"$WORK/schema" \
        --plugin=protoc-gen-synurang-ffi="$PLUGIN" \
        --synurang-ffi_out="$WORK/out-enum-style" \
        --synurang-ffi_opt="lang=c,mode=$mode,enum_names=short" \
        enum-style/root.proto >"$log" 2>&1; then
        echo "unexpected success for mixed enum_names C $mode generation" >&2
        exit 1
    fi
    grep -Fq 'C lite symbol collision' "$log"
    grep -Fq 'PKG_FOO_FOO_BAR' "$log"
    grep -Fq 'qualified enum_names spelling' "$log"
done

log="$WORK/enum-style-ffi.log"
if protoc -I"$WORK/schema" \
    --plugin=protoc-gen-synurang-ffi="$PLUGIN" \
    --synurang-ffi_out="$WORK/out-enum-style" \
    --synurang-ffi_opt="lang=c,mode=default,enum_names=short" \
    enum-style/root_service.proto >"$log" 2>&1; then
    echo "unexpected success for mixed enum_names C FFI generation" >&2
    exit 1
fi
grep -Fq 'C FFI symbol collision' "$log"
grep -Fq 'PKG_FOO_FOO_BAR' "$log"
grep -Fq 'qualified enum_names spelling' "$log"

# When protoc generates both files in one response, their enum_names setting
# is known rather than speculative.  The same schemas are valid with short
# names and must generate/compile in both lite and full service modes.
mkdir -p "$WORK/out-enum-style-same" "$WORK/out-enum-style-same-ffi"
protoc -I"$WORK/schema" \
    --plugin=protoc-gen-synurang-ffi="$PLUGIN" \
    --synurang-ffi_out="$WORK/out-enum-style-same" \
    --synurang-ffi_opt="lang=c,mode=lite,enum_names=short" \
    enum-style/dependency.proto enum-style/root.proto
grep -Fq '#define PKG_FOO_BAR ' \
    "$WORK/out-enum-style-same/enum-style/dependency_lite.h"
grep -Fq '#define PKG_FOO_FOO_BAR ' \
    "$WORK/out-enum-style-same/enum-style/root_lite.h"
cc -std=c11 -Wall -Wextra -Werror -pedantic -I"$WORK/out-enum-style-same" \
    -c "$WORK/out-enum-style-same/enum-style/dependency_lite.c" \
    -o "$WORK/enum-style-same-dependency.o"
cc -std=c11 -Wall -Wextra -Werror -pedantic -I"$WORK/out-enum-style-same" \
    -c "$WORK/out-enum-style-same/enum-style/root_lite.c" \
    -o "$WORK/enum-style-same-root.o"

protoc -I"$WORK/schema" \
    --plugin=protoc-gen-synurang-ffi="$PLUGIN" \
    --synurang-ffi_out="$WORK/out-enum-style-same-ffi" \
    --synurang-ffi_opt="lang=c,mode=default,enum_names=short" \
    enum-style/dependency.proto enum-style/root_service.proto
test -f "$WORK/out-enum-style-same-ffi/enum-style/root_service_ffi.c"
cc -std=c11 -Wall -Wextra -Werror -pedantic \
    -I"$WORK/out-enum-style-same-ffi" -I"$ROOT_DIR/include" \
    -c "$WORK/out-enum-style-same-ffi/enum-style/root_service_ffi.c" \
    -o "$WORK/enum-style-same-root-ffi.o"

# Cross-style alternatives from one dependency are mutually exclusive.  Here
# Foo.FOO_X's qualified name equals FooFoo.FOO_FOO_X's short name, but either
# complete style is internally valid; validating their union as one concrete
# header would be a false collision.
mkdir -p "$WORK/schema/enum-style-safe" "$WORK/out-enum-style-safe"
cat > "$WORK/schema/enum-style-safe/dependency.proto" <<'PROTO'
syntax = "proto3";
package safe;
enum Foo { FOO_X = 0; }
enum FooFoo { FOO_FOO_X = 0; }
PROTO
cat > "$WORK/schema/enum-style-safe/root.proto" <<'PROTO'
syntax = "proto3";
package safe.consumer;
import "enum-style-safe/dependency.proto";
message Root { safe.Foo value = 1; }
PROTO

protoc -I"$WORK/schema" \
    --plugin=protoc-gen-synurang-ffi="$PLUGIN" \
    --synurang-ffi_out="$WORK/out-enum-style-safe" \
    --synurang-ffi_opt=lang=c,mode=lite enum-style-safe/dependency.proto
protoc -I"$WORK/schema" \
    --plugin=protoc-gen-synurang-ffi="$PLUGIN" \
    --synurang-ffi_out="$WORK/out-enum-style-safe" \
    --synurang-ffi_opt=lang=c,mode=lite,enum_names=short \
    enum-style-safe/root.proto
cc -std=c11 -Wall -Wextra -Werror -pedantic -I"$WORK/out-enum-style-safe" \
    -c "$WORK/out-enum-style-safe/enum-style-safe/dependency_lite.c" \
    -o "$WORK/enum-style-safe-dependency.o"
cc -std=c11 -Wall -Wextra -Werror -pedantic -I"$WORK/out-enum-style-safe" \
    -c "$WORK/out-enum-style-safe/enum-style-safe/root_lite.c" \
    -o "$WORK/enum-style-safe-root.o"

# A dependency style that collides with the shared runtime is not viable and
# must not contribute speculative symbols.  Qualified Lite.LITE_OK is valid;
# its short alternative would be SYNURANG_LITE_OK and is rejected when that
# dependency itself is generated with enum_names=short.
mkdir -p "$WORK/schema/enum-runtime-safe" "$WORK/out-enum-runtime-safe"
cat > "$WORK/schema/enum-runtime-safe/dependency.proto" <<'PROTO'
syntax = "proto3";
package synurang;
enum Lite { LITE_OK = 0; }
PROTO
cat > "$WORK/schema/enum-runtime-safe/root.proto" <<'PROTO'
syntax = "proto3";
package runtime.safe;
import "enum-runtime-safe/dependency.proto";
message Root { synurang.Lite value = 1; }
PROTO

protoc -I"$WORK/schema" \
    --plugin=protoc-gen-synurang-ffi="$PLUGIN" \
    --synurang-ffi_out="$WORK/out-enum-runtime-safe" \
    --synurang-ffi_opt=lang=c,mode=lite enum-runtime-safe/dependency.proto
grep -Fq '#define SYNURANG_LITE_LITE_OK ' \
    "$WORK/out-enum-runtime-safe/enum-runtime-safe/dependency_lite.h"
protoc -I"$WORK/schema" \
    --plugin=protoc-gen-synurang-ffi="$PLUGIN" \
    --synurang-ffi_out="$WORK/out-enum-runtime-safe" \
    --synurang-ffi_opt=lang=c,mode=lite,enum_names=short \
    enum-runtime-safe/root.proto
cc -std=c11 -Wall -Wextra -Werror -pedantic -I"$WORK/out-enum-runtime-safe" \
    -c "$WORK/out-enum-runtime-safe/enum-runtime-safe/dependency_lite.c" \
    -o "$WORK/enum-runtime-safe-dependency.o"
cc -std=c11 -Wall -Wextra -Werror -pedantic -I"$WORK/out-enum-runtime-safe" \
    -c "$WORK/out-enum-runtime-safe/enum-runtime-safe/root_lite.c" \
    -o "$WORK/enum-runtime-safe-root.o"

echo "C lite codegen edge checks passed."

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."
PLUGIN="$ROOT_DIR/bin/protoc-gen-synurang-ffi"

cd "$ROOT_DIR"
echo "Building canonical Rust generator..."
make build_plugin

OUT_ROOT="$(mktemp -d /tmp/synurang-codegen.XXXXXX)"
AX_DIR="$(mktemp -d /tmp/synurang-codegen-ax.XXXXXX)"
EDGE_DIR="$(mktemp -d /tmp/synurang-codegen-edge.XXXXXX)"
trap 'rm -rf "$OUT_ROOT" "$AX_DIR" "$EDGE_DIR"' EXIT

run_case() {
    local label="$1"
    local include_args="$2"
    local opts="$3"
    shift 3
    local out="$OUT_ROOT/$label"
    mkdir -p "$out"
    local opt_args=()
    if [[ -n "$opts" ]]; then
        opt_args+=("--synurang-ffi_opt=$opts")
    fi
    # include_args is intentionally split into protoc's individual -I flags.
    protoc $include_args \
        --plugin=protoc-gen-synurang-ffi="$PLUGIN" \
        --synurang-ffi_out="$out" \
        "${opt_args[@]}" \
        "$@"
    if ! find "$out" -type f -print -quit | grep -q .; then
        echo "Error: codegen case '$label' produced no files" >&2
        return 1
    fi
}

cat > "$AX_DIR/activex_fixture.proto" <<'PROTO'
syntax = "proto3";
package ax.v1;

import "activex.proto";
import "google/protobuf/empty.proto";
import "google/protobuf/wrappers.proto";

option go_package = "github.com/ivere27/synurang/test/ax;ax";

service AxGridService {
  option (synurang.v1.activex_service) = {
    prefix: "VFG"
    properties: [
      { dispid: 1 name: "Rows" },
      { dispid: 2 name: "BackColor" olecolor: true },
      { dispid: 3 name: "CustomThing" custom: true }
    ]
  };

  rpc SetRows(SetRowsRequest) returns (google.protobuf.Empty);
  rpc GetRows(GetRowsRequest) returns (google.protobuf.Int32Value);
  rpc SetBackColor(SetBackColorRequest) returns (google.protobuf.Empty);
  rpc GetBackColor(GetRowsRequest) returns (google.protobuf.Int32Value);
}

message SetRowsRequest { int64 grid_id = 1; int32 value = 2; }
message SetBackColorRequest { int64 grid_id = 1; int32 value = 2; }
message GetRowsRequest { int64 grid_id = 1; }
PROTO

cat > "$EDGE_DIR/edge_enum.proto" <<'PROTO'
syntax = "proto3";
package edge.v1;
option go_package = "example.com/edge;edge";

enum SomeKind {
  SOME_KIND_UNSPECIFIED = 0;
  SOME_KIND_FIRST = 1;
  OTHER_VALUE = 2;
}

enum DigitKind {
  DIGIT_KIND_UNSPECIFIED = 0;
  DIGIT_KIND_5X = 1;
  DIGIT_KIND_10 = 2;
}
PROTO

echo "Running language/mode generation matrix..."
run_case default "-Iapi -I/usr/include" "" core.proto cache.proto
cmp "$OUT_ROOT/default/core_ffi.pb.go" pkg/api/core_ffi.pb.go
cmp "$OUT_ROOT/default/cache_ffi.pb.go" pkg/api/cache_ffi.pb.go
cmp "$OUT_ROOT/default/core_ffi.pb.dart" lib/src/generated/core_ffi.pb.dart
cmp "$OUT_ROOT/default/cache_ffi.pb.dart" lib/src/generated/cache_ffi.pb.dart
run_case go_core "-Iapi -I/usr/include" "lang=go" core.proto cache.proto
run_case go_example "-Iexample/api -Iapi -I/usr/include" "lang=go" example.proto
run_case go_plugin_server "-Iexample/api -Iapi -I/usr/include" "lang=go,mode=plugin_server,services=GoGreeterService" example.proto
run_case go_plugin_client "-Iexample/api -Iapi -I/usr/include" "lang=go,mode=plugin_client,services=GoGreeterService" example.proto
run_case dart "-Iexample/api -Iapi -I/usr/include" "lang=dart" example.proto
run_case cpp "-Iexample/api -Iapi -I/usr/include" "lang=cpp" example.proto
run_case cpp_lite "-Iapi -I/usr/include" "lang=cpp,mode=lite" core.proto cache.proto
run_case cpp_plugin "-Iexample/api -Iapi -I/usr/include" "lang=cpp,mode=plugin_server,services=GoGreeterService" example.proto
run_case rust "-Iapi -I/usr/include" "lang=rust" core.proto
run_case rust_native "-Itest/api -Iapi -I/usr/include" "lang=rust,mode=native" native_test.proto
run_case rust_wasm "-Itest/api -Iapi -I/usr/include" "lang=rust,mode=wasm" native_test.proto
run_case rust_plugin "-Iexample/api -Iapi -I/usr/include" "lang=rust,mode=plugin_server,services=GoGreeterService" example.proto
run_case c_native "-Itest -Iapi -I/usr/include" "lang=c,mode=native" \
    api/c_ffi/dependency.proto api/c_ffi/service.proto
run_case c_activex "-I$AX_DIR -Iapi -I/usr/include" "lang=c,mode=activex" activex_fixture.proto
run_case java "-Iexample/api -Iapi -I/usr/include" "lang=java" example.proto
run_case csharp "-Iexample/api -Iapi -I/usr/include" "lang=csharp" example.proto
run_case csharp_lite "-Iexample/api -Iapi -I/usr/include" "lang=csharp,mode=lite" example.proto
run_case typescript "-Iexample/api -Iapi -I/usr/include" "lang=typescript" example.proto
run_case typescript_lite "-Iexample/api -Iapi -I/usr/include" "lang=typescript,mode=lite" example.proto
run_case c_lite "-I$EDGE_DIR -Iapi -I/usr/include" "lang=c,mode=lite" edge_enum.proto
run_case swift_lite "-Iexample/api -Iapi -I/usr/include" "lang=swift,mode=lite" example.proto
run_case swift_edge "-I$EDGE_DIR -Iapi -I/usr/include" "lang=swift,mode=lite" edge_enum.proto
run_case python "-Iexample/api -Iapi -I/usr/include" "lang=python" example.proto
run_case python_alias "-Iexample/api -Iapi -I/usr/include" "lang=py" example.proto
run_case python_lite "-Iexample/api -Iapi -I/usr/include" "lang=python,mode=lite" example.proto
run_case go_import_map "-Iapi -I/usr/include" "lang=go,Mcore.proto=example.com/override;corex" core.proto cache.proto
run_case go_empty_import_map "-Iapi -I/usr/include" "lang=go,Mcore.proto=" core.proto cache.proto
run_case go_annotations "-Iapi -I/usr/include" "lang=go,annotate_code=true" core.proto cache.proto
run_case go_api_level "-Iapi -I/usr/include" "lang=go,paths=source_relative,default_api_level=API_OPAQUE,apilevelMcore.proto=API_OPAQUE" core.proto

check_reject() {
    local opts="$1"
    local needle="$2"
    local output
    if output="$(protoc -Iapi -I/usr/include \
        --plugin=protoc-gen-synurang-ffi="$PLUGIN" \
        --synurang-ffi_out="$OUT_ROOT/rejected" \
        --synurang-ffi_opt="$opts" \
        core.proto 2>&1)"; then
        echo "Error: generator unexpectedly accepted '$opts'" >&2
        return 1
    fi
    if ! grep -Fq "$needle" <<<"$output"; then
        echo "Error: rejection for '$opts' did not contain '$needle': $output" >&2
        return 1
    fi
}

mkdir -p "$OUT_ROOT/rejected"
echo "Checking option and language validation..."
check_reject 'bogus=x' 'no such flag -bogus'
check_reject 'lang=go,paths=bad' 'unknown path type "bad"'
check_reject 'lang=go,annotate_code=maybe' 'bad value for parameter "annotate_code"'
check_reject 'lang=go,module=example.com/x' 'generated file does not match prefix "example.com/x"'
check_reject 'lang=go,default_api_level=BAD' 'unknown API level "BAD"'
check_reject 'lang=python2' 'unsupported language "python2"'

echo "Running Rust generator unit tests..."
cargo test --locked --manifest-path cmd/protoc-gen-synurang-ffi/Cargo.toml

echo "Running generated plugin cancellation tests..."
go test ./cmd/protoc-gen-synurang-ffi -run 'Test(Rust|Cpp)PluginServerCancelCallbacks' -count=1

echo "Canonical Rust generator regression suite passed."

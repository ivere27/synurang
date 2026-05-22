#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."
GO_PLUGIN="$ROOT_DIR/bin/protoc-gen-synurang-ffi"
RS_PLUGIN="$ROOT_DIR/bin/protoc-gen-synurang-ffi-rs"
BENCH_RUNS="${BENCH_RUNS:-5}"

cd "$ROOT_DIR"

echo "Building Go generator..."
go build -o "$GO_PLUGIN" ./cmd/protoc-gen-synurang-ffi

echo "Building Rust generator..."
cargo build --release --manifest-path cmd/protoc-gen-synurang-ffi-rs/Cargo.toml
mkdir -p "$ROOT_DIR/bin"
cp "$ROOT_DIR/target/release/protoc-gen-synurang-ffi-rs" "$RS_PLUGIN"

GO_OUT="$(mktemp -d /tmp/synurang-ffi-go.XXXXXX)"
RS_OUT="$(mktemp -d /tmp/synurang-ffi-rs.XXXXXX)"
AX_DIR="$(mktemp -d /tmp/synurang-ffi-ax.XXXXXX)"
EDGE_DIR="$(mktemp -d /tmp/synurang-ffi-edge.XXXXXX)"
trap 'rm -rf "$GO_OUT" "$RS_OUT" "$AX_DIR" "$EDGE_DIR"' EXIT

run_pair() {
    local include_args="$1"
    local opts="$2"
    shift 2
    protoc $include_args \
        --plugin=protoc-gen-synurang-ffi="$GO_PLUGIN" \
        --synurang-ffi_out="$GO_OUT" \
        --synurang-ffi_opt="$opts" \
        "$@"
    protoc $include_args \
        --plugin=protoc-gen-synurang-ffi="$RS_PLUGIN" \
        --synurang-ffi_out="$RS_OUT" \
        --synurang-ffi_opt="$opts" \
        "$@"
}

echo "Comparing generated outputs..."
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

message SetRowsRequest {
  int64 grid_id = 1;
  int32 value = 2;
}

message SetBackColorRequest {
  int64 grid_id = 1;
  int32 value = 2;
}

message GetRowsRequest {
  int64 grid_id = 1;
}
PROTO

run_pair "-Iapi -I/usr/include" "lang=go" core.proto cache.proto
run_pair "-Iexample/api -Iapi -I/usr/include" "lang=go" example.proto
run_pair "-Iexample/api -Iapi -I/usr/include" "lang=go,mode=plugin_server,services=GoGreeterService" example.proto
run_pair "-Iexample/api -Iapi -I/usr/include" "lang=go,mode=plugin_client,services=GoGreeterService" example.proto
run_pair "-Iexample/api -Iapi -I/usr/include" "lang=dart" example.proto
run_pair "-Iexample/api -Iapi -I/usr/include" "lang=cpp,mode=plugin_server,services=GoGreeterService" example.proto
run_pair "-Iexample/api -Iapi -I/usr/include" "lang=rust,mode=plugin_server,services=GoGreeterService" example.proto
run_pair "-Iapi -I/usr/include" "lang=cpp" core.proto
run_pair "-Iexample/api -Iapi -I/usr/include" "lang=cpp" example.proto
run_pair "-Iapi -I/usr/include" "lang=cpp,mode=lite" core.proto cache.proto
run_pair "-Itest/api -Iapi -I/usr/include" "lang=cpp,mode=lite" native_test.proto
run_pair "-Iexample/api -Iapi -I/usr/include" "lang=typescript" example.proto
run_pair "-Iexample/api -Iapi -I/usr/include" "lang=typescript,mode=lite" example.proto
run_pair "-Iapi -I/usr/include" "lang=rust" core.proto
run_pair "-Itest/api -Iapi -I/usr/include" "lang=rust,mode=native" native_test.proto
run_pair "-Itest/api -Iapi -I/usr/include" "lang=rust,mode=wasm" native_test.proto
run_pair "-Iapi -I/usr/include" "lang=c,mode=native" core.proto
run_pair "-Iexample/api -Iapi -I/usr/include" "lang=java" example.proto
run_pair "-Iexample/api -Iapi -I/usr/include" "lang=csharp" example.proto
run_pair "-Iexample/api -Iapi -I/usr/include" "lang=csharp,mode=lite" example.proto
run_pair "-Iexample/api -Iapi -I/usr/include" "lang=swift,mode=lite" example.proto
run_pair "-I$AX_DIR -Iapi -I/usr/include" "lang=c,mode=activex" activex_fixture.proto
run_pair "-Iapi -I/usr/include" "lang=go,Mcore.proto=example.com/override;corex" core.proto cache.proto
run_pair "-Itest/api -Iapi -I/usr/include" "lang=go,Mnative_test.proto=example.com/nativeoverride" native_test.proto
run_pair "-Iapi -I/usr/include" "lang=go,Mcore.proto=" core.proto cache.proto
run_pair "-Iapi -I/usr/include" "lang=go,annotate_code=true" core.proto cache.proto

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

enum CleanKind {
  CLEAN_KIND_UNSPECIFIED = 0;
  CLEAN_KIND_ONE = 1;
  CLEAN_KIND_TWO = 2;
}
PROTO
run_pair "-I$EDGE_DIR -Iapi -I/usr/include" "lang=swift,mode=lite" edge_enum.proto
run_pair "-Iapi -I/usr/include" "lang=go,paths=source_relative,default_api_level=API_OPAQUE,apilevelMcore.proto=API_OPAQUE" core.proto

diff -ru "$GO_OUT" "$RS_OUT"
echo "Output parity: OK"

echo "Checking flag-validation parity..."
check_reject() {
    local opt="$1"
    local needle="$2"
    local go_out rs_out
    go_out="$(protoc -Iapi -I/usr/include \
        --plugin=protoc-gen-synurang-ffi="$GO_PLUGIN" \
        --synurang-ffi_out="$GO_OUT" \
        --synurang-ffi_opt="$opt" \
        core.proto 2>&1 || true)"
    rs_out="$(protoc -Iapi -I/usr/include \
        --plugin=protoc-gen-synurang-ffi="$RS_PLUGIN" \
        --synurang-ffi_out="$RS_OUT" \
        --synurang-ffi_opt="$opt" \
        core.proto 2>&1 || true)"
    if ! grep -q "$needle" <<<"$go_out"; then
        echo "Go did not reject '$opt' with '$needle': $go_out" >&2
        return 1
    fi
    if ! grep -q "$needle" <<<"$rs_out"; then
        echo "Rust did not reject '$opt' with '$needle': $rs_out" >&2
        return 1
    fi
}
check_reject 'bogus=x' 'no such flag -bogus'
check_reject 'lang=go,paths=bad' 'unknown path type "bad"'
check_reject 'lang=go,annotate_code=maybe' 'bad value for parameter "annotate_code"'
check_reject 'lang=go,module=example.com/x' 'generated file does not match prefix "example.com/x"'
check_reject 'lang=go,default_api_level=BAD' 'unknown API level "BAD" for parameter "default_api_level"'
check_reject 'lang=go,apilevelMcore.proto=BAD' 'unknown API level "BAD" for parameter "apilevelMcore.proto"'
check_reject 'lang=go,paths=' 'unknown path type ""'
check_reject 'lang=go,default_api_level=' 'unknown API level "" for parameter "default_api_level"'
check_reject 'lang=go,apilevelMcore.proto=' 'unknown API level "" for parameter "apilevelMcore.proto"'
echo "Flag-validation parity: OK"

echo "Binary sizes:"
stat -c '  go   %n %s bytes' "$GO_PLUGIN"
stat -c '  rust %n %s bytes' "$RS_PLUGIN"

# GNU time (/usr/bin/time) supports `-f`; macOS's BSD time does not. Probe
# instead of assuming the path means GNU time is installed.
if /usr/bin/time -f "" true >/dev/null 2>&1; then
    echo "Benchmarking protoc plugin runs (BENCH_RUNS=$BENCH_RUNS)..."
    bench_one() {
        local label="$1"
        local plugin="$2"
        local out
        out="$(mktemp -d /tmp/synurang-ffi-bench.XXXXXX)"
        local rc=0
        /usr/bin/time -f "  $label run elapsed_s=%e cpu=%P rss_kb=%M" \
            protoc -Iapi -I/usr/include \
                --plugin=protoc-gen-synurang-ffi="$plugin" \
                --synurang-ffi_out="$out" \
                --synurang-ffi_opt=lang=cpp,mode=lite \
                core.proto cache.proto >/dev/null || rc=$?
        rm -rf "$out"
        return "$rc"
    }
    for _ in $(seq 1 "$BENCH_RUNS"); do
        bench_one go "$GO_PLUGIN"
        bench_one rust "$RS_PLUGIN"
    done
else
    echo "Skipping benchmark: GNU /usr/bin/time -f not available."
fi

echo "Rust generator parity test passed."

#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
if (( $# == 0 )); then
    echo "Usage: test_go.sh MODULE..." >&2
    exit 2
fi
mkdir -p "$ROOT/test/call/pb"
protoc -I"$ROOT/test/call" --go_out="paths=source_relative:$ROOT/test/call/pb" \
    --go-grpc_out="paths=source_relative:$ROOT/test/call/pb" "$ROOT/test/call/conformance.proto"
export SYNURANG_TEST_MODULES
SYNURANG_TEST_MODULES=$(IFS=:; echo "$*")
EARLY_BUILD=$(mktemp -d)
trap 'rm -rf "$EARLY_BUILD"' EXIT
cc -std=c11 -shared -fPIC -pthread -I"$ROOT/include" "$ROOT/test/call/early_module.c" \
    "$ROOT/src/call.c" "$ROOT/src/c_runtime.c" -o "$EARLY_BUILD/early_go.so"
export SYNURANG_TEST_EARLY_MODULE="$EARLY_BUILD/early_go.so"
cc -std=c11 -shared -fPIC -pthread -I"$ROOT/include" "$ROOT/test/call/release_module.c" \
    "$ROOT/src/call.c" "$ROOT/src/c_runtime.c" -o "$EARLY_BUILD/release.so"
export SYNURANG_TEST_RELEASE_MODULE="$EARLY_BUILD/release.so"
cd "$ROOT"
go test -race -tags synurang_call_conformance ./test/call/go_host -count=1 -timeout=90s -v

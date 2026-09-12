#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="${1:-$ROOT/build/shared_memory}"
bash "$ROOT/example/shared_memory/build.sh" "$OUT"
OUT="$(cd "$OUT" && pwd)"
export PYTHONPATH="$ROOT/python:$OUT${PYTHONPATH:+:$PYTHONPATH}"
python3 "$ROOT/example/shared_memory/caller.py" "$OUT"
"$OUT/cpp_caller" "$OUT/backend.so"
python3 "$ROOT/test/call/shared_memory_edges.py" "$OUT"

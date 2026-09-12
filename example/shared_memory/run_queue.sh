#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="${1:-$ROOT/build/shared_memory}"
bash "$ROOT/example/shared_memory/build.sh" "$OUT"
OUT="$(cd "$OUT" && pwd)"
export PYTHONPATH="$ROOT/python:$OUT${PYTHONPATH:+:$PYTHONPATH}"
for scenario in tracking inspection; do
  for policy in fifo latest batch; do
    python3 "$ROOT/example/shared_memory/queue_caller.py" "$OUT" \
      --scenario "$scenario" --policy "$policy" --frames 42 --output "$OUT/queue-results"
    "$OUT/cpp_queue_caller" "$OUT" \
      --scenario "$scenario" --policy "$policy" --frames 42 --output "$OUT/queue-results"
  done
done
python3 "$ROOT/test/call/frame_queue_edges.py" "$OUT"
python3 "$ROOT/example/shared_memory/queue_report.py" "$OUT/queue-results"

#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/synurang-python-runtime.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

case "$(uname -s)" in
    Darwin)
        cc -std=c11 -dynamiclib \
            "$ROOT_DIR/test/python/mock_plugin.c" \
            -o "$TMP_DIR/libmock_synurang.dylib"
        PLUGIN="$TMP_DIR/libmock_synurang.dylib"
        ;;
    Linux)
        cc -std=c11 -shared -fPIC \
            "$ROOT_DIR/test/python/mock_plugin.c" \
            -o "$TMP_DIR/libmock_synurang.so"
        PLUGIN="$TMP_DIR/libmock_synurang.so"
        ;;
    *)
        echo "Python runtime test currently supports Linux and macOS" >&2
        exit 1
        ;;
esac

PYTHONPATH="$ROOT_DIR/python${PYTHONPATH:+:$PYTHONPATH}" \
PYTHONDONTWRITEBYTECODE=1 \
SYNURANG_PYTHON_TEST_PLUGIN="$PLUGIN" \
python3 -m unittest discover -s "$ROOT_DIR/test/python" -p 'test_*.py' -v

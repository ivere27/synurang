#!/bin/bash
set -euo pipefail

# The same generated @grpc/grpc-js client against the Go example over the
# network and over Synurang FFI (bin/libplugin_go.so through koffi).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."
BIN_DIR="$ROOT_DIR/bin"
PLUGIN="$BIN_DIR/protoc-gen-synurang-ffi"
OUT_DIR="$ROOT_DIR/test/generated_typescript_grpc"

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

cd "$ROOT_DIR"
echo "Building code generator, Go plugin and TCP process child..."
make build_plugin build_plugin_go build_process_tcp_child

echo "Generating TypeScript grpc-js clients from example.proto..."
protoc -Iexample/api -Iapi -I/usr/include \
    --plugin=protoc-gen-synurang-ffi="$PLUGIN" \
    --synurang-ffi_out="$OUT_DIR" \
    --synurang-ffi_opt=lang=typescript,grpc=js \
    example.proto

cat > "$OUT_DIR/package.json" <<'EOF'
{
  "private": true,
  "type": "module",
  "dependencies": {
    "@grpc/grpc-js": "1.14.4",
    "koffi": "3.2.1"
  },
  "devDependencies": {
    "@types/node": "^24.0.0",
    "typescript": "^5.6.0"
  }
}
EOF
npm install --prefix "$OUT_DIR" --no-audit --no-fund --silent

cp "$SCRIPT_DIR/typescript/grpc_plugin_e2e.ts" "$OUT_DIR/grpc_plugin_e2e.ts"
"$OUT_DIR/node_modules/.bin/tsc" --target ES2020 \
    --module NodeNext \
    --moduleResolution NodeNext \
    --strict \
    --outDir "$OUT_DIR/dist" \
    "$OUT_DIR/grpc_plugin_e2e.ts"
node "$OUT_DIR/dist/grpc_plugin_e2e.js" "$BIN_DIR/libplugin_go.so" "$BIN_DIR/process_child_tcp"

echo "TypeScript grpc-js plugin test passed!"
rm -rf "$OUT_DIR"

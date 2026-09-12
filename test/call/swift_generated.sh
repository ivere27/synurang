#!/usr/bin/env bash
set -euo pipefail
# Run generated typed clients and native conformance with a real Swift compiler.
# Usage: SWIFT=/path/to/swift bash test/call/swift_generated.sh BUILD_DIR [MODULE...]
task_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
task_build="$(realpath "${1:?Provide the native conformance build directory}")"
shift
task_swift="${SWIFT:-swift}"
task_generator="${SYNURANG_GENERATOR:-$task_root/target/debug/protoc-gen-synurang-ffi}"
task_work="$(mktemp -d /tmp/synurang-swift-generated-XXXXXX)"
trap 'rm -rf "$task_work"' EXIT
mkdir -p "$task_work/Sources"
protoc -I "$task_root/test/call" \
  --plugin="protoc-gen-synurang-ffi=$task_generator" \
  --synurang-ffi_out="lang=swift,mode=client:$task_work/Sources" \
  "$task_root/test/call/conformance.proto"
cp "$task_root/test/call/swift_host/Sources/Conformance.swift" "$task_work/Sources/Conformance.swift"
cat > "$task_work/Package.swift" <<'SWIFT_PACKAGE'
// swift-tools-version:5.9
import PackageDescription
import Foundation
let package = Package(
    name: "GeneratedConformance",
    platforms: [.macOS(.v10_15)],
    dependencies: [.package(name: "Synurang", path: ProcessInfo.processInfo.environment["SYNURANG_SWIFT_PACKAGE"]!)],
    targets: [.executableTarget(name: "GeneratedConformance", dependencies: [.product(name: "SynurangLite", package: "Synurang")],
        path: "Sources", swiftSettings: [.define("GENERATED_CONFORMANCE")])]
)
SWIFT_PACKAGE
export SYNURANG_SWIFT_PACKAGE="$task_root/swift"
export LD_LIBRARY_PATH="$task_build${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
if [ "$#" = 0 ]; then
  set -- "$task_build/c_module.so" "$task_build/cpp_module.so" "$task_build/rust_module.so"
fi
"${CC:-cc}" -std=c11 -I "$task_root/include" -c "$task_root/src/module_host.c" -o "$task_work/module_host.o"
"$task_swift" run --package-path "$task_work" \
  -Xlinker --whole-archive -Xlinker "$task_build/c_module.a" -Xlinker --no-whole-archive \
  -Xlinker "$task_work/module_host.o" -Xlinker --export-dynamic -Xlinker -ldl \
  GeneratedConformance "$@" --linked

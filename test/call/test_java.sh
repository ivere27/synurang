#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BUILD=${1:?Usage: test_java.sh BUILD_DIR MODULE...}
shift
GENERATOR=${SYNURANG_GENERATOR:-$ROOT/target/debug/protoc-gen-synurang-ffi}
cc -std=c11 -shared -fPIC -pthread -I"$ROOT/include" "$ROOT/test/call/release_module.c" \
    "$ROOT/src/call.c" "$ROOT/src/c_runtime.c" -o "$BUILD/release.so"
export SYNURANG_TEST_RELEASE_MODULE="$BUILD/release.so"
mkdir -p "$BUILD/java-generated" "$BUILD/java-classes" "$BUILD/java-deps"
cmake -S "$ROOT/java/core/src/main/c" -B "$BUILD/java-jni" -DCMAKE_BUILD_TYPE=Debug
cmake --build "$BUILD/java-jni" -j2
fetch() {
    local artifact=$1 destination=$2
    if [[ ! -s "$destination" ]]; then
        curl -fsSL "https://repo.maven.apache.org/maven2/$artifact" -o "$destination.tmp"
        mv "$destination.tmp" "$destination"
    fi
}
fetch io/grpc/grpc-api/1.60.0/grpc-api-1.60.0.jar "$BUILD/java-deps/grpc-api.jar"
fetch com/google/guava/guava/32.0.1-android/guava-32.0.1-android.jar "$BUILD/java-deps/guava.jar"
fetch com/google/protobuf/protobuf-java/3.25.1/protobuf-java-3.25.1.jar "$BUILD/java-deps/protobuf-java.jar"
protoc -I"$ROOT/test/call" --plugin="protoc-gen-synurang-ffi=$GENERATOR" \
    --synurang-ffi_out="lang=java,mode=client:$BUILD/java-generated" \
    --java_out="$BUILD/java-generated" "$ROOT/test/call/conformance.proto"
mapfile -t sources < <(rg --files "$ROOT/java/core/src/main/java" "$ROOT/java/grpc/src/main/java" \
    "$ROOT/test/call/java" "$BUILD/java-generated" -g '*.java')
javac --release 8 -cp "$BUILD/java-deps/*" -d "$BUILD/java-classes" "${sources[@]}"
for test in ModuleConformance GrpcModuleConformance GeneratedModuleConformance; do
    java -Dsynurang.library.path="$BUILD/java-jni/libsynurang_jni.so" \
        -cp "$BUILD/java-classes:$BUILD/java-deps/*" "$test" "$@"
done
cc -std=c11 -shared -fPIC -pthread -I"$ROOT/include" "$ROOT/test/call/early_module.c" \
    "$ROOT/src/call.c" "$ROOT/src/c_runtime.c" -o "$BUILD/early_java.so"
java -Dsynurang.library.path="$BUILD/java-jni/libsynurang_jni.so" \
    -cp "$BUILD/java-classes:$BUILD/java-deps/*" EarlyModuleConformance "$BUILD/early_java.so"

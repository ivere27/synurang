#!/usr/bin/env bash
set -euo pipefail

# Desktop JAR packaging script — runs inside Docker (like build_android_aar_inside.sh).
#
# Builds JNI natives for linux-{x86_64,x86,armv7,aarch64}, windows-{x86_64,x86}, macos-{x86_64,aarch64},
# then packages:
#   synurang-desktop-{VERSION}.jar      = core classes + embedded JNI natives
#   synurang-desktop-grpc-{VERSION}.jar  = grpc classes only
#
# Usage (inside Docker): VERSION=0.5.10 /opt/synurang/build_desktop_jar.sh

REPO_ROOT="${REPO_ROOT:-$(pwd)}"
VERSION="${VERSION:-0.5.10}"
GROUP_ID="${GROUP_ID:-io.github.ivere27}"
ARTIFACT_ID_CORE="${ARTIFACT_ID_CORE:-synurang-desktop}"
ARTIFACT_ID_GRPC="${ARTIFACT_ID_GRPC:-synurang-desktop-grpc}"
DIST_DIR="${DIST_DIR:-${REPO_ROOT}/dist/maven}"
JOBS="${JOBS:-$(nproc)}"

if [[ ! -d "${REPO_ROOT}/java/core/src/main/java" ]]; then
  echo "Error: java sources not found under ${REPO_ROOT}/java/core/src/main/java" >&2
  exit 1
fi

JNI_SRC="${REPO_ROOT}/java/core/src/main/c"

WORK_DIR="$(mktemp -d /tmp/synurang-desktop-XXXXXX)"
NATIVES_DIR="${WORK_DIR}/natives"
cleanup() {
  rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

# ── Build JNI natives ────────────────────────────────────────────────────────

# linux-x86_64 (native)
echo "Building JNI: linux-x86_64..."
BUILD_LINUX_X64="${WORK_DIR}/build-linux-x86_64"
cmake -S "${JNI_SRC}" -B "${BUILD_LINUX_X64}" -DCMAKE_BUILD_TYPE=Release
cmake --build "${BUILD_LINUX_X64}" --parallel "${JOBS}"
mkdir -p "${NATIVES_DIR}/linux-x86_64"
cp "${BUILD_LINUX_X64}/libsynurang_jni.so" "${NATIVES_DIR}/linux-x86_64/"

# linux-x86 (cross-compile)
if command -v i686-linux-gnu-gcc >/dev/null 2>&1; then
  echo "Building JNI: linux-x86..."
  BUILD_LINUX_X86="${WORK_DIR}/build-linux-x86"
  cmake -S "${JNI_SRC}" -B "${BUILD_LINUX_X86}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_NAME=Linux \
    -DCMAKE_SYSTEM_PROCESSOR=i686 \
    -DCMAKE_C_COMPILER=i686-linux-gnu-gcc
  cmake --build "${BUILD_LINUX_X86}" --parallel "${JOBS}"
  mkdir -p "${NATIVES_DIR}/linux-x86"
  cp "${BUILD_LINUX_X86}/libsynurang_jni.so" "${NATIVES_DIR}/linux-x86/"
else
  echo "SKIP: linux-x86 (i686-linux-gnu-gcc not found)"
fi

# linux-armv7 (cross-compile)
if command -v arm-linux-gnueabihf-gcc >/dev/null 2>&1; then
  echo "Building JNI: linux-armv7..."
  BUILD_LINUX_ARMV7="${WORK_DIR}/build-linux-armv7"
  cmake -S "${JNI_SRC}" -B "${BUILD_LINUX_ARMV7}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_NAME=Linux \
    -DCMAKE_SYSTEM_PROCESSOR=armv7 \
    -DCMAKE_C_COMPILER=arm-linux-gnueabihf-gcc
  cmake --build "${BUILD_LINUX_ARMV7}" --parallel "${JOBS}"
  mkdir -p "${NATIVES_DIR}/linux-armv7"
  cp "${BUILD_LINUX_ARMV7}/libsynurang_jni.so" "${NATIVES_DIR}/linux-armv7/"
else
  echo "SKIP: linux-armv7 (arm-linux-gnueabihf-gcc not found)"
fi

# linux-aarch64 (cross-compile)
if command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
  echo "Building JNI: linux-aarch64..."
  BUILD_LINUX_ARM64="${WORK_DIR}/build-linux-aarch64"
  cmake -S "${JNI_SRC}" -B "${BUILD_LINUX_ARM64}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_NAME=Linux \
    -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
    -DCMAKE_C_COMPILER=aarch64-linux-gnu-gcc
  cmake --build "${BUILD_LINUX_ARM64}" --parallel "${JOBS}"
  mkdir -p "${NATIVES_DIR}/linux-aarch64"
  cp "${BUILD_LINUX_ARM64}/libsynurang_jni.so" "${NATIVES_DIR}/linux-aarch64/"
else
  echo "SKIP: linux-aarch64 (aarch64-linux-gnu-gcc not found)"
fi

# windows-x86_64 (MinGW cross-compile)
if command -v x86_64-w64-mingw32-gcc >/dev/null 2>&1; then
  echo "Building JNI: windows-x86_64..."
  BUILD_WIN64="${WORK_DIR}/build-windows-x86_64"
  cmake -S "${JNI_SRC}" -B "${BUILD_WIN64}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_NAME=Windows \
    -DCMAKE_C_COMPILER=x86_64-w64-mingw32-gcc \
    -DSYNURANG_JNI_INCLUDE="${JNI_SRC}/win32;${JAVA_HOME}/include"
  cmake --build "${BUILD_WIN64}" --parallel "${JOBS}"
  mkdir -p "${NATIVES_DIR}/windows-x86_64"
  cp "${BUILD_WIN64}/libsynurang_jni.dll" "${NATIVES_DIR}/windows-x86_64/synurang_jni.dll"
else
  echo "SKIP: windows-x86_64 (x86_64-w64-mingw32-gcc not found)"
fi

# windows-x86 (MinGW cross-compile)
if command -v i686-w64-mingw32-gcc >/dev/null 2>&1; then
  echo "Building JNI: windows-x86..."
  BUILD_WIN32="${WORK_DIR}/build-windows-x86"
  cmake -S "${JNI_SRC}" -B "${BUILD_WIN32}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_NAME=Windows \
    -DCMAKE_C_COMPILER=i686-w64-mingw32-gcc \
    -DSYNURANG_JNI_INCLUDE="${JNI_SRC}/win32;${JAVA_HOME}/include"
  cmake --build "${BUILD_WIN32}" --parallel "${JOBS}"
  mkdir -p "${NATIVES_DIR}/windows-x86"
  cp "${BUILD_WIN32}/libsynurang_jni.dll" "${NATIVES_DIR}/windows-x86/synurang_jni.dll"
else
  echo "SKIP: windows-x86 (i686-w64-mingw32-gcc not found)"
fi

# macos-x86_64 (zig cross-compile)
if command -v zig >/dev/null 2>&1; then
  echo "Building JNI: macos-x86_64..."
  mkdir -p "${NATIVES_DIR}/macos-x86_64"
  zig cc -target x86_64-macos -shared \
    -I"${JAVA_HOME}/include" -I"${JNI_SRC}/darwin" \
    -o "${NATIVES_DIR}/macos-x86_64/libsynurang_jni.dylib" \
    "${JNI_SRC}/synurang_jni.c"

  echo "Building JNI: macos-aarch64..."
  mkdir -p "${NATIVES_DIR}/macos-aarch64"
  zig cc -target aarch64-macos -shared \
    -I"${JAVA_HOME}/include" -I"${JNI_SRC}/darwin" \
    -o "${NATIVES_DIR}/macos-aarch64/libsynurang_jni.dylib" \
    "${JNI_SRC}/synurang_jni.c"
else
  echo "SKIP: macos-x86_64, macos-aarch64 (zig not found)"
fi

# ── Build Java classes via Gradle ────────────────────────────────────────────
GRADLE_REPO_INIT="${WORK_DIR}/gradle-repositories.init.gradle"
cat > "${GRADLE_REPO_INIT}" <<'GRADLE'
allprojects {
  repositories {
    mavenCentral()
    google()
  }
}
GRADLE

echo "Building Java host jars (core + grpc)..."
gradle -p "${REPO_ROOT}/java" --no-daemon -I "${GRADLE_REPO_INIT}" clean :core:jar :core:sourcesJar :core:javadocJar :grpc:jar :grpc:sourcesJar :grpc:javadocJar

CORE_JAR="$(find "${REPO_ROOT}/java/core/build/libs" -maxdepth 1 -type f -name '*.jar' ! -name '*-sources.jar' ! -name '*-javadoc.jar' | head -n 1)"
CORE_SOURCES_JAR="$(find "${REPO_ROOT}/java/core/build/libs" -maxdepth 1 -type f -name '*-sources.jar' | head -n 1)"
CORE_JAVADOC_JAR="$(find "${REPO_ROOT}/java/core/build/libs" -maxdepth 1 -type f -name '*-javadoc.jar' | head -n 1)"
GRPC_JAR="$(find "${REPO_ROOT}/java/grpc/build/libs" -maxdepth 1 -type f -name '*.jar' ! -name '*-sources.jar' ! -name '*-javadoc.jar' | head -n 1)"
GRPC_SOURCES_JAR="$(find "${REPO_ROOT}/java/grpc/build/libs" -maxdepth 1 -type f -name '*-sources.jar' | head -n 1)"
GRPC_JAVADOC_JAR="$(find "${REPO_ROOT}/java/grpc/build/libs" -maxdepth 1 -type f -name '*-javadoc.jar' | head -n 1)"
if [[ -z "${CORE_JAR}" || ! -f "${CORE_JAR}" ]]; then
  echo "Error: core jar build failed." >&2
  exit 1
fi
if [[ -z "${GRPC_JAR}" || ! -f "${GRPC_JAR}" ]]; then
  echo "Error: grpc jar build failed." >&2
  exit 1
fi

# ── Core Desktop JAR (classes + native/) ─────────────────────────────────────
CORE_DIR="${WORK_DIR}/desktop-core"
mkdir -p "${CORE_DIR}"

# Extract core classes
(cd "${CORE_DIR}" && jar xf "${CORE_JAR}")

# Embed native libraries
NATIVE_COUNT=0
for PLATFORM_DIR in "${NATIVES_DIR}"/*/; do
  [[ -d "${PLATFORM_DIR}" ]] || continue
  PLATFORM="$(basename "${PLATFORM_DIR}")"
  mkdir -p "${CORE_DIR}/native/${PLATFORM}"
  for LIB in "${PLATFORM_DIR}"/*; do
    [[ -f "${LIB}" ]] || continue
    cp "${LIB}" "${CORE_DIR}/native/${PLATFORM}/"
    NATIVE_COUNT=$((NATIVE_COUNT + 1))
  done
done

if [[ "${NATIVE_COUNT}" -eq 0 ]]; then
  echo "Error: no native libraries were built." >&2
  exit 1
fi

mkdir -p "${DIST_DIR}"
CORE_JAR_OUT="${DIST_DIR}/${ARTIFACT_ID_CORE}-${VERSION}.jar"
(cd "${CORE_DIR}" && jar cf "${CORE_JAR_OUT}" .)
echo "Built: ${CORE_JAR_OUT} (${NATIVE_COUNT} native libs embedded)"

# Sources & Javadoc for core
CORE_SOURCES_OUT="${DIST_DIR}/${ARTIFACT_ID_CORE}-${VERSION}-sources.jar"
CORE_JAVADOC_OUT="${DIST_DIR}/${ARTIFACT_ID_CORE}-${VERSION}-javadoc.jar"
if [[ -n "${CORE_SOURCES_JAR}" && -f "${CORE_SOURCES_JAR}" ]]; then
  cp "${CORE_SOURCES_JAR}" "${CORE_SOURCES_OUT}"
fi
if [[ -n "${CORE_JAVADOC_JAR}" && -f "${CORE_JAVADOC_JAR}" ]]; then
  cp "${CORE_JAVADOC_JAR}" "${CORE_JAVADOC_OUT}"
fi

# Core POM (no dependencies)
CORE_POM_OUT="${DIST_DIR}/${ARTIFACT_ID_CORE}-${VERSION}.pom"
cat > "${CORE_POM_OUT}" <<POM
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 http://maven.apache.org/xsd/maven-4.0.0.xsd">
  <modelVersion>4.0.0</modelVersion>
  <groupId>${GROUP_ID}</groupId>
  <artifactId>${ARTIFACT_ID_CORE}</artifactId>
  <version>${VERSION}</version>
  <packaging>jar</packaging>
  <name>${ARTIFACT_ID_CORE}</name>
  <description>Synurang JNI host runtime for desktop (Linux, macOS, Windows)</description>
  <url>https://github.com/ivere27/synurang</url>
  <licenses>
    <license>
      <name>MIT License</name>
      <url>https://opensource.org/licenses/MIT</url>
    </license>
  </licenses>
  <developers>
    <developer>
      <id>ivere27</id>
      <name>ivere27</name>
      <url>https://github.com/ivere27</url>
    </developer>
  </developers>
  <scm>
    <connection>scm:git:git://github.com/ivere27/synurang.git</connection>
    <developerConnection>scm:git:ssh://github.com:ivere27/synurang.git</developerConnection>
    <url>https://github.com/ivere27/synurang</url>
  </scm>
</project>
POM

# ── gRPC Desktop JAR (classes only) ─────────────────────────────────────────
GRPC_JAR_OUT="${DIST_DIR}/${ARTIFACT_ID_GRPC}-${VERSION}.jar"
cp "${GRPC_JAR}" "${GRPC_JAR_OUT}"
echo "Built: ${GRPC_JAR_OUT}"

# Sources & Javadoc for grpc
GRPC_SOURCES_OUT="${DIST_DIR}/${ARTIFACT_ID_GRPC}-${VERSION}-sources.jar"
GRPC_JAVADOC_OUT="${DIST_DIR}/${ARTIFACT_ID_GRPC}-${VERSION}-javadoc.jar"
if [[ -n "${GRPC_SOURCES_JAR}" && -f "${GRPC_SOURCES_JAR}" ]]; then
  cp "${GRPC_SOURCES_JAR}" "${GRPC_SOURCES_OUT}"
fi
if [[ -n "${GRPC_JAVADOC_JAR}" && -f "${GRPC_JAVADOC_JAR}" ]]; then
  cp "${GRPC_JAVADOC_JAR}" "${GRPC_JAVADOC_OUT}"
fi

# gRPC POM (depends on core + grpc-api provided)
GRPC_POM_OUT="${DIST_DIR}/${ARTIFACT_ID_GRPC}-${VERSION}.pom"
cat > "${GRPC_POM_OUT}" <<POM
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 http://maven.apache.org/xsd/maven-4.0.0.xsd">
  <modelVersion>4.0.0</modelVersion>
  <groupId>${GROUP_ID}</groupId>
  <artifactId>${ARTIFACT_ID_GRPC}</artifactId>
  <version>${VERSION}</version>
  <packaging>jar</packaging>
  <name>${ARTIFACT_ID_GRPC}</name>
  <description>Synurang gRPC channel adapter for desktop Java</description>
  <url>https://github.com/ivere27/synurang</url>
  <licenses>
    <license>
      <name>MIT License</name>
      <url>https://opensource.org/licenses/MIT</url>
    </license>
  </licenses>
  <developers>
    <developer>
      <id>ivere27</id>
      <name>ivere27</name>
      <url>https://github.com/ivere27</url>
    </developer>
  </developers>
  <scm>
    <connection>scm:git:git://github.com/ivere27/synurang.git</connection>
    <developerConnection>scm:git:ssh://github.com:ivere27/synurang.git</developerConnection>
    <url>https://github.com/ivere27/synurang</url>
  </scm>
  <dependencies>
    <dependency>
      <groupId>${GROUP_ID}</groupId>
      <artifactId>${ARTIFACT_ID_CORE}</artifactId>
      <version>${VERSION}</version>
    </dependency>
    <dependency>
      <groupId>io.grpc</groupId>
      <artifactId>grpc-api</artifactId>
      <version>1.60.0</version>
      <scope>provided</scope>
    </dependency>
  </dependencies>
</project>
POM

echo ""
echo "Built desktop JAR artifacts:"
echo "  ${CORE_JAR_OUT}"
echo "  ${CORE_POM_OUT}"
echo "  ${GRPC_JAR_OUT}"
echo "  ${GRPC_POM_OUT}"

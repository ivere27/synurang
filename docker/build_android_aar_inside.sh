#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(pwd)}"
VERSION="${VERSION:-0.5.0}"
GROUP_ID="${GROUP_ID:-io.github.ivere27}"
ARTIFACT_ID_CORE="${ARTIFACT_ID_CORE:-synurang-android}"
ARTIFACT_ID_GRPC="${ARTIFACT_ID_GRPC:-synurang-android-grpc}"
ANDROID_API="${ANDROID_API:-21}"
ANDROID_ABIS="${ANDROID_ABIS:-arm64-v8a,armeabi-v7a}"
DIST_DIR="${DIST_DIR:-${REPO_ROOT}/dist/maven}"
JOBS="${JOBS:-$(nproc)}"

export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-/opt/android-sdk}"
export ANDROID_HOME="${ANDROID_HOME:-${ANDROID_SDK_ROOT}}"
export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-${ANDROID_SDK_ROOT}/ndk/28.2.13676358}"

TOOLCHAIN_FILE="${ANDROID_NDK_HOME}/build/cmake/android.toolchain.cmake"
if [[ ! -f "${TOOLCHAIN_FILE}" ]]; then
  echo "Error: Android NDK toolchain not found: ${TOOLCHAIN_FILE}" >&2
  exit 1
fi

if [[ ! -d "${REPO_ROOT}/java/core/src/main/java" ]]; then
  echo "Error: java sources not found under ${REPO_ROOT}/java/core/src/main/java" >&2
  exit 1
fi

IFS=',' read -r -a ABI_LIST <<< "${ANDROID_ABIS}"

WORK_DIR="$(mktemp -d /tmp/synurang-aar-XXXXXX)"
GRADLE_REPO_INIT="${WORK_DIR}/gradle-repositories.init.gradle"
cleanup() {
  rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

cat > "${GRADLE_REPO_INIT}" <<'GRADLE'
allprojects {
  repositories {
    mavenCentral()
    google()
  }
}
GRADLE

echo "Gradle version:"
gradle --version | sed -n '1,4p'

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

echo "Building JNI libs for ABIs: ${ANDROID_ABIS}"

# ── Core AAR (classes + JNI .so) ─────────────────────────────────────────────
CORE_AAR_DIR="${WORK_DIR}/aar-core"
mkdir -p "${CORE_AAR_DIR}/jni"

cat > "${CORE_AAR_DIR}/AndroidManifest.xml" <<'MANIFEST'
<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="io.github.ivere27.synurang" />
MANIFEST

cp "${CORE_JAR}" "${CORE_AAR_DIR}/classes.jar"
: > "${CORE_AAR_DIR}/R.txt"

if [[ -f "${REPO_ROOT}/java/core/src/main/resources/META-INF/proguard/synurang.pro" ]]; then
  cp "${REPO_ROOT}/java/core/src/main/resources/META-INF/proguard/synurang.pro" "${CORE_AAR_DIR}/proguard.txt"
fi

for ABI in "${ABI_LIST[@]}"; do
  ABI="${ABI//[[:space:]]/}"
  [[ -n "${ABI}" ]] || continue

  BUILD_DIR="${WORK_DIR}/build-${ABI}"
  cmake -S "${REPO_ROOT}/java/core/src/main/c" \
        -B "${BUILD_DIR}" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_TOOLCHAIN_FILE="${TOOLCHAIN_FILE}" \
        -DANDROID_ABI="${ABI}" \
        -DANDROID_PLATFORM="android-${ANDROID_API}"
  cmake --build "${BUILD_DIR}" --parallel "${JOBS}"

  mkdir -p "${CORE_AAR_DIR}/jni/${ABI}"
  cp "${BUILD_DIR}/libsynurang_jni.so" "${CORE_AAR_DIR}/jni/${ABI}/"
done

mkdir -p "${DIST_DIR}"
CORE_AAR_OUT="${DIST_DIR}/${ARTIFACT_ID_CORE}-${VERSION}.aar"
(
  cd "${CORE_AAR_DIR}"
  zip -qr "${CORE_AAR_OUT}" .
)

CORE_SOURCES_OUT="${DIST_DIR}/${ARTIFACT_ID_CORE}-${VERSION}-sources.jar"
CORE_JAVADOC_OUT="${DIST_DIR}/${ARTIFACT_ID_CORE}-${VERSION}-javadoc.jar"
if [[ -n "${CORE_SOURCES_JAR}" && -f "${CORE_SOURCES_JAR}" ]]; then
  cp "${CORE_SOURCES_JAR}" "${CORE_SOURCES_OUT}"
fi
if [[ -n "${CORE_JAVADOC_JAR}" && -f "${CORE_JAVADOC_JAR}" ]]; then
  cp "${CORE_JAVADOC_JAR}" "${CORE_JAVADOC_OUT}"
fi

CORE_POM_OUT="${DIST_DIR}/${ARTIFACT_ID_CORE}-${VERSION}.pom"
cat > "${CORE_POM_OUT}" <<POM
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 http://maven.apache.org/xsd/maven-4.0.0.xsd">
  <modelVersion>4.0.0</modelVersion>
  <groupId>${GROUP_ID}</groupId>
  <artifactId>${ARTIFACT_ID_CORE}</artifactId>
  <version>${VERSION}</version>
  <packaging>aar</packaging>
  <name>${ARTIFACT_ID_CORE}</name>
  <description>Synurang JNI host runtime for Android</description>
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

# ── gRPC AAR (classes only, no JNI) ─────────────────────────────────────────
GRPC_AAR_DIR="${WORK_DIR}/aar-grpc"
mkdir -p "${GRPC_AAR_DIR}"

cat > "${GRPC_AAR_DIR}/AndroidManifest.xml" <<'MANIFEST'
<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="io.github.ivere27.synurang.grpc" />
MANIFEST

cp "${GRPC_JAR}" "${GRPC_AAR_DIR}/classes.jar"
: > "${GRPC_AAR_DIR}/R.txt"

if [[ -f "${REPO_ROOT}/java/grpc/src/main/resources/META-INF/proguard/synurang-grpc.pro" ]]; then
  cp "${REPO_ROOT}/java/grpc/src/main/resources/META-INF/proguard/synurang-grpc.pro" "${GRPC_AAR_DIR}/proguard.txt"
fi

GRPC_AAR_OUT="${DIST_DIR}/${ARTIFACT_ID_GRPC}-${VERSION}.aar"
(
  cd "${GRPC_AAR_DIR}"
  zip -qr "${GRPC_AAR_OUT}" .
)

GRPC_SOURCES_OUT="${DIST_DIR}/${ARTIFACT_ID_GRPC}-${VERSION}-sources.jar"
GRPC_JAVADOC_OUT="${DIST_DIR}/${ARTIFACT_ID_GRPC}-${VERSION}-javadoc.jar"
if [[ -n "${GRPC_SOURCES_JAR}" && -f "${GRPC_SOURCES_JAR}" ]]; then
  cp "${GRPC_SOURCES_JAR}" "${GRPC_SOURCES_OUT}"
fi
if [[ -n "${GRPC_JAVADOC_JAR}" && -f "${GRPC_JAVADOC_JAR}" ]]; then
  cp "${GRPC_JAVADOC_JAR}" "${GRPC_JAVADOC_OUT}"
fi

GRPC_POM_OUT="${DIST_DIR}/${ARTIFACT_ID_GRPC}-${VERSION}.pom"
cat > "${GRPC_POM_OUT}" <<POM
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 http://maven.apache.org/xsd/maven-4.0.0.xsd">
  <modelVersion>4.0.0</modelVersion>
  <groupId>${GROUP_ID}</groupId>
  <artifactId>${ARTIFACT_ID_GRPC}</artifactId>
  <version>${VERSION}</version>
  <packaging>aar</packaging>
  <name>${ARTIFACT_ID_GRPC}</name>
  <description>Synurang gRPC channel adapter for Android</description>
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

echo "Built artifacts:"
echo "  ${CORE_AAR_OUT}"
echo "  ${CORE_POM_OUT}"
echo "  ${CORE_SOURCES_OUT}"
echo "  ${CORE_JAVADOC_OUT}"
echo "  ${GRPC_AAR_OUT}"
echo "  ${GRPC_POM_OUT}"
echo "  ${GRPC_SOURCES_OUT}"
echo "  ${GRPC_JAVADOC_OUT}"

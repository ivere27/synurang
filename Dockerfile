FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    build-essential \
    ca-certificates \
    cmake \
    curl \
    file \
    git \
    golang-go \
    openjdk-17-jdk \
    pkg-config \
    python3 \
    unzip \
    xz-utils \
    zip && \
    rm -rf /var/lib/apt/lists/*

ENV JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64

# Install modern Gradle (Ubuntu package is too old for current java/build.gradle DSL)
ENV GRADLE_VERSION=8.12
ENV GRADLE_HOME=/opt/gradle/gradle-${GRADLE_VERSION}
ENV PATH=${GRADLE_HOME}/bin:${PATH}
RUN mkdir -p /opt/gradle && \
    curl -fsSL "https://services.gradle.org/distributions/gradle-${GRADLE_VERSION}-bin.zip" -o /tmp/gradle.zip && \
    unzip -q /tmp/gradle.zip -d /opt/gradle && \
    rm -f /tmp/gradle.zip

ENV ANDROID_SDK_ROOT=/opt/android-sdk
ENV ANDROID_HOME=/opt/android-sdk
ENV PATH=${ANDROID_SDK_ROOT}/cmdline-tools/latest/bin:${ANDROID_SDK_ROOT}/platform-tools:${PATH}

RUN mkdir -p ${ANDROID_SDK_ROOT}/cmdline-tools && \
    curl -fsSL https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip -o /tmp/cmdline-tools.zip && \
    unzip -q /tmp/cmdline-tools.zip -d ${ANDROID_SDK_ROOT}/cmdline-tools && \
    mv ${ANDROID_SDK_ROOT}/cmdline-tools/cmdline-tools ${ANDROID_SDK_ROOT}/cmdline-tools/latest && \
    rm -f /tmp/cmdline-tools.zip

RUN yes | sdkmanager --licenses >/dev/null && \
    sdkmanager \
      "build-tools;34.0.0" \
      "cmake;3.22.1" \
      "ndk;28.2.13676358" \
      "platform-tools" \
      "platforms;android-34"

ENV ANDROID_NDK_HOME=/opt/android-sdk/ndk/28.2.13676358

COPY docker/build_android_aar_inside.sh /opt/synurang/build_android_aar.sh
RUN chmod +x /opt/synurang/build_android_aar.sh

WORKDIR /workspace/synurang
ENTRYPOINT ["/opt/synurang/build_android_aar.sh"]

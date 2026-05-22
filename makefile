# Synurang Makefile
# Flutter FFI + gRPC bridge for bidirectional Go/Dart communication
# Supports all 4 gRPC RPC types via FFI: Unary, Server Stream, Client Stream, Bidi Stream

# =============================================================================
# Variables
# =============================================================================
SERVER_PATH := cmd/server/main.go
COMMIT_HASH ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo "dev")
COMMIT_DATE ?= $(shell git log -1 --format='%cd' --date=format:'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "unknown")
BUILD_DATE := $(shell date +"%Y-%m-%dT%H:%M:%SZ")
LD_FLAGS := -X main.commitHash=$(COMMIT_HASH) -X main.commitDate=$(COMMIT_DATE) -X main.buildDate=$(BUILD_DATE)
CURRENT_DIR := $(shell pwd)
BRUTE_DURATION ?= 5m
BRUTE_PHASE ?= 45s
BRUTE_WORKERS ?= 16
BRUTE_MAX_G_DELTA ?= 64
BRUTE_MAX_FD_DELTA ?= 48
BRUTE_MAX_RSS_MB_DELTA ?= 256
BRUTE_GO_TEST_TIMEOUT ?= 40m
JAVA_BUILD_DIR ?= build/java
JAVA_CLASSES_DIR := $(JAVA_BUILD_DIR)/classes
JAVA_LIB_DIR := $(JAVA_BUILD_DIR)/libs
JAVA_JAR := $(JAVA_LIB_DIR)/java.jar

# Android NDK paths
NDK_HOME ?= $(HOME)/android-ndk-r23c

ANDROID_CC_ARM := $(NDK_HOME)/toolchains/llvm/prebuilt/linux-x86_64/bin/armv7a-linux-androideabi21-clang
ANDROID_CC_ARM64 := $(NDK_HOME)/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android21-clang
ANDROID_CC_X86_64 := $(NDK_HOME)/toolchains/llvm/prebuilt/linux-x86_64/bin/x86_64-linux-android21-clang

# Docker Android AAR packaging
AAR_DOCKER_IMAGE ?= synurang-android-aar:latest
AAR_VERSION ?= 0.6.0
AAR_BUILD_TYPE ?= Release
AAR_GROUP_ID ?= io.github.ivere27
AAR_ARTIFACT_ID_CORE ?= synurang-android
AAR_ARTIFACT_ID_GRPC ?= synurang-android-grpc
AAR_DEBUG_ARTIFACT_ID_CORE ?= $(AAR_ARTIFACT_ID_CORE)-debug
AAR_DEBUG_ARTIFACT_ID_GRPC ?= $(AAR_ARTIFACT_ID_GRPC)-debug
AAR_ANDROID_ABIS ?= arm64-v8a,armeabi-v7a
AAR_ANDROID_API ?= 21
DOCKER_GO_BUILD_CACHE_VOLUME ?= go-build-cache
DOCKER_GRADLE_BUILD_CACHE_VOLUME ?= gradle-build-cache
DOCKER_GO_BUILD_CACHE_DIR ?= /cache/go-build
DOCKER_GRADLE_CACHE_DIR ?= /cache/gradle
MAVEN_SETTINGS ?= $(CURRENT_DIR)/.maven-settings.xml
MAVEN_REPO_URL ?= https://central.sonatype.com/api/v1/publisher/upload

# Docker Desktop JAR packaging
DESKTOP_DOCKER_IMAGE ?= synurang-desktop-jar:latest
DESKTOP_VERSION ?= 0.6.0
DESKTOP_GROUP_ID ?= io.github.ivere27
DESKTOP_ARTIFACT_ID_CORE ?= synurang-desktop
DESKTOP_ARTIFACT_ID_GRPC ?= synurang-desktop-grpc

.PHONY: all proto shared_linux shared_android shared_plugin clean test test_go test_dart test_cpp test_rust test_csharp test_csharp_gen test_csharp_ffi test_swift test_swift_gen test_ffi_csharp test_plugin test_plugin_race run ffigen benchmark build_server build_plugin_host build_jni build_java build_csharp test_host_java test_host_csharp test_host_swift run_android_java build_process_go_android test_ffi test_ffi_go test_ffi_cpp test_ffi_rust test_ffi_java test_ffi_dart test_bruteforce_go test_bruteforce_process_go test_bruteforce_plugin test_bruteforce_plugin_go test_bruteforce_cpp test_bruteforce_plugin_cpp test_bruteforce_rust test_bruteforce_plugin_rust build_brute_all test_bruteforce_process_cpp test_bruteforce_process_rust test_bruteforce_dart test_bruteforce_hybrid_dart test_bruteforce_java test_bruteforce_hybrid_java test_bruteforce_csharp test_bruteforce_hybrid_csharp test_bruteforce_swift test_bruteforce_hybrid_swift build_host_csharp_brute build_process_tcp_child test_bruteforce download_grpc_jars test_native_wasm_gen test_typescript_gen build_plugin_rs test_ffi_rs_gen docker_android_aar_image docker_android_aar docker_android_aar_debug publish_maven docker_desktop_jar_image docker_desktop_jar

# =============================================================================
# Default Target
# =============================================================================
all: proto shared_linux
	@echo "Build complete. Run 'make test' to run tests."

# =============================================================================
# FFI Bindings Generation
# =============================================================================

ffigen:
	@echo "Regenerating FFI bindings from C header..."
	@# Automatically detect GCC include path on Linux to find stddef.h
	@if [ "$$(uname)" = "Linux" ]; then \
		GCC_INC=$$(find /usr/lib/gcc/x86_64-linux-gnu -name stddef.h | head -n 1 | xargs dirname); \
		if [ -n "$$GCC_INC" ]; then \
			echo "Detected GCC include path: $$GCC_INC"; \
			export C_INCLUDE_PATH="$$GCC_INC:$$C_INCLUDE_PATH"; \
		fi; \
		dart run ffigen --config ffigen.yaml; \
	else \
		dart run ffigen --config ffigen.yaml; \
	fi
	@echo "FFI bindings regenerated."

# =============================================================================
# Proto Generation
# =============================================================================

build_plugin:
	go build -o bin/protoc-gen-synurang-ffi ./cmd/protoc-gen-synurang-ffi

build_plugin_rs:
	cargo build --release --manifest-path cmd/protoc-gen-synurang-ffi-rs/Cargo.toml
	mkdir -p bin
	cp target/release/protoc-gen-synurang-ffi-rs bin/protoc-gen-synurang-ffi-rs

test_ffi_rs_gen:
	bash test/test_ffi_rs_gen.sh

proto: build_plugin
	@echo "Generating proto code..."
	mkdir -p pkg/api
	protoc -Iapi -I/usr/include \
		--go_out=./pkg/api --go_opt=paths=source_relative \
		--go-grpc_out=./pkg/api --go-grpc_opt=paths=source_relative \
		core.proto cache.proto activex.proto
	protoc -Iapi -I/usr/include \
		--dart_out=grpc:lib/src/generated \
		core.proto cache.proto
	protoc -Iapi -I/usr/include \
		--plugin=protoc-gen-synurang-ffi=./bin/protoc-gen-synurang-ffi \
		--synurang-ffi_out=./pkg/api --synurang-ffi_opt=lang=go \
		core.proto cache.proto
	protoc -Iapi -I/usr/include \
		--plugin=protoc-gen-synurang-ffi=./bin/protoc-gen-synurang-ffi \
		--synurang-ffi_out=./lib/src/generated --synurang-ffi_opt=lang=dart \
		core.proto cache.proto

	@echo "Generating example proto code..."
	mkdir -p example/pkg/api
	mkdir -p example/lib/src/generated
	protoc -Iexample/api -Iapi -I/usr/include \
		--go_out=./example/pkg/api --go_opt=paths=source_relative \
		--go-grpc_out=./example/pkg/api --go-grpc_opt=paths=source_relative \
		example.proto
	# Generate core.proto + cache.proto for example Dart (needed for cross-proto imports)
	protoc -Iapi -I/usr/include \
		--dart_out=grpc:example/lib/src/generated \
		core.proto cache.proto
	protoc -Iexample/api -Iapi -I/usr/include \
		--dart_out=grpc:example/lib/src/generated \
		example.proto

	protoc -Iexample/api -Iapi -I/usr/include \
		--plugin=protoc-gen-synurang-ffi=./bin/protoc-gen-synurang-ffi \
		--synurang-ffi_out=./example/pkg/api --synurang-ffi_opt=lang=go \
		example.proto
	protoc -Iexample/api -Iapi -I/usr/include \
		--plugin=protoc-gen-synurang-ffi=./bin/protoc-gen-synurang-ffi \
		--synurang-ffi_out=./example/lib/src/generated --synurang-ffi_opt=lang=dart \
		example.proto

	@echo "Generating test/plugin proto code..."
	mkdir -p test/plugin/api
	protoc -Iexample/api -Iapi -I/usr/include \
		--go_out=./test/plugin/api --go_opt=paths=source_relative \
		--go_opt=Mcore.proto=github.com/ivere27/synurang/pkg/api \
		--go-grpc_out=./test/plugin/api --go-grpc_opt=paths=source_relative \
		--go-grpc_opt=Mcore.proto=github.com/ivere27/synurang/pkg/api \
		example.proto
	protoc -Iexample/api -Iapi -I/usr/include \
		--plugin=protoc-gen-synurang-ffi=./bin/protoc-gen-synurang-ffi \
		--synurang-ffi_out=./test/plugin/api \
		--synurang-ffi_opt=lang=go,mode=plugin_server,services=GoGreeterService \
		example.proto
	protoc -Iexample/api -Iapi -I/usr/include \
		--plugin=protoc-gen-synurang-ffi=./bin/protoc-gen-synurang-ffi \
		--synurang-ffi_out=./test/plugin/api \
		--synurang-ffi_opt=lang=dart,mode=plugin_server,services=GoGreeterService \
		example.proto

	@echo "Proto generation complete."

# =============================================================================
# Shared Library Builds
# =============================================================================

# Linux amd64
shared_linux:
	@echo "Building Linux shared library..."
	GOARCH=amd64 GOOS=linux CGO_ENABLED=1 GO111MODULE=on \
		go build -trimpath -ldflags "-s -w $(LD_FLAGS)" \
		-o libsynurang.so -buildmode=c-shared $(SERVER_PATH)
	mv libsynurang.h ./src/
	mv libsynurang.so ./src/
	@echo "Linux build complete: src/libsynurang.so"

# Linux Example Shared Library
shared_example_linux:
	@echo "Building Example Linux shared library..."
	GOARCH=amd64 GOOS=linux CGO_ENABLED=1 GO111MODULE=on \
		go build -trimpath -ldflags "-s -w $(LD_FLAGS)" \
		-o libsynura_example.so -buildmode=c-shared example/cmd/server/main.go
	mkdir -p example/linux/lib
	mv libsynura_example.h example/linux/lib/
	mv libsynura_example.so example/linux/lib/
	@echo "Example Linux build complete"

# Android ARM, ARM64, x86_64 (parallel builds)
shared_android:
	@echo "Building Android shared libraries in parallel..."
	GOARCH=arm64 GOOS=android CGO_ENABLED=1 CC=$(ANDROID_CC_ARM64) \
		go build -trimpath -ldflags "-s -w $(LD_FLAGS) -extldflags '-Wl,-z,max-page-size=16384'" \
		-o libsynurang-android-arm64.so -buildmode=c-shared $(SERVER_PATH) & \
	GOARCH=arm GOOS=android GOARM=7 CGO_ENABLED=1 CC=$(ANDROID_CC_ARM) \
		go build -trimpath -ldflags "-s -w $(LD_FLAGS)" \
		-o libsynurang-android-arm.so -buildmode=c-shared $(SERVER_PATH) & \
	GOARCH=amd64 GOOS=android CGO_ENABLED=1 CC=$(ANDROID_CC_X86_64) \
		go build -trimpath -ldflags "-s -w $(LD_FLAGS) -extldflags '-Wl,-z,max-page-size=16384'" \
		-o libsynurang-android-x86_64.so -buildmode=c-shared $(SERVER_PATH) & \
	wait
	mv libsynurang-android-*.h libsynurang-android-*.so ./src/
	@echo "Android build complete."

# Android run target (MODE=release|debug, default: debug)
MODE ?= debug
run_android: shared_android
	@echo "Linking shared libraries to example app..."
	mkdir -p example/android/app/src/main/jniLibs/arm64-v8a
	mkdir -p example/android/app/src/main/jniLibs/armeabi-v7a
	mkdir -p example/android/app/src/main/jniLibs/x86_64
	ln -sf $(CURRENT_DIR)/src/libsynurang-android-arm64.so example/android/app/src/main/jniLibs/arm64-v8a/libsynurang.so
	ln -sf $(CURRENT_DIR)/src/libsynurang-android-arm.so example/android/app/src/main/jniLibs/armeabi-v7a/libsynurang.so
	ln -sf $(CURRENT_DIR)/src/libsynurang-android-x86_64.so example/android/app/src/main/jniLibs/x86_64/libsynurang.so
	@DEVICE_ID=$$(flutter devices | grep "android" | head -n 1 | awk -F "•" '{print $$2}' | xargs); \
	if [ -z "$$DEVICE_ID" ]; then echo "No Android device found"; exit 1; fi; \
	echo "Using Android device: $$DEVICE_ID (mode: $(MODE))"; \
	cd example && flutter run -d $$DEVICE_ID --$(MODE)

# =============================================================================
# Android AAR (Docker)
# =============================================================================
docker_android_aar_image:
	@echo "Building Docker image for Android AAR packaging..."
	docker build -t "$(AAR_DOCKER_IMAGE)" -f Dockerfile .

docker_android_aar: docker_android_aar_image
	@echo "Packaging Android AARs (version $(AAR_VERSION), build $(AAR_BUILD_TYPE), ABIs $(AAR_ANDROID_ABIS))..."
	docker run --rm --entrypoint bash \
		-v "$(DOCKER_GO_BUILD_CACHE_VOLUME):$(DOCKER_GO_BUILD_CACHE_DIR)" \
		-v "$(DOCKER_GRADLE_BUILD_CACHE_VOLUME):$(DOCKER_GRADLE_CACHE_DIR)" \
		"$(AAR_DOCKER_IMAGE)" \
		-lc 'chmod -R a+rwx /cache/go-build /cache/gradle || true'
	docker run --rm \
		-u "$$(id -u):$$(id -g)" \
		-v "$(CURRENT_DIR):/workspace/synurang" \
		-v "$(DOCKER_GO_BUILD_CACHE_VOLUME):$(DOCKER_GO_BUILD_CACHE_DIR)" \
		-v "$(DOCKER_GRADLE_BUILD_CACHE_VOLUME):$(DOCKER_GRADLE_CACHE_DIR)" \
		-w /workspace/synurang \
		-e GOCACHE="$(DOCKER_GO_BUILD_CACHE_DIR)/synurang-go-build" \
		-e GRADLE_USER_HOME="$(DOCKER_GRADLE_CACHE_DIR)" \
		-e VERSION="$(AAR_VERSION)" \
		-e GROUP_ID="$(AAR_GROUP_ID)" \
		-e ARTIFACT_ID_CORE="$(AAR_ARTIFACT_ID_CORE)" \
		-e ARTIFACT_ID_GRPC="$(AAR_ARTIFACT_ID_GRPC)" \
		-e CMAKE_BUILD_TYPE="$(AAR_BUILD_TYPE)" \
		-e ANDROID_ABIS="$(AAR_ANDROID_ABIS)" \
		-e ANDROID_API="$(AAR_ANDROID_API)" \
		"$(AAR_DOCKER_IMAGE)"
	@echo "AAR artifacts: dist/maven/"

docker_android_aar_debug:
	$(MAKE) docker_android_aar \
		AAR_BUILD_TYPE=Debug \
		AAR_ARTIFACT_ID_CORE="$(AAR_DEBUG_ARTIFACT_ID_CORE)" \
		AAR_ARTIFACT_ID_GRPC="$(AAR_DEBUG_ARTIFACT_ID_GRPC)" \
		AAR_VERSION="$(AAR_VERSION)"

publish_maven:
	@if [ ! -f "$(MAVEN_SETTINGS)" ]; then \
		echo "Error: Maven settings not found: $(MAVEN_SETTINGS)"; \
		echo "Create .maven-settings.xml with your Sonatype Central credentials."; \
		exit 1; \
	fi
	@MAVEN_USER=$$(sed -n 's|.*<username>\(.*\)</username>.*|\1|p' "$(MAVEN_SETTINGS)" | head -1); \
	MAVEN_PASS=$$(sed -n 's|.*<password>\(.*\)</password>.*|\1|p' "$(MAVEN_SETTINGS)" | head -1); \
	DIST="$(CURRENT_DIR)/dist/maven"; \
	upload_bundle() { \
		local ARTIFACT="$$1" VERSION="$$2" EXT="$$3" GROUP="$$4"; \
		local FILE="$$DIST/$$ARTIFACT-$$VERSION.$$EXT"; \
		local POM="$$DIST/$$ARTIFACT-$$VERSION.pom"; \
		local GROUP_PATH=$$(echo "$$GROUP" | tr '.' '/'); \
		local TOP_DIR=$$(echo "$$GROUP" | cut -d. -f1); \
		if [ ! -f "$$FILE" ] || [ ! -f "$$POM" ]; then \
			echo "Error: $$ARTIFACT-$$VERSION not found in $$DIST"; \
			echo "Run 'make docker_android_aar docker_desktop_jar' first."; \
			exit 1; \
		fi; \
		echo "Creating bundle for $$ARTIFACT-$$VERSION..."; \
		BUNDLE_DIR=$$(mktemp -d); \
		BUNDLE_ZIP="/tmp/synurang-bundle-$$$$.zip"; \
		rm -f "$$BUNDLE_ZIP"; \
		TARGET="$$BUNDLE_DIR/$$GROUP_PATH/$$ARTIFACT/$$VERSION"; \
		mkdir -p "$$TARGET"; \
		cp "$$FILE" "$$TARGET/"; \
		cp "$$POM" "$$TARGET/"; \
		for CLASSIFIER in sources javadoc; do \
			CFILE="$$DIST/$$ARTIFACT-$$VERSION-$$CLASSIFIER.jar"; \
			if [ -f "$$CFILE" ]; then cp "$$CFILE" "$$TARGET/"; fi; \
		done; \
		for f in "$$TARGET"/*; do \
			md5sum "$$f" | cut -d' ' -f1 > "$$f.md5"; \
			sha1sum "$$f" | cut -d' ' -f1 > "$$f.sha1"; \
			gpg -ab "$$f"; \
		done; \
		cd "$$BUNDLE_DIR" && zip -qr "$$BUNDLE_ZIP" "$$TOP_DIR" || { echo "zip failed"; exit 1; }; \
		rm -rf "$$BUNDLE_DIR"; \
		echo "Uploading $$ARTIFACT-$$VERSION to Maven Central..."; \
		RESPONSE=$$(curl -s -w "\n%{http_code}" \
			-u "$$MAVEN_USER:$$MAVEN_PASS" \
			-X POST "$(MAVEN_REPO_URL)" \
			-F "bundle=@$$BUNDLE_ZIP" \
			-F "name=$$ARTIFACT-$$VERSION" \
			-F "publishingType=AUTOMATIC"); \
		rm -f "$$BUNDLE_ZIP"; \
		HTTP_CODE=$$(echo "$$RESPONSE" | tail -1); \
		BODY=$$(echo "$$RESPONSE" | head -n -1); \
		if [ "$$HTTP_CODE" -ge 200 ] && [ "$$HTTP_CODE" -lt 300 ]; then \
			echo "Upload successful (HTTP $$HTTP_CODE): $$ARTIFACT-$$VERSION"; \
			echo "$$BODY"; \
		else \
			echo "Upload failed (HTTP $$HTTP_CODE): $$ARTIFACT-$$VERSION"; \
			echo "$$BODY"; \
			exit 1; \
		fi; \
	}; \
	for ARTIFACT in $(AAR_ARTIFACT_ID_CORE) $(AAR_ARTIFACT_ID_GRPC); do \
		upload_bundle "$$ARTIFACT" "$(AAR_VERSION)" "aar" "$(AAR_GROUP_ID)"; \
	done; \
	for ARTIFACT in $(DESKTOP_ARTIFACT_ID_CORE) $(DESKTOP_ARTIFACT_ID_GRPC); do \
		upload_bundle "$$ARTIFACT" "$(DESKTOP_VERSION)" "jar" "$(DESKTOP_GROUP_ID)"; \
	done

# =============================================================================
# Desktop JAR (Docker)
# =============================================================================
docker_desktop_jar_image:
	@echo "Building Docker image for desktop JAR packaging..."
	docker build -t "$(DESKTOP_DOCKER_IMAGE)" -f Dockerfile.desktop .

docker_desktop_jar: docker_desktop_jar_image
	@echo "Packaging desktop JARs (version $(DESKTOP_VERSION))..."
	docker run --rm --entrypoint bash \
		-v "$(DOCKER_GO_BUILD_CACHE_VOLUME):$(DOCKER_GO_BUILD_CACHE_DIR)" \
		-v "$(DOCKER_GRADLE_BUILD_CACHE_VOLUME):$(DOCKER_GRADLE_CACHE_DIR)" \
		"$(DESKTOP_DOCKER_IMAGE)" \
		-lc 'chmod -R a+rwx /cache/go-build /cache/gradle || true'
	docker run --rm \
		-u "$$(id -u):$$(id -g)" \
		-v "$(CURRENT_DIR):/workspace/synurang" \
		-v "$(DOCKER_GO_BUILD_CACHE_VOLUME):$(DOCKER_GO_BUILD_CACHE_DIR)" \
		-v "$(DOCKER_GRADLE_BUILD_CACHE_VOLUME):$(DOCKER_GRADLE_CACHE_DIR)" \
		-w /workspace/synurang \
		-e GOCACHE="$(DOCKER_GO_BUILD_CACHE_DIR)/synurang-go-build" \
		-e GRADLE_USER_HOME="$(DOCKER_GRADLE_CACHE_DIR)" \
		-e VERSION="$(DESKTOP_VERSION)" \
		-e GROUP_ID="$(DESKTOP_GROUP_ID)" \
		-e ARTIFACT_ID_CORE="$(DESKTOP_ARTIFACT_ID_CORE)" \
		-e ARTIFACT_ID_GRPC="$(DESKTOP_ARTIFACT_ID_GRPC)" \
		"$(DESKTOP_DOCKER_IMAGE)"
	@echo "Desktop JAR artifacts: dist/maven/"

# Plugin Shared Library (for test/plugin)
shared_plugin:
	@echo "Building plugin shared library..."
	CGO_ENABLED=1 go build -buildmode=c-shared \
		-o test/plugin/impl/plugin.so ./test/plugin/impl/
	@echo "Plugin build complete: test/plugin/impl/plugin.so"

# Plugin Host Application
build_plugin_host:
	@echo "Building plugin host application..."
	go build -o test/plugin/host/host ./test/plugin/host/
	@echo "Plugin host build complete: test/plugin/host/host"

# =============================================================================
# Tests
# =============================================================================

# Run all tests (Go + Dart + C++ + Rust + Native/WASM + TypeScript + C# + Swift + Plugin)
test: test_go test_dart test_cpp test_rust test_native_wasm_gen test_typescript_gen test_csharp test_swift test_plugin test_ffi_rs_gen
	@echo "All tests complete."

# C++ Tests (Generation + FFI)
test_cpp: test_cpp_gen test_cpp_ffi
	@echo "All C++ tests complete."

# C++ Gen tests
test_cpp_gen:
	@echo "Running C++ Generation tests..."
	./test/test_cpp_gen.sh
	@echo "C++ Generation tests complete."

# C++ FFI Integration tests (Mock Backend)
test_cpp_ffi:
	@echo "Running C++ FFI Integration tests..."
	cd test/cpp_ffi && $(MAKE)
	flutter pub get
	LD_LIBRARY_PATH=$(CURRENT_DIR)/test/cpp_ffi:${LD_LIBRARY_PATH} dart test test/cpp_ffi/cpp_integration_test.dart
	@echo "C++ FFI Integration tests complete."

# Rust Tests (Generation + FFI)
test_rust: test_rust_gen test_rust_ffi
	@echo "All Rust tests complete."

# Rust Gen tests
test_rust_gen:
	@echo "Running Rust Generation tests..."
	./test/test_rust_gen.sh
	@echo "Rust Generation tests complete."

# Native/WASM codegen tests
test_native_wasm_gen:
	@echo "Running Native/WASM generation tests..."
	./test/test_native_wasm_gen.sh
	@echo "Native/WASM generation tests complete."

# TypeScript codegen tests
test_typescript_gen:
	@echo "Running TypeScript generation tests..."
	./test/test_typescript_gen.sh
	@echo "TypeScript generation tests complete."

# Swift Tests (Generation + FFI host)
test_swift: test_swift_gen test_host_swift
	@echo "All Swift tests complete."

# Swift codegen tests
test_swift_gen:
	@echo "Running Swift generation tests..."
	./test/test_swift_gen.sh
	@echo "Swift generation tests complete."

# Rust FFI Integration tests (Mock Backend)
test_rust_ffi:
	@echo "Running Rust FFI Integration tests..."
	cd test/rust_ffi && cargo build --release
	flutter pub get
	LD_LIBRARY_PATH=$(CURRENT_DIR)/target/release:${LD_LIBRARY_PATH} dart test test/rust_ffi/rust_integration_test.dart
	@echo "Rust FFI Integration tests complete."

# C# Tests (Generation + FFI)
test_csharp: test_csharp_gen test_csharp_ffi
	@echo "All C# tests complete."

# C# Gen tests
test_csharp_gen:
	@echo "Running C# Generation tests..."
	./test/test_csharp_gen.sh
	@echo "C# Generation tests complete."

# C# FFI API test (same style as other test/ffi/* targets)
test_csharp_ffi: build_plugin_go build_csharp
	@echo "Running C# FFI API test..."
	dotnet run --project test/host/csharp/ -- --ffi-only
	@echo "C# FFI API test complete."

# C# FFI API test (alias)
test_ffi_csharp: test_csharp_ffi

# Plugin FFI tests (Go-to-Go via shared library)
test_plugin: proto shared_plugin build_plugin_host
	@echo "Running Plugin FFI tests..."
	cd test/plugin/host && ./host
	@echo "Plugin FFI tests complete."

# Plugin FFI tests with race detector
test_plugin_race: proto shared_plugin
	@echo "Building and running Plugin FFI tests with race detector..."
	go build -race -o test/plugin/host/host_race ./test/plugin/host/
	cd test/plugin/host && ./host_race
	@echo "Plugin FFI race tests complete."

# =============================================================================
# FFI API Tests (No gRPC — raw bytes, all 4 RPC types)
# =============================================================================

# Run all FFI API tests (Go, C++, Rust, Java, Dart, C#)
test_ffi: test_ffi_go test_ffi_cpp test_ffi_rust test_ffi_java test_ffi_dart test_ffi_csharp
	@echo "\n═══════════════════════════════════════════════════════════════"
	@echo "  All FFI API tests passed (Go, C++, Rust, Java, Dart, C#)"
	@echo "═══════════════════════════════════════════════════════════════\n"

# Go FFI test
test_ffi_go: build_plugin_go
	@echo "Running Go FFI API test..."
	go run ./test/ffi/go/

# C++ FFI test
test_ffi_cpp: build_plugin_go
	@echo "Running C++ FFI API test..."
	@mkdir -p test/ffi/cpp/build
	cd test/ffi/cpp/build && cmake .. && make -j4
	./bin/test_ffi_cpp

# Rust FFI test
test_ffi_rust: build_plugin_go
	@echo "Running Rust FFI API test..."
	cargo run --manifest-path test/ffi/rust/Cargo.toml

# Java FFI test
test_ffi_java: build_plugin_go build_java
	@echo "Running Java FFI API test..."
	javac -cp $(JAVA_JAR) -d test/ffi/java test/ffi/java/FfiApiTest.java
	java -Djava.library.path=java/core/src/main/c/build \
		-cp $(JAVA_JAR):test/ffi/java \
		FfiApiTest

# Dart FFI test (uses example shared library for GoGreeterService)
test_ffi_dart: shared_example_linux
	@echo "Running Dart FFI API test..."
	flutter pub get
	LD_LIBRARY_PATH=$(CURRENT_DIR)/src:$(CURRENT_DIR)/example/linux/lib:${LD_LIBRARY_PATH} \
		flutter test test/ffi/dart/ffi_api_test.dart

# Go tests only (requires generated proto code)
test_go: proto
	@echo "Running Go tests..."
	go test -v ./pkg/api/...
	go test -v ./pkg/service/...
	go test -v ./example/pkg/api/...
	@echo "Go tests complete."

# Dart tests only (requires shared library + FFI bindings + server binary for benchmarks)
# NOTE: --concurrency=1 is required because all tests share the same gRPC server
test_dart: shared_linux ffigen build_server
	@echo "Running Dart tests..."
	flutter pub get
	LD_LIBRARY_PATH=$(CURRENT_DIR)/src:${LD_LIBRARY_PATH} dart test --concurrency=1
	@echo "Dart tests complete."

# Run large stream integration tests
test_large_stream: shared_linux shared_example_linux
	@echo "Running Large Stream Integration Tests..."
	cd example && flutter pub get
	cd example && LD_LIBRARY_PATH=$(CURRENT_DIR)/src:$(CURRENT_DIR)/example/linux/lib:${LD_LIBRARY_PATH} flutter test test/large_stream_test.dart

# Run benchmark tests (FFI, TCP, UDS comparison)
benchmark: shared_linux ffigen build_server
	@echo "Running Benchmark Tests (FFI, TCP, UDS)..."
	flutter pub get
	LD_LIBRARY_PATH=$(CURRENT_DIR)/src:${LD_LIBRARY_PATH} dart test test/full_verification_and_benchmark_test.dart --concurrency=1
	@echo "Benchmark tests complete."

# Randomized Go-host process brute-force stress test
# (includes crash/RSS/goroutine/fd checks)
BRUTE_ENV := SYNURANG_BRUTE=1 \
	SYNURANG_BRUTE_DURATION=$(BRUTE_DURATION) \
	SYNURANG_BRUTE_PHASE=$(BRUTE_PHASE) \
	SYNURANG_BRUTE_WORKERS=$(BRUTE_WORKERS) \
	SYNURANG_BRUTE_MAX_G_DELTA=$(BRUTE_MAX_G_DELTA) \
	SYNURANG_BRUTE_MAX_FD_DELTA=$(BRUTE_MAX_FD_DELTA) \
	SYNURANG_BRUTE_MAX_RSS_MB_DELTA=$(BRUTE_MAX_RSS_MB_DELTA)

test_bruteforce_process_go: build_process_all
	@echo "Running Go process brute-force stress test (Go/C++/Rust children)..."
	@echo "[Go Host -> Go Child]"
	$(BRUTE_ENV) go test -v ./pkg/synurang -run TestProcessRandomBruteforce -count=1 -timeout 12m
	@echo "[Go Host -> C++ Child]"
	$(BRUTE_ENV) SYNURANG_BRUTE_CHILD_BIN=$(CURRENT_DIR)/bin/process_child_cpp \
		go test -v ./pkg/synurang -run TestProcessRandomBruteforce -count=1 -timeout 12m
	@echo "[Go Host -> Rust Child]"
	$(BRUTE_ENV) SYNURANG_BRUTE_CHILD_BIN=$(CURRENT_DIR)/bin/process_child_rust \
		go test -v ./pkg/synurang -run TestProcessRandomBruteforce -count=1 -timeout 12m
	@echo "Go process brute-force stress test complete."

test_bruteforce_go: test_bruteforce_process_go

# Build all brute-force hosts
build_brute_all: build_plugin_all build_process_all build_host_java_brute build_host_csharp_brute build_garbage_child
	@echo "Building C++ brute-force hosts..."
	@mkdir -p test/host/cpp/build
	cd test/host/cpp/build && cmake .. -DENABLE_PROCESS_BRUTE=ON && make -j4 brute_cpp_host brute_cpp_process_host
	@echo "Building Rust brute-force hosts..."
	cd test/host/rust && cargo build --release --bin brute-rust-host --bin brute-process-rust-host
	@mkdir -p bin
	install target/release/brute-rust-host bin/brute_rust_host
	install target/release/brute-process-rust-host bin/brute_rust_process_host
	@echo "Brute-force build complete."

# Build garbage child fuzzer
build_garbage_child:
	@mkdir -p bin
	g++ -O2 test/fuzz/garbage_child.cpp -o bin/garbage_child

# Run C++ host brute-force
test_bruteforce_plugin_cpp: build_brute_all
	@echo "Running C++ host brute-force..."
	$(BRUTE_ENV) ./bin/brute_cpp_host

test_bruteforce_cpp: test_bruteforce_plugin_cpp

# Run Rust host brute-force
test_bruteforce_plugin_rust: build_brute_all
	@echo "Running Rust host brute-force..."
	$(BRUTE_ENV) ./bin/brute_rust_host

test_bruteforce_rust: test_bruteforce_plugin_rust

# Run C++ process host brute-force against Go/C++/Rust process children
test_bruteforce_process_cpp: build_brute_all
	@echo "Running C++ process host brute-force..."
	$(BRUTE_ENV) ./bin/brute_cpp_process_host

# Run Rust process host brute-force against Go/C++/Rust process children
test_bruteforce_process_rust: build_brute_all
	@echo "Running Rust process host brute-force..."
	$(BRUTE_ENV) SYNURANG_BRUTE_INCLUDE_CPP_CHILD=1 ./bin/brute_rust_process_host

# Run Go plugin brute-force (all 3 plugin languages + reload-under-load)
test_bruteforce_plugin_go: build_plugin_all
	@echo "Running Go plugin brute-force tests..."
	$(BRUTE_ENV) go test -v ./pkg/synurang -run 'TestPlugin(RandomBruteforce|ReloadUnderLoad)' -count=1 -timeout $(BRUTE_GO_TEST_TIMEOUT)
	@echo "Plugin brute-force tests complete."

test_bruteforce_plugin: test_bruteforce_plugin_go

# Brute-force mode (all|ffi, default: all)
BRUTE_MODE ?= all

# Run Dart host brute-force (supports BRUTE_MODE=all|ffi)
test_bruteforce_hybrid_dart: build_plugin_all $(if $(filter all,$(BRUTE_MODE)),build_process_tcp_child)
	@echo "Running Dart hybrid brute-force (mode: $(BRUTE_MODE))..."
	$(BRUTE_ENV) SYNURANG_BRUTE_MODE=$(BRUTE_MODE) \
		LD_LIBRARY_PATH=$(CURRENT_DIR)/src:$(CURRENT_DIR)/example/linux/lib:${LD_LIBRARY_PATH} \
		dart test test/host/dart/bruteforce_test.dart --concurrency=1

test_bruteforce_dart: test_bruteforce_hybrid_dart

# Run Java host brute-force (supports BRUTE_MODE=all|ffi)
test_bruteforce_hybrid_java: build_plugin_all build_host_java_brute $(if $(filter all,$(BRUTE_MODE)),build_process_tcp_child)
	@echo "Running Java hybrid brute-force (mode: $(BRUTE_MODE))..."
	$(BRUTE_ENV) SYNURANG_BRUTE_MODE=$(BRUTE_MODE) \
		java -Djava.library.path=java/core/src/main/c/build \
		-cp '$(JAVA_JAR):java/libs/*:test/host/java/build' \
		JavaHostBruteTest

test_bruteforce_java: test_bruteforce_hybrid_java

# Build C# host brute-force test
build_host_csharp_brute: build_csharp
	@echo "Building C# host brute-force test..."
	dotnet build test/host/csharp-brute/
	@echo "Built: test/host/csharp-brute/"

# Run C# host brute-force (supports BRUTE_MODE=all|ffi)
# .NET runtime thread pool/epoll uses more FDs than native runtimes; override threshold.
test_bruteforce_hybrid_csharp: build_plugin_all build_host_csharp_brute $(if $(filter all,$(BRUTE_MODE)),build_process_tcp_child)
	@echo "Running C# hybrid brute-force (mode: $(BRUTE_MODE))..."
	$(BRUTE_ENV) SYNURANG_BRUTE_MAX_FD_DELTA=128 SYNURANG_BRUTE_MODE=$(BRUTE_MODE) \
		dotnet run --project test/host/csharp-brute/ --no-build

test_bruteforce_csharp: test_bruteforce_hybrid_csharp

# Swift host tests run inside the swift:5.9 Docker image — keeps the toolchain
# off the developer's machine. Override SWIFT_DOCKER_IMAGE to pin a different
# tag; override SWIFT_PLUGIN to point at a non-Go plugin shared library.
SWIFT_DOCKER_IMAGE ?= swift:5.9
SWIFT_PLUGIN ?= /work/bin/libplugin_go.so

# Swift host loading plugins (mirrors test_host_csharp). Builds the Go plugin
# first because the swift:5.9 image is missing libprotobuf for the C++ plugin;
# Go and Rust plugins are statically linked and work out of the box.
test_host_swift: build_plugin_go
	@echo "Testing Swift host (in $(SWIFT_DOCKER_IMAGE) Docker)..."
	docker run --rm \
		-v $(CURRENT_DIR):/work -w /work/swift \
		-e SYNURANG_TEST_PLUGIN_PATH=$(SWIFT_PLUGIN) \
		$(SWIFT_DOCKER_IMAGE) swift test

# Swift host brute-force (supports BRUTE_MODE=ffi only — Swift has no process
# host yet). Reuses the same env vars as the C#/Java brute targets.
test_bruteforce_hybrid_swift: build_plugin_go
	@echo "Running Swift hybrid brute-force (in $(SWIFT_DOCKER_IMAGE) Docker)..."
	docker run --rm \
		-v $(CURRENT_DIR):/work -w /work/swift \
		-e SYNURANG_TEST_PLUGIN_PATH=$(SWIFT_PLUGIN) \
		-e SYNURANG_BRUTE=1 \
		-e SYNURANG_BRUTE_DURATION=$(BRUTE_DURATION) \
		-e SYNURANG_BRUTE_WORKERS=$(BRUTE_WORKERS) \
		-e SYNURANG_BRUTE_MAX_FD_DELTA=$(BRUTE_MAX_FD_DELTA) \
		-e SYNURANG_BRUTE_MAX_RSS_MB_DELTA=$(BRUTE_MAX_RSS_MB_DELTA) \
		$(SWIFT_DOCKER_IMAGE) swift test --filter PluginStressTests

test_bruteforce_swift: test_bruteforce_hybrid_swift

# Run all brute-force tests (all modes × all languages)
.PHONY: test_bruteforce test_bruteforce_process_go test_bruteforce_process_cpp test_bruteforce_process_rust \
        test_bruteforce_plugin_go test_bruteforce_plugin_cpp test_bruteforce_plugin_rust \
        test_bruteforce_hybrid_dart test_bruteforce_hybrid_java test_bruteforce_hybrid_csharp \
        test_bruteforce_hybrid_swift test_bruteforce_swift test_host_swift
test_bruteforce:
	@$(MAKE) test_bruteforce_process_go
	@$(MAKE) test_bruteforce_process_cpp
	@$(MAKE) test_bruteforce_process_rust
	@$(MAKE) test_bruteforce_plugin_go
	@$(MAKE) test_bruteforce_plugin_cpp
	@$(MAKE) test_bruteforce_plugin_rust
	@$(MAKE) test_bruteforce_hybrid_dart
	@$(MAKE) test_bruteforce_hybrid_java
	@$(MAKE) test_bruteforce_hybrid_csharp
	@$(MAKE) test_bruteforce_hybrid_swift
	@echo "All brute-force tests complete."

test_bruteforce_host: test_bruteforce

# Build standalone synurang server binary for TCP/UDS tests
build_server:
	@echo "Building standalone synurang server..."
	@mkdir -p bin
	go build -o bin/synurang_server $(SERVER_PATH)
	@echo "Built: bin/synurang_server"

# Quick Go test (no verbose)
test_quick:
	go test ./...

# =============================================================================
# Development
# =============================================================================

# Run standalone server for testing
run:
	go run $(SERVER_PATH) -port 18000 -socket /tmp/synurang.sock

# Run console example (former main.dart)
run_console_example: shared_linux shared_example_linux
	@echo "Running console example (FFI mode)..."
	flutter pub get
	LD_LIBRARY_PATH=$(CURRENT_DIR)/src:$(CURRENT_DIR)/example/linux/lib:${LD_LIBRARY_PATH} dart run example/console_main.dart

# NOTE: run_console_tcp and run_console_uds removed - use run_console_example with --mode=tcp|uds flag

# Build standalone example server binary
build_example_server:
	@echo "Building standalone example server..."
	@mkdir -p bin
	go build -o bin/synurang_example_server example/cmd/server/main.go
	@echo "Built: bin/synurang_example_server"

# Build process mode example (parent + child)
build_process_example:
	@echo "Building process mode example..."
	@mkdir -p bin
	go build -o bin/process_child ./example/go/process
	go build -o bin/process_parent ./example/cmd/process_parent/main.go
	@echo "Built: bin/process_parent, bin/process_child"

# Run process mode example
run_process_example: build_process_example
	@echo "Running process mode example..."
	./bin/process_parent --child=./bin/process_child

# NOTE: build_process_go removed - use build_process_example or build_process_all

# Build C++ process child
build_process_cpp:
	@echo "Building C++ process child..."
	@mkdir -p example/cpp/process/build
	cd example/cpp/process/build && cmake .. && make -j4
	@mkdir -p bin
	install example/cpp/process/build/process_child bin/process_child_cpp
	@echo "Built: bin/process_child_cpp"

# Build Rust process child
build_process_rust:
	@echo "Building Rust process child..."
	cd example/rust/process && cargo build --release
	@mkdir -p bin
	install target/release/process_child bin/process_child_rust
	@echo "Built: bin/process_child_rust"

# Build all process mode binaries
build_process_all: build_process_example build_process_cpp build_process_rust
	@echo "Built all process mode binaries"

# Build TCP process child (for Dart/Java process-mode tests)
build_process_tcp_child:
	@echo "Building TCP process child..."
	@mkdir -p bin
	go build -o bin/process_child_tcp ./test/host/tcp_process_child
	@echo "Built: bin/process_child_tcp"

# Run multi-language process mode example
run_process_multilang: build_process_example build_process_rust
	@echo "Running multi-language process mode example..."
	@echo "[Go Parent -> Go Child]"
	./bin/process_parent --child=./bin/process_child

	@echo "\n[Go Parent -> Rust Child]"
	./bin/process_parent --child=./bin/process_child_rust

# =============================================================================
# Plugin Mode (FFI Shared Library) Examples
# =============================================================================

# Helper for FFI plugin generation
# Usage: $(call GEN_FFI_PLUGIN,lang,output_dir,mode,services)
GEN_FFI_PLUGIN = protoc -Iexample/api -Iapi \
	--plugin=protoc-gen-synurang-ffi=./bin/protoc-gen-synurang-ffi \
	--synurang-ffi_out=$(2) \
	--synurang-ffi_opt=lang=$(1),mode=$(3),services=$(4) \
	example/api/example.proto

# Generate C++ plugin FFI code
gen_plugin_cpp:
	@echo "Generating C++ plugin FFI code..."
	$(call GEN_FFI_PLUGIN,cpp,./example/cpp/plugin,plugin_server,GoGreeterService)
	@echo "Generated: example/cpp/plugin/example_ffi_plugin.{h,cc}"

# Build C++ plugin shared library
build_plugin_cpp: gen_plugin_cpp
	@echo "Building C++ plugin..."
	@mkdir -p example/cpp/plugin/build
	cd example/cpp/plugin/build && cmake .. && make -j4
	@mkdir -p bin
	cp example/cpp/plugin/build/libplugin.so bin/libplugin_cpp.so

# Build Go plugin shared library
build_plugin_go:
	@echo "Building Go plugin..."
	@mkdir -p bin
	CGO_ENABLED=1 go build -buildmode=c-shared -o bin/libplugin_go.so ./example/go/plugin

# Generate Rust plugin FFI code
gen_plugin_rust:
	@echo "Generating Rust plugin FFI code..."
	$(call GEN_FFI_PLUGIN,rust,./example/rust/plugin/src,plugin_server,GoGreeterService)
	@sed -i 's/#\!\[/\/\/ #\!\[/g' example/rust/plugin/src/example_ffi_plugin.rs
	@echo "Generated: example/rust/plugin/src/example_ffi_plugin.rs"

# Build Rust plugin shared library
build_plugin_rust: gen_plugin_rust
	@echo "Building Rust plugin..."
	cd example/rust/plugin && cargo build --release
	@mkdir -p bin
	cp target/release/libsynurang_rust_plugin.so bin/libplugin_rust.so 2>/dev/null || \
	cp target/release/libsynurang_rust_plugin.dylib bin/libplugin_rust.dylib 2>/dev/null || true
	@echo "Built: bin/libplugin_rust.so"

# NOTE: Individual test_plugin_{go,cpp,rust} removed - use test_plugin_all instead

# Build all plugins
build_plugin_all: build_plugin_go build_plugin_cpp build_plugin_rust
	@echo "Built all plugins: bin/libplugin_{go,cpp,rust}.so"

# Test all plugins together (loads Go, C++, Rust plugins × all host languages)
test_plugin_all: test_host_all
	@echo "All plugin tests complete (Go, C++, Rust plugins × Go, C++, Rust, Java, C#, Swift hosts)."

# =============================================================================
# Host Mode (C++/Rust/Java parents loading plugins)
# =============================================================================

# Test all hosts (Go, C++, Rust, Java, C#, Swift parents)
test_host_all: test_host_go test_host_cpp test_host_rust test_host_java test_host_csharp test_host_swift
	@echo "All host tests complete (Go, C++, Rust, Java, C#, Swift parents × plugins)"

# Go host loading plugins (uses Go's native gRPC server test)
test_host_go: build_plugin_all
	@echo "Testing Go host with all plugins..."
	go run ./test/plugin/multi/main.go

# C++ host loading plugins
test_host_cpp: build_plugin_all
	@echo "Testing C++ host..."
	@mkdir -p test/host/cpp/build
	cd test/host/cpp/build && cmake .. && make -j4
	./bin/test_cpp_host

# Rust host loading plugins
test_host_rust: build_plugin_all
	@echo "Testing Rust host..."
	cd test/host/rust && cargo build --release
	@mkdir -p bin
	cp target/release/test-rust-host bin/test_rust_host
	./bin/test_rust_host

# Java host loading plugins
test_host_java: build_plugin_all build_java
	@echo "Testing Java host..."
	@mkdir -p test/host/java/build
	javac -cp '$(JAVA_JAR):java/libs/*' -d test/host/java/build test/host/java/JavaHostTest.java
	java -Djava.library.path=java/core/src/main/c/build -cp '$(JAVA_JAR):java/libs/*:test/host/java/build' JavaHostTest

# C# host loading plugins
build_csharp:
	@echo "Building C# host library..."
	dotnet build csharp/Synurang/

test_host_csharp: build_plugin_all build_csharp
	@echo "Testing C# host..."
	dotnet build test/host/csharp/
	dotnet run --project test/host/csharp/

# Build JNI native library
build_jni:
	@echo "Building JNI native library..."
	@mkdir -p java/core/src/main/c/build
	cd java/core/src/main/c/build && cmake .. -DCMAKE_BUILD_TYPE=Release && make -j4
	@echo "Built: java/core/src/main/c/build/libsynurang_jni.so"

# Download grpc-java jars for compilation (cached per-jar existence)
GRPC_VERSION := 1.60.0
GRPC_JARS := java/libs
download_grpc_jars:
	@mkdir -p $(GRPC_JARS)
	@test -f $(GRPC_JARS)/grpc-api-$(GRPC_VERSION).jar || curl -sL -o $(GRPC_JARS)/grpc-api-$(GRPC_VERSION).jar \
		https://repo1.maven.org/maven2/io/grpc/grpc-api/$(GRPC_VERSION)/grpc-api-$(GRPC_VERSION).jar
	@test -f $(GRPC_JARS)/grpc-core-$(GRPC_VERSION).jar || curl -sL -o $(GRPC_JARS)/grpc-core-$(GRPC_VERSION).jar \
		https://repo1.maven.org/maven2/io/grpc/grpc-core/$(GRPC_VERSION)/grpc-core-$(GRPC_VERSION).jar
	@test -f $(GRPC_JARS)/grpc-netty-shaded-$(GRPC_VERSION).jar || curl -sL -o $(GRPC_JARS)/grpc-netty-shaded-$(GRPC_VERSION).jar \
		https://repo1.maven.org/maven2/io/grpc/grpc-netty-shaded/$(GRPC_VERSION)/grpc-netty-shaded-$(GRPC_VERSION).jar
	@test -f $(GRPC_JARS)/grpc-util-$(GRPC_VERSION).jar || curl -sL -o $(GRPC_JARS)/grpc-util-$(GRPC_VERSION).jar \
		https://repo1.maven.org/maven2/io/grpc/grpc-util/$(GRPC_VERSION)/grpc-util-$(GRPC_VERSION).jar
	@test -f $(GRPC_JARS)/grpc-context-$(GRPC_VERSION).jar || curl -sL -o $(GRPC_JARS)/grpc-context-$(GRPC_VERSION).jar \
		https://repo1.maven.org/maven2/io/grpc/grpc-context/$(GRPC_VERSION)/grpc-context-$(GRPC_VERSION).jar
	@test -f $(GRPC_JARS)/jsr305-3.0.2.jar || curl -sL -o $(GRPC_JARS)/jsr305-3.0.2.jar \
		https://repo1.maven.org/maven2/com/google/code/findbugs/jsr305/3.0.2/jsr305-3.0.2.jar
	@test -f $(GRPC_JARS)/error_prone_annotations-2.23.0.jar || curl -sL -o $(GRPC_JARS)/error_prone_annotations-2.23.0.jar \
		https://repo1.maven.org/maven2/com/google/errorprone/error_prone_annotations/2.23.0/error_prone_annotations-2.23.0.jar
	@test -f $(GRPC_JARS)/guava-32.0.1-android.jar || curl -sL -o $(GRPC_JARS)/guava-32.0.1-android.jar \
		https://repo1.maven.org/maven2/com/google/guava/guava/32.0.1-android/guava-32.0.1-android.jar
	@test -f $(GRPC_JARS)/failureaccess-1.0.1.jar || curl -sL -o $(GRPC_JARS)/failureaccess-1.0.1.jar \
		https://repo1.maven.org/maven2/com/google/guava/failureaccess/1.0.1/failureaccess-1.0.1.jar
	@test -f $(GRPC_JARS)/perfmark-api-0.26.0.jar || curl -sL -o $(GRPC_JARS)/perfmark-api-0.26.0.jar \
		https://repo1.maven.org/maven2/io/perfmark/perfmark-api/0.26.0/perfmark-api-0.26.0.jar
	@test -f $(GRPC_JARS)/grpc-stub-$(GRPC_VERSION).jar || curl -sL -o $(GRPC_JARS)/grpc-stub-$(GRPC_VERSION).jar \
		https://repo1.maven.org/maven2/io/grpc/grpc-stub/$(GRPC_VERSION)/grpc-stub-$(GRPC_VERSION).jar

# Compile Java host library (core + grpc into single jar for desktop tests)
build_java: build_jni download_grpc_jars
	@echo "Compiling Java host library..."
	@mkdir -p $(JAVA_CLASSES_DIR) $(JAVA_LIB_DIR)
	javac -cp 'java/libs/*' -d $(JAVA_CLASSES_DIR) \
		java/core/src/main/java/io/github/ivere27/synurang/*.java \
		java/grpc/src/main/java/io/github/ivere27/synurang/*.java
	cd $(JAVA_CLASSES_DIR) && jar cf ../libs/java.jar io/
	@echo "Built: $(JAVA_CLASSES_DIR) $(JAVA_JAR)"

# Build Java host brute-force executable
build_host_java_brute: build_java
	@echo "Building Java host brute-force test..."
	@mkdir -p test/host/java/build
	javac -cp '$(JAVA_JAR):java/libs/*' -d test/host/java/build test/host/java/JavaHostBruteTest.java
	@echo "Built: test/host/java/build/ (JavaHostBruteTest)"

# Build Go plugin for Android (for Java/Kotlin example app)
build_plugin_go_android:
	@echo "Building Go plugin for Android..."
	@mkdir -p example/java/android/app/src/main/jniLibs/arm64-v8a
	@mkdir -p example/java/android/app/src/main/jniLibs/armeabi-v7a
	GOARCH=arm64 GOOS=android CGO_ENABLED=1 CC=$(ANDROID_CC_ARM64) \
		go build -trimpath -ldflags "-s -w" \
		-buildmode=c-shared -o example/java/android/app/src/main/jniLibs/arm64-v8a/libplugin_go.so \
		./example/go/plugin & \
	GOARCH=arm GOOS=android GOARM=7 CGO_ENABLED=1 CC=$(ANDROID_CC_ARM) \
		go build -trimpath -ldflags "-s -w" \
		-buildmode=c-shared -o example/java/android/app/src/main/jniLibs/armeabi-v7a/libplugin_go.so \
		./example/go/plugin & \
	wait
	@echo "Built Go plugin for Android ABIs"

# Build Go process binary for Android (socketpair IPC mode)
# Named libprocess_go.so so Android extracts it from APK into nativeLibraryDir
build_process_go_android:
	@echo "Building Go process binary for Android..."
	@mkdir -p example/java/android/app/src/main/jniLibs/arm64-v8a
	@mkdir -p example/java/android/app/src/main/jniLibs/armeabi-v7a
	GOARCH=arm64 GOOS=android CGO_ENABLED=1 CC=$(ANDROID_CC_ARM64) \
		go build -trimpath -ldflags "-s -w -extldflags '-Wl,-z,max-page-size=16384'" \
		-o example/java/android/app/src/main/jniLibs/arm64-v8a/libprocess_go.so \
		./example/go/process & \
	GOARCH=arm GOOS=android GOARM=7 CGO_ENABLED=1 CC=$(ANDROID_CC_ARM) \
		go build -trimpath -ldflags "-s -w" \
		-o example/java/android/app/src/main/jniLibs/armeabi-v7a/libprocess_go.so \
		./example/go/process & \
	wait
	@echo "Built Go process binary for Android ABIs"

# Build Rust media plugin for Android
build_plugin_media_android:
	@echo "Building Rust media plugin for Android..."
	cd example/java/rust-plugin && \
		cargo ndk -t arm64-v8a -t armeabi-v7a \
		-o ../android/app/src/main/jniLibs -- build --release
	mv example/java/android/app/src/main/jniLibs/arm64-v8a/libsynurang_media_plugin.so \
		example/java/android/app/src/main/jniLibs/arm64-v8a/libplugin_media.so
	mv example/java/android/app/src/main/jniLibs/armeabi-v7a/libsynurang_media_plugin.so \
		example/java/android/app/src/main/jniLibs/armeabi-v7a/libplugin_media.so
	@echo "Built Rust media plugin for Android ABIs"

# Run Android Java/Kotlin example app
ANDROID_HOME ?= $(HOME)/Android/Sdk
ANDROID_NDK_HOME ?= $(NDK_HOME)
export ANDROID_HOME
export ANDROID_NDK_HOME
run_android_java: build_java build_plugin_go_android build_process_go_android build_plugin_media_android
	@DEVICE_ID=$$(adb devices | grep -v "List" | grep "device$$" | head -n 1 | awk '{print $$1}'); \
	if [ -z "$$DEVICE_ID" ]; then echo "No Android device found"; exit 1; fi; \
	echo "Using Android device: $$DEVICE_ID"; \
	cd example/java/android && ./gradlew installDebug && \
	adb -s $$DEVICE_ID shell am start -n com.example.synurang.demo/.MainActivity && \
	sleep 1 && \
	adb -s $$DEVICE_ID logcat --pid=$$(adb -s $$DEVICE_ID shell pidof com.example.synurang.demo)

# Run Flutter example
run_flutter_example: shared_linux shared_example_linux ffigen
	@echo "Running Flutter example (random token)..."
	cd example && flutter pub get
	cd example && LD_LIBRARY_PATH=$(CURRENT_DIR)/src:$(CURRENT_DIR)/example/linux/lib:${LD_LIBRARY_PATH} flutter run -d linux

# Run Flutter example with fixed token and fixed socket paths (for CLI tests)
run_flutter_testable: shared_linux shared_example_linux
	@echo "Running Flutter example (token=demo-token, fixed sockets)..."
	cd example && flutter pub get
	cd example && LD_LIBRARY_PATH=$(CURRENT_DIR)/src:$(CURRENT_DIR)/example/linux/lib:${LD_LIBRARY_PATH} flutter run -d linux \
		--dart-define=TOKEN=demo-token \
		--dart-define=GO_SOCKET=/tmp/synurang_test.sock \
		--dart-define=FLUTTER_SOCKET=/tmp/flutter_view.sock

# Test Go server via transport CLI (TCP)
test_go_tcp: build_example_server
	@echo "Starting Go server (background)..."
	@$(CURRENT_DIR)/bin/synurang_example_server --golang-port=18000 --golang-socket="" --token=demo-token > /dev/null 2>&1 & \
	SERVER_PID=$$!; \
	sleep 0.5; \
	echo "Testing Go server via TCP..."; \
	go run example/cmd/client/main.go --target=go --transport=tcp --addr=localhost:18000 --token=demo-token; \
	EXIT_CODE=$$?; \
	kill $$SERVER_PID; \
	exit $$EXIT_CODE

# Test Go server via transport CLI (UDS)
test_go_uds: build_example_server
	@echo "Starting Go server (background)..."
	@rm -f /tmp/synurang_test.sock; \
	$(CURRENT_DIR)/bin/synurang_example_server --golang-socket=/tmp/synurang_test.sock --golang-port="" --token=demo-token > /dev/null 2>&1 & \
	SERVER_PID=$$!; \
	sleep 0.5; \
	echo "Testing Go server via UDS..."; \
	go run example/cmd/client/main.go --target=go --transport=uds --socket=/tmp/synurang_test.sock --token=demo-token; \
	EXIT_CODE=$$?; \
	kill $$SERVER_PID; \
	rm -f /tmp/synurang_test.sock; \
	exit $$EXIT_CODE

# NOTE: test_flutter_tcp and test_flutter_uds removed - use example/cmd/client directly

# =============================================================================
# Flutter Integration
# =============================================================================

# Generate FFI bindings

# Get Flutter dependencies
pub_get:
	flutter pub get

# =============================================================================
# Clean
# =============================================================================

clean:
	rm -f src/*.so src/*.h
	rm -f pkg/api/*.pb.go
	rm -rf lib/src/generated/*.dart
	rm -f bin/protoc-gen-synurang-ffi
	rm -f test/plugin/api/*.pb.go test/plugin/api/*.pb.dart
	rm -f test/plugin/impl/plugin.so test/plugin/impl/plugin.h
	rm -f test/plugin/host/host

# =============================================================================
# Help
# =============================================================================

help:
	@echo "Synurang Makefile"
	@echo ""
	@echo "Build Targets:"
	@echo "  all               - Build proto and Linux shared library"
	@echo "  shared_linux      - Build Linux amd64 shared library"
	@echo "  shared_android    - Build Android ARM/ARM64/x86_64 shared libraries"
	@echo "  proto             - Generate Go, Dart, and FFI proto code"
	@echo "  docker_android_aar_image - Build Docker image for Android AAR packaging"
	@echo "  docker_android_aar - Build core + grpc AARs (JNI bridge, multi-ABI) into dist/maven"
	@echo "  docker_android_aar_debug - Build debug core + grpc AARs into dist/maven"
	@echo "  docker_desktop_jar_image - Build Docker image for desktop JAR packaging"
	@echo "  docker_desktop_jar - Build desktop JARs (JNI natives + classes) into dist/maven"
	@echo "  publish_maven     - Upload all bundles (AAR + desktop JAR) to Maven Central"
	@echo ""
	@echo "Test Targets:"
	@echo "  test              - Run all tests (Go + Dart + C++ + Rust + Native/WASM + C# + Swift + Plugin)"
	@echo "  test_ffi          - Run all FFI API tests (Go, C++, Rust, Java, Dart, C#)"
	@echo "  test_ffi_{go,cpp,rust,java,dart,csharp} - Run individual FFI API test"
	@echo "  test_go           - Run Go tests only"
	@echo "  test_dart         - Run Dart tests only"
	@echo "  test_plugin       - Run plugin FFI tests (test/plugin)"
	@echo "  test_plugin_all   - Test all plugins × all hosts (Go,C++,Rust × Go,C++,Rust,Java,C#,Swift)"
	@echo "  test_cpp          - Run C++ tests (gen + FFI)"
	@echo "  test_rust         - Run Rust tests (gen + FFI)"
	@echo "  test_native_wasm_gen - Run native/wasm codegen checks"
	@echo "  test_typescript_gen - Run TypeScript codegen checks"
	@echo "  test_csharp       - Run C# tests (gen + FFI API)"
	@echo "  test_swift        - Run Swift tests (gen + Docker FFI host)"
	@echo "  test_swift_gen    - Run Swift codegen checks"
	@echo "  test_bruteforce_process_go   - Go host managing Go/C++/Rust children"
	@echo "  test_bruteforce_process_cpp  - C++ host managing Go/C++/Rust children"
	@echo "  test_bruteforce_process_rust - Rust host managing Go/C++/Rust children"
	@echo "  test_bruteforce_plugin_go    - Go host loading Go/C++/Rust .so plugins"
	@echo "  test_bruteforce_plugin_cpp   - C++ app loading Synurang library"
	@echo "  test_bruteforce_plugin_rust  - Rust app loading Synurang library"
	@echo "  test_bruteforce_dart         - Dart hybrid test (Plugin + TCP Process)"
	@echo "  test_bruteforce_java         - Java hybrid test (Plugin + TCP Process)"
	@echo "  test_bruteforce_csharp       - C# hybrid test (Plugin + TCP Process)"
	@echo "  test_bruteforce_swift        - Swift FFI brute-force (Docker, plugin only)"
	@echo "  test_bruteforce              - Run all brute-force tests above"
	@echo ""
	@echo "Host Mode (Polyglot Parents):"
	@echo "  test_host_all     - Test all hosts (Go, C++, Rust, Java, C# parents)"
	@echo "  test_host_go      - Test Go parent loading plugins"
	@echo "  test_host_cpp     - Test C++ parent loading plugins"
	@echo "  test_host_rust    - Test Rust parent loading plugins"
	@echo "  test_host_java    - Test Java parent loading plugins"
	@echo "  test_host_csharp  - Test C# parent loading plugins"
	@echo "  test_host_swift   - Test Swift parent loading plugins (in swift:5.9 Docker)"
	@echo ""
	@echo "Plugin Mode:"
	@echo "  build_plugin_all  - Build all plugins (Go, C++, Rust)"
	@echo "  build_plugin_go   - Build Go plugin"
	@echo "  build_plugin_cpp  - Build C++ plugin"
	@echo "  build_plugin_rust - Build Rust plugin"
	@echo ""
	@echo "Process Mode:"
	@echo "  build_process_all     - Build all process mode binaries"
	@echo "  build_process_tcp_child - Build TCP process child (Dart/Java process tests)"
	@echo "  run_process_example   - Run Go parent + Go child"
	@echo "  run_process_multilang - Run Go parent with Go/Rust children"
	@echo ""
	@echo "Development:"
	@echo "  run               - Run standalone Go server"
	@echo "  run_android       - Run Flutter on Android (MODE=release|debug)"
	@echo "  run_android_java  - Run Java/Kotlin example on Android"
	@echo "  run_flutter_example   - Run Flutter example (Linux)"
	@echo "  run_console_example   - Run console example (FFI)"
	@echo "  ffigen            - Generate FFI bindings"
	@echo "  clean             - Remove generated files"
	@echo ""
	@echo "Examples:"
	@echo "  make test                    # Run all tests"
	@echo "  make test_bruteforce         # Run all stress tests (multi-hour)"
	@echo "  make test_bruteforce_process_go # 10m randomized stress/leak check"
	@echo "  make test_plugin_all         # Test Go/C++/Rust plugins × all hosts"
	@echo "  make test_host_all           # Test all host combinations (Go,C++,Rust,Java,C#)"
	@echo "  make test_host_csharp        # C# host test"
	@echo "  make run_android MODE=release  # Flutter app"
	@echo "  make run_android_java          # Java/Kotlin app"
	@echo "  make test_host_java            # Java host test (desktop)"
	@echo "  make test_host_swift           # Swift host test (Docker swift:5.9)"
	@echo "  make test_bruteforce_swift BRUTE_DURATION=30s # Swift FFI stress, 30s"
	@echo "  make docker_android_aar AAR_VERSION=0.6.0 # Build core + grpc AAR bundles"
	@echo "  make docker_android_aar_debug AAR_VERSION=0.6.1-SNAPSHOT # Build debug AAR bundles"

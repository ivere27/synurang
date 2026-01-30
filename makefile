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

# Android NDK paths
NDK_HOME ?= $(HOME)/android-ndk-r23c

ANDROID_CC_ARM := $(NDK_HOME)/toolchains/llvm/prebuilt/linux-x86_64/bin/armv7a-linux-androideabi21-clang
ANDROID_CC_ARM64 := $(NDK_HOME)/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android21-clang
ANDROID_CC_X86_64 := $(NDK_HOME)/toolchains/llvm/prebuilt/linux-x86_64/bin/x86_64-linux-android21-clang

.PHONY: all proto shared_linux shared_android shared_plugin clean test test_go test_dart test_cpp test_rust test_plugin test_plugin_race run ffigen benchmark build_server build_plugin_host

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

proto: build_plugin
	@echo "Generating proto code..."
	mkdir -p pkg/api
	protoc -Iapi -I/usr/include \
		--go_out=./pkg/api --go_opt=paths=source_relative \
		--go-grpc_out=./pkg/api --go-grpc_opt=paths=source_relative \
		core.proto
	protoc -Iapi -I/usr/include \
		--dart_out=grpc:lib/src/generated \
		core.proto
	protoc -Iapi -I/usr/include \
		--plugin=protoc-gen-synurang-ffi=./bin/protoc-gen-synurang-ffi \
		--synurang-ffi_out=./pkg/api --synurang-ffi_opt=lang=go \
		core.proto
	protoc -Iapi -I/usr/include \
		--plugin=protoc-gen-synurang-ffi=./bin/protoc-gen-synurang-ffi \
		--synurang-ffi_out=./lib/src/generated --synurang-ffi_opt=lang=dart \
		core.proto

	@echo "Generating example proto code..."
	mkdir -p example/pkg/api
	mkdir -p example/lib/src/generated
	protoc -Iexample/api -Iapi -I/usr/include \
		--go_out=./example/pkg/api --go_opt=paths=source_relative \
		--go-grpc_out=./example/pkg/api --go-grpc_opt=paths=source_relative \
		example.proto
	# Generate core.proto for example Dart (needed for cross-proto imports)
	protoc -Iapi -I/usr/include \
		--dart_out=grpc:example/lib/src/generated \
		core.proto
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

run_android_release: shared_android
	@echo "Linking shared libraries to example app..."
	mkdir -p example/android/app/src/main/jniLibs/arm64-v8a
	mkdir -p example/android/app/src/main/jniLibs/armeabi-v7a
	mkdir -p example/android/app/src/main/jniLibs/x86_64
	ln -sf $(CURRENT_DIR)/src/libsynurang-android-arm64.so example/android/app/src/main/jniLibs/arm64-v8a/libsynurang.so
	ln -sf $(CURRENT_DIR)/src/libsynurang-android-arm.so example/android/app/src/main/jniLibs/armeabi-v7a/libsynurang.so
	ln -sf $(CURRENT_DIR)/src/libsynurang-android-x86_64.so example/android/app/src/main/jniLibs/x86_64/libsynurang.so
	@DEVICE_ID=$$(flutter devices | grep "android" | head -n 1 | awk -F "•" '{print $$2}' | xargs); \
	if [ -z "$$DEVICE_ID" ]; then echo "No Android device found"; exit 1; fi; \
	echo "Using Android device: $$DEVICE_ID"; \
	cd example && flutter run -d $$DEVICE_ID --release

run_android_debug: shared_android
	@echo "Linking shared libraries to example app..."
	mkdir -p example/android/app/src/main/jniLibs/arm64-v8a
	mkdir -p example/android/app/src/main/jniLibs/armeabi-v7a
	mkdir -p example/android/app/src/main/jniLibs/x86_64
	ln -sf $(CURRENT_DIR)/src/libsynurang-android-arm64.so example/android/app/src/main/jniLibs/arm64-v8a/libsynurang.so
	ln -sf $(CURRENT_DIR)/src/libsynurang-android-arm.so example/android/app/src/main/jniLibs/armeabi-v7a/libsynurang.so
	ln -sf $(CURRENT_DIR)/src/libsynurang-android-x86_64.so example/android/app/src/main/jniLibs/x86_64/libsynurang.so
	@DEVICE_ID=$$(flutter devices | grep "android" | head -n 1 | awk -F "•" '{print $$2}' | xargs); \
	if [ -z "$$DEVICE_ID" ]; then echo "No Android device found"; exit 1; fi; \
	echo "Using Android device: $$DEVICE_ID"; \
	cd example && flutter run -d $$DEVICE_ID --debug

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

# Run all tests (Go + Dart + C++ + Rust + Plugin)
test: test_go test_dart test_cpp test_rust test_plugin
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

# Rust FFI Integration tests (Mock Backend)
test_rust_ffi:
	@echo "Running Rust FFI Integration tests..."
	cd test/rust_ffi && cargo build --release
	flutter pub get
	LD_LIBRARY_PATH=$(CURRENT_DIR)/test/rust_ffi/target/release:${LD_LIBRARY_PATH} dart test test/rust_ffi/rust_integration_test.dart
	@echo "Rust FFI Integration tests complete."

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

# Run console example with TCP (spawns separate Go server process)
run_console_tcp: build_example_server
	@echo "Running console example (TCP mode - bidirectional gRPC)..."
	flutter pub get
	dart run example/console_main.dart --mode=tcp --golang-port=18000 --flutter-port=10050 --server=$(CURRENT_DIR)/bin/synurang_example_server

# Run console example with UDS (spawns separate Go server process)
run_console_uds: build_example_server
	@echo "Running console example (UDS mode - bidirectional gRPC)..."
	flutter pub get
	dart run example/console_main.dart --mode=uds --golang-socket=/tmp/synurang_go.sock --flutter-socket=/tmp/synurang_flutter.sock --server=$(CURRENT_DIR)/bin/synurang_example_server

# Build standalone example server binary
build_example_server:
	@echo "Building standalone example server..."
	@mkdir -p bin
	go build -o bin/synurang_example_server example/cmd/server/main.go
	@echo "Built: bin/synurang_example_server"

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

# Test Flutter server via transport CLI (TCP)
test_flutter_tcp:
	@echo "⚠️  Ensure Flutter example is running (linux/android) and listening on port 10050"
	@echo "Testing Flutter server via TCP..."
	go run example/cmd/client/main.go --target=flutter --transport=tcp --addr=localhost:10050 --token=demo-token

# Test Flutter server via transport CLI (UDS)
test_flutter_uds:
	@echo "⚠️  Ensure Flutter example is running (linux) and listening on /tmp/flutter_view.sock"
	@echo "Testing Flutter server via UDS..."
	go run example/cmd/client/main.go --target=flutter --transport=uds --socket=/tmp/flutter_view.sock --token=demo-token

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
	@echo "  all            - Build proto and Linux shared library"
	@echo "  shared_linux   - Build Linux amd64 shared library"
	@echo "  shared_android - Build Android ARM/ARM64/x86_64 shared libraries"
	@echo "  shared_plugin  - Build plugin shared library (test/plugin/impl/plugin.so)"
	@echo "  proto          - Generate Go and Dart proto code (includes test/plugin)"
	@echo ""
	@echo "Test Targets:"
	@echo "  test           - Run all tests (Go + Dart + C++ + Rust + Plugin)"
	@echo "  test_go        - Run Go tests only"
	@echo "  test_dart      - Run Dart tests only"
	@echo "  test_plugin    - Run plugin FFI tests (Go-to-Go via shared library)"
	@echo "  test_plugin_race - Run plugin FFI tests with race detector"
	@echo "  test_quick     - Run Go tests (no verbose)"
	@echo ""
	@echo "Development:"
	@echo "  run            - Run standalone Go server"
	@echo "  run_example    - Run Dart example app"
	@echo "  ffigen         - Generate FFI bindings"
	@echo "  pub_get        - Get Flutter dependencies"
	@echo "  clean          - Remove generated files"
	@echo ""
	@echo "Example:"
	@echo "  make shared_linux test_go run_example"
	@echo "  make test_plugin  # Test plugin FFI"

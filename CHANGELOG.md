## 0.7.0

*   **Canonical Rust generator**: Replaced the Go code-generator implementation and the temporary `protoc-gen-synurang-ffi-rs` binary with one Rust-based `protoc-gen-synurang-ffi`. Output selection is unchanged, including `lang=go` and the existing default Go/Dart generation behavior.
*   **Python 3.10+ neutral clients and codegen**: Added dependency-free proto3 protobuf-lite messages, a neutral `RpcTransport`, `FfiTransport` over the `ctypes` plugin host, and an optional synchronous `GrpcTransport` for remote servers. The same generated `*Client` API supports all four RPC cardinalities over either transport, while `*Ffi(host)` remains compatible. `mode=lite` emits only messages; neither `google.protobuf` nor `protoc --python_out` is required. Python 2 is not supported.
*   **Generator release packaging**: Added a version-pinned Docker release build for static Linux x86-64/AArch64 and Windows x86-64 binaries, reproducible archives, `SHA256SUMS`, and Make targets for publishing the assets to GitHub Releases.
*   **Generator regression coverage**: Consolidated language/mode generation and option validation around the canonical Rust binary, including Python generation and rejection of unsupported Python 2 output.

## 0.6.2

*   **Dart core recovery**: Added `StartGrpcServerOptions`, `CoreState`, `CoreRecoveryResult`, `recoverCoreAsync`, `getCoreState`, and `resetCoreState` so apps can explicitly recover the embedded native core after an FFI timeout by resetting Dart helper isolates and issuing native `Stop` / `Start` calls.
*   **Timeout and shutdown handling**: Per-call FFI timeouts now mark the core unhealthy, fail pending requests, close active server/plugin streams, and gate new RPCs with `CoreUnavailableException` or `CoreRestartRequiredException`. `FfiClientChannel` maps these recovery errors to gRPC `unavailable`.
*   **Recovery test coverage**: Added a debug-only `HangFor` RPC plus recovery tests covering core state transitions, concurrent `recoverCoreAsync` callers, lifecycle calls while unhealthy, pending request cleanup, stream cleanup, and `restartRequired` behavior.
*   **Rust generator implementation**: Added `protoc-gen-synurang-ffi-rs`, a Rust/prost reimplementation of `protoc-gen-synurang-ffi`, with make targets and parity tests that compare generated output, flag validation, and benchmark runs against the Go generator.

## 0.6.1

*   **C++ Lite support**: Added a zero-dependency C++11 header-only runtime (`cpp/synurang_lite.hpp`) and `lang=cpp,mode=lite` code generation for protobuf messages and FFI service stubs.
*   **C++ Lite protobuf coverage**: Generated lite headers now cover imported lite headers, well-known types, maps, repeated and packed fields, optional fields, oneofs, and streaming service helpers without requiring libprotobuf or gRPC.
*   **C++ generation tests**: Expanded C++ generator tests to validate lite header generation for core/cache/native protos and syntax-check the generated headers with `g++`.

## 0.6.0

*   **Swift Lite support**: Added zero-dependency Swift runtime packaging, Swift code generation, ProtoLite encoding/decoding, well-known type support, plugin host/stream APIs, and Swift generator/integration/stress tests.
*   **TypeScript support**: Added TypeScript Lite schema/code generation and TypeScript FFI client generation, with generator coverage for enums, services, streaming methods, and well-known types.
*   **Plugin cancellation callbacks**: Added `on_cancel` support for Rust and C++ plugin servers with regression tests covering cancellation callback behavior.

## 0.5.10

*   **C# Lite and stream worker fixes**: Added C# Lite support for .NET 4.0, fixed `internal` visibility and `repeated int32` code generation issues, and stabilized plugin stream scheduling with a dedicated worker plus regression tests.

## 0.5.6

*   **Concurrency and packaging fixes**: Hardened plugin host/stream teardown across hosts, improved Android debug AAR packaging, and added Java/Rust host test coverage.

## 0.5.5

*   **TypeScript codegen**: Added lightweight TypeScript schema constants for enums, field numbers, and full gRPC method paths, with generator coverage tests.

## 0.5.4

*   **Structured FFI errors**: Replaced `PluginError` with `FfiError` carrying `code`, `message`, and `grpc_code` fields across all 6 languages (Go, Dart, C++, Rust, Java, C#).
*   **New wire format**: Unary uses `resp_len < 0` for errors (payload is serialized `core.v1.Error`); stream uses `status < 0`. Removes the old status-byte prefix overhead.
*   **Plugin stream interfaces**: Go plugin server codegen now emits minimal `PluginStream` interfaces instead of `grpc.ServerStream`, removing the `google.golang.org/grpc/metadata` dependency from plugin code.
*   **gRPC status extraction**: New `pkg/ffierror` package extracts structured errors from gRPC status details via reflection, avoiding a hard gRPC dependency.

## 0.5.0

*   **WASM & Rust native**: Added WASM and Rust native support.
*   **ActiveX**: Added ActiveX support.

## 0.4.0

*   **C# support**: Added full support for C# via pure managed interop (NativeLibrary + Marshal).
*   **Pull-based C ABI**: Dart plugin host with pull-based C ABI support for streaming.

## 0.3.0

*   **FFI without gRPC dependency**: FFI transport layer no longer requires gRPC as a dependency.
*   **Android/Java support**: Added full support for Android and Java via JNI.
*   **Process Mode improvements**: Enhanced process mode functionality.

## 0.2.0

*   **Process Mode**: Support for parent-child IPC via socketpair (Unix) and Named Pipes (Windows).
*   **Multi-language Support**: Full support for C++ and Rust (including streaming) via FFI and Process Mode.

## 0.1.9

*   In-process microservice (FFI + shared library).
*   Apply template.

## 0.1.8

*   Add runtime library and Go-to-Go FFI support.

## 0.1.7

*   Add support for Android, iOS, macOS, and Windows platforms in pubspec.yaml and project structure.

## 0.1.6

*   Fix: `protoc-gen-synurang-ffi` now correctly maps `google/protobuf/` imports to `package:protobuf/well_known_types/`.
*   Fix: Correct Go/Dart module paths in example code and proto definitions + dart_package option

## 0.1.5

*   Include Dart generated files in the package.

## 0.1.4

*   Fix internal import paths to use GitHub module path.

## 0.1.3

*   Include generated Go code for remote usage.

## 0.1.2

*   Fix go.mod configuration.

## 0.1.1

*   Fix link in documentation.

## 0.1.0

*   Initial release of `synurang`, a Flutter FFI + gRPC bridge for bidirectional Go/Dart communication.

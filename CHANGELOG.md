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

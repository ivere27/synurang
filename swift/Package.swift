// swift-tools-version:5.9
//
// Synurang Swift Package — protobuf codecs and native module clients.
//
// SynurangLite provides:
//   - ProtoLite (zero-dependency protobuf wire encoder/decoder)
//   - ModuleHost + ModuleClient for the unified nonblocking call ABI
//   - ModuleResponses / ModuleDuplex for demand-driven async streaming
//   - PluginHost (actor) + PluginStream (actor) for loading and talking
//     to Synurang FFI plugins (Go/C++/Rust shared libraries) via dlopen.
//   - BidiStream<Req, Resp> for typed bidirectional streaming RPCs.
//
// Zero external dependencies: no SwiftProtobuf, no grpc-swift, no Foundation
// extras. Suitable for shipping in XCFrameworks alongside a Rust core that
// exports the Synurang C ABI.
//
// Generated code (output of protoc-gen-synurang-ffi --lang=swift --mode=lite)
// imports this module and produces struct-based messages + actor-based
// service stubs.

import PackageDescription

let package = Package(
    name: "Synurang",
    platforms: [
        .iOS(.v13),
        .macOS(.v10_15),
        .tvOS(.v13),
        .watchOS(.v6),
    ],
    products: [
        .library(name: "SynurangLite", targets: ["SynurangLite"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "SynurangLite",
            dependencies: [],
            path: "Sources/SynurangLite"
        ),
        .testTarget(
            name: "SynurangLiteTests",
            dependencies: ["SynurangLite"],
            path: "Tests/SynurangLiteTests"
        ),
    ]
)

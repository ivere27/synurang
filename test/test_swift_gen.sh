#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."
BIN_DIR="$ROOT_DIR/bin"
PLUGIN="$BIN_DIR/protoc-gen-synurang-ffi"
OUT_DIR="$ROOT_DIR/test/generated_swift"
PROTO_DIR="$OUT_DIR/protos"
SRC_DIR="$OUT_DIR/Sources/GeneratedSwiftFixtures"
TEST_DIR="$OUT_DIR/Tests/GeneratedSwiftFixturesTests"
SWIFT_DOCKER_IMAGE="${SWIFT_DOCKER_IMAGE:-swift:5.9}"

assert_contains() {
    local file="$1"
    local pattern="$2"
    local message="$3"
    if ! grep -q "$pattern" "$file"; then
        echo "Error: $message"
        exit 1
    fi
}

rm -rf "$OUT_DIR"
mkdir -p "$BIN_DIR" "$PROTO_DIR" "$SRC_DIR" "$TEST_DIR"

echo "Building protoc-gen-synurang-ffi..."
cd "$ROOT_DIR"
go build -o "$PLUGIN" ./cmd/protoc-gen-synurang-ffi

cat > "$PROTO_DIR/swift_core.proto" <<'EOF'
syntax = "proto3";
package swift.coverage.core;
option go_package = "github.com/ivere27/synurang/test/generated/swift/core;swiftcore";

message Error {
  int32 code = 1;
  string message = 2;
  int32 grpc_code = 3;
}

message SharedPayload {
  string label = 1;
}
EOF

cat > "$PROTO_DIR/swift_coverage.proto" <<'EOF'
syntax = "proto3";
package swift.coverage.v1;
option go_package = "github.com/ivere27/synurang/test/generated/swift/coverage;swiftcoverage";

import "google/protobuf/empty.proto";
import "google/protobuf/timestamp.proto";
import "google/protobuf/wrappers.proto";
import "swift_core.proto";

enum ValueKind {
  VALUE_KIND_UNSPECIFIED = 0;
  VALUE_KIND_ALPHA = 1;
  VALUE_KIND_BETA = 2;
}

message Child {
  string label = 1;
}

message KeywordMessage {
  string class = 1;
  string self = 2;
}

message CoverageRequest {
  optional string note = 1;
  repeated int32 ids = 2;
  repeated sint32 zigzag = 3;
  repeated fixed64 fixeds = 4;
  map<string, sint32> scores = 5;
  oneof selector {
    string name = 6;
    int64 id = 7;
    Child child = 8;
  }
  ValueKind kind = 9;
  google.protobuf.Timestamp timestamp = 10;
  google.protobuf.Int32Value wrapped = 11;
  swift.coverage.core.Error error = 12;
  bytes raw = 13;
  KeywordMessage keywords = 14;
  swift.coverage.core.SharedPayload shared = 15;
}

message CoverageResponse {
  repeated ValueKind kinds = 1;
  map<int32, Child> children = 2;
  google.protobuf.Empty empty = 3;
}

service CoverageService {
  rpc Unary(CoverageRequest) returns (CoverageResponse);
  rpc Server(CoverageRequest) returns (stream CoverageResponse);
  rpc Client(stream CoverageRequest) returns (CoverageResponse);
  rpc Bidi(stream CoverageRequest) returns (stream CoverageResponse);
}
EOF

echo "Generating Swift lite fixtures..."
protoc -I"$PROTO_DIR" -I/usr/include \
    --experimental_allow_proto3_optional \
    --plugin=protoc-gen-synurang-ffi="$PLUGIN" \
    --synurang-ffi_out="$SRC_DIR" \
    --synurang-ffi_opt=lang=swift,mode=lite \
    swift_core.proto swift_coverage.proto

CORE_SWIFT="$SRC_DIR/swift_core_lite.swift"
COVERAGE_SWIFT="$SRC_DIR/swift_coverage_lite.swift"

if [ ! -f "$CORE_SWIFT" ] || [ ! -f "$COVERAGE_SWIFT" ]; then
    echo "Error: Swift lite files were not generated"
    exit 1
fi

assert_contains "$CORE_SWIFT" 'public struct Error' "swift_core_lite.swift missing generated Error message"
assert_contains "$COVERAGE_SWIFT" 'AsyncThrowingStream<CoverageResponse, Swift.Error>' "streaming stubs must use Swift.Error"
assert_contains "$COVERAGE_SWIFT" 'public var `class`' "Swift keyword field was not escaped"
assert_contains "$COVERAGE_SWIFT" 'public var scores: \[String: Int32\]' "map field was not generated as Swift Dictionary"
assert_contains "$COVERAGE_SWIFT" 'public enum CoverageRequestSelectorOneof' "oneof enum was not generated"

cat > "$OUT_DIR/Package.swift" <<'EOF'
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GeneratedSwiftFixtures",
    platforms: [
        .iOS(.v13),
        .macOS(.v10_15),
    ],
    products: [
        .library(name: "GeneratedSwiftFixtures", targets: ["GeneratedSwiftFixtures"]),
    ],
    dependencies: [
        .package(path: "../../swift"),
    ],
    targets: [
        .target(
            name: "GeneratedSwiftFixtures",
            dependencies: [
                .product(name: "SynurangLite", package: "swift"),
            ]
        ),
        .testTarget(
            name: "GeneratedSwiftFixturesTests",
            dependencies: [
                "GeneratedSwiftFixtures",
                .product(name: "SynurangLite", package: "swift"),
            ]
        ),
    ]
)
EOF

cat > "$TEST_DIR/GeneratedSwiftFixturesTests.swift" <<'EOF'
import Foundation
import SynurangLite
import XCTest
@testable import GeneratedSwiftFixtures

final class GeneratedSwiftFixturesTests: XCTestCase {

    func testGeneratedMessagesRoundTripRichSchema() throws {
        var req = CoverageRequest()
        req.note = "present"
        req.ids = [1, -2, 300]
        req.zigzag = [-1, 0, 2]
        req.fixeds = [1, UInt64.max]
        req.scores = ["alpha": 11, "beta": -7, "": 0]
        var child = Child()
        child.label = "nested"
        req.selector = .child(child)
        req.kind = .alpha
        req.timestamp = Timestamp(seconds: 123, nanos: 456)
        req.wrapped = Int32Value(42)
        var err = Error()
        err.code = 7
        err.message = "boom"
        err.grpcCode = 13
        req.error = err
        req.raw = Data([0x00, 0x7F, 0xFF])

        var keywords = KeywordMessage()
        keywords.`class` = "reserved-class"
        keywords.`self` = "reserved-self"
        req.keywords = keywords
        var shared = SharedPayload()
        shared.label = "from-import"
        req.shared = shared

        let bytes = try req.serializedData()
        let back = try CoverageRequest(serializedBytes: bytes)

        XCTAssertEqual(back.note, "present")
        XCTAssertEqual(back.ids, [1, -2, 300])
        XCTAssertEqual(back.zigzag, [-1, 0, 2])
        XCTAssertEqual(back.fixeds, [1, UInt64.max])
        XCTAssertEqual(back.scores["alpha"], 11)
        XCTAssertEqual(back.scores["beta"], -7)
        XCTAssertEqual(back.scores[""], 0)
        XCTAssertEqual(back.kind, .alpha)
        XCTAssertEqual(back.timestamp?.seconds, 123)
        XCTAssertEqual(back.timestamp?.nanos, 456)
        XCTAssertEqual(back.wrapped?.value, 42)
        XCTAssertEqual(back.error?.code, 7)
        XCTAssertEqual(back.error?.message, "boom")
        XCTAssertEqual(back.error?.grpcCode, 13)
        XCTAssertEqual(back.raw, Data([0x00, 0x7F, 0xFF]))
        XCTAssertEqual(back.keywords?.`class`, "reserved-class")
        XCTAssertEqual(back.keywords?.`self`, "reserved-self")
        XCTAssertEqual(back.shared?.label, "from-import")

        switch back.selector {
        case .child(let child):
            XCTAssertEqual(child.label, "nested")
        default:
            XCTFail("expected child oneof case")
        }
    }

    func testGeneratedResponseRoundTripMapsEnumsAndWkt() throws {
        var response = CoverageResponse()
        response.kinds = [.unspecified, .alpha, .beta]
        response.children = [
            1: {
                var child = Child()
                child.label = "one"
                return child
            }(),
            -2: {
                var child = Child()
                child.label = "minus-two"
                return child
            }(),
        ]
        response.empty = Empty()

        let bytes = try response.serializedData()
        let back = try CoverageResponse(serializedBytes: bytes)

        XCTAssertEqual(back.kinds, [.unspecified, .alpha, .beta])
        XCTAssertEqual(back.children[1]?.label, "one")
        XCTAssertEqual(back.children[-2]?.label, "minus-two")
        XCTAssertNotNil(back.empty)
    }

    func testGeneratedServiceStreamingSignatureUsesSwiftError() throws {
        let _: (CoverageServiceFfiLite, CoverageRequest) async throws -> AsyncThrowingStream<CoverageResponse, Swift.Error> = {
            client, request in
            try await client.server(request)
        }
    }
}
EOF

echo "Running generated Swift fixture tests..."
if command -v swift >/dev/null 2>&1; then
    (cd "$OUT_DIR" && swift test)
else
    docker run --rm \
        -u "$(id -u):$(id -g)" \
        -e HOME=/tmp \
        -v "$ROOT_DIR":/work \
        -w /work/test/generated_swift \
        "$SWIFT_DOCKER_IMAGE" swift test
fi

echo "Swift generation test passed."

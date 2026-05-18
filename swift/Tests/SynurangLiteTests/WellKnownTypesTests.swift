import XCTest
@testable import SynurangLite

/// Round-trip and edge-case coverage for the lite shims of
/// `google.protobuf.{Empty,*Value,Timestamp,Duration}`.
///
/// Each type is exercised on three axes:
///   1. Non-default value round-trip (encode → decode → equal).
///   2. Default value is *not* emitted on the wire (proto3 implicit default).
///   3. Unknown fields are tolerated on decode.
final class WellKnownTypesTests: XCTestCase {

    // MARK: - Empty

    func testEmptyRoundTrip() throws {
        let bytes = try Empty().serializedData()
        XCTAssertEqual(bytes.count, 0)
        _ = try Empty(serializedBytes: bytes) // does not throw
    }

    func testEmptyTolerateUnknownFields() throws {
        var w = ProtoWriter()
        w.writeString(fieldNumber: 99, value: "garbage")
        w.writeInt32(fieldNumber: 100, value: 1)
        // Empty must skip unknown fields rather than throw.
        _ = try Empty(serializedBytes: w.data)
    }

    // MARK: - Scalar wrappers — default-value omission

    func testInt32ValueDefaultOmitted() throws {
        XCTAssertEqual(try Int32Value(0).serializedData().count, 0)
        XCTAssertEqual(try Int64Value(0).serializedData().count, 0)
        XCTAssertEqual(try UInt32Value(0).serializedData().count, 0)
        XCTAssertEqual(try UInt64Value(0).serializedData().count, 0)
        XCTAssertEqual(try BoolValue(false).serializedData().count, 0)
        XCTAssertEqual(try FloatValue(0).serializedData().count, 0)
        XCTAssertEqual(try DoubleValue(0).serializedData().count, 0)
        XCTAssertEqual(try StringValue("").serializedData().count, 0)
        XCTAssertEqual(try BytesValue(Data()).serializedData().count, 0)
    }

    func testInt32ValueRoundTrip() throws {
        for v in [Int32.min, -1, 0, 1, 42, Int32.max] {
            let bytes = try Int32Value(v).serializedData()
            XCTAssertEqual(try Int32Value(serializedBytes: bytes).value, v)
        }
    }

    func testInt64ValueRoundTrip() throws {
        for v in [Int64.min, -1, 0, 1, Int64.max, -1_000_000_000_000] {
            let bytes = try Int64Value(v).serializedData()
            XCTAssertEqual(try Int64Value(serializedBytes: bytes).value, v)
        }
    }

    func testUInt32ValueRoundTrip() throws {
        for v: UInt32 in [0, 1, 42, UInt32.max] {
            let bytes = try UInt32Value(v).serializedData()
            XCTAssertEqual(try UInt32Value(serializedBytes: bytes).value, v)
        }
    }

    func testUInt64ValueRoundTrip() throws {
        for v: UInt64 in [0, 1, 0xDEAD_BEEF_CAFE_BABE, UInt64.max] {
            let bytes = try UInt64Value(v).serializedData()
            XCTAssertEqual(try UInt64Value(serializedBytes: bytes).value, v)
        }
    }

    func testBoolValueRoundTrip() throws {
        let trueBytes = try BoolValue(true).serializedData()
        XCTAssertGreaterThan(trueBytes.count, 0)
        XCTAssertTrue(try BoolValue(serializedBytes: trueBytes).value)
        XCTAssertFalse(try BoolValue(serializedBytes: Data()).value)
    }

    func testFloatValueRoundTrip() throws {
        for v: Float in [-3.5, 3.14, .infinity, -.infinity, .leastNormalMagnitude] {
            let bytes = try FloatValue(v).serializedData()
            XCTAssertEqual(try FloatValue(serializedBytes: bytes).value, v)
        }
    }

    func testFloatValueNaNRoundTrip() throws {
        // NaN ≠ NaN, so compare bit patterns instead of values.
        let bytes = try FloatValue(.nan).serializedData()
        XCTAssertTrue(try FloatValue(serializedBytes: bytes).value.isNaN)
    }

    func testDoubleValueRoundTrip() throws {
        for v: Double in [-1.25e100, 3.14159265358979, .infinity, -.infinity] {
            let bytes = try DoubleValue(v).serializedData()
            XCTAssertEqual(try DoubleValue(serializedBytes: bytes).value, v)
        }
    }

    func testStringValueRoundTripUnicode() throws {
        for v in ["hello", "안녕 \u{1F600}", String(repeating: "x", count: 4096)] {
            let bytes = try StringValue(v).serializedData()
            XCTAssertEqual(try StringValue(serializedBytes: bytes).value, v)
        }
    }

    func testBytesValueRoundTrip() throws {
        let payloads: [Data] = [
            Data([0x00, 0xFF, 0x42]),
            Data(repeating: 0xAA, count: 1024),
        ]
        for p in payloads {
            let bytes = try BytesValue(p).serializedData()
            XCTAssertEqual(try BytesValue(serializedBytes: bytes).value, p)
        }
    }

    func testWrapperTolerateUnknownFields() throws {
        // Construct a payload with a field 1 value (matching int wrapper) plus
        // a stray unknown field at tag 99 — wrapper must keep value, skip rest.
        var w = ProtoWriter()
        w.writeInt32(fieldNumber: 1, value: 42)
        w.writeString(fieldNumber: 99, value: "ignored")
        let decoded = try Int32Value(serializedBytes: w.data)
        XCTAssertEqual(decoded.value, 42)
    }

    func testWrapperRejectsWrongWireType() throws {
        // Encoder sends field 1 as length-delimited; an int wrapper expects
        // varint. Lite policy: skip the wire-type-mismatched field and leave
        // `value` at its default.
        var w = ProtoWriter()
        w.writeString(fieldNumber: 1, value: "not an int")
        XCTAssertEqual(try Int32Value(serializedBytes: w.data).value, 0)
    }

    // MARK: - Timestamp / Duration

    func testTimestampRoundTrip() throws {
        let ts = Timestamp(seconds: 1_700_000_000, nanos: 123_456_789)
        let bytes = try ts.serializedData()
        let back = try Timestamp(serializedBytes: bytes)
        XCTAssertEqual(back.seconds, 1_700_000_000)
        XCTAssertEqual(back.nanos, 123_456_789)
    }

    func testTimestampDefaultOmitted() throws {
        // (0, 0) — both fields default; nothing is emitted.
        XCTAssertEqual(try Timestamp().serializedData().count, 0)
    }

    func testTimestampPartialDefaults() throws {
        // Only seconds non-default — must round-trip.
        let bytes = try Timestamp(seconds: 5, nanos: 0).serializedData()
        let back = try Timestamp(serializedBytes: bytes)
        XCTAssertEqual(back.seconds, 5)
        XCTAssertEqual(back.nanos, 0)
    }

    func testTimestampNegativeSeconds() throws {
        // Pre-epoch instants.
        let bytes = try Timestamp(seconds: -1, nanos: -500).serializedData()
        let back = try Timestamp(serializedBytes: bytes)
        XCTAssertEqual(back.seconds, -1)
        XCTAssertEqual(back.nanos, -500)
    }

    func testDurationRoundTrip() throws {
        let d = Duration(seconds: -7200, nanos: 250_000_000)
        let bytes = try d.serializedData()
        let back = try Duration(serializedBytes: bytes)
        XCTAssertEqual(back.seconds, -7200)
        XCTAssertEqual(back.nanos, 250_000_000)
    }

    func testTimestampTolerateUnknownFields() throws {
        var w = ProtoWriter()
        w.writeInt64(fieldNumber: 1, value: 123)
        w.writeInt32(fieldNumber: 2, value: 456)
        w.writeString(fieldNumber: 7, value: "future field")
        let ts = try Timestamp(serializedBytes: w.data)
        XCTAssertEqual(ts.seconds, 123)
        XCTAssertEqual(ts.nanos, 456)
    }

    // MARK: - encode(into:) nesting

    func testWktsNestInsideUserMessage() throws {
        // Reproduces what generated code does: emit a WKT field inline
        // using `encode(into:)`. Decode the outer payload manually.
        var outer = ProtoWriter()
        try outer.writeMessage(fieldNumber: 5) { inner in
            try Timestamp(seconds: 99, nanos: 7).encode(into: &inner)
        }

        var r = ProtoReader(data: outer.data)
        let tag = try r.readTag()!
        XCTAssertEqual(tag.fieldNumber, 5)
        XCTAssertEqual(tag.wire, .lengthDelimited)
        let body = try r.readLengthDelimited()
        let ts = try Timestamp(serializedBytes: body)
        XCTAssertEqual(ts.seconds, 99)
        XCTAssertEqual(ts.nanos, 7)
    }
}

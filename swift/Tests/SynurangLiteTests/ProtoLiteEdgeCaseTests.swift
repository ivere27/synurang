import XCTest
@testable import SynurangLite

/// Edge-case tests for `ProtoReader` / `ProtoWriter`. The happy-path coverage
/// lives in `ProtoLiteTests`; this file is the protocol-conformance and
/// malformed-input sweep that mirrors what the .NET and Java suites cover.
final class ProtoLiteEdgeCaseTests: XCTestCase {

    // MARK: - Negative int32 / int64 varint width

    func testNegativeInt32IsSignExtendedToTenBytes() {
        // Proto spec: a negative int32 must be sign-extended to int64 before
        // varint encoding (10 bytes on the wire). Spot-check the byte length.
        var w = ProtoWriter()
        w.writeInt32(fieldNumber: 1, value: -1)
        // 1 tag byte + 10 varint bytes = 11.
        XCTAssertEqual(w.data.count, 11)

        // Round-trip.
        var r = ProtoReader(data: w.data)
        _ = try? r.readTag()
        XCTAssertEqual(try? r.readInt32(), -1)
    }

    func testNegativeInt64TenByteVarint() {
        var w = ProtoWriter()
        w.writeInt64(fieldNumber: 1, value: Int64.min)
        XCTAssertEqual(w.data.count, 11)
        var r = ProtoReader(data: w.data)
        _ = try? r.readTag()
        XCTAssertEqual(try? r.readInt64(), Int64.min)
    }

    // MARK: - Zigzag boundaries

    func testZigzagBoundary() throws {
        let values: [Int32] = [0, -1, 1, Int32.min, Int32.max]
        // Spot-check: ZZ encoding of -1 is varint 1 → 1 tag + 1 payload = 2 bytes.
        var w = ProtoWriter()
        w.writeSInt32(fieldNumber: 1, value: -1)
        XCTAssertEqual(w.data.count, 2)

        for v in values {
            var ww = ProtoWriter()
            ww.writeSInt32(fieldNumber: 7, value: v)
            var r = ProtoReader(data: ww.data)
            _ = try r.readTag()
            XCTAssertEqual(try r.readSInt32(), v, "sint32 \(v)")
        }
    }

    // MARK: - Float / Double special values

    func testFloatInfinityAndNaN() throws {
        var w = ProtoWriter()
        w.writeFloat(fieldNumber: 1, value: .infinity)
        w.writeFloat(fieldNumber: 2, value: -.infinity)
        w.writeFloat(fieldNumber: 3, value: .nan)

        var r = ProtoReader(data: w.data)
        _ = try r.readTag(); XCTAssertEqual(try r.readFloat(), .infinity)
        _ = try r.readTag(); XCTAssertEqual(try r.readFloat(), -.infinity)
        _ = try r.readTag(); XCTAssertTrue(try r.readFloat().isNaN)
    }

    func testDoubleSpecial() throws {
        var w = ProtoWriter()
        w.writeDouble(fieldNumber: 1, value: .infinity)
        w.writeDouble(fieldNumber: 2, value: -0.0)
        w.writeDouble(fieldNumber: 3, value: .pi)

        var r = ProtoReader(data: w.data)
        _ = try r.readTag(); XCTAssertEqual(try r.readDouble(), .infinity)
        _ = try r.readTag()
        // -0.0 round-trips bit-exact: bitPattern check.
        let neg = try r.readDouble()
        XCTAssertEqual(neg.bitPattern, Double(-0.0).bitPattern)
        _ = try r.readTag(); XCTAssertEqual(try r.readDouble(), .pi)
    }

    // MARK: - Large payload

    func testLargeStringRoundTrip() throws {
        let big = String(repeating: "ABCD", count: 100_000) // 400KB
        var w = ProtoWriter()
        w.writeString(fieldNumber: 1, value: big)

        var r = ProtoReader(data: w.data)
        _ = try r.readTag()
        XCTAssertEqual(try r.readString(), big)
    }

    func testLargeBytesRoundTrip() throws {
        let big = Data(repeating: 0x5A, count: 1 << 20) // 1MB
        var w = ProtoWriter()
        w.writeBytes(fieldNumber: 1, value: big)

        var r = ProtoReader(data: w.data)
        _ = try r.readTag()
        XCTAssertEqual(try r.readBytes(), big)
    }

    // MARK: - Repeated (packed and unpacked)

    /// Packed varint: tag (length-delimited) + length + raw varints concatenated.
    func testPackedRepeatedVarintRoundTrip() throws {
        let values: [Int32] = [1, 2, 300, -1]
        var inner = ProtoWriter()
        for v in values {
            inner.writeVarint(UInt64(bitPattern: Int64(v)))
        }
        var outer = ProtoWriter()
        outer.writeLengthDelimited(fieldNumber: 4, data: inner.data)

        var r = ProtoReader(data: outer.data)
        let tag = try r.readTag()!
        XCTAssertEqual(tag.fieldNumber, 4)
        XCTAssertEqual(tag.wire, .lengthDelimited)
        let payload = try r.readLengthDelimited()
        var pr = ProtoReader(data: payload)
        var got: [Int32] = []
        while !pr.isEOF {
            got.append(try pr.readInt32())
        }
        XCTAssertEqual(got, values)
    }

    func testUnpackedRepeatedRoundTrip() throws {
        // Proto3 default for non-packed: one tag+value per entry.
        var w = ProtoWriter()
        for v: Int32 in [10, 20, 30] {
            w.writeInt32(fieldNumber: 2, value: v)
        }

        var r = ProtoReader(data: w.data)
        var got: [Int32] = []
        while let tag = try r.readTag() {
            XCTAssertEqual(tag.fieldNumber, 2)
            got.append(try r.readInt32())
        }
        XCTAssertEqual(got, [10, 20, 30])
    }

    // MARK: - Maps (manual entry shape)

    /// Reproduces what generated code emits for a `map<string, sint32>`:
    /// each entry is a length-delimited message containing key (tag 1) + value (tag 2).
    func testMapEntryEncodeDecode() throws {
        let entries: [(String, Int32)] = [("alpha", 1), ("beta", -2), ("", 0)]

        var outer = ProtoWriter()
        for (k, v) in entries {
            var entry = ProtoWriter()
            if !k.isEmpty { entry.writeString(fieldNumber: 1, value: k) }
            if v != 0 { entry.writeSInt32(fieldNumber: 2, value: v) }
            outer.writeLengthDelimited(fieldNumber: 9, data: entry.data)
        }

        var r = ProtoReader(data: outer.data)
        var decoded: [String: Int32] = [:]
        while let tag = try r.readTag() {
            XCTAssertEqual(tag.fieldNumber, 9)
            XCTAssertEqual(tag.wire, .lengthDelimited)
            let body = try r.readLengthDelimited()
            var br = ProtoReader(data: body)
            var k = ""
            var v: Int32 = 0
            while let t = try br.readTag() {
                switch t.fieldNumber {
                case 1: k = try br.readString()
                case 2: v = try br.readSInt32()
                default: try br.skip(wire: t.wire)
                }
            }
            decoded[k] = v
        }
        XCTAssertEqual(decoded["alpha"], 1)
        XCTAssertEqual(decoded["beta"], -2)
        XCTAssertEqual(decoded[""], 0)
    }

    // MARK: - Malformed inputs

    func testEmptyBufferEOF() throws {
        var r = ProtoReader(data: Data())
        XCTAssertTrue(r.isEOF)
        XCTAssertNil(try r.readTag())
    }

    func testVarintOverflow() {
        // 10 bytes all with high bit set ⇒ shift > 63 ⇒ malformedVarint.
        let bad = Data(repeating: 0xFF, count: 11)
        var r = ProtoReader(data: bad)
        XCTAssertThrowsError(try r.readVarint()) { err in
            guard let p = err as? ProtoReaderError else {
                return XCTFail("expected ProtoReaderError, got \(err)")
            }
            switch p {
            case .malformedVarint, .unexpectedEnd: break
            default: XCTFail("unexpected: \(p)")
            }
        }
    }

    func testInvalidWireType() {
        // Tag with wire type 6 (undefined). Field 1 << 3 | 6 = 0x0E.
        let bad = Data([0x0E])
        var r = ProtoReader(data: bad)
        XCTAssertThrowsError(try r.readTag())
    }

    func testGroupWireTypesRejected() {
        // Wire types 3 (startGroup) and 4 (endGroup) are not supported.
        let startGroup = Data([0x0B]) // field 1, wire 3
        var r = ProtoReader(data: startGroup)
        let tag = (try? r.readTag())!
        XCTAssertEqual(tag.wire, .startGroup)
        XCTAssertThrowsError(try r.skip(wire: tag.wire))
    }

    func testTruncatedFixed32() {
        // Tag for field 1 fixed32, then only 2 bytes (need 4).
        let bad = Data([0x0D, 0x01, 0x02])
        var r = ProtoReader(data: bad)
        _ = try? r.readTag()
        XCTAssertThrowsError(try r.readFixed32())
    }

    func testTruncatedFixed64() {
        let bad = Data([0x09, 0x01, 0x02, 0x03])
        var r = ProtoReader(data: bad)
        _ = try? r.readTag()
        XCTAssertThrowsError(try r.readFixed64())
    }

    func testInvalidUTF8String() {
        // Length-delimited with invalid UTF-8 bytes (lone continuation byte).
        var w = ProtoWriter()
        w.writeLengthDelimited(fieldNumber: 1, data: Data([0xC3, 0x28]))
        var r = ProtoReader(data: w.data)
        _ = try? r.readTag()
        XCTAssertThrowsError(try r.readString()) { err in
            XCTAssertTrue(err is ProtoReaderError)
        }
    }

    // MARK: - Skip cascade

    func testSkipMixedWireTypes() throws {
        var w = ProtoWriter()
        w.writeInt64(fieldNumber: 1, value: Int64.max)
        w.writeDouble(fieldNumber: 2, value: 1.5)
        w.writeString(fieldNumber: 3, value: "skip")
        w.writeFloat(fieldNumber: 4, value: 2.5)

        var r = ProtoReader(data: w.data)
        // Skip everything; we just want to assert it terminates cleanly at EOF.
        while let tag = try r.readTag() {
            try r.skip(wire: tag.wire)
        }
        XCTAssertTrue(r.isEOF)
    }

    // MARK: - FfiError edge cases

    func testFfiErrorRoundTripWithUnknownFields() {
        var w = ProtoWriter()
        w.writeInt32(fieldNumber: 1, value: 99)
        w.writeString(fieldNumber: 2, value: "boom")
        // Unknown field — must be skipped.
        w.writeString(fieldNumber: 99, value: "future")
        w.writeInt32(fieldNumber: 3, value: 14)
        let err = FfiError.fromPayload(w.data)
        XCTAssertEqual(err.code, 99)
        XCTAssertEqual(err.message, "boom")
        XCTAssertEqual(err.grpcCode, 14)
    }

    func testFfiErrorUTF8Fallback() {
        // Bare-UTF8 message (no proto framing).
        let raw = Data("plain text error".utf8)
        let err = FfiError.fromPayload(raw)
        // Decoder may parse a leading byte as a tag — message defaults to
        // UTF-8 fallback when field 2 is absent.
        XCTAssertFalse(err.message.isEmpty)
    }
}

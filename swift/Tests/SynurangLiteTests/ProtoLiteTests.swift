import XCTest
@testable import SynurangLite

final class ProtoLiteTests: XCTestCase {

    // MARK: - Varint round-trip

    func testVarintRoundTripSmall() throws {
        var w = ProtoWriter()
        w.writeVarint(0)
        w.writeVarint(1)
        w.writeVarint(127)
        w.writeVarint(128)
        w.writeVarint(300)
        w.writeVarint(UInt64.max)

        var r = ProtoReader(data: w.data)
        XCTAssertEqual(try r.readVarint(), 0)
        XCTAssertEqual(try r.readVarint(), 1)
        XCTAssertEqual(try r.readVarint(), 127)
        XCTAssertEqual(try r.readVarint(), 128)
        XCTAssertEqual(try r.readVarint(), 300)
        XCTAssertEqual(try r.readVarint(), UInt64.max)
        XCTAssertTrue(r.isEOF)
    }

    // MARK: - Scalar fields

    func testScalarFieldsRoundTrip() throws {
        var w = ProtoWriter()
        w.writeInt32(fieldNumber: 1, value: -7)
        w.writeInt64(fieldNumber: 2, value: -123456789012345)
        w.writeUInt32(fieldNumber: 3, value: 42)
        w.writeUInt64(fieldNumber: 4, value: 0xDEAD_BEEF_CAFE_BABE)
        w.writeBool(fieldNumber: 5, value: true)
        w.writeBool(fieldNumber: 6, value: false)
        w.writeFloat(fieldNumber: 7, value: 3.5)
        w.writeDouble(fieldNumber: 8, value: -1.25e100)
        w.writeString(fieldNumber: 9, value: "hello \u{1F600}")
        w.writeBytes(fieldNumber: 10, value: Data([0x00, 0xFF, 0x42]))

        var r = ProtoReader(data: w.data)

        var got: [Int: Any] = [:]
        while let tag = try r.readTag() {
            switch tag.fieldNumber {
            case 1: got[1] = try r.readInt32()
            case 2: got[2] = try r.readInt64()
            case 3: got[3] = try r.readUInt32()
            case 4: got[4] = try r.readUInt64()
            case 5, 6: got[tag.fieldNumber] = try r.readBool()
            case 7: got[7] = try r.readFloat()
            case 8: got[8] = try r.readDouble()
            case 9: got[9] = try r.readString()
            case 10: got[10] = try r.readBytes()
            default: try r.skip(wire: tag.wire)
            }
        }

        XCTAssertEqual(got[1] as? Int32, -7)
        XCTAssertEqual(got[2] as? Int64, -123456789012345)
        XCTAssertEqual(got[3] as? UInt32, 42)
        XCTAssertEqual(got[4] as? UInt64, 0xDEAD_BEEF_CAFE_BABE)
        XCTAssertEqual(got[5] as? Bool, true)
        XCTAssertEqual(got[6] as? Bool, false)
        XCTAssertEqual(got[7] as? Float, 3.5)
        XCTAssertEqual(got[8] as? Double, -1.25e100)
        XCTAssertEqual(got[9] as? String, "hello \u{1F600}")
        XCTAssertEqual(got[10] as? Data, Data([0x00, 0xFF, 0x42]))
    }

    // MARK: - sint zigzag

    func testZigzagRoundTrip() throws {
        let cases32: [Int32] = [0, -1, 1, -2, 2, Int32.min, Int32.max, 12345, -12345]
        for v in cases32 {
            var w = ProtoWriter()
            w.writeSInt32(fieldNumber: 1, value: v)
            var r = ProtoReader(data: w.data)
            let tag = try r.readTag()!
            XCTAssertEqual(tag.fieldNumber, 1)
            XCTAssertEqual(try r.readSInt32(), v)
        }

        let cases64: [Int64] = [0, -1, 1, Int64.min, Int64.max, -9_999_999_999]
        for v in cases64 {
            var w = ProtoWriter()
            w.writeSInt64(fieldNumber: 1, value: v)
            var r = ProtoReader(data: w.data)
            _ = try r.readTag()
            XCTAssertEqual(try r.readSInt64(), v)
        }
    }

    // MARK: - Fixed encoding

    func testFixedRoundTrip() throws {
        var w = ProtoWriter()
        w.writeFixed32(fieldNumber: 1, value: 0xCAFEBABE)
        w.writeFixed64(fieldNumber: 2, value: 0x0102_0304_0506_0708)
        w.writeSFixed32(fieldNumber: 3, value: -42)
        w.writeSFixed64(fieldNumber: 4, value: -42)

        var r = ProtoReader(data: w.data)
        _ = try r.readTag()
        XCTAssertEqual(try r.readFixed32(), 0xCAFEBABE)
        _ = try r.readTag()
        XCTAssertEqual(try r.readFixed64(), 0x0102_0304_0506_0708)
        _ = try r.readTag()
        XCTAssertEqual(try r.readSFixed32(), -42)
        _ = try r.readTag()
        XCTAssertEqual(try r.readSFixed64(), -42)
    }

    // MARK: - Skip

    func testSkipUnknownField() throws {
        var w = ProtoWriter()
        w.writeInt32(fieldNumber: 5, value: 99)
        w.writeString(fieldNumber: 6, value: "skip-me")
        w.writeFloat(fieldNumber: 7, value: 1.0)
        w.writeDouble(fieldNumber: 8, value: 2.0)

        var r = ProtoReader(data: w.data)
        var sawFive = false
        while let tag = try r.readTag() {
            if tag.fieldNumber == 5 {
                XCTAssertEqual(try r.readInt32(), 99)
                sawFive = true
            } else {
                try r.skip(wire: tag.wire)
            }
        }
        XCTAssertTrue(sawFive)
        XCTAssertTrue(r.isEOF)
    }

    // MARK: - Nested message

    func testWriteMessage() throws {
        var w = ProtoWriter()
        w.writeMessage(fieldNumber: 4) { inner in
            inner.writeString(fieldNumber: 1, value: "inside")
            inner.writeInt32(fieldNumber: 2, value: 7)
        }

        var r = ProtoReader(data: w.data)
        let tag = try r.readTag()!
        XCTAssertEqual(tag.fieldNumber, 4)
        XCTAssertEqual(tag.wire, .lengthDelimited)
        let body = try r.readLengthDelimited()

        var ir = ProtoReader(data: body)
        let t1 = try ir.readTag()!
        XCTAssertEqual(t1.fieldNumber, 1)
        XCTAssertEqual(try ir.readString(), "inside")
        let t2 = try ir.readTag()!
        XCTAssertEqual(t2.fieldNumber, 2)
        XCTAssertEqual(try ir.readInt32(), 7)
    }

    // MARK: - FfiError payload

    func testFfiErrorFromPayload() throws {
        var w = ProtoWriter()
        w.writeInt32(fieldNumber: 1, value: 42)
        w.writeString(fieldNumber: 2, value: "boom")
        w.writeInt32(fieldNumber: 3, value: 13)
        let err = FfiError.fromPayload(w.data)
        XCTAssertEqual(err.code, 42)
        XCTAssertEqual(err.message, "boom")
        XCTAssertEqual(err.grpcCode, 13)
    }

    func testFfiErrorEmptyPayload() throws {
        let err = FfiError.fromPayload(nil)
        XCTAssertEqual(err.code, 0)
        XCTAssertEqual(err.message, "")
    }

    func testFfiErrorFallbackToUTF8() throws {
        // Payload that doesn't look like a valid FfiError proto: a single
        // unknown-field varint. Decoder should fall back to UTF-8.
        let raw = Data([0x08, 0x01]) // field 1 varint = 1
        let err = FfiError.fromPayload(raw)
        // Field 1 varint == code; message comes from UTF-8 fallback.
        XCTAssertEqual(err.code, 1)
        // The raw payload as UTF-8 ("\u{08}\u{01}") is two control chars; we
        // only assert that *some* fallback message is set.
        XCTAssertFalse(err.message.isEmpty)
    }

    // MARK: - Truncated input

    func testTruncatedVarintThrows() {
        // Single byte with continuation bit set, then EOF.
        let truncated = Data([0x80])
        var r = ProtoReader(data: truncated)
        XCTAssertThrowsError(try r.readVarint())
    }

    func testTruncatedLengthDelimitedThrows() {
        // length=10, but only 2 bytes follow
        let bad = Data([0x0A, 0x01, 0x02])
        var r = ProtoReader(data: bad)
        XCTAssertThrowsError(try r.readLengthDelimited())
    }
}

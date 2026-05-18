import Foundation

/// Minimal protobuf writer. Mirrors the C# `ProtoWriter` API.
///
/// Buffers bytes in an in-memory `Data`; callers retrieve the final payload
/// via the `data` property. The writer is a `struct` so it can be passed by
/// inout to message-serialization closures (matches Go-template generated
/// code shape).
public struct ProtoWriter {
    public private(set) var data: Data

    public init() {
        self.data = Data()
    }

    public mutating func writeTag(fieldNumber: Int, wire: WireType) {
        let tag = (UInt64(fieldNumber) << 3) | UInt64(wire.rawValue)
        writeVarint(tag)
    }

    public mutating func writeVarint(_ value: UInt64) {
        var v = value
        while v >= 0x80 {
            data.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        data.append(UInt8(v))
    }

    public mutating func writeInt32(fieldNumber: Int, value: Int32) {
        writeTag(fieldNumber: fieldNumber, wire: .varint)
        // proto encodes negative int32 as 10-byte varint (sign-extended to int64)
        writeVarint(UInt64(bitPattern: Int64(value)))
    }

    public mutating func writeInt64(fieldNumber: Int, value: Int64) {
        writeTag(fieldNumber: fieldNumber, wire: .varint)
        writeVarint(UInt64(bitPattern: value))
    }

    public mutating func writeUInt32(fieldNumber: Int, value: UInt32) {
        writeTag(fieldNumber: fieldNumber, wire: .varint)
        writeVarint(UInt64(value))
    }

    public mutating func writeUInt64(fieldNumber: Int, value: UInt64) {
        writeTag(fieldNumber: fieldNumber, wire: .varint)
        writeVarint(value)
    }

    public mutating func writeSInt32(fieldNumber: Int, value: Int32) {
        writeTag(fieldNumber: fieldNumber, wire: .varint)
        let zz = (UInt32(bitPattern: value) << 1) ^ UInt32(bitPattern: value >> 31)
        writeVarint(UInt64(zz))
    }

    public mutating func writeSInt64(fieldNumber: Int, value: Int64) {
        writeTag(fieldNumber: fieldNumber, wire: .varint)
        let zz = (UInt64(bitPattern: value) << 1) ^ UInt64(bitPattern: value >> 63)
        writeVarint(zz)
    }

    public mutating func writeBool(fieldNumber: Int, value: Bool) {
        writeTag(fieldNumber: fieldNumber, wire: .varint)
        writeVarint(value ? 1 : 0)
    }

    public mutating func writeFixed32(fieldNumber: Int, value: UInt32) {
        writeTag(fieldNumber: fieldNumber, wire: .fixed32)
        writeFixed32Raw(value)
    }

    public mutating func writeFixed64(fieldNumber: Int, value: UInt64) {
        writeTag(fieldNumber: fieldNumber, wire: .fixed64)
        writeFixed64Raw(value)
    }

    public mutating func writeSFixed32(fieldNumber: Int, value: Int32) {
        writeFixed32(fieldNumber: fieldNumber, value: UInt32(bitPattern: value))
    }

    public mutating func writeSFixed64(fieldNumber: Int, value: Int64) {
        writeFixed64(fieldNumber: fieldNumber, value: UInt64(bitPattern: value))
    }

    public mutating func writeFloat(fieldNumber: Int, value: Float) {
        writeFixed32(fieldNumber: fieldNumber, value: value.bitPattern)
    }

    public mutating func writeDouble(fieldNumber: Int, value: Double) {
        writeFixed64(fieldNumber: fieldNumber, value: value.bitPattern)
    }

    public mutating func writeString(fieldNumber: Int, value: String) {
        let bytes = Data(value.utf8)
        writeLengthDelimited(fieldNumber: fieldNumber, data: bytes)
    }

    public mutating func writeBytes(fieldNumber: Int, value: Data) {
        writeLengthDelimited(fieldNumber: fieldNumber, data: value)
    }

    public mutating func writeLengthDelimited(fieldNumber: Int, data payload: Data) {
        writeTag(fieldNumber: fieldNumber, wire: .lengthDelimited)
        writeVarint(UInt64(payload.count))
        data.append(payload)
    }

    /// Writes a nested message: serializes via `body(&inner)` and emits it as
    /// a length-delimited field.
    public mutating func writeMessage(
        fieldNumber: Int,
        body: (inout ProtoWriter) throws -> Void
    ) rethrows {
        var inner = ProtoWriter()
        try body(&inner)
        writeLengthDelimited(fieldNumber: fieldNumber, data: inner.data)
    }

    /// Writes pre-serialized message bytes as a length-delimited field.
    public mutating func writeMessageBytes(fieldNumber: Int, bytes: Data) {
        writeLengthDelimited(fieldNumber: fieldNumber, data: bytes)
    }

    private mutating func writeFixed32Raw(_ value: UInt32) {
        for i in 0..<4 {
            data.append(UInt8(truncatingIfNeeded: (value >> (8 * UInt32(i))) & 0xFF))
        }
    }

    private mutating func writeFixed64Raw(_ value: UInt64) {
        for i in 0..<8 {
            data.append(UInt8(truncatingIfNeeded: (value >> (8 * UInt64(i))) & 0xFF))
        }
    }
}

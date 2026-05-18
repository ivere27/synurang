import Foundation

/// Errors raised by `ProtoReader` when the input is malformed or truncated.
public enum ProtoReaderError: Error, CustomStringConvertible {
    case unexpectedEnd
    case malformedVarint
    case invalidWireType(Int)
    case invalidUTF8

    public var description: String {
        switch self {
        case .unexpectedEnd: return "unexpected end of protobuf payload"
        case .malformedVarint: return "malformed protobuf varint"
        case .invalidWireType(let v): return "unsupported protobuf wire type: \(v)"
        case .invalidUTF8: return "invalid UTF-8 in protobuf string field"
        }
    }
}

/// Minimal protobuf reader. Mirrors the C# `ProtoReader` API:
/// no schema awareness, just wire-format primitives. Generated lite code
/// drives this directly.
///
/// The reader is a `struct` so multiple readers can co-exist (e.g. nested
/// length-delimited packed reads) without reference-counting.
public struct ProtoReader {
    public let data: Data
    public private(set) var position: Int

    public init(data: Data) {
        self.data = data
        self.position = 0
    }

    public var isEOF: Bool { position >= data.count }

    /// Reads the next tag. Returns `nil` at EOF, otherwise `(fieldNumber, wire)`.
    public mutating func readTag() throws -> (fieldNumber: Int, wire: WireType)? {
        if isEOF { return nil }
        let tag = try readVarint()
        let wireRaw = Int(tag & 0x07)
        guard let wire = WireType(rawValue: wireRaw) else {
            throw ProtoReaderError.invalidWireType(wireRaw)
        }
        return (Int(tag >> 3), wire)
    }

    /// Reads a varint (1–10 bytes) and returns the raw 64-bit value.
    public mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            try ensureAvailable(1)
            let b = data[data.startIndex + position]
            position += 1
            result |= UInt64(b & 0x7F) << shift
            if (b & 0x80) == 0 { return result }
            shift += 7
            if shift > 63 { throw ProtoReaderError.malformedVarint }
        }
    }

    public mutating func readInt32() throws -> Int32 {
        let v = try readVarint()
        return Int32(truncatingIfNeeded: Int64(bitPattern: v))
    }

    public mutating func readInt64() throws -> Int64 {
        let v = try readVarint()
        return Int64(bitPattern: v)
    }

    public mutating func readUInt32() throws -> UInt32 {
        let v = try readVarint()
        return UInt32(truncatingIfNeeded: v)
    }

    public mutating func readUInt64() throws -> UInt64 {
        return try readVarint()
    }

    public mutating func readSInt32() throws -> Int32 {
        let v = try readVarint()
        let u32 = UInt32(truncatingIfNeeded: v)
        // zigzag decode
        return Int32(bitPattern: (u32 >> 1) ^ (0 &- (u32 & 1)))
    }

    public mutating func readSInt64() throws -> Int64 {
        let v = try readVarint()
        return Int64(bitPattern: (v >> 1) ^ (0 &- (v & 1)))
    }

    public mutating func readBool() throws -> Bool {
        return try readVarint() != 0
    }

    public mutating func readFixed32() throws -> UInt32 {
        try ensureAvailable(4)
        var v: UInt32 = 0
        let base = data.startIndex + position
        for i in 0..<4 {
            v |= UInt32(data[base + i]) << (8 * UInt32(i))
        }
        position += 4
        return v
    }

    public mutating func readFixed64() throws -> UInt64 {
        try ensureAvailable(8)
        var v: UInt64 = 0
        let base = data.startIndex + position
        for i in 0..<8 {
            v |= UInt64(data[base + i]) << (8 * UInt64(i))
        }
        position += 8
        return v
    }

    public mutating func readSFixed32() throws -> Int32 {
        return Int32(bitPattern: try readFixed32())
    }

    public mutating func readSFixed64() throws -> Int64 {
        return Int64(bitPattern: try readFixed64())
    }

    public mutating func readFloat() throws -> Float {
        let bits = try readFixed32()
        return Float(bitPattern: bits)
    }

    public mutating func readDouble() throws -> Double {
        let bits = try readFixed64()
        return Double(bitPattern: bits)
    }

    public mutating func readLengthDelimited() throws -> Data {
        let len = Int(try readVarint())
        if len < 0 { throw ProtoReaderError.malformedVarint }
        try ensureAvailable(len)
        let start = data.startIndex + position
        let slice = data.subdata(in: start..<(start + len))
        position += len
        return slice
    }

    public mutating func readString() throws -> String {
        let bytes = try readLengthDelimited()
        guard let s = String(data: bytes, encoding: .utf8) else {
            throw ProtoReaderError.invalidUTF8
        }
        return s
    }

    public mutating func readBytes() throws -> Data {
        return try readLengthDelimited()
    }

    /// Skips an unknown field of the given wire type.
    public mutating func skip(wire: WireType) throws {
        switch wire {
        case .varint:
            _ = try readVarint()
        case .fixed64:
            try ensureAvailable(8)
            position += 8
        case .lengthDelimited:
            let len = Int(try readVarint())
            if len < 0 { throw ProtoReaderError.malformedVarint }
            try ensureAvailable(len)
            position += len
        case .fixed32:
            try ensureAvailable(4)
            position += 4
        case .startGroup, .endGroup:
            // proto2 groups are deprecated; SynurangLite does not support them.
            throw ProtoReaderError.invalidWireType(wire.rawValue)
        }
    }

    private func ensureAvailable(_ count: Int) throws {
        if position + count > data.count {
            throw ProtoReaderError.unexpectedEnd
        }
    }
}

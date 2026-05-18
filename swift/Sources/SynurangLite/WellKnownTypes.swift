// Hand-maintained part of SynurangLite. DO NOT EDIT generated headers
// reference these types.
//
// Lite-mode shims for the protobuf well-known types most commonly used at
// gRPC method boundaries. Generated lite code references these by their
// short Swift names (`Empty`, `Int32Value`, ...), matching the GoIdent
// names emitted by protoc-gen-synurang-ffi for `google.protobuf.*` inputs.
//
// Each type provides `serializedData()` / `init(serializedBytes:)` so the
// generated `_ffi.swift` stubs treat them like any other lite message, and
// an `encode(into:)` so they round-trip when nested in a user message.

import Foundation

// MARK: - Empty

/// Shim for `google.protobuf.Empty`. Serializes to zero bytes; tolerates and
/// skips any unknown fields on decode.
public struct Empty: Sendable {
    public init() {}

    public func serializedData() throws -> Data {
        return Data()
    }

    public func encode(into _: inout ProtoWriter) throws {
        // no fields
    }

    public init(serializedBytes data: Data) throws {
        if data.isEmpty { return }
        var r = ProtoReader(data: data)
        while let tag = try r.readTag() {
            try r.skip(wire: tag.wire)
        }
    }
}

// MARK: - Scalar wrappers (google.protobuf.*Value)
//
// All wrappers carry a single field at tag 1; default-value semantics mean
// `value == 0 / "" / false / empty` is *not* re-emitted on the wire.

public struct Int32Value: Sendable {
    public var value: Int32
    public init(_ value: Int32 = 0) { self.value = value }

    public func serializedData() throws -> Data {
        var w = ProtoWriter()
        try encode(into: &w)
        return w.data
    }

    public func encode(into w: inout ProtoWriter) throws {
        if value != 0 {
            w.writeInt32(fieldNumber: 1, value: value)
        }
    }

    public init(serializedBytes data: Data) throws {
        self.value = 0
        var r = ProtoReader(data: data)
        while let tag = try r.readTag() {
            if tag.fieldNumber == 1, tag.wire == .varint {
                value = try r.readInt32()
            } else {
                try r.skip(wire: tag.wire)
            }
        }
    }
}

public struct Int64Value: Sendable {
    public var value: Int64
    public init(_ value: Int64 = 0) { self.value = value }

    public func serializedData() throws -> Data {
        var w = ProtoWriter()
        try encode(into: &w)
        return w.data
    }

    public func encode(into w: inout ProtoWriter) throws {
        if value != 0 {
            w.writeInt64(fieldNumber: 1, value: value)
        }
    }

    public init(serializedBytes data: Data) throws {
        self.value = 0
        var r = ProtoReader(data: data)
        while let tag = try r.readTag() {
            if tag.fieldNumber == 1, tag.wire == .varint {
                value = try r.readInt64()
            } else {
                try r.skip(wire: tag.wire)
            }
        }
    }
}

public struct UInt32Value: Sendable {
    public var value: UInt32
    public init(_ value: UInt32 = 0) { self.value = value }

    public func serializedData() throws -> Data {
        var w = ProtoWriter()
        try encode(into: &w)
        return w.data
    }

    public func encode(into w: inout ProtoWriter) throws {
        if value != 0 {
            w.writeUInt32(fieldNumber: 1, value: value)
        }
    }

    public init(serializedBytes data: Data) throws {
        self.value = 0
        var r = ProtoReader(data: data)
        while let tag = try r.readTag() {
            if tag.fieldNumber == 1, tag.wire == .varint {
                value = try r.readUInt32()
            } else {
                try r.skip(wire: tag.wire)
            }
        }
    }
}

public struct UInt64Value: Sendable {
    public var value: UInt64
    public init(_ value: UInt64 = 0) { self.value = value }

    public func serializedData() throws -> Data {
        var w = ProtoWriter()
        try encode(into: &w)
        return w.data
    }

    public func encode(into w: inout ProtoWriter) throws {
        if value != 0 {
            w.writeUInt64(fieldNumber: 1, value: value)
        }
    }

    public init(serializedBytes data: Data) throws {
        self.value = 0
        var r = ProtoReader(data: data)
        while let tag = try r.readTag() {
            if tag.fieldNumber == 1, tag.wire == .varint {
                value = try r.readUInt64()
            } else {
                try r.skip(wire: tag.wire)
            }
        }
    }
}

public struct BoolValue: Sendable {
    public var value: Bool
    public init(_ value: Bool = false) { self.value = value }

    public func serializedData() throws -> Data {
        var w = ProtoWriter()
        try encode(into: &w)
        return w.data
    }

    public func encode(into w: inout ProtoWriter) throws {
        if value {
            w.writeBool(fieldNumber: 1, value: value)
        }
    }

    public init(serializedBytes data: Data) throws {
        self.value = false
        var r = ProtoReader(data: data)
        while let tag = try r.readTag() {
            if tag.fieldNumber == 1, tag.wire == .varint {
                value = try r.readBool()
            } else {
                try r.skip(wire: tag.wire)
            }
        }
    }
}

public struct FloatValue: Sendable {
    public var value: Float
    public init(_ value: Float = 0) { self.value = value }

    public func serializedData() throws -> Data {
        var w = ProtoWriter()
        try encode(into: &w)
        return w.data
    }

    public func encode(into w: inout ProtoWriter) throws {
        if value != 0 {
            w.writeFloat(fieldNumber: 1, value: value)
        }
    }

    public init(serializedBytes data: Data) throws {
        self.value = 0
        var r = ProtoReader(data: data)
        while let tag = try r.readTag() {
            if tag.fieldNumber == 1, tag.wire == .fixed32 {
                value = try r.readFloat()
            } else {
                try r.skip(wire: tag.wire)
            }
        }
    }
}

public struct DoubleValue: Sendable {
    public var value: Double
    public init(_ value: Double = 0) { self.value = value }

    public func serializedData() throws -> Data {
        var w = ProtoWriter()
        try encode(into: &w)
        return w.data
    }

    public func encode(into w: inout ProtoWriter) throws {
        if value != 0 {
            w.writeDouble(fieldNumber: 1, value: value)
        }
    }

    public init(serializedBytes data: Data) throws {
        self.value = 0
        var r = ProtoReader(data: data)
        while let tag = try r.readTag() {
            if tag.fieldNumber == 1, tag.wire == .fixed64 {
                value = try r.readDouble()
            } else {
                try r.skip(wire: tag.wire)
            }
        }
    }
}

public struct StringValue: Sendable {
    public var value: String
    public init(_ value: String = "") { self.value = value }

    public func serializedData() throws -> Data {
        var w = ProtoWriter()
        try encode(into: &w)
        return w.data
    }

    public func encode(into w: inout ProtoWriter) throws {
        if !value.isEmpty {
            w.writeString(fieldNumber: 1, value: value)
        }
    }

    public init(serializedBytes data: Data) throws {
        self.value = ""
        var r = ProtoReader(data: data)
        while let tag = try r.readTag() {
            if tag.fieldNumber == 1, tag.wire == .lengthDelimited {
                value = try r.readString()
            } else {
                try r.skip(wire: tag.wire)
            }
        }
    }
}

public struct BytesValue: Sendable {
    public var value: Data
    public init(_ value: Data = Data()) { self.value = value }

    public func serializedData() throws -> Data {
        var w = ProtoWriter()
        try encode(into: &w)
        return w.data
    }

    public func encode(into w: inout ProtoWriter) throws {
        if !value.isEmpty {
            w.writeBytes(fieldNumber: 1, value: value)
        }
    }

    public init(serializedBytes data: Data) throws {
        self.value = Data()
        var r = ProtoReader(data: data)
        while let tag = try r.readTag() {
            if tag.fieldNumber == 1, tag.wire == .lengthDelimited {
                value = try r.readBytes()
            } else {
                try r.skip(wire: tag.wire)
            }
        }
    }
}

// MARK: - Timestamp / Duration
//
// Shape matches the canonical `google.protobuf.Timestamp` /
// `google.protobuf.Duration` definitions: two int64 fields (`seconds` at
// tag 1, `nanos` at tag 2 — `nanos` is int32 in the upstream proto, but
// fits cleanly in Int32 here).

public struct Timestamp: Sendable {
    public var seconds: Int64
    public var nanos: Int32
    public init(seconds: Int64 = 0, nanos: Int32 = 0) {
        self.seconds = seconds
        self.nanos = nanos
    }

    public func serializedData() throws -> Data {
        var w = ProtoWriter()
        try encode(into: &w)
        return w.data
    }

    public func encode(into w: inout ProtoWriter) throws {
        if seconds != 0 { w.writeInt64(fieldNumber: 1, value: seconds) }
        if nanos != 0 { w.writeInt32(fieldNumber: 2, value: nanos) }
    }

    public init(serializedBytes data: Data) throws {
        self.seconds = 0
        self.nanos = 0
        var r = ProtoReader(data: data)
        while let tag = try r.readTag() {
            switch tag.fieldNumber {
            case 1: seconds = try r.readInt64()
            case 2: nanos = try r.readInt32()
            default: try r.skip(wire: tag.wire)
            }
        }
    }
}

public struct Duration: Sendable {
    public var seconds: Int64
    public var nanos: Int32
    public init(seconds: Int64 = 0, nanos: Int32 = 0) {
        self.seconds = seconds
        self.nanos = nanos
    }

    public func serializedData() throws -> Data {
        var w = ProtoWriter()
        try encode(into: &w)
        return w.data
    }

    public func encode(into w: inout ProtoWriter) throws {
        if seconds != 0 { w.writeInt64(fieldNumber: 1, value: seconds) }
        if nanos != 0 { w.writeInt32(fieldNumber: 2, value: nanos) }
    }

    public init(serializedBytes data: Data) throws {
        self.seconds = 0
        self.nanos = 0
        var r = ProtoReader(data: data)
        while let tag = try r.readTag() {
            switch tag.fieldNumber {
            case 1: seconds = try r.readInt64()
            case 2: nanos = try r.readInt32()
            default: try r.skip(wire: tag.wire)
            }
        }
    }
}

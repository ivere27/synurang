import Foundation

/// Error thrown when the FFI plugin reports a non-success result.
///
/// Mirrors the C# `FfiError` class. The wire payload is a tiny protobuf with
/// the following schema:
///
///   message FfiErrorPayload {
///       int32  code      = 1;  // application-defined code
///       string message   = 2;
///       int32  grpc_code = 3;  // grpc.Code (gRPC status code)
///   }
///
/// All fields are optional in practice: hosts that receive an empty payload
/// surface an empty-message `FfiError` with `code = 0, grpcCode = 0`.
public struct FfiError: Error, CustomStringConvertible {
    public let code: Int32
    public let grpcCode: Int32
    public let message: String
    public let payload: Data?

    public init(
        message: String,
        code: Int32 = 0,
        grpcCode: Int32 = 2,
        payload: Data? = nil
    ) {
        self.code = code
        self.grpcCode = grpcCode
        self.message = message
        self.payload = payload
    }

    public var description: String {
        if message.isEmpty {
            return "FfiError(code=\(code), grpcCode=\(grpcCode))"
        }
        return message
    }

    public var localizedDescription: String { description }

    /// Decodes an `FfiError` from a wire-format payload as produced by the
    /// Synurang plugin ABI.
    ///
    /// On any parse failure the function falls back to using the raw payload
    /// as a UTF-8 string for the message (matches the C# behaviour).
    public static func fromPayload(_ payload: Data?) -> FfiError {
        guard let payload = payload, !payload.isEmpty else {
            return FfiError(message: "", code: 0, grpcCode: 0, payload: payload)
        }

        var reader = ProtoReader(data: payload)
        var code: Int32 = 0
        var grpcCode: Int32 = 0
        var message: String?

        while true {
            do {
                guard let tag = try reader.readTag() else { break }
                switch (tag.fieldNumber, tag.wire) {
                case (1, .varint):
                    code = (try? reader.readInt32()) ?? code
                case (2, .lengthDelimited):
                    message = (try? reader.readString()) ?? message
                case (3, .varint):
                    grpcCode = (try? reader.readInt32()) ?? grpcCode
                default:
                    try reader.skip(wire: tag.wire)
                }
            } catch {
                break
            }
        }

        if message == nil {
            // Fallback: treat payload as a raw UTF-8 message.
            message = String(data: payload, encoding: .utf8) ?? ""
        }

        return FfiError(
            message: message ?? "",
            code: code,
            grpcCode: grpcCode,
            payload: payload
        )
    }
}

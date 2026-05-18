// Code in this file is part of SynurangLite. DO NOT EDIT generated headers
// reference this module. Hand-maintained.

import Foundation

/// Protobuf wire type tag (3 low bits of every field tag varint).
///
/// See https://protobuf.dev/programming-guides/encoding/#structure
public enum WireType: Int, Sendable {
    case varint = 0
    case fixed64 = 1
    case lengthDelimited = 2
    case startGroup = 3
    case endGroup = 4
    case fixed32 = 5
}

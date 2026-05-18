import Foundation

/// Sentinel error thrown when an operation is attempted on a `PluginHost`
/// or `PluginStream` that has been (or is being) closed.
///
/// Modelled as a distinct struct (rather than a sub-error of `FfiError`)
/// because Swift's struct-based error model has no inheritance. Callers
/// that want a single catch can pattern-match on `PluginClosedError`
/// before catching the broader `FfiError`.
public struct PluginClosedError: Error, CustomStringConvertible {
    public init() {}
    public var description: String { "plugin is closed" }
    public var localizedDescription: String { description }
}

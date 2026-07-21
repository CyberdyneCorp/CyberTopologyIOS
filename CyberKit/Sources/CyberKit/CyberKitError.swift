import CyberRemesherC

/// Error thrown by every fallible CyberKit call, mapping the engine's
/// `CyberStatus` code plus its thread-local `cyber_last_error()` detail.
public struct CyberKitError: Error, Equatable, Sendable, CustomStringConvertible {
    public enum Code: Equatable, Sendable {
        case io
        case invalidArgument
        case invalidParameter
        case emptyMesh
        case runtime
        case cancelled
        case unknown(UInt32)
    }

    public let code: Code
    /// Engine-provided detail for the failure (may be empty).
    public let message: String

    public var description: String {
        message.isEmpty ? "CyberKitError.\(code)" : "CyberKitError.\(code): \(message)"
    }

    init(code: Code, message: String) {
        self.code = code
        self.message = message
    }

    init(status: CyberStatus) {
        switch status {
        case CYBER_ERR_IO: code = .io
        case CYBER_ERR_INVALID_ARG: code = .invalidArgument
        case CYBER_ERR_INVALID_PARAM: code = .invalidParameter
        case CYBER_ERR_EMPTY: code = .emptyMesh
        case CYBER_ERR_RUNTIME: code = .runtime
        case CYBER_ERR_CANCELLED: code = .cancelled
        default: code = .unknown(status.rawValue)
        }
        message = String(cString: cyber_last_error())
    }
}

/// Converts a `CyberStatus` return code into a thrown `CyberKitError`.
@inline(__always)
func check(_ status: CyberStatus) throws {
    guard status == CYBER_OK else { throw CyberKitError(status: status) }
}

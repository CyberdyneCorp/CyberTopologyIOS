import CyberRemesherC

/// Entry point for engine-global queries.
public enum CyberEngine {
    /// Semantic version of the linked CyberRemesherAndUV engine.
    public struct Version: Equatable, Sendable, CustomStringConvertible {
        public let major: Int
        public let minor: Int
        public let patch: Int

        public var description: String { "\(major).\(minor).\(patch)" }
    }

    /// Returns the engine's semantic version (mirrors its CMake project version).
    public static func version() -> Version {
        var major: Int32 = 0
        var minor: Int32 = 0
        var patch: Int32 = 0
        cyber_version(&major, &minor, &patch)
        return Version(major: Int(major), minor: Int(minor), patch: Int(patch))
    }
}

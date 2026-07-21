import Testing
@testable import CyberKit

@Suite("CyberEngine")
struct CyberEngineTests {
    @Test("version() reports the linked engine's semantic version")
    func versionIsRealAndNonZero() {
        let version = CyberEngine.version()
        #expect(version.major >= 0)
        #expect(version.minor >= 0)
        #expect(version.patch >= 0)
        // A 0.0.0 answer would mean the call never reached the engine.
        #expect(version != CyberEngine.Version(major: 0, minor: 0, patch: 0))
    }

    @Test("version description is dotted semver")
    func versionDescription() {
        let version = CyberEngine.version()
        #expect(version.description == "\(version.major).\(version.minor).\(version.patch)")
    }
}

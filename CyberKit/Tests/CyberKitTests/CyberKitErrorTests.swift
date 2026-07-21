import CyberRemesherC
import Testing
@testable import CyberKit

@Suite("CyberKitError")
struct CyberKitErrorTests {
    @Test("every engine status maps to its typed code", arguments: [
        (CYBER_ERR_IO, CyberKitError.Code.io),
        (CYBER_ERR_INVALID_ARG, .invalidArgument),
        (CYBER_ERR_INVALID_PARAM, .invalidParameter),
        (CYBER_ERR_EMPTY, .emptyMesh),
        (CYBER_ERR_RUNTIME, .runtime),
        (CYBER_ERR_CANCELLED, .cancelled),
    ])
    func statusMapping(status: CyberStatus, expected: CyberKitError.Code) {
        #expect(CyberKitError(status: status).code == expected)
    }

    @Test("an unrecognized status is preserved as .unknown")
    func unknownStatus() {
        let error = CyberKitError(status: CyberStatus(rawValue: 999))
        #expect(error.code == .unknown(999))
    }

    @Test("check() passes CYBER_OK through and throws otherwise")
    func checkBehavior() throws {
        try check(CYBER_OK)
        #expect(throws: CyberKitError.self) { try check(CYBER_ERR_RUNTIME) }
    }

    @Test("description includes the engine message when present")
    func descriptionFormatting() {
        let bare = CyberKitError(code: .runtime, message: "")
        #expect(bare.description == "CyberKitError.runtime")

        let detailed = CyberKitError(code: .io, message: "no such file")
        #expect(detailed.description == "CyberKitError.io: no such file")
    }
}

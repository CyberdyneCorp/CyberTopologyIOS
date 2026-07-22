import XCTest
@testable import CyberTopology

/// Device-only half of task 3.7 (design D9 / QA spec "No silent skips"):
/// Pencil Pro squeeze delivery, barrel-roll reporting, and haptic ACTUATION
/// exist only on physical hardware — neither the simulator nor XCUITest can
/// synthesize a squeeze, a barrel roll, or verify that a tick was felt.
/// Everything BELOW those hardware boundaries is covered on simulator:
/// squeeze policy + palette + arbiter wiring (`QuickVerbPaletteTests`), the
/// event→feedback mapping against the injected haptic seam
/// (`SnapFeedbackTests`), and the full Tweak/Move merge-snap drag with
/// pre-highlight, journaled merge, and recorded ticks
/// (`MeshEditControllerTests`). These tests skip LOUDLY so the run report
/// classifies the hardware half against the device test plan (task 9.6).
final class PencilProHardwareTests: XCTestCase {
    static let squeezeSkipReason =
        "device-only: UIPencilInteraction squeeze delivery requires a "
        + "physical Apple Pencil Pro; it cannot be synthesized in the "
        + "simulator or by XCUITest. The policy below the delegate callback "
        + "is covered by QuickVerbPaletteTests; delivery is part of the "
        + "device test plan (design D9 release gate, task 9.6)."

    static let barrelRollSkipReason =
        "device-only: barrel-roll angles are reported only by a physical "
        + "Apple Pencil Pro (UIHoverGestureRecognizer.rollAngle is always 0 "
        + "elsewhere). The model hook is covered by QuickVerbPaletteTests; "
        + "hardware reporting is part of the device test plan (task 9.6)."

    static let hapticSkipReason =
        "device-only: haptic ACTUATION (Core Haptics transient ticks and "
        + "UICanvasFeedbackGenerator routing to the Pencil Pro actuator) "
        + "requires hardware with the corresponding actuator — the "
        + "simulator reports supportsHaptics == false and plays nothing. "
        + "The event→feedback mapping is covered by SnapFeedbackTests and "
        + "MeshEditControllerTests via the injected haptic seam; actuation "
        + "is part of the device test plan (task 9.6)."

    @MainActor
    func testPencilProSqueezeDeliveryOpensThePalette() throws {
        throw XCTSkip(Self.squeezeSkipReason)
    }

    @MainActor
    func testPencilProBarrelRollIsReported() throws {
        throw XCTSkip(Self.barrelRollSkipReason)
    }

    @MainActor
    func testSnapHapticTickActuatesOnHardware() throws {
        throw XCTSkip(Self.hapticSkipReason)
    }
}

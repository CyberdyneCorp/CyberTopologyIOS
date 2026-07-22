import XCTest
@testable import CyberTopology

/// Device-only half of the hover-preview scenario (task 3.6, design D9 /
/// QA spec "No silent skips"): Apple Pencil hover EVENT DELIVERY exists
/// only on hover-capable hardware (Pencil 2 on M2+ iPads, Pencil Pro) with
/// a physical Pencil hovering — neither the simulator nor XCUITest can
/// synthesize `UIHoverGestureRecognizer` pencil events. Everything BELOW
/// the recognizer (camera ray → engine raycast → element picks → engine
/// loop walk → render state) is covered end to end by `HoverPreviewTests`;
/// this test skips LOUDLY so the run report classifies the hardware half
/// against the device test plan (task 9.6) instead of dropping it.
final class HoverHardwareTests: XCTestCase {
    static let hardwareSkipReason =
        "device-only: Apple Pencil hover delivery requires hover-capable "
        + "hardware (Pencil 2 on M2+ iPads / Pencil Pro) with a physical "
        + "Pencil hovering; UIHoverGestureRecognizer pencil events cannot be "
        + "synthesized in the simulator or by XCUITest. The query path below "
        + "the recognizer is covered by HoverPreviewTests; hover delivery is "
        + "part of the device test plan (design D9 release gate, task 9.6)."

    @MainActor
    func testPencilHoverDeliveryOnHoverCapableHardware() throws {
        throw XCTSkip(Self.hardwareSkipReason)
    }
}

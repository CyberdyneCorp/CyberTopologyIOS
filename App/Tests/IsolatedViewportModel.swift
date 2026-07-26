import CyberKit
import Foundation
import Testing

@testable import CyberTopology

/// An app-test viewport model backed by an EPHEMERAL `UserDefaults` suite.
///
/// App-hosted tests build a real `MetalViewport.Coordinator`, whose default
/// `ViewportInputModel` reads `UserDefaults.standard`. On a DEVICE that has been used
/// by hand, persisted preferences therefore leak into unit tests — and some of those
/// preferences change geometry. **Auto Relax (task 4.5) runs INSIDE each authoring
/// operation's own transaction**, so a device where it was left on nudges vertices
/// after the symmetry-plane snap.
///
/// That is exactly what made three tests look like device-only float failures on the
/// first real device run (see `add-cybertopology-app` 9.6): the seam vertices landed
/// 0.0234 off the plane instead of exactly on it, Merge Pair's survivor drifted off the
/// midpoint, and a plane-snapped vertex read 2^-20 instead of 0. Forcing Auto Relax off
/// reproduced the simulator's numbers byte for byte, on the same device.
///
/// The failure mode is worth naming: it is not device-specific and it is not flaky in a
/// random way. It is *deterministic per machine* — green on any machine where the
/// preference happens to be off, red on any machine where it is on, including a
/// simulator. Isolating the defaults is what makes these tests depend only on their
/// own inputs.
enum IsolatedViewportModel {
    /// A fresh model whose preferences cannot be inherited from the host, and cannot
    /// leak back out to it.
    @MainActor
    static func make() -> ViewportInputModel {
        let suite = "cybertopology.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        // Belt and braces: a brand-new suite is empty, but an explicit clear means a
        // reused name (or a future default-on preference) cannot change a result.
        defaults.removePersistentDomain(forName: suite)
        return ViewportInputModel(defaults: defaults)
    }
}

extension IsolatedViewportModel {
    /// A `MetalViewport` whose preferences are isolated from the host machine.
    ///
    /// Use this in app tests instead of constructing `MetalViewport` directly. The
    /// direct constructor picks up `UserDefaults.standard`, which is how a preference
    /// left on by hand becomes a test failure on that machine only.
    @MainActor
    static func viewport(
        bundle: DocumentBundle = DocumentBundle(),
        orbitSpeed: Double = 1,
        zoomSpeed: Double = 1,
        onUndo: @escaping @MainActor () -> Void = {},
        onRedo: @escaping @MainActor () -> Void = {}
    ) -> MetalViewport {
        var viewport = MetalViewport(
            bundle: bundle, orbitSpeed: orbitSpeed, zoomSpeed: zoomSpeed,
            onUndo: onUndo, onRedo: onRedo
        )
        viewport.inputModel = make()
        return viewport
    }
}

/// Guards the isolation itself. Without this, a harness quietly reverting to
/// `UserDefaults.standard` only shows up as an unrelated geometry failure on whichever
/// machine happens to have the preference set — which is how it hid the first time.
@MainActor
struct IsolatedViewportModelTests {
    @Test("An isolated model starts from a CLEAN preference state")
    func startsClean() {
        // On a machine where Auto Relax was left ON (the iPad this was found on), a
        // model reading UserDefaults.standard reports true here. Isolation means this
        // assertion is machine-independent.
        #expect(IsolatedViewportModel.make().autoRelaxEnabled == false)
    }

    @Test("Two isolated models share no state")
    func modelsAreIndependent() {
        let a = IsolatedViewportModel.make()
        let b = IsolatedViewportModel.make()
        a.setAutoRelax(true)
        #expect(a.autoRelaxEnabled)
        #expect(b.autoRelaxEnabled == false, "preferences leaked between isolated models")
    }

    @Test("A viewport built by the factory carries the isolated model")
    func viewportUsesTheIsolatedModel() {
        #expect(IsolatedViewportModel.viewport().inputModel.autoRelaxEnabled == false)
    }
}

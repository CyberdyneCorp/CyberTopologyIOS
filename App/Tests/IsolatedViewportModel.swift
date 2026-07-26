import Foundation

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

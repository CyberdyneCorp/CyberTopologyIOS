import CyberKit
import Foundation
import Testing
import UIKit
import simd

@testable import CyberTopology

/// Anchors `Bundle(for:)` to the app test target for the bundled scan.
private final class RealTargetToolBundleAnchor {}

/// Phase 4 TOOLS driven against a real scanned Target (the Stanford bunny)
/// through the full app pipeline — authoring and symmetric authoring snap
/// their results onto dense, curved geometry rather than a flat plane. The
/// per-tool suites all use synthetic targets; this is the end-to-end check
/// that the tools behave on a real scan. App-hosted, so it runs on the iPad.
@MainActor
struct RealTargetToolTests {
    /// Coordinator + document-journal harness (same shape as the 4.4 suite).
    @MainActor
    private final class Harness {
        var bundle = DocumentBundle()
        let coordinator: MetalViewport.Coordinator
        private(set) var committed: [DocumentCommand] = []

        init() throws {
            coordinator = MetalViewport(
                bundle: DocumentBundle(), orbitSpeed: 1, zoomSpeed: 1, onUndo: {}, onRedo: {}
            ).makeCoordinator()
            _ = coordinator.makeView()
            try #require(coordinator.renderer != nil, "Metal device unavailable")
            coordinator.onCommit = { [weak self] command in
                self?.committed.append(command)
                self?.perform(command)
            }
            coordinator.bundleProvider = { [weak self] in self?.bundle ?? DocumentBundle() }
        }

        func sync() { coordinator.syncMesh(from: bundle) }
        func perform(_ command: DocumentCommand) {
            bundle.journal.record(command)
            command.apply(to: &bundle)
            sync()
        }

        var editObject: DocumentManifest.Object? {
            bundle.manifest.objects.first { $0.role == .editMesh }
        }
        func editMesh() throws -> Mesh { try bundle.mesh(for: #require(editObject)) }

        func authorQuad(_ corners: [SIMD2<Float>]) throws {
            let context = try #require(coordinator.makeEditContext())
            coordinator.meshEditor.applyCreate(
                verb: "test.createQuad", screenPoints: corners, context: context
            ) { mesh, ring, snapper in
                try mesh.createFace(at: ring, snapping: snapper)
            }
        }

        func setSymmetry(_ settings: SymmetrySettings) {
            let current = bundle.manifest.symmetry
            guard settings != (current ?? SymmetrySettings()) else { return }
            perform(.setSymmetry(from: current, to: settings))
        }
    }

    private func loadBunny() throws -> Mesh {
        let url = try #require(
            Bundle(for: RealTargetToolBundleAnchor.self)
                .url(forResource: "stanford-bunny", withExtension: "obj"),
            "stanford-bunny.obj not bundled"
        )
        return try Mesh.loadOBJ(at: url)
    }

    /// Loads the bunny as the Target and frames the camera so its centroid is
    /// at screen centre (a screen-centre ray then raycasts onto the front
    /// surface). Returns the centroid, radius and a verification snapper.
    private func bunnyTarget(
        _ harness: Harness
    ) throws -> (centroid: SIMD3<Float>, radius: Float, snapper: SurfaceSnapper) {
        let bunny = try loadBunny()
        try harness.bundle.addObject(name: "bunny", role: .target, mesh: bunny)
        harness.sync()
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for id in stride(from: UInt32(0), to: UInt32(bunny.vertexCount), by: 97) {
            guard let p = bunny.vertexPosition(id) else { continue }
            lo = simd_min(lo, p)
            hi = simd_max(hi, p)
        }
        let centroid = (lo + hi) * 0.5
        let radius = simd_length(hi - lo) * 0.5
        harness.coordinator.renderer?.camera = CameraState(
            focus: centroid, distance: radius * 2.5, azimuth: 0.7, elevation: 0.4
        )
        return (centroid, radius, try SurfaceSnapper(target: bunny))
    }

    /// Every live vertex of the EditMesh, and the worst distance from the
    /// bunny surface.
    private func worstSurfaceResidual(_ mesh: Mesh, _ snapper: SurfaceSnapper) throws -> Float {
        var worst: Float = 0
        for id in 0..<UInt32(mesh.vertexCount) {
            guard let p = mesh.vertexPosition(id) else { continue }
            let hit = try #require(snapper.snapToSurface(p))
            worst = max(worst, simd_distance(hit.point, p))
        }
        return worst
    }

    @Test("Authoring a quad lands its face on the bunny surface")
    func authoringLandsOnTheBunny() throws {
        let harness = try Harness()
        let (centroid, radius, snapper) = try bunnyTarget(harness)

        // A small quad around screen centre — its corners raycast onto the
        // bunny's front surface (unprojectCorners), then weld/snap onto it.
        let c = SIMD2<Float>(0.5, 0.5)
        let d: Float = 0.04
        try harness.authorQuad([
            c + SIMD2(-d, -d), c + SIMD2(d, -d), c + SIMD2(d, d), c + SIMD2(-d, d),
        ])

        let mesh = try harness.editMesh()
        #expect(mesh.faceCount == 1)
        #expect(mesh.vertexCount == 4)
        // Every authored vertex sits ON the bunny.
        #expect(try worstSurfaceResidual(mesh, snapper) <= radius * 1e-3)
        // Anti-vacuity: the quad landed on the bunny near where we aimed, not
        // off in empty space or at the origin.
        var quadCentre = SIMD3<Float>.zero
        for id in 0..<UInt32(mesh.vertexCount) {
            quadCentre += try #require(mesh.vertexPosition(id))
        }
        quadCentre /= Float(mesh.vertexCount)
        #expect(simd_distance(quadCentre, centroid) < radius)
    }

    @Test("Symmetric authoring lands BOTH copies on the bunny")
    func symmetricAuthoringLandsBothOnTheBunny() throws {
        let harness = try Harness()
        let (centroid, radius, snapper) = try bunnyTarget(harness)

        var settings = SymmetrySettings()
        settings.isEnabled = true
        settings = settings.settingMirror(.x, enabled: true)
        settings.origin = centroid  // mirror about the bunny's own centre
        harness.setSymmetry(settings)

        // Author OFF to one side so the authored quad and its mirror are
        // distinct regions of the bunny.
        let c = SIMD2<Float>(0.62, 0.5)
        let d: Float = 0.035
        try harness.authorQuad([
            c + SIMD2(-d, -d), c + SIMD2(d, -d), c + SIMD2(d, d), c + SIMD2(-d, d),
        ])

        let mesh = try harness.editMesh()
        // The authored quad plus its mirror copy.
        #expect(mesh.faceCount == 2, "authored + mirror")
        // Both copies' vertices land on the bunny surface — the mirror ring is
        // reflected and then snapped onto the (asymmetric) scan, so it conforms
        // even though the bunny is not symmetric.
        #expect(try worstSurfaceResidual(mesh, snapper) <= radius * 1e-3)
        _ = centroid
    }
}

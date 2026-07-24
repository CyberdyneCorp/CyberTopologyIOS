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

        var inputModel: ViewportInputModel { coordinator.inputModel }
        var editor: MeshEditController { coordinator.meshEditor }

        /// Arms a retopology tool through the model (the toolbar path).
        func selectTool(_ tool: RetopoTool) { coordinator.inputModel.selectTool(tool) }

        /// A tap at a world point (a 2-sample stroke) — the Extend Boundary
        /// hold-select entry.
        func tap(at world: SIMD3<Float>) {
            let point = screenPoint(of: world)
            stroke(verb: .pencil, through: [point, point])
        }

        /// Orbits the live camera and feeds the new pose to the armed camera
        /// tool (the Extend Boundary automatic-step driver).
        func orbitAndFeed(byPoints delta: SIMD2<Float>) {
            coordinator.renderer?.orbit(byPoints: delta)
            coordinator.feedCameraToArmedTool()
        }

        /// Normalized viewport point of a world position under the live camera.
        func screenPoint(of world: SIMD3<Float>) -> SIMD2<Double> {
            let m = coordinator.renderer!.viewProjectionColumns()
            let cx = m[0] * world.x + m[4] * world.y + m[8] * world.z + m[12]
            let cy = m[1] * world.x + m[5] * world.y + m[9] * world.z + m[13]
            let cw = m[3] * world.x + m[7] * world.y + m[11] * world.z + m[15]
            return SIMD2(Double(cx / cw) * 0.5 + 0.5, 1 - (Double(cy / cw) * 0.5 + 0.5))
        }

        /// Drives a tool stroke through the real capture pipeline.
        func stroke(verb: InputArbiter.Verb, through points: [SIMD2<Double>]) {
            let capture = coordinator.inputModel.controller.capture
            guard let first = points.first else { return }
            capture.begin(
                source: .finger, verb: verb,
                sample: .init(time: 0, x: first.x, y: first.y, pressure: 0.5, type: .finger)
            )
            for (index, point) in points.dropFirst().enumerated() {
                capture.append(sample: .init(
                    time: Double(index + 1) * 0.02, x: point.x, y: point.y,
                    pressure: 0.5, type: .finger
                ))
            }
            capture.end()
        }

        /// Densifies waypoints into a drawable polyline (a real stroke delivers
        /// a dense sample stream; a 2-sample line classifies as a tap).
        func densified(through waypoints: [SIMD2<Double>], samplesPerSegment: Int = 24)
            -> [SIMD2<Double>]
        {
            var out: [SIMD2<Double>] = []
            for index in 1..<waypoints.count {
                let a = waypoints[index - 1]
                let b = waypoints[index]
                for step in 0..<samplesPerSegment {
                    out.append(a + (b - a) * (Double(step) / Double(samplesPerSegment)))
                }
            }
            if let last = waypoints.last { out.append(last) }
            return out
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

    /// A drag in screen space that starts on a boundary edge of `seed` and
    /// runs outward (away from the patch centroid) across the bunny — the
    /// gesture the growth tools (Draw Strip / Build Quad) grow a new row from.
    private func boundaryDrag(off seed: Mesh, _ harness: Harness, length: Double = 0.09)
        throws -> [SIMD2<Double>]
    {
        var centroid = SIMD3<Float>.zero
        for id in 0..<UInt32(seed.vertexCount) {
            centroid += try #require(seed.vertexPosition(id))
        }
        centroid /= Float(seed.vertexCount)
        let boundary = try #require(
            (0..<UInt32(seed.edgeCount)).first { seed.isBoundaryEdge($0) == true },
            "an authored quad has boundary edges"
        )
        let ends = try #require(seed.edgeEndpoints(of: boundary))
        let a = try #require(seed.vertexPosition(ends.0))
        let b = try #require(seed.vertexPosition(ends.1))
        let start = harness.screenPoint(of: (a + b) * 0.5)
        let centre = harness.screenPoint(of: centroid)
        var outward = start - centre
        let n = simd_length(outward)
        outward = n > 1e-9 ? outward / n : SIMD2<Double>(0, -1)
        return harness.densified(through: [start, start + outward * length])
    }

    @Test("Drawing a strip off an authored quad lands the new faces on the bunny")
    func drawStripGrowsOntoTheBunny() throws {
        let harness = try Harness()
        let (_, radius, snapper) = try bunnyTarget(harness)
        let c = SIMD2<Float>(0.5, 0.5)
        let d: Float = 0.045
        try harness.authorQuad([
            c + SIMD2(-d, -d), c + SIMD2(d, -d), c + SIMD2(d, d), c + SIMD2(-d, d),
        ])
        let seeded = try harness.editMesh()
        #expect(seeded.faceCount == 1)

        // Grow a strip off one boundary edge, out across the surface.
        harness.selectTool(.drawStrip)
        harness.stroke(verb: .pencil, through: try boundaryDrag(off: seeded, harness, length: 0.2))

        let grown = try harness.editMesh()
        #expect(grown.faceCount > seeded.faceCount, "the strip grew at least one quad")
        // Every vertex — the seed AND the newly grown stations — sits on the
        // bunny: the strip's stations snap onto the scanned Target, not the
        // authoring plane.
        #expect(
            try worstSurfaceResidual(grown, snapper) <= radius * 2e-3,
            "a grown strip vertex left the bunny surface"
        )
    }

    @Test("Building a quad off an authored edge lands the new face on the bunny")
    func buildQuadGrowsOntoTheBunny() throws {
        let harness = try Harness()
        let (_, radius, snapper) = try bunnyTarget(harness)
        let c = SIMD2<Float>(0.5, 0.5)
        let d: Float = 0.045
        try harness.authorQuad([
            c + SIMD2(-d, -d), c + SIMD2(d, -d), c + SIMD2(d, d), c + SIMD2(-d, d),
        ])
        let seeded = try harness.editMesh()
        #expect(seeded.faceCount == 1)

        // Build Quad dragged off a boundary edge tents a new face; its apex
        // is dropped onto the bunny (the drag end raycasts onto the Target).
        harness.selectTool(.buildQuad)
        harness.stroke(verb: .pencil, through: try boundaryDrag(off: seeded, harness, length: 0.2))

        let grown = try harness.editMesh()
        #expect(grown.faceCount > seeded.faceCount, "Build Quad grew a face")
        #expect(grown.vertexCount > seeded.vertexCount, "Build Quad added a vertex")
        // The seed AND the new apex sit on the bunny surface.
        #expect(
            try worstSurfaceResidual(grown, snapper) <= radius * 2e-3,
            "a built vertex left the bunny surface"
        )
    }

    /// The row count staged in a live Extend Boundary session.
    private func extendBoundaryRows(_ harness: Harness) -> Int? {
        guard case .extendBoundary(let plan) = harness.editor.cameraSession?.plan
        else { return nil }
        return plan.commitOffsets.count
    }

    @Test("Extend Boundary steps a row off an authored rim on the bunny")
    func extendBoundaryGrowsOntoTheBunny() throws {
        let harness = try Harness()
        let (_, radius, snapper) = try bunnyTarget(harness)
        let c = SIMD2<Float>(0.5, 0.5)
        let d: Float = 0.05
        try harness.authorQuad([
            c + SIMD2(-d, -d), c + SIMD2(d, -d), c + SIMD2(d, d), c + SIMD2(-d, d),
        ])
        let seeded = try harness.editMesh()
        #expect(seeded.faceCount == 1)
        // A corner of the authored quad to hold on (auto-selects the rim).
        let corner = try #require(seeded.vertexPosition(0))

        harness.selectTool(.extendBoundary)
        harness.inputModel.setExtendBoundaryMode(.automatic)
        harness.tap(at: corner)
        #expect(harness.inputModel.cameraToolBanner?.tool == .extendBoundary)

        // Orbit until at least one automatic row steps off; nothing journals
        // while the preview accumulates.
        var fed = 0
        while (extendBoundaryRows(harness) ?? 0) < 1, fed < 400 {
            harness.orbitAndFeed(byPoints: SIMD2(80, 35))
            fed += 1
        }
        #expect((extendBoundaryRows(harness) ?? 0) >= 1, "an automatic row stepped off")
        #expect(harness.bundle.journal.depth == 1, "preview only until commit")

        // Commit lands the whole extrusion as one entry.
        harness.inputModel.commitCameraToolSession()
        let grown = try harness.editMesh()
        #expect(grown.faceCount > seeded.faceCount, "Extend Boundary grew the rim")
        // The extruded rim rows land on the bunny (the tool snaps each row's
        // vertices onto the Target).
        #expect(
            try worstSurfaceResidual(grown, snapper) <= radius * 5e-3,
            "an extruded rim vertex left the bunny surface"
        )
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

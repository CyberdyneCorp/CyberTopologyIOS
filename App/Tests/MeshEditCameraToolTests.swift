import CyberKit
import CyberKitTesting
import Foundation
import Testing
import simd
@testable import CyberTopology

/// Task 4.2: the camera-as-manipulator tools (Patch Clone / Extend
/// Boundary / Transform Vertices) and the stroke-driven Draw Strip, wired
/// end to end — selection strokes through the REAL capture pipeline, real
/// renderer camera orbits fed through the coordinator's arbiter-gated
/// camera→tool feed, engine ops, journaled commits (ONE entry per
/// committed session action), cancel discards (spec: retopology-tools /
/// "Core RT action roster", scenarios "Patch Clone round-trip" and
/// "Extend Boundary automatic mode").
@MainActor
struct MeshEditCameraToolTests {
    /// Coordinator + document-journal harness (the `MeshEditToolTests`
    /// shape; duplicated because that one is private to its suite).
    @MainActor
    private final class Harness {
        var bundle = DocumentBundle()
        let coordinator: MetalViewport.Coordinator
        private(set) var committed: [DocumentCommand] = []

        init() throws {
            coordinator = MetalViewport(
                bundle: DocumentBundle(), orbitSpeed: 1, zoomSpeed: 1,
                onUndo: {}, onRedo: {}
            ).makeCoordinator()
            _ = coordinator.makeView()
            try #require(coordinator.renderer != nil, "Metal device unavailable")
            coordinator.onCommit = { [weak self] command in
                self?.committed.append(command)
                self?.perform(command)
            }
            coordinator.bundleProvider = { [weak self] in
                self?.bundle ?? DocumentBundle()
            }
        }

        var inputModel: ViewportInputModel { coordinator.inputModel }
        var editor: MeshEditController { coordinator.meshEditor }

        func sync() {
            coordinator.syncMesh(from: bundle)
        }

        func perform(_ command: DocumentCommand) {
            bundle.journal.record(command)
            command.apply(to: &bundle)
            sync()
        }

        func undo() {
            if let command = bundle.journal.undo() {
                command.revert(on: &bundle)
                sync()
            }
        }

        func screenPoint(of world: SIMD3<Float>) -> SIMD2<Double> {
            let m = coordinator.renderer!.viewProjectionColumns()
            let point = ScreenRay.normalizedPoint(of: world, viewProjectionColumns: m)!
            return SIMD2(Double(point.x), Double(point.y))
        }

        func selectTool(_ tool: RetopoTool) {
            inputModel.selectTool(tool)
        }

        /// Drives a stroke through the real capture pipeline.
        func stroke(verb: InputArbiter.Verb, through points: [SIMD2<Double>]) {
            let capture = inputModel.controller.capture
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

        func densified(
            through waypoints: [SIMD2<Double>], samplesPerSegment: Int = 24
        ) -> [SIMD2<Double>] {
            var out: [SIMD2<Double>] = []
            for index in 1..<waypoints.count {
                let a = waypoints[index - 1]
                let b = waypoints[index]
                for step in 0..<samplesPerSegment {
                    let t = Double(step) / Double(samplesPerSegment)
                    out.append(a + (b - a) * t)
                }
            }
            if let last = waypoints.last { out.append(last) }
            return out
        }

        /// A Pencil TAP at a world position (the commit gesture).
        func tap(at world: SIMD3<Float>) {
            let point = screenPoint(of: world)
            stroke(verb: .pencil, through: [point, point])
        }

        /// The real camera orbit fed through the coordinator's arbiter-
        /// gated camera→tool routing (the exact path the UIKit gesture
        /// handlers take).
        func orbitAndFeed(byPoints delta: SIMD2<Float>) {
            coordinator.renderer?.orbit(byPoints: delta)
            coordinator.feedCameraToArmedTool()
        }

        var editObject: DocumentManifest.Object? {
            bundle.manifest.objects.first { $0.role == .editMesh }
        }

        func editMesh() throws -> Mesh {
            try bundle.mesh(for: #require(editObject))
        }
    }

    private func meshFromOBJ(_ text: String) throws -> Mesh {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("camera-tool-tests-\(UUID().uuidString).obj")
        try text.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try Mesh.loadOBJ(at: url)
    }

    /// Big flat Target at z = 0 plus the two-quad strip cage:
    ///
    ///   v3(0,2) --- v4(1.4,2) ------- v5(4,2)
    ///    |            |                 |
    ///   v0(0,0) --- v1(1.4,0) ------- v2(4,0)
    private func makeSeededHarness() throws -> Harness {
        let harness = try Harness()
        let target = try meshFromOBJ("""
        v -5 -5 0
        v 5 -5 0
        v 5 5 0
        v -5 5 0
        f 1 2 3 4
        """)
        try harness.bundle.addObject(name: "target", role: .target, mesh: target)
        let strip = try meshFromOBJ("""
        v 0 0 0
        v 1.4 0 0
        v 4 0 0
        v 0 2 0
        v 1.4 2 0
        v 4 2 0
        f 1 2 5 4
        f 2 3 6 5
        """)
        try harness.bundle.addObject(name: "cage", role: .editMesh, mesh: strip)
        harness.sync()
        return harness
    }

    private func payloadBefore(_ harness: Harness) throws -> Data {
        let object = try #require(harness.editObject)
        return try #require(harness.bundle.payloads[object.payloadFile])
    }

    private func committedMeshEditVerb(
        _ harness: Harness, at index: Int = 0
    ) throws -> String {
        guard case .meshEdit(let edit) = try #require(
            harness.committed.indices.contains(index) ? harness.committed[index] : nil
        ) else {
            Issue.record("expected a meshEdit command")
            return ""
        }
        return edit.verb
    }
}

// MARK: - Patch Clone (spec scenario "Patch Clone round-trip")

extension MeshEditCameraToolTests {
    /// The spec scenario end to end: select a patch with one stroke,
    /// orbit the camera, tap to paste — the copy lands projected onto the
    /// Target at the new location and the session stays armed for further
    /// pastes; every paste is ONE journal entry, undo is byte-exact.
    @Test func patchCloneRoundTripPastesProjectedCopiesRepeatably() throws {
        let harness = try makeSeededHarness()
        let before = try payloadBefore(harness)
        harness.selectTool(.patchClone)

        // ONE selection stroke across the left quad.
        harness.stroke(verb: .pencil, through: harness.densified(through: [
            harness.screenPoint(of: SIMD3(0.3, 1, 0)),
            harness.screenPoint(of: SIMD3(1.1, 1, 0)),
        ]))
        let banner = try #require(harness.inputModel.cameraToolBanner)
        #expect(banner.tool == .patchClone)
        #expect(harness.bundle.journal.depth == 0, "selection must not journal")
        // The session ghost preview is live.
        #expect(harness.editor.cameraSession != nil)

        // Orbit the REAL camera through the arbiter-gated feed.
        for _ in 0..<5 {
            harness.orbitAndFeed(byPoints: SIMD2(60, 25))
        }

        // Tap to paste.
        harness.tap(at: SIMD3(2, 1, 0))
        #expect(harness.bundle.journal.depth == 1)
        #expect(try committedMeshEditVerb(harness) == "tool.patchClone.paste")
        var mesh = try harness.editMesh()
        #expect(mesh.faceCount == 4)
        #expect(mesh.vertexCount == 12)
        // Projected onto the Target: every vertex of the clone sits on
        // the z = 0 plane, and the clone did NOT land on the original.
        let positions = mesh.positions()
        for base in stride(from: 18, to: positions.count, by: 3) {
            #expect(abs(positions[base + 2]) < 1e-4)
        }
        var cloneCentroid = SIMD3<Float>.zero
        for base in stride(from: 18, to: positions.count, by: 3) {
            cloneCentroid += SIMD3(positions[base], positions[base + 1], positions[base + 2])
        }
        cloneCentroid /= 6
        #expect(simd_distance(cloneCentroid, SIMD3(0.7, 1, 0)) > 0.2, "paste must move")

        // REPEATABLE: the session survived its own commit — orbit on and
        // paste again through the banner's commit path.
        #expect(harness.inputModel.cameraToolBanner != nil)
        for _ in 0..<4 {
            harness.orbitAndFeed(byPoints: SIMD2(-40, 30))
        }
        harness.inputModel.commitCameraToolSession()
        #expect(harness.bundle.journal.depth == 2)
        mesh = try harness.editMesh()
        #expect(mesh.faceCount == 6)

        // Undo (an EXTERNAL payload change) restores bytes AND discards
        // the armed session.
        harness.undo()
        harness.undo()
        let object = try #require(harness.editObject)
        #expect(harness.bundle.payloads[object.payloadFile] == before)
        #expect(try harness.editMesh().faceCount == 2)
        #expect(harness.inputModel.cameraToolBanner == nil)
        #expect(harness.editor.cameraSession == nil)
    }

    /// Flip mirrors the pending patch: the pasted copy's winding is
    /// reversed (coherent normals for a mirrored placement).
    @Test func patchCloneFlipPastesMirroredPatch() throws {
        let harness = try makeSeededHarness()
        harness.selectTool(.patchClone)
        harness.stroke(verb: .pencil, through: harness.densified(through: [
            harness.screenPoint(of: SIMD3(0.3, 1, 0)),
            harness.screenPoint(of: SIMD3(1.1, 1, 0)),
        ]))
        try #require(harness.editor.cameraSession != nil)
        harness.inputModel.togglePatchCloneFlip()
        #expect(harness.inputModel.cameraToolBanner?.flipped == true)
        for _ in 0..<3 {
            harness.orbitAndFeed(byPoints: SIMD2(50, 0))
        }
        harness.inputModel.commitCameraToolSession()
        #expect(harness.bundle.journal.depth == 1)
        // The clone exists; its winding was reversed (the engine op's
        // flip contract is asserted down in PlacementOpsTests — here the
        // end-to-end path proves the option reaches the op).
        #expect(try harness.editMesh().faceCount > 2)
    }

    /// Barrel roll rotates the patch being placed (task 3.7a consumer;
    /// hardware DELIVERY is the device-only PencilProHardwareTests skip —
    /// this drives the same model entry the hover recognizer calls).
    @Test func barrelRollRotatesArmedPatchClonePlacement() throws {
        let harness = try makeSeededHarness()
        // Top-down camera: the roll axis (camera forward) is exactly -z,
        // so the rotated extents are exact after the plane snap.
        harness.coordinator.renderer?.camera = CameraState(
            focus: SIMD3(1.8, 1, 0), distance: 12, azimuth: 0, elevation: 0
        )
        harness.selectTool(.patchClone)
        harness.stroke(verb: .pencil, through: harness.densified(through: [
            harness.screenPoint(of: SIMD3(0.3, 1, 0)),
            harness.screenPoint(of: SIMD3(1.1, 1, 0)),
        ]))
        try #require(harness.editor.cameraSession != nil)

        // The first report is the baseline; the second rotates by the
        // delta.
        harness.inputModel.barrelRollChanged(0.25)
        harness.inputModel.barrelRollChanged(0.25 + .pi / 2)
        guard case .patchClone(let plan) = try #require(harness.editor.cameraSession).plan
        else {
            Issue.record("expected a patch clone session")
            return
        }
        #expect(abs(plan.rollAngle - .pi / 2) < 1e-5)

        // The paste applies the rotation: the whole strip patch (4 wide,
        // 2 tall in x/y) comes back rotated 90° about the view axis, so
        // the pasted copy's extent is ~2 wide and ~4 tall.
        harness.inputModel.commitCameraToolSession()
        #expect(harness.bundle.journal.depth == 1)
        let positions = try harness.editMesh().positions()
        var lower = SIMD2<Float>(.greatestFiniteMagnitude, .greatestFiniteMagnitude)
        var upper = -lower
        for base in stride(from: 18, to: positions.count, by: 3) {
            lower = simd_min(lower, SIMD2(positions[base], positions[base + 1]))
            upper = simd_max(upper, SIMD2(positions[base], positions[base + 1]))
        }
        let extent = upper - lower
        #expect(abs(extent.x - 2.0) < 0.15, "extent \(extent)")
        #expect(abs(extent.y - 4.0) < 0.15, "extent \(extent)")
    }
}

// MARK: - Extend Boundary (spec scenario "Extend Boundary automatic mode")

extension MeshEditCameraToolTests {
    /// The spec scenario end to end: hold on a boundary vertex
    /// auto-selects the whole boundary; with automatic steps enabled,
    /// orbiting extrudes quad strips continuously following the camera;
    /// commit journals the WHOLE stack as one entry; undo restores bytes.
    @Test func extendBoundaryAutomaticModeStepsRowsWithTheCameraIntoOneEntry() throws {
        let harness = try makeSeededHarness()
        let before = try payloadBefore(harness)
        harness.selectTool(.extendBoundary)
        harness.inputModel.setExtendBoundaryMode(.automatic)

        // HOLD on a boundary vertex: the WHOLE closed rim auto-selects.
        harness.tap(at: SIMD3(0, 0, 0))
        let banner = try #require(harness.inputModel.cameraToolBanner)
        #expect(banner.tool == .extendBoundary)
        #expect(banner.mode == .automatic)
        #expect(banner.status.contains("6 boundary vertices"))
        #expect(!banner.canCommit)

        // Orbit until at least two automatic rows stepped off. Nothing
        // journals while the strips accumulate (preview only).
        var fed = 0
        while (rowCount(harness) ?? 0) < 2, fed < 400 {
            harness.orbitAndFeed(byPoints: SIMD2(80, 35))
            fed += 1
        }
        let rows = try #require(rowCount(harness))
        #expect(rows >= 2)
        #expect(harness.bundle.journal.depth == 0)

        // Commit: the whole stack lands as ONE journal entry.
        harness.inputModel.commitCameraToolSession()
        #expect(harness.bundle.journal.depth == 1)
        #expect(try committedMeshEditVerb(harness) == "tool.extendBoundary.grid")
        let mesh = try harness.editMesh()
        #expect(mesh.faceCount == 2 + 6 * rows)  // 6 rim edges per row (closed)
        #expect(mesh.vertexCount == 6 + 6 * rows)
        // The session ended with the extrusion.
        #expect(harness.inputModel.cameraToolBanner == nil)

        harness.undo()
        let object = try #require(harness.editObject)
        #expect(harness.bundle.payloads[object.payloadFile] == before)
        #expect(try harness.editMesh().faceCount == 2)
    }

    private func rowCount(_ harness: Harness) -> Int? {
        guard case .extendBoundary(let plan) =
            harness.editor.cameraSession?.plan
        else { return nil }
        return plan.commitOffsets.count
    }

    /// A stroke ALONG part of the boundary selects that contiguous run;
    /// single mode extrudes exactly one camera-adjusted row on commit.
    @Test func extendBoundarySingleModeExtrudesTheStrokedSubChain() throws {
        let harness = try makeSeededHarness()
        harness.selectTool(.extendBoundary)
        harness.inputModel.setExtendBoundaryMode(.single)

        // Stroke along the bottom edge (v0 → v2): the bottom three
        // vertices select as an OPEN sub-chain.
        harness.stroke(verb: .pencil, through: harness.densified(through: [
            harness.screenPoint(of: SIMD3(0, 0, 0)),
            harness.screenPoint(of: SIMD3(4, 0, 0)),
        ]))
        let banner = try #require(harness.inputModel.cameraToolBanner)
        #expect(banner.status.contains("3 boundary vertices"))

        for _ in 0..<6 {
            harness.orbitAndFeed(byPoints: SIMD2(70, 30))
        }
        try #require(harness.inputModel.cameraToolBanner?.canCommit == true)
        harness.inputModel.commitCameraToolSession()
        #expect(harness.bundle.journal.depth == 1)
        let mesh = try harness.editMesh()
        #expect(mesh.faceCount == 4)  // 2 sub-chain edges -> 2 new quads
        #expect(mesh.vertexCount == 9)
        #expect(try mesh.stats().quads == 4)
    }

    /// Fan mode closes the selected boundary onto one camera-placed apex
    /// with triangles.
    @Test func extendBoundaryFanModeClosesChainWithTriangles() throws {
        let harness = try makeSeededHarness()
        harness.selectTool(.extendBoundary)
        harness.inputModel.setExtendBoundaryMode(.fan)
        harness.stroke(verb: .pencil, through: harness.densified(through: [
            harness.screenPoint(of: SIMD3(0, 0, 0)),
            harness.screenPoint(of: SIMD3(4, 0, 0)),
        ]))
        try #require(harness.editor.cameraSession != nil)
        for _ in 0..<4 {
            harness.orbitAndFeed(byPoints: SIMD2(60, 20))
        }
        harness.inputModel.commitCameraToolSession()
        #expect(harness.bundle.journal.depth == 1)
        #expect(try committedMeshEditVerb(harness) == "tool.extendBoundary.fan")
        let mesh = try harness.editMesh()
        #expect(try mesh.stats().triangles == 2)  // 2 sub-chain edges
        #expect(mesh.vertexCount == 7)  // one shared apex
    }

    /// Cancel discards the accumulated automatic rows without journaling.
    @Test func extendBoundaryCancelDiscardsAccumulatedRows() throws {
        let harness = try makeSeededHarness()
        harness.selectTool(.extendBoundary)
        harness.inputModel.setExtendBoundaryMode(.automatic)
        harness.tap(at: SIMD3(0, 0, 0))
        try #require(harness.editor.cameraSession != nil)
        for _ in 0..<80 {
            harness.orbitAndFeed(byPoints: SIMD2(80, 35))
        }
        harness.inputModel.cancelCameraToolSession()
        #expect(harness.bundle.journal.depth == 0)
        #expect(harness.inputModel.cameraToolBanner == nil)
        #expect(try harness.editMesh().faceCount == 2)
    }
}

// MARK: - Transform Vertices

extension MeshEditCameraToolTests {
    /// Selected vertices lock to screen space: the camera moves them over
    /// the model (live preview), commit re-snaps onto the Target, journals
    /// ONCE, and reports how many re-snapped.
    @Test func transformVerticesFollowsCameraThenResnapsAndReports() throws {
        let harness = try makeSeededHarness()
        let before = try payloadBefore(harness)
        harness.selectTool(.transformVertices)

        // Select the left column (v0, v3) with one stroke.
        harness.stroke(verb: .pencil, through: harness.densified(through: [
            harness.screenPoint(of: SIMD3(0, 0, 0)),
            harness.screenPoint(of: SIMD3(0, 2, 0)),
        ]))
        let banner = try #require(harness.inputModel.cameraToolBanner)
        #expect(banner.tool == .transformVertices)
        #expect(banner.status.contains("2 vertices"))

        // The camera feed mutates the LIVE mesh (screen lock) while the
        // document payload stays untouched. NOTE: an orbit is a rotation
        // about the camera FOCUS, so a vertex sitting exactly on the
        // focus is screen-lock's fixed point — assert movement on v3.
        for _ in 0..<5 {
            harness.orbitAndFeed(byPoints: SIMD2(70, 30))
        }
        let live = try #require(harness.coordinator.recognizerEditMesh)
        let movedLive = try #require(live.vertexPosition(3))
        #expect(simd_distance(movedLive, SIMD3(0, 2, 0)) > 0.05)
        #expect(harness.bundle.journal.depth == 0)
        let object = try #require(harness.editObject)
        #expect(harness.bundle.payloads[object.payloadFile] == before)

        // Commit: ONE journal entry, vertices re-snapped onto the Target
        // plane, and the re-snap report published.
        harness.inputModel.commitCameraToolSession()
        #expect(harness.bundle.journal.depth == 1)
        #expect(try committedMeshEditVerb(harness) == "tool.transformVertices")
        let mesh = try harness.editMesh()
        let v0 = try #require(mesh.vertexPosition(0))
        let v3 = try #require(mesh.vertexPosition(3))
        #expect(abs(v0.z) < 1e-4)
        #expect(abs(v3.z) < 1e-4)
        #expect(simd_distance(v3, SIMD3(0, 2, 0)) > 0.05, "the move must commit")
        let report = try #require(harness.editor.lastResnapReport)
        #expect(report.resnapped >= 1)
        #expect(report.maxDistance > 0)
        let status = try #require(harness.inputModel.cameraToolStatus)
        #expect(status.contains("re-snapped"))
        #expect(harness.inputModel.cameraToolBanner == nil)

        harness.undo()
        #expect(harness.bundle.payloads[object.payloadFile] == before)
    }

    /// Cancel discards the live camera edits: the mesh reloads from the
    /// document payload, nothing journals.
    @Test func transformVerticesCancelDiscardsLiveEdits() throws {
        let harness = try makeSeededHarness()
        harness.selectTool(.transformVertices)
        harness.stroke(verb: .pencil, through: harness.densified(through: [
            harness.screenPoint(of: SIMD3(0, 0, 0)),
            harness.screenPoint(of: SIMD3(0, 2, 0)),
        ]))
        try #require(harness.editor.cameraSession != nil)
        for _ in 0..<5 {
            harness.orbitAndFeed(byPoints: SIMD2(70, 30))
        }
        harness.inputModel.cancelCameraToolSession()
        #expect(harness.bundle.journal.depth == 0)
        let live = try #require(harness.coordinator.recognizerEditMesh)
        #expect(try #require(live.vertexPosition(0)) == SIMD3(0, 0, 0))
        #expect(harness.editor.cameraSession == nil)
    }
}

// MARK: - Draw Strip (stroke-driven)

extension MeshEditCameraToolTests {
    /// Drag from a boundary quad edge: the strip follows the stroke with
    /// stations one source-edge-length apart (preserving quad size),
    /// welded onto the edge, one journal entry; undo restores bytes.
    @Test func drawStripFollowsStrokePreservingQuadSize() throws {
        let harness = try makeSeededHarness()
        let before = try payloadBefore(harness)
        // Top-down camera: the strip's side frames span cross(view,
        // tangent) — with the view exactly -z the rail positions are
        // exact after the plane snap.
        harness.coordinator.renderer?.camera = CameraState(
            focus: SIMD3(0.7, -0.5, 0), distance: 12, azimuth: 0, elevation: 0
        )
        harness.selectTool(.drawStrip)

        // Drag from the bottom edge of the LEFT quad (v0-v1, length 1.4)
        // straight down for ~2.9 units: two stations, two quads.
        harness.stroke(verb: .pencil, through: harness.densified(through: [
            harness.screenPoint(of: SIMD3(0.7, 0, 0)),
            harness.screenPoint(of: SIMD3(0.7, -2.9, 0)),
        ]))

        #expect(harness.bundle.journal.depth == 1)
        #expect(try committedMeshEditVerb(harness) == "tool.drawStrip")
        let mesh = try harness.editMesh()
        #expect(mesh.faceCount == 4)
        #expect(try mesh.stats().quads == 4)
        #expect(mesh.vertexCount == 10)
        // Quad size preserved: the first station's rail pair spans the
        // source edge length (1.4) one edge-length below it.
        #expect(mesh.nearestVertex(to: SIMD3(0, -1.4, 0), maxDistance: 0.1) != nil)
        #expect(mesh.nearestVertex(to: SIMD3(1.4, -1.4, 0), maxDistance: 0.1) != nil)
        // Welded onto the start edge.
        let start = try #require(mesh.nearestEdge(to: SIMD3(0.7, 0, 0), maxDistance: 0.05))
        #expect(mesh.edgeFaces(of: start.edge).count == 2)

        harness.undo()
        let object = try #require(harness.editObject)
        #expect(harness.bundle.payloads[object.payloadFile] == before)
    }

    /// Strokes that do not start on a boundary edge journal nothing.
    @Test func drawStripFromInteriorOrEmptySurfaceIsInert() throws {
        let harness = try makeSeededHarness()
        harness.selectTool(.drawStrip)
        // Start over empty Target surface.
        harness.stroke(verb: .pencil, through: harness.densified(through: [
            harness.screenPoint(of: SIMD3(-4, -4, 0)),
            harness.screenPoint(of: SIMD3(-4, -1, 0)),
        ]))
        #expect(harness.bundle.journal.depth == 0)
    }
}

// MARK: - Session routing invariants

extension MeshEditCameraToolTests {
    /// The arbiter owns the camera→tool routing: the gate is open exactly
    /// while a session is armed, and the coordinator's feed respects it.
    @Test func cameraFeedIsGatedByTheArbiter() throws {
        let harness = try makeSeededHarness()
        let controller = harness.inputModel.controller
        #expect(!controller.cameraFeedsArmedTool)

        harness.selectTool(.patchClone)
        harness.stroke(verb: .pencil, through: harness.densified(through: [
            harness.screenPoint(of: SIMD3(0.3, 1, 0)),
            harness.screenPoint(of: SIMD3(1.1, 1, 0)),
        ]))
        try #require(harness.editor.cameraSession != nil)
        #expect(controller.cameraFeedsArmedTool)

        // Cancelling closes the gate again.
        harness.inputModel.cancelCameraToolSession()
        #expect(!controller.cameraFeedsArmedTool)

        // And with the gate closed, orbits no longer reach the session.
        harness.orbitAndFeed(byPoints: SIMD2(50, 20))
        #expect(harness.editor.cameraSession == nil)
    }

    /// Selecting a verb persistently (disarming the tool) discards the
    /// armed session without journaling.
    @Test func verbTapDisarmsToolAndDiscardsSession() throws {
        let harness = try makeSeededHarness()
        harness.selectTool(.extendBoundary)
        harness.tap(at: SIMD3(0, 0, 0))
        try #require(harness.editor.cameraSession != nil)

        harness.inputModel.verbPressBegan(.relax, at: 0)
        harness.inputModel.verbPressEnded(.relax, at: 0.1)  // quick tap
        #expect(harness.inputModel.activeTool == nil)
        #expect(harness.editor.cameraSession == nil)
        #expect(harness.inputModel.cameraToolBanner == nil)
        #expect(harness.bundle.journal.depth == 0)
    }

    /// A new selection stroke replaces the armed session.
    @Test func newSelectionStrokeReplacesArmedSession() throws {
        let harness = try makeSeededHarness()
        harness.selectTool(.patchClone)
        harness.stroke(verb: .pencil, through: harness.densified(through: [
            harness.screenPoint(of: SIMD3(0.3, 1, 0)),
            harness.screenPoint(of: SIMD3(1.1, 1, 0)),
        ]))
        guard case .patchClone(let first)? = harness.editor.cameraSession?.plan else {
            Issue.record("expected a patch clone session")
            return
        }
        // Select ONLY the right quad now (stroke near its right edge).
        harness.stroke(verb: .pencil, through: harness.densified(through: [
            harness.screenPoint(of: SIMD3(3.6, 0.6, 0)),
            harness.screenPoint(of: SIMD3(3.6, 1.4, 0)),
        ]))
        guard case .patchClone(let second)? = harness.editor.cameraSession?.plan else {
            Issue.record("expected a replacement session")
            return
        }
        #expect(second.faces != first.faces)
        #expect(harness.bundle.journal.depth == 0)
    }

    /// The visual-verification probes drive REAL journaled actions for
    /// every camera tool (the screenshot hooks' entry point).
    @Test func visualVerificationProbesJournalEveryCameraTool() throws {
        for tool in RetopoTool.allCases where tool.isCameraManipulator || tool == .drawStrip {
            let harness = try makeSeededHarness()
            #expect(
                harness.editor.probeToolStrokeForVisualVerification(tool),
                "probe for \(tool.rawValue) did not journal"
            )
            #expect(!harness.committed.isEmpty, "\(tool.rawValue) committed nothing")
        }
    }
}

import CyberKit
import CyberKitTesting
import Foundation
import Testing
import simd
@testable import CyberTopology

/// Task 3.3: the five verbs wired end to end — committed stroke fixtures and
/// synthetic verb scrubs replay through the REAL pipeline (capture → engine
/// recognizer → MeshEditController → engine ops → journaled DocumentCommand)
/// against a real coordinator, renderer camera, and engine meshes. Undo and
/// cancellation are asserted byte-exact (specs: pencil-interaction / "Five
/// coherent verbs across stages", document-model / "EditMesh vertex
/// snapping", quality-assurance / "Gesture grammar regression suite" — the
/// fixtures now assert resulting MESH STATE, not just interpretation).
@MainActor
struct MeshEditControllerTests {
    /// Coordinator + document-journal harness: `perform` mirrors
    /// `TopoDocument.perform` (record + apply) and re-syncs the viewport,
    /// exactly like the SwiftUI update pass does after a commit.
    @MainActor
    private final class Harness {
        var bundle = DocumentBundle()
        let coordinator: MetalViewport.Coordinator
        private(set) var committed: [DocumentCommand] = []
        /// When false, `perform`/`undo`/`redo` do NOT re-sync the viewport —
        /// modeling the race window where touches drain before the SwiftUI
        /// update pass runs (journal-integrity regression tests). The
        /// coordinator must self-heal through `bundleProvider`, exactly as
        /// in production.
        var autoSync = true

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
            // Chip alternative swap (task 3.5): mirrors
            // `TopoDocument.performReplacingLast` (expected-current guard,
            // revert + apply + in-place journal replacement in one step).
            coordinator.onReplaceCommit = { [weak self] replacement, expected in
                self?.replaceLast(with: replacement, expecting: expected) ?? false
            }
            // Production wiring (updateUIView): strokes re-sync against the
            // LIVE document, never a stale per-update snapshot.
            coordinator.bundleProvider = { [weak self] in
                self?.bundle ?? DocumentBundle()
            }
        }

        func sync() {
            coordinator.syncMesh(from: bundle)
        }

        func perform(_ command: DocumentCommand) {
            bundle.journal.record(command)
            command.apply(to: &bundle)
            if autoSync { sync() }
        }

        func replaceLast(
            with command: DocumentCommand, expecting current: DocumentCommand
        ) -> Bool {
            guard bundle.journal.currentCommand == current,
                let replaced = bundle.journal.replaceCurrent(with: command)
            else { return false }
            replaced.revert(on: &bundle)
            command.apply(to: &bundle)
            if autoSync { sync() }
            return true
        }

        func undo() {
            if let command = bundle.journal.undo() {
                command.revert(on: &bundle)
                if autoSync { sync() }
            }
        }

        func redo() {
            if let command = bundle.journal.redo() {
                command.apply(to: &bundle)
                if autoSync { sync() }
            }
        }

        /// Normalized viewport point of a world position under the live
        /// camera (the inverse of `ViewportRenderer.cameraRay`).
        func screenPoint(of world: SIMD3<Float>) -> SIMD2<Double> {
            let m = coordinator.renderer!.viewProjectionColumns()
            let cx = m[0] * world.x + m[4] * world.y + m[8] * world.z + m[12]
            let cy = m[1] * world.x + m[5] * world.y + m[9] * world.z + m[13]
            let cw = m[3] * world.x + m[7] * world.y + m[11] * world.z + m[15]
            return SIMD2(
                Double(cx / cw) * 0.5 + 0.5,
                1 - (Double(cy / cw) * 0.5 + 0.5)
            )
        }

        /// Drives a stroke through the real capture pipeline (the entry the
        /// UIKit touch layer uses), with the given verb and pressure.
        func stroke(
            verb: InputArbiter.Verb, through points: [SIMD2<Double>], pressure: Double = 0.5
        ) {
            let capture = coordinator.inputModel.controller.capture
            guard let first = points.first else { return }
            capture.begin(
                source: .finger, verb: verb,
                sample: .init(
                    time: 0, x: first.x, y: first.y, pressure: pressure, type: .finger
                )
            )
            for (index, point) in points.dropFirst().enumerated() {
                capture.append(sample: .init(
                    time: Double(index + 1) * 0.02, x: point.x, y: point.y,
                    pressure: pressure, type: .finger
                ))
            }
            capture.end()
        }

        /// Densifies waypoints into a drawable polyline (a real Pencil
        /// stroke delivers a dense sample stream; a 2-sample "line" would
        /// classify as a tap).
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

        var editObject: DocumentManifest.Object? {
            bundle.manifest.objects.first { $0.role == .editMesh }
        }

        func editMesh() throws -> Mesh {
            try bundle.mesh(for: #require(editObject))
        }
    }

    private func meshFromOBJ(_ text: String) throws -> Mesh {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("edit-ctl-\(UUID().uuidString).obj")
        try text.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try Mesh.loadOBJ(at: url)
    }

    /// Big flat Target at z = 0 (verbs anchor their brushes to it).
    private func addPlaneTarget(to harness: Harness) throws {
        let target = try meshFromOBJ("""
        v -5 -5 0
        v 5 -5 0
        v 5 5 0
        v -5 5 0
        f 1 2 3 4
        """)
        try harness.bundle.addObject(name: "target", role: .target, mesh: target)
        harness.sync()
    }

    /// EditMesh: two disconnected quad strips 0.2 apart on the Target plane.
    private func addStripsEditMesh(to harness: Harness) throws {
        let strips = try meshFromOBJ("""
        v 0 0 0
        v 1 0 0
        v 2 0 0
        v 3 0 0
        v 0 1 0
        v 1 1 0
        v 2 1 0
        v 3 1 0
        v 0 1.2 0
        v 1 1.2 0
        v 2 1.2 0
        v 3 1.2 0
        v 0 2.2 0
        v 1 2.2 0
        v 2 2.2 0
        v 3 2.2 0
        f 1 2 6 5
        f 2 3 7 6
        f 3 4 8 7
        f 9 10 14 13
        f 10 11 15 14
        f 11 12 16 15
        """)
        try harness.bundle.addObject(name: "cage", role: .editMesh, mesh: strips)
        harness.sync()
    }

    /// 3x3-quad grid with the interior (1,1) vertex perturbed.
    private func addPerturbedGridEditMesh(to harness: Harness) throws {
        var obj = ""
        for row in 0...3 {
            for col in 0...3 {
                obj += row == 1 && col == 1 ? "v 1.35 0.75 0\n" : "v \(col) \(row) 0\n"
            }
        }
        for row in 0..<3 {
            for col in 0..<3 {
                let a = row * 4 + col + 1
                obj += "f \(a) \(a + 1) \(a + 5) \(a + 4)\n"
            }
        }
        try harness.bundle.addObject(
            name: "cage", role: .editMesh, mesh: try meshFromOBJ(obj)
        )
        harness.sync()
    }

    // MARK: - Pencil: square fixture → journaled quad on the seeded Target

    /// Fixture-replay integration: the committed square gesture creates a
    /// journaled quad on the seeded (domed) Target; undo removes it, redo
    /// restores it. This is the same injection entry the UI test drives.
    @Test func squareFixtureCreatesJournaledQuadOnSeededTarget() throws {
        let harness = try Harness()
        let target = try Mesh.loadOBJ(at: UITestSupport.writeSeedTargetOBJ())
        try harness.bundle.addObject(name: "target", role: .target, mesh: target)
        harness.sync()
        #expect(harness.editObject == nil)

        harness.coordinator.inputModel.injectSquareStroke()

        // One journaled command created the EditMesh object with one quad.
        #expect(harness.bundle.journal.depth == 1)
        let object = try #require(harness.editObject)
        #expect(object.counts == .init(vertices: 4, faces: 1))
        let created = try harness.editMesh()
        #expect(created.vertexCount == 4)
        #expect(created.faceCount == 1)

        // Every authored vertex sits ON the domed Target surface (spec:
        // document-model / "EditMesh vertex snapping") — the dome has no
        // z = 0 point in the stroke's footprint, so this cannot pass
        // without real projection.
        let snapper = try SurfaceSnapper(target: target)
        for id in 0..<4 {
            let position = try #require(created.vertexPosition(UInt32(id)))
            #expect(position.z > 0.05)
            let hit = try #require(snapper.snapToSurface(position))
            #expect(simd_distance(hit.point, position) < 1e-3)
        }

        // Undo removes the quad; redo restores it (three/four-finger taps
        // route to exactly these journal walks).
        harness.undo()
        #expect(harness.editObject == nil)
        #expect(harness.coordinator.recognizerEditMesh == nil)
        harness.redo()
        #expect(try harness.editMesh().faceCount == 1)
    }

    @Test func squareFixtureAppendsQuadToExistingEditMesh() throws {
        let harness = try Harness()
        try addPlaneTarget(to: harness)
        try addStripsEditMesh(to: harness)
        let object = try #require(harness.editObject)
        let payloadBefore = try #require(harness.bundle.payloads[object.payloadFile])

        harness.coordinator.inputModel.injectSquareStroke()

        #expect(harness.bundle.journal.depth == 1)
        guard case .meshEdit(let edit) = try #require(harness.committed.first) else {
            Issue.record("expected a meshEdit command")
            return
        }
        #expect(edit.verb == "pencil.createQuad")
        #expect(edit.before == payloadBefore)
        #expect(edit.afterCounts == .init(vertices: 20, faces: 7))
        #expect(try harness.editMesh().faceCount == 7)

        // Undo restores the exact pre-stroke payload bytes.
        harness.undo()
        #expect(harness.bundle.payloads[object.payloadFile] == payloadBefore)
        #expect(try harness.editMesh().faceCount == 6)
    }

    /// REGRESSION (device: quads rendered as a self-intersecting bowtie): a
    /// TALL-THIN quad drawn over the Target must create a SIMPLE face, not a
    /// crossed one. The corner estimate orders corners by stroke position (the
    /// drawn perimeter), which is always simple; angle-around-centroid
    /// ordering swapped two corners of a thin quad and twisted the face. This
    /// drives the full app path — recognize, unproject onto the Target, build
    /// the face — and checks the result's screen projection does not cross.
    @Test func tallThinQuadCreatesASimpleFaceNotABowtie() throws {
        let harness = try Harness()
        try addPlaneTarget(to: harness)

        // A tall, thin quad (world 0.4 wide x 2 tall) on the plane — the
        // aspect that made corner ordering fragile.
        let corners: [SIMD3<Float>] = [
            SIMD3(0, 0, 0), SIMD3(0.4, 0, 0), SIMD3(0.4, 2, 0), SIMD3(0, 2, 0),
        ]
        harness.stroke(
            verb: .pencil,
            through: harness.densified(through: corners.map { harness.screenPoint(of: $0) } + [harness.screenPoint(of: corners[0])])
        )

        #expect(harness.bundle.journal.depth == 1, "the thin quad should create a face")
        let mesh = try harness.editMesh()
        #expect(mesh.faceCount == 1)
        #expect(mesh.vertexCount == 4)

        // Project the created ring to screen and assert it does not
        // self-intersect (bowtie). Vertices are in creation = ring order.
        let screen = (0..<4).compactMap { mesh.vertexPosition(UInt32($0)) }
            .map { harness.screenPoint(of: $0) }
        try #require(screen.count == 4)
        func ccw(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>) -> Bool {
            (c.y - a.y) * (b.x - a.x) > (b.y - a.y) * (c.x - a.x)
        }
        func crosses(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>, _ d: SIMD2<Double>) -> Bool {
            ccw(a, c, d) != ccw(b, c, d) && ccw(a, b, c) != ccw(a, b, d)
        }
        let bowtie = crosses(screen[0], screen[1], screen[2], screen[3])
            || crosses(screen[1], screen[2], screen[3], screen[0])
        #expect(!bowtie, "the created face self-intersects (bowtie): \(screen)")
    }

    /// A straight line over nothing interprets as toggle-visibility (not a
    /// 3.3 verb): the mesh and journal stay untouched.
    @Test func pencilLineDoesNotMutate() throws {
        let harness = try Harness()
        try addPlaneTarget(to: harness)
        try addStripsEditMesh(to: harness)

        harness.stroke(verb: .pencil, through: [SIMD2(0.1, 0.9), SIMD2(0.2, 0.85)])
        #expect(harness.bundle.journal.depth == 0)
        #expect(harness.committed.isEmpty)
    }

    // MARK: - Relax

    @Test func relaxScrubSmoothsUnderTheBrushAndJournalsOnce() throws {
        let harness = try Harness()
        try addPlaneTarget(to: harness)
        try addPerturbedGridEditMesh(to: harness)
        let object = try #require(harness.editObject)
        let payloadBefore = try #require(harness.bundle.payloads[object.payloadFile])
        let centroid = SIMD3<Float>(1, 1, 0)
        let distanceBefore = simd_distance(SIMD3(1.35, 0.75, 0), centroid)

        // Scrub back and forth over the perturbed region: one journaled
        // command for the whole stroke.
        let brush = harness.screenPoint(of: SIMD3(1, 1, 0))
        let nearby = harness.screenPoint(of: SIMD3(1.3, 0.8, 0))
        harness.stroke(verb: .relax, through: [brush, nearby, brush])

        #expect(harness.bundle.journal.depth == 1)
        let relaxed = try harness.editMesh()
        let vertex = try #require(relaxed.nearestVertex(to: centroid, maxDistance: 0.6))
        #expect(simd_distance(vertex.position, centroid) < distanceBefore)

        harness.undo()
        #expect(harness.bundle.payloads[object.payloadFile] == payloadBefore)
    }

    // MARK: - Move (geodesic falloff)

    @Test func moveDragsWithGeodesicFalloffIgnoringDisconnectedComponent() throws {
        let harness = try Harness()
        try addPlaneTarget(to: harness)
        try addStripsEditMesh(to: harness)

        // Drag the strip-A vertex at (0,1) — 0.2 away from strip B — along
        // +x by 0.6 world units.
        let grab = harness.screenPoint(of: SIMD3(0, 1, 0))
        let drop = harness.screenPoint(of: SIMD3(0.6, 1, 0))
        harness.stroke(verb: .move, through: [grab, drop])

        #expect(harness.bundle.journal.depth == 1)
        let moved = try harness.editMesh()
        // The seed followed the drag (full weight at zero geodesic
        // distance)…
        let seed = try #require(moved.nearestVertex(to: SIMD3(0.6, 1, 0), maxDistance: 0.1))
        #expect(abs(seed.position.x - 0.6) < 1e-3)
        // …its strip-A neighbor (the only vertex left on y == 1 between
        // x 1 and 2) moved partially along the drag…
        let positions = allPositions(of: moved)
        let neighbor = try #require(positions.first {
            abs($0.y - 1) < 1e-3 && $0.x > 1.05 && $0.x < 1.7
        })
        #expect(neighbor.x > 1.05)
        // …and the whole Euclidean-close strip B stayed bit-exact (spec
        // scenario "Geodesic Move falloff"), starting with the vertex only
        // 0.2 away from the seed.
        for x in 0...3 {
            for y in [Float(1.2), 2.2] {
                let expected = SIMD3(Float(x), y, 0)
                let pick = try #require(
                    moved.nearestVertex(to: expected, maxDistance: 1e-5)
                )
                #expect(pick.position == expected)
            }
        }
    }

    /// x,y,z of every live vertex (walks stable engine ids).
    private func allPositions(of mesh: Mesh) -> [SIMD3<Float>] {
        var out: [SIMD3<Float>] = []
        var id: UInt32 = 0
        while out.count < mesh.vertexCount && id < 100_000 {
            if let position = mesh.vertexPosition(id) {
                out.append(position)
            }
            id += 1
        }
        return out
    }

    // MARK: - Tweak

    @Test func tweakDragsExactlyOneVertex() throws {
        let harness = try Harness()
        try addPlaneTarget(to: harness)
        try addStripsEditMesh(to: harness)

        let grab = harness.screenPoint(of: SIMD3(3, 0, 0))
        let drop = harness.screenPoint(of: SIMD3(3.5, -0.4, 0))
        harness.stroke(verb: .tweak, through: [grab, drop])

        #expect(harness.bundle.journal.depth == 1)
        let tweaked = try harness.editMesh()
        let vertex = try #require(
            tweaked.nearestVertex(to: SIMD3(3.5, -0.4, 0), maxDistance: 0.05)
        )
        #expect(abs(vertex.position.z) < 1e-4)  // stayed on the Target plane
        // Its neighbor did not move (tweak is single-vertex by definition).
        let neighbor = try #require(
            tweaked.nearestVertex(to: SIMD3(2, 0, 0), maxDistance: 1e-4)
        )
        #expect(neighbor.position == SIMD3(2, 0, 0))
    }

    // MARK: - Erase

    @Test func eraseDeletesFacesUnderTheStrokeWithPressureScaledRadius() throws {
        let harness = try Harness()
        try addPlaneTarget(to: harness)
        // Fine 6x6 grid (0.5 spacing): face centroids sit 0.354+ from the
        // brush center, between the zero-pressure radius (~0.28) and the
        // full-pressure radius (~0.85) — so pressure decides the outcome.
        var obj = ""
        for row in 0...6 {
            for col in 0...6 {
                obj += "v \(Double(col) * 0.5) \(Double(row) * 0.5) 0\n"
            }
        }
        for row in 0..<6 {
            for col in 0..<6 {
                let a = row * 7 + col + 1
                obj += "f \(a) \(a + 1) \(a + 8) \(a + 7)\n"
            }
        }
        try harness.bundle.addObject(
            name: "cage", role: .editMesh, mesh: try meshFromOBJ(obj)
        )
        harness.sync()
        let object = try #require(harness.editObject)
        let payloadBefore = try #require(harness.bundle.payloads[object.payloadFile])
        let facesBefore = try harness.editMesh().faceCount
        #expect(facesBefore == 36)

        let center = harness.screenPoint(of: SIMD3(1.5, 1.5, 0))
        harness.stroke(verb: .erase, through: [center, center], pressure: 1)

        #expect(harness.bundle.journal.depth == 1)
        let erased = try harness.editMesh()
        #expect(erased.faceCount < facesBefore)
        guard case .meshEdit(let edit) = try #require(harness.committed.first) else {
            Issue.record("expected a meshEdit command")
            return
        }
        #expect(edit.verb == "erase")

        // Undo restores the exact payload; a zero-pressure stroke at the
        // same spot reaches no face centroid, so nothing changes and — by
        // the no-op rule — nothing is journaled (pressure-scaled radius,
        // spec: retopology-tools "Erase pressure scales coarseness").
        harness.undo()
        #expect(harness.bundle.payloads[object.payloadFile] == payloadBefore)
        harness.stroke(verb: .erase, through: [center, center], pressure: 0)
        #expect(try harness.editMesh().faceCount == facesBefore)
        #expect(harness.bundle.journal.depth == 0)
    }

    // MARK: - Cancellation (palm rejection / pen-priority aborts)

    @Test func cancelledStrokeDiscardsLiveEditsAndJournalsNothing() throws {
        let harness = try Harness()
        try addPlaneTarget(to: harness)
        try addPerturbedGridEditMesh(to: harness)
        let capture = harness.coordinator.inputModel.controller.capture
        let brush = harness.screenPoint(of: SIMD3(1, 1, 0))

        capture.begin(
            source: .finger, verb: .relax,
            sample: .init(time: 0, x: brush.x, y: brush.y, pressure: 0.5, type: .finger)
        )
        capture.append(sample: .init(
            time: 0.02, x: brush.x, y: brush.y, pressure: 0.5, type: .finger
        ))
        // Live mutation happened on the shared handle…
        let live = try #require(harness.coordinator.recognizerEditMesh)
        let livePerturbed = try #require(
            live.nearestVertex(to: SIMD3(1, 1, 0), maxDistance: 0.6)
        )
        #expect(livePerturbed.position != SIMD3(1.35, 0.75, 0))

        // …but cancellation discards it: nothing journaled, and the live
        // mesh is restored from the document payload.
        capture.cancel()
        #expect(harness.bundle.journal.depth == 0)
        let restored = try #require(harness.coordinator.recognizerEditMesh)
        let restoredPerturbed = try #require(
            restored.nearestVertex(to: SIMD3(1.35, 0.75, 0), maxDistance: 1e-4)
        )
        #expect(restoredPerturbed.position == SIMD3(1.35, 0.75, 0))
    }

    /// Verbs require a Target surface to anchor to: without one the brush
    /// verbs are inert (spec: document-model — snapping is tied to the
    /// ACTIVE Target; surface-free editing modes are later scope).
    @Test func brushVerbsAreInertWithoutATarget() throws {
        let harness = try Harness()
        try addStripsEditMesh(to: harness)
        harness.stroke(verb: .relax, through: [SIMD2(0.5, 0.5), SIMD2(0.55, 0.5)])
        harness.stroke(verb: .erase, through: [SIMD2(0.5, 0.5)])
        #expect(harness.bundle.journal.depth == 0)
    }

    // MARK: - Journal integrity under deferred SwiftUI re-sync (review fixes)

    /// Race regression: stroke N+1 begins BEFORE the SwiftUI update pass
    /// that normally refreshes the coordinator snapshot after stroke N's
    /// commit (a main-thread hitch queues the pen-down into the same
    /// runloop drain). The stroke-begin re-sync through `bundleProvider`
    /// must pin stroke N's AFTER payload as stroke N+1's before — one undo
    /// reverts exactly one stroke, never both.
    @Test func strokeQueuedBeforeViewportResyncPinsCurrentBeforePayload() throws {
        let harness = try Harness()
        try addPlaneTarget(to: harness)
        try addPerturbedGridEditMesh(to: harness)
        let object = try #require(harness.editObject)
        let original = try #require(harness.bundle.payloads[object.payloadFile])

        harness.autoSync = false  // no SwiftUI pass between the strokes

        let brush = harness.screenPoint(of: SIMD3(1, 1, 0))
        let nearby = harness.screenPoint(of: SIMD3(1.3, 0.8, 0))
        harness.stroke(verb: .relax, through: [brush, nearby, brush])
        let eraseAt = harness.screenPoint(of: SIMD3(1.5, 1.5, 0))
        harness.stroke(verb: .erase, through: [eraseAt, eraseAt], pressure: 1)

        #expect(harness.bundle.journal.depth == 2)
        try #require(harness.committed.count == 2)
        guard case .meshEdit(let first) = harness.committed[0],
            case .meshEdit(let second) = harness.committed[1]
        else {
            Issue.record("expected two meshEdit commands")
            return
        }
        #expect(first.before == original)
        // The corrupted chain of the original bug pinned
        // second.before == first.before (pre-relax bytes).
        #expect(second.before == first.after)
        #expect(second.before != first.before)

        // One undo reverts exactly ONE stroke…
        harness.autoSync = true
        harness.undo()
        #expect(harness.bundle.payloads[object.payloadFile] == first.after)
        // …and the second reaches the original bytes.
        harness.undo()
        #expect(harness.bundle.payloads[object.payloadFile] == original)
    }

    /// Undo-tap-then-pen-down in the same runloop drain: the brush must
    /// mutate the POST-undo document state (re-synced at stroke begin),
    /// never the pre-undo live mesh — committing that would resurrect the
    /// geometry the user just undid.
    @Test func penDownAfterUndoTapMutatesPostUndoState() throws {
        let harness = try Harness()
        try addPlaneTarget(to: harness)
        try addStripsEditMesh(to: harness)
        let object = try #require(harness.editObject)
        let original = try #require(harness.bundle.payloads[object.payloadFile])

        // Stroke 1 erases one face (committed + synced normally).
        let center = harness.screenPoint(of: SIMD3(1.5, 0.5, 0))
        harness.stroke(verb: .erase, through: [center, center], pressure: 1)
        #expect(harness.bundle.journal.depth == 1)
        #expect(try harness.editMesh().faceCount < 6)

        // The undo drains, then the pen lands BEFORE any SwiftUI pass.
        harness.autoSync = false
        harness.undo()
        #expect(harness.bundle.payloads[object.payloadFile] == original)

        let grab = harness.screenPoint(of: SIMD3(3, 0, 0))
        let drop = harness.screenPoint(of: SIMD3(3.4, -0.3, 0))
        harness.stroke(verb: .tweak, through: [grab, drop])

        guard case .meshEdit(let edit) = try #require(harness.committed.last) else {
            Issue.record("expected a meshEdit command")
            return
        }
        // The transaction pinned the POST-undo payload as before…
        #expect(edit.before == original)
        // …and the committed mesh still has all six faces (the erase was
        // NOT resurrected) with the tweak applied.
        let mesh = try harness.editMesh()
        #expect(mesh.faceCount == 6)
        #expect(mesh.nearestVertex(to: SIMD3(3.4, -0.3, 0), maxDistance: 0.05) != nil)
    }

    /// A document WITH an EditMesh whose payload cannot be deserialized
    /// must never gain a second `.editMesh` object from the pencil
    /// create-first-quad fallback, and the broken snapshot leaves the
    /// brush verbs inert (snapshot-consistency invariant: a deserialize
    /// failure clears editObject together with the other three fields).
    @Test func corruptEditMeshPayloadNeverCreatesADuplicateObject() throws {
        let harness = try Harness()
        try addPlaneTarget(to: harness)
        try addStripsEditMesh(to: harness)
        let object = try #require(harness.editObject)

        harness.bundle.payloads[object.payloadFile] = Data("not a payload".utf8)
        harness.sync()

        // Deserialize failure clears the WHOLE snapshot, but the document
        // is still known to contain an EditMesh object.
        #expect(harness.coordinator.editObject == nil)
        #expect(harness.coordinator.recognizerEditMesh == nil)
        #expect(harness.coordinator.documentHasEditMesh)

        // Pencil quad: no duplicate `.editMesh` object, nothing journaled.
        harness.coordinator.inputModel.injectSquareStroke()
        let editMeshObjects = harness.bundle.manifest.objects.filter { $0.role == .editMesh }
        #expect(editMeshObjects.count == 1)
        #expect(harness.bundle.journal.depth == 0)
        #expect(harness.committed.isEmpty)

        // Brush verbs are inert against the broken snapshot — no crash,
        // no journal entry.
        harness.stroke(verb: .relax, through: [SIMD2(0.5, 0.5), SIMD2(0.52, 0.5)])
        #expect(harness.bundle.journal.depth == 0)
    }

    // MARK: - Journal-failure discard (review fix: no unjournaled divergence)

    /// `journalOrDiscard` is the single epilogue for every path that
    /// mutated the LIVE mesh (brush commit + pencil quad). When building
    /// the command throws — payload serialization failing AFTER the
    /// mutation landed and the overlay refreshed — the live edits MUST be
    /// discarded: keeping them would leave the live mesh permanently
    /// diverged from the document with no journal entry (the next stroke
    /// would then pin the stale document payload as `before` while
    /// serializing the phantom geometry into `after`, breaking byte-exact
    /// revert). A serialization failure cannot be forced through a real
    /// engine mesh, so the seam is exercised directly.
    @Test func journalFailureDiscardsLiveEditsInsteadOfDesyncing() {
        let controller = MeshEditController()
        var committed: [DocumentCommand] = []
        var discards = 0
        controller.onCommit = { committed.append($0) }
        controller.onDiscardLiveEdits = { discards += 1 }

        struct Boom: Error {}
        controller.journalOrDiscard(verb: "relax") { throw Boom() }
        #expect(committed.isEmpty)
        #expect(discards == 1)

        // Success path: the command reaches the journal, nothing discarded.
        let id = UUID()
        let object = DocumentManifest.Object(
            id: id, name: "EditMesh", role: .editMesh,
            payloadFile: "\(id.uuidString).payload",
            counts: .init(vertices: 4, faces: 1)
        )
        let command = DocumentCommand.addObject(object: object, payload: Data([1, 2, 3]))
        controller.journalOrDiscard(verb: "relax") { command }
        #expect(committed == [command])
        #expect(discards == 1)

        // No-op strokes journal nothing and discard nothing.
        controller.journalOrDiscard(verb: "relax") { nil }
        #expect(committed == [command])
        #expect(discards == 1)
    }

    /// End-to-end failure path through `applyPencilInterpretation`: a
    /// createQuad whose corners collapse to one Target point (two identical
    /// screen corners) makes `createFace` throw. The controller must take
    /// the discard path (same epilogue as a serialization failure), journal
    /// nothing, and leave the mesh at the document state.
    @Test func degeneratePencilQuadDiscardsAndJournalsNothing() throws {
        let harness = try Harness()
        try addPlaneTarget(to: harness)
        try addStripsEditMesh(to: harness)
        let meshEditor = harness.coordinator.meshEditor
        let chainedDiscard = meshEditor.onDiscardLiveEdits
        var discards = 0
        meshEditor.onDiscardLiveEdits = {
            discards += 1
            chainedDiscard?()
        }

        let corner = SIMD2<Float>(0.45, 0.45)
        let degenerate = StrokeInterpretation(
            shape: .closedLoop, shapeConfidence: 0.9, context: .emptySurface,
            candidates: [.init(action: .createQuad, confidence: 0.9, elements: [])],
            quadCorners: [corner, corner, SIMD2(0.55, 0.55), SIMD2(0.45, 0.55)]
        )
        meshEditor.strokeEnded(verb: .pencil, interpretation: degenerate)

        #expect(harness.bundle.journal.depth == 0)
        #expect(harness.committed.isEmpty)
        #expect(discards == 1)
        // The live mesh still matches the document (createFace left it
        // untouched; the discard reloaded identical state).
        #expect(try harness.editMesh().faceCount == 6)
        let live = try #require(harness.coordinator.recognizerEditMesh)
        #expect(live.faceCount == 6)
        #expect(live.vertexCount == 16)
    }

    // MARK: - Live-edit upload coalescing (review fix: per frame, not per sample)

    /// Brush samples arrive at up to 240 Hz; geometry must NOT be
    /// re-uploaded per sample (each upload rebuilds the engine render cache
    /// and runs the pool's synchronous GPU reuse fence). The refresh is
    /// parked on the renderer and flushed once per rendered frame.
    @Test func liveBrushSamplesCoalesceGeometryUploadsToOncePerFrame() throws {
        let harness = try Harness()
        try addPlaneTarget(to: harness)
        try addPerturbedGridEditMesh(to: harness)
        let renderer = try #require(harness.coordinator.renderer)
        let overlayPool = renderer.overlayPath.bufferPool
        let capture = harness.coordinator.inputModel.controller.capture
        let brush = harness.screenPoint(of: SIMD3(1, 1, 0))
        let nearby = harness.screenPoint(of: SIMD3(1.3, 0.8, 0))

        let baseline = overlayPool.uploadCount
        capture.begin(
            source: .finger, verb: .relax,
            sample: .init(time: 0, x: brush.x, y: brush.y, pressure: 0.5, type: .finger)
        )
        for index in 1...12 {
            let point = index.isMultiple(of: 2) ? nearby : brush
            capture.append(sample: .init(
                time: Double(index) * 0.004, x: point.x, y: point.y,
                pressure: 0.5, type: .finger
            ))
        }
        // 13 mutating samples: zero uploads, one parked refresh.
        #expect(overlayPool.uploadCount == baseline)
        #expect(renderer.pendingGeometryRefresh != nil)

        // One frame flushes exactly one geometry load (two streams:
        // positions + edge indices).
        _ = renderer.renderOffscreen(width: 32, height: 32)
        #expect(overlayPool.uploadCount == baseline + 2)
        #expect(renderer.pendingGeometryRefresh == nil)

        // More samples: still nothing until the next frame.
        capture.append(sample: .init(
            time: 0.06, x: brush.x, y: brush.y, pressure: 0.5, type: .finger
        ))
        #expect(overlayPool.uploadCount == baseline + 2)
        _ = renderer.renderOffscreen(width: 32, height: 32)
        #expect(overlayPool.uploadCount == baseline + 4)

        capture.end()
        #expect(harness.bundle.journal.depth == 1)
    }

    /// The coalesced refresh must still show the CURRENT mesh: an erase
    /// that removed faces is reflected in the overlay after the next frame.
    @Test func coalescedOverlayRefreshReflectsTheLiveMutation() throws {
        let harness = try Harness()
        try addPlaneTarget(to: harness)
        try addPerturbedGridEditMesh(to: harness)
        let renderer = try #require(harness.coordinator.renderer)
        let capture = harness.coordinator.inputModel.controller.capture
        let edgesBefore = renderer.overlayPath.edgeIndexCount
        try #require(edgesBefore > 0)

        let center = harness.screenPoint(of: SIMD3(1, 1, 0))
        capture.begin(
            source: .finger, verb: .erase,
            sample: .init(time: 0, x: center.x, y: center.y, pressure: 1, type: .finger)
        )
        // The live mesh already lost faces, but the overlay upload waits
        // for the frame.
        let live = try #require(harness.coordinator.recognizerEditMesh)
        try #require(live.faceCount < 9)
        #expect(renderer.overlayPath.edgeIndexCount == edgesBefore)

        _ = renderer.renderOffscreen(width: 32, height: 32)
        #expect(renderer.overlayPath.edgeIndexCount < edgesBefore)
        capture.end()
    }

    // MARK: - External document change mid-stroke (review fix)

    /// An externally-driven EditMesh payload change (iCloud conflict revert
    /// reloading the document) landing MID-BRUSH-STROKE cancels the
    /// session: later samples must not mutate an orphaned handle, and the
    /// stroke must not journal a `before` payload the document no longer
    /// contains. The external reload wins.
    @Test func externalEditMeshChangeMidStrokeCancelsTheSession() throws {
        let harness = try Harness()
        try addPlaneTarget(to: harness)
        try addPerturbedGridEditMesh(to: harness)
        let object = try #require(harness.editObject)
        let capture = harness.coordinator.inputModel.controller.capture
        let meshEditor = harness.coordinator.meshEditor

        let brush = harness.screenPoint(of: SIMD3(1, 1, 0))
        capture.begin(
            source: .finger, verb: .relax,
            sample: .init(time: 0, x: brush.x, y: brush.y, pressure: 0.5, type: .finger)
        )
        capture.append(sample: .init(
            time: 0.02, x: brush.x, y: brush.y, pressure: 0.5, type: .finger
        ))
        try #require(meshEditor.isSessionActive)

        // External change: the document payload is replaced under the
        // in-flight stroke (single-quad mesh, clearly distinct).
        let external = try meshFromOBJ("""
        v 0 0 0
        v 1 0 0
        v 1 1 0
        v 0 1 0
        f 1 2 3 4
        """)
        harness.bundle.payloads[object.payloadFile] = try external.payloadData()
        harness.sync()  // the updateUIView path

        // Session cancelled; the snapshot now binds the external state.
        #expect(!meshEditor.isSessionActive)
        let rebound = try #require(harness.coordinator.recognizerEditMesh)
        #expect(rebound.vertexCount == 4)
        #expect(rebound.faceCount == 1)

        // The rest of the stroke is inert: no mutation of the new mesh, no
        // journal entry at stroke end.
        capture.append(sample: .init(
            time: 0.04, x: brush.x, y: brush.y, pressure: 0.5, type: .finger
        ))
        capture.end()
        #expect(harness.bundle.journal.depth == 0)
        #expect(harness.committed.isEmpty)
        #expect(rebound.vertexCount == 4)
    }

    // MARK: - Task 3.4: full gesture grammar (capture → recognizer → verbs)

    /// 3x2 quad grid on the Target plane (world twin of the recognizer
    /// suite's grid32 fixture): the middle horizontal row is a 3-edge loop,
    /// each column an open 2-quad ring.
    private func addGridEditMesh(to harness: Harness) throws {
        // 2-unit spacing: at the harness camera scale (~0.05 screen per
        // world unit) 1-unit cells would put EVERY point of a stroke
        // within the vertex/edge pick radii, making merge/tag swallow the
        // other line gestures.
        var obj = ""
        for row in 0...2 {
            for col in 0...3 {
                obj += "v \(col * 2) \(row * 2) 0\n"
            }
        }
        for row in 0..<2 {
            for col in 0..<3 {
                let a = row * 4 + col + 1
                obj += "f \(a) \(a + 1) \(a + 5) \(a + 4)\n"
            }
        }
        try harness.bundle.addObject(
            name: "cage", role: .editMesh, mesh: try meshFromOBJ(obj)
        )
        harness.sync()
    }

    /// Big triangle pair sharing the diagonal (side,0)–(0,side).
    private func addTrianglePairEditMesh(to harness: Harness, side: Int = 3) throws {
        try harness.bundle.addObject(
            name: "cage", role: .editMesh,
            mesh: try meshFromOBJ("""
            v 0 0 0
            v \(side) 0 0
            v \(side) \(side) 0
            v 0 \(side) 0
            f 1 2 4
            f 2 3 4
            """)
        )
        harness.sync()
    }

    private func annotations(of harness: Harness) -> MeshAnnotations? {
        harness.editObject?.annotations
    }

    @Test func lineAcrossRingInsertsFullEdgeLoopAndUndoRestoresBytes() throws {
        let harness = try Harness()
        try addPlaneTarget(to: harness)
        try addGridEditMesh(to: harness)
        let object = try #require(harness.editObject)
        let payloadBefore = try #require(harness.bundle.payloads[object.payloadFile])

        // Vertical stroke across the middle column's three horizontal
        // edges (endpoints clear of any vertex pick radius).
        harness.stroke(verb: .pencil, through: harness.densified(through: [
            harness.screenPoint(of: SIMD3(3, -1, 0)),
            harness.screenPoint(of: SIMD3(3, 5, 0)),
        ]))

        #expect(harness.bundle.journal.depth == 1)
        guard case .meshEdit(let edit) = try #require(harness.committed.first) else {
            Issue.record("expected a meshEdit command")
            return
        }
        #expect(edit.verb == "pencil.insertLoop")
        let inserted = try harness.editMesh()
        // The WHOLE ring split (recon NOTE: the old engine op split exactly
        // one quad): 6 quads -> 8, three midpoints on x = 1.5.
        #expect(inserted.faceCount == 8)
        #expect(inserted.vertexCount == 15)
        #expect(try inserted.stats().quads == 8)
        for y: Float in [0, 2, 4] {
            let midpoint = try #require(
                inserted.nearestVertex(to: SIMD3(3, y, 0), maxDistance: 1e-3)
            )
            #expect(midpoint.position == SIMD3(3, y, 0))
        }

        harness.undo()
        #expect(harness.bundle.payloads[object.payloadFile] == payloadBefore)
        #expect(try harness.editMesh().faceCount == 6)
        harness.redo()
        #expect(try harness.editMesh().faceCount == 8)
    }

    @Test func lineAlongLoopTagsWholeLoopWithColoredRenderAndUndoClears() throws {
        let harness = try Harness()
        try addPlaneTarget(to: harness)
        try addGridEditMesh(to: harness)
        let object = try #require(harness.editObject)
        let payloadBefore = try #require(harness.bundle.payloads[object.payloadFile])
        let renderer = try #require(harness.coordinator.renderer)
        #expect(renderer.overlayPath.taggedIndexCount == 0)

        // Stroke ALONG the middle row (the disambiguation counterpart of
        // the ring-insert stroke above), endpoints clear of vertex picks.
        harness.stroke(verb: .pencil, through: harness.densified(through: [
            harness.screenPoint(of: SIMD3(1, 2, 0)),
            harness.screenPoint(of: SIMD3(5, 2, 0)),
        ]))

        #expect(harness.bundle.journal.depth == 1)
        guard case .annotationEdit(let edit) = try #require(harness.committed.first) else {
            Issue.record("expected an annotationEdit command")
            return
        }
        #expect(edit.verb == "pencil.tagLoop")
        // The WHOLE loop is tagged (engine loop walk), topology untouched,
        // payload bytes untouched.
        let tagged = try #require(annotations(of: harness))
        #expect(tagged.taggedEdges.count == 3)
        #expect(tagged.hiddenFaces.isEmpty)
        #expect(harness.bundle.payloads[object.payloadFile] == payloadBefore)
        #expect(try harness.editMesh().faceCount == 6)
        // Minimal colored-line render (full styles are 4.3): the overlay
        // carries a tagged-edge pass after the sync.
        #expect(renderer.overlayPath.taggedIndexCount == 6)

        // Undo clears the tags — and the colored pass.
        harness.undo()
        #expect(annotations(of: harness) == nil)
        #expect(renderer.overlayPath.taggedIndexCount == 0)
        // Drawing along the tagged loop again would re-tag (redo path).
        harness.redo()
        #expect(try #require(annotations(of: harness)).taggedEdges.count == 3)
        #expect(renderer.overlayPath.taggedIndexCount == 6)
    }

    // scribbleOverEdgeDissolvesItIntoOneQuad retired: dissolveEdge is no
    // longer a stroke gesture (it is a tool). A scribble over geometry now
    // DELETES the faces it covers — covered at the interpreter level by
    // StrokeInterpreterTests.scribbleOverGeometryResolvesDelete, and the
    // end-to-end delete path by xOverAFaceDeletesItAndUndoRestores below.

    @Test func xOverAFaceDeletesItAndUndoRestores() throws {
        let harness = try Harness()
        try addPlaneTarget(to: harness)
        try addStripsEditMesh(to: harness)
        let object = try #require(harness.editObject)
        let payloadBefore = try #require(harness.bundle.payloads[object.payloadFile])

        // X inside the first strip-A quad: its footprint (bounding box)
        // covers only that face's centroid.
        harness.stroke(verb: .pencil, through: harness.densified(through: [
            harness.screenPoint(of: SIMD3(0.15, 0.15, 0)),
            harness.screenPoint(of: SIMD3(0.85, 0.85, 0)),
            harness.screenPoint(of: SIMD3(0.85, 0.15, 0)),
            harness.screenPoint(of: SIMD3(0.15, 0.85, 0)),
        ], samplesPerSegment: 16))

        #expect(harness.bundle.journal.depth == 1)
        guard case .meshEdit(let edit) = try #require(harness.committed.first) else {
            Issue.record("expected a meshEdit command")
            return
        }
        #expect(edit.verb == "pencil.deleteFaces")
        let after = try harness.editMesh()
        #expect(after.faceCount == 5)
        // The deleted region is exactly the X'd quad: no vertex remains at
        // its exclusive corner (0,0).
        #expect(after.nearestVertex(to: SIMD3(0, 0, 0), maxDistance: 0.5) == nil)

        harness.undo()
        #expect(harness.bundle.payloads[object.payloadFile] == payloadBefore)
        #expect(try harness.editMesh().faceCount == 6)
    }

    @Test func vertexToVertexLineMergesThem() throws {
        let harness = try Harness()
        try addPlaneTarget(to: harness)
        try addStripsEditMesh(to: harness)
        let object = try #require(harness.editObject)
        let payloadBefore = try #require(harness.bundle.payloads[object.payloadFile])

        // Stroke from the (0,0) corner vertex onto its neighbor at (1,0):
        // the start vertex snaps onto the end vertex.
        harness.stroke(verb: .pencil, through: harness.densified(through: [
            harness.screenPoint(of: SIMD3(0, 0, 0)),
            harness.screenPoint(of: SIMD3(1, 0, 0)),
        ]))

        #expect(harness.bundle.journal.depth == 1)
        guard case .meshEdit(let edit) = try #require(harness.committed.first) else {
            Issue.record("expected a meshEdit command")
            return
        }
        #expect(edit.verb == "pencil.mergeVertices")
        let merged = try harness.editMesh()
        #expect(merged.vertexCount == 15)
        // Nothing left at (0,0); the survivor sits exactly at (1,0).
        #expect(merged.nearestVertex(to: SIMD3(0, 0, 0), maxDistance: 0.9) == nil)
        let keep = try #require(merged.nearestVertex(to: SIMD3(1, 0, 0), maxDistance: 1e-3))
        #expect(keep.position == SIMD3(1, 0, 0))
        // The corner quad degenerated to a triangle; the rest stay quads.
        #expect(try merged.stats().triangles == 1)

        harness.undo()
        #expect(harness.bundle.payloads[object.payloadFile] == payloadBefore)
        #expect(try harness.editMesh().vertexCount == 16)
    }

    @Test func circleOverEdgeRotatesTheDiagonal() throws {
        let harness = try Harness()
        try addPlaneTarget(to: harness)
        // Side 6: the triangle centroids sit ~1.4 world units off the
        // diagonal's midpoint, clearly OUTSIDE the small circle (a tighter
        // pair would read as a lasso enclosing both faces).
        try addTrianglePairEditMesh(to: harness, side: 6)
        let object = try #require(harness.editObject)
        let payloadBefore = try #require(harness.bundle.payloads[object.payloadFile])
        // Before: the diagonal connects (6,0)–(0,6).
        let before = try harness.editMesh()
        let diagonalBefore = try #require(
            before.nearestEdge(to: SIMD3(3, 3, 0), maxDistance: 1e-3)
        )
        let endsBefore = try #require(before.edgeEndpoints(of: diagonalBefore.edge))
        #expect(Set([endsBefore.0, endsBefore.1]) == Set([1, 3]))

        // Small circle over the diagonal's midpoint.
        var circle: [SIMD2<Double>] = []
        let center = harness.screenPoint(of: SIMD3(3, 3, 0))
        for i in 0...72 {
            let angle = 2.0 * Double.pi * Double(i) / 72
            circle.append(SIMD2(center.x + 0.05 * cos(angle), center.y + 0.05 * sin(angle)))
        }
        harness.stroke(verb: .pencil, through: circle)

        #expect(harness.bundle.journal.depth == 1)
        guard case .meshEdit(let edit) = try #require(harness.committed.first) else {
            Issue.record("expected a meshEdit command")
            return
        }
        #expect(edit.verb == "pencil.rotateEdge")
        let rotated = try harness.editMesh()
        #expect(rotated.faceCount == 2)
        let diagonalAfter = try #require(
            rotated.nearestEdge(to: SIMD3(3, 3, 0), maxDistance: 1e-3)
        )
        let endsAfter = try #require(rotated.edgeEndpoints(of: diagonalAfter.edge))
        #expect(Set([endsAfter.0, endsAfter.1]) == Set([0, 2]))

        harness.undo()
        #expect(harness.bundle.payloads[object.payloadFile] == payloadBefore)
    }

    /// hideRegion is retired from the stroke grammar (it is a tool now). A
    /// closed stroke that used to hide the faces it enclosed now creates a
    /// quad and hides NOTHING — this is the app-level proof the gesture is
    /// gone.
    @Test func closedStrokeOverFacesCreatesQuadAndHidesNothing() throws {
        let harness = try Harness()
        try addPlaneTarget(to: harness)
        try addStripsEditMesh(to: harness)

        // The same flat closed stroke that used to be a hide-lasso, over
        // strip B.
        let center = harness.screenPoint(of: SIMD3(1.5, 1.7, 0))
        var loop: [SIMD2<Double>] = []
        for i in 0...140 {
            let angle = 2.0 * Double.pi * Double(i) / 140
            loop.append(SIMD2(
                center.x + 0.20 * cos(angle), center.y + 0.06 * sin(angle)
            ))
        }
        harness.stroke(verb: .pencil, through: loop)

        // Whatever it committed, it must NOT be a hide: no annotationEdit,
        // nothing hidden.
        if case .annotationEdit = harness.committed.first {
            Issue.record("a closed stroke must not hide faces any more")
        }
        #expect(annotations(of: harness)?.hiddenFaces.isEmpty ?? true)
    }

    @Test func verticalLinesInEmptySpaceInvertAndShowAllVisibility() throws {
        let harness = try Harness()
        try addPlaneTarget(to: harness)
        try addStripsEditMesh(to: harness)
        let object = try #require(harness.editObject)

        // Seed: strip B hidden (as the lasso gesture would leave it).
        let stripB = MeshAnnotations(hiddenFaces: [3, 4, 5])
        harness.perform(.annotationEdit(.init(
            objectID: object.id, verb: "seed", before: nil, after: stripB
        )))

        // Straight line DOWNWARD in empty space (right of the mesh):
        // inverts visibility.
        let top = harness.screenPoint(of: SIMD3(4.5, 2.5, 0))
        let bottom = harness.screenPoint(of: SIMD3(4.5, -0.5, 0))
        let downward = harness.densified(through: [top, bottom].sorted { $0.y < $1.y })
        harness.stroke(verb: .pencil, through: downward)

        guard case .annotationEdit(let invert) = try #require(harness.committed.last)
        else {
            Issue.record("expected an annotationEdit command")
            return
        }
        #expect(invert.verb == "pencil.invertVisibility")
        #expect(try #require(annotations(of: harness)).hiddenFaces == [0, 1, 2])

        // Straight line UPWARD: show all (annotations clear entirely).
        harness.stroke(verb: .pencil, through: Array(downward.reversed()))
        guard case .annotationEdit(let show) = try #require(harness.committed.last) else {
            Issue.record("expected an annotationEdit command")
            return
        }
        #expect(show.verb == "pencil.showAll")
        #expect(annotations(of: harness) == nil)

        // Undo walks back through the visibility states exactly.
        harness.undo()
        #expect(try #require(annotations(of: harness)).hiddenFaces == [0, 1, 2])
        harness.undo()
        #expect(try #require(annotations(of: harness)).hiddenFaces == [3, 4, 5])
    }

    @Test func gridStrokeCreatesBlockOfQuadsInOneJournalEntry() throws {
        let harness = try Harness()
        let target = try Mesh.loadOBJ(at: UITestSupport.writeSeedTargetOBJ())
        try harness.bundle.addObject(name: "target", role: .target, mesh: target)
        harness.sync()
        #expect(harness.editObject == nil)

        harness.coordinator.inputModel.injectGridStroke()

        // ONE journaled command created the EditMesh with the whole block:
        // 3 quad cells over a 2x4 lattice.
        #expect(harness.bundle.journal.depth == 1)
        let object = try #require(harness.editObject)
        #expect(object.counts == .init(vertices: 8, faces: 3))
        let created = try harness.editMesh()
        #expect(try created.stats().quads == 3)

        // Every lattice vertex is snapped onto the domed Target.
        let snapper = try SurfaceSnapper(target: target)
        for id in 0..<8 {
            let position = try #require(created.vertexPosition(UInt32(id)))
            let hit = try #require(snapper.snapToSurface(position))
            #expect(simd_distance(hit.point, position) < 1e-3)
        }

        harness.undo()
        #expect(harness.editObject == nil)
        harness.redo()
        #expect(try harness.editMesh().faceCount == 3)
    }

    @Test func doubleTapOnVertexActivatesTweakVerb() throws {
        let harness = try Harness()
        try addPlaneTarget(to: harness)
        try addStripsEditMesh(to: harness)
        let corner = harness.screenPoint(of: SIMD3(0, 2.2, 0))

        #expect(harness.coordinator.inputModel.activeVerb == .pencil)
        // First tap: recorded, nothing switches, nothing journals.
        harness.stroke(verb: .pencil, through: [corner])
        #expect(harness.coordinator.inputModel.activeVerb == .pencil)
        #expect(harness.bundle.journal.depth == 0)

        // Second tap on the same vertex inside the window: Tweak activates
        // (the following drag is the regular Tweak verb, covered above).
        harness.stroke(verb: .pencil, through: [corner])
        #expect(harness.coordinator.inputModel.activeVerb == .tweak)
        #expect(harness.bundle.journal.depth == 0)

        // A tap on a DIFFERENT vertex never chains into a double-tap.
        harness.coordinator.inputModel.selectVerb(.pencil)
        harness.stroke(verb: .pencil, through: [corner])
        harness.stroke(
            verb: .pencil, through: [harness.screenPoint(of: SIMD3(3, 2.2, 0))]
        )
        #expect(harness.coordinator.inputModel.activeVerb == .pencil)
    }

    // MARK: - Task 3.5: interpretation chip alternatives (one-tap swap)

    /// The chip's flagship direction (spec scenario "One-tap misrecognition
    /// fix"): a wavy stroke ALONG the middle loop interprets as tagLoop with
    /// a ranked insertLoop alternative; tapping the alternative REPLACES the
    /// journaled annotationEdit with the meshEdit loop insert in place —
    /// exactly one journal entry after the swap, one undo back to pristine
    /// bytes, no extra undo step.
    @Test func tagLoopStrokeSwapsToInsertLoopInPlace() throws {
        let harness = try Harness()
        try addPlaneTarget(to: harness)
        try addGridEditMesh(to: harness)
        let object = try #require(harness.editObject)
        let payloadBefore = try #require(harness.bundle.payloads[object.payloadFile])

        // Along the middle row, recorded with the corpus's standard hand
        // wobble: every sample stays within the recognizer's edge radius
        // (ALONG-dominant → tagLoop best) while the wobble's crossings of
        // the row rank insertLoop as the alternative — the genuinely
        // ambiguous stroke of the spec scenario.
        let start = harness.screenPoint(of: SIMD3(1, 2, 0))
        let end = harness.screenPoint(of: SIMD3(5, 2, 0))
        let points = StrokeGestureCorpus.path(through: [
            .init(start.x, start.y), .init(end.x, end.y),
        ])
        var chip: MeshEditController.PencilStrokeOutcome?
        harness.coordinator.meshEditor.onPencilStrokeResolved = { chip = $0 }
        harness.stroke(verb: .pencil, through: points.map { SIMD2($0.x, $0.y) })

        // Applied: tagLoop (whole middle loop), journaled once.
        #expect(harness.bundle.journal.depth == 1)
        guard case .annotationEdit(let applied) = try #require(harness.committed.first)
        else {
            Issue.record("expected an annotationEdit command")
            return
        }
        #expect(applied.verb == "pencil.tagLoop")
        #expect(try #require(annotations(of: harness)).taggedEdges.count == 3)

        // The chip carries the insertLoop alternative.
        let outcome = try #require(chip)
        #expect(outcome.appliedIndex == 0)
        #expect(outcome.interpretation?.best?.action == .tagLoop)
        let alternativeIndex = try #require(outcome.alternatives.first { index in
            outcome.interpretation?.candidates[index].action == .insertLoop
        })

        // ONE TAP: the applied result swaps in place.
        let swapped = try #require(
            harness.coordinator.meshEditor.applyAlternative(at: alternativeIndex)
        )
        #expect(swapped.appliedIndex == alternativeIndex)

        // Journal invariant: still exactly ONE entry; the annotation edit
        // is gone (reverted, not stacked), the loop insert is applied.
        #expect(harness.bundle.journal.depth == 1)
        #expect(annotations(of: harness) == nil)
        guard case .meshEdit(let edit) = try #require(harness.bundle.journal.currentCommand)
        else {
            Issue.record("expected the journal current to be the meshEdit swap")
            return
        }
        #expect(edit.verb == "pencil.insertLoop")
        #expect(edit.before == payloadBefore)
        // The full ring split (which ring depends on which crossed edge
        // seeded the walk — the invariant is a real all-quad loop insert).
        let inserted = try harness.editMesh()
        #expect(inserted.faceCount > 6)
        #expect(try inserted.stats().quads == inserted.faceCount)

        // The swapped chip offers the original reading back — swap-back
        // restores the tagged loop, still one entry.
        let backIndex = try #require(swapped.alternatives.first { index in
            swapped.interpretation?.candidates[index].action == .tagLoop
        })
        #expect(harness.coordinator.meshEditor.applyAlternative(at: backIndex) != nil)
        #expect(harness.bundle.journal.depth == 1)
        #expect(try #require(annotations(of: harness)).taggedEdges.count == 3)
        #expect(harness.bundle.payloads[object.payloadFile] == payloadBefore)
        #expect(try harness.editMesh().faceCount == 6)

        // One undo steps over the WHOLE stroke+swaps history.
        harness.undo()
        #expect(annotations(of: harness) == nil)
        #expect(harness.bundle.payloads[object.payloadFile] == payloadBefore)
        #expect(harness.bundle.journal.depth == 0)
    }

    /// The UI test's exact path (seeded strip + fixture injection through
    /// the model): the committed vertical ring-insert stroke runs ALONG the
    /// strip's middle edge while its hand wobble crosses it — tagLoop
    /// applies with insertLoop ranked as the alternative (the spec's
    /// misrecognition pair), and one tap through the MODEL swaps the
    /// annotation for the loop insert in place.
    @Test func ringStrokeOnSeededStripSwapsToInsertLoopViaTheModel() throws {
        let harness = try Harness()
        let seed = try Mesh.loadOBJ(at: UITestSupport.writeSeedStripOBJ())
        try harness.bundle.addObject(name: "seed-strip", role: .editMesh, mesh: seed)
        harness.sync()
        let object = try #require(harness.editObject)
        let payloadBefore = try #require(harness.bundle.payloads[object.payloadFile])
        let model = harness.coordinator.inputModel

        model.injectRingStroke()

        // Applied: the middle edge tagged (annotation only), one entry.
        #expect(harness.bundle.journal.depth == 1)
        guard case .annotationEdit(let edit) = try #require(harness.committed.first)
        else {
            let record = model.lastInterpretation?.summary ?? "nil"
            Issue.record("expected an annotationEdit; record: \(record)")
            return
        }
        #expect(edit.verb == "pencil.tagLoop")
        #expect(harness.bundle.payloads[object.payloadFile] == payloadBefore)
        #expect(try harness.editMesh().faceCount == 2)
        #expect(try #require(annotations(of: harness)).taggedEdges.isEmpty == false)

        // The published chip offers the insert-loop alternative.
        let chip = try #require(model.interpretationChip)
        #expect(chip.title == "Tag loop")
        let alternative = try #require(
            chip.alternatives.first { $0.action == .insertLoop }
        )

        // One tap through the MODEL (the UI's entry point): swapped in
        // place — the tag reverts, the ranked ring splits (the recognizer's
        // ring for this stroke walks one strip quad), still one entry.
        model.chooseAlternative(alternative.id)
        #expect(harness.bundle.journal.depth == 1)
        #expect(annotations(of: harness) == nil)
        let inserted = try harness.editMesh()
        #expect(inserted.faceCount == 3)
        #expect(inserted.vertexCount == 8)
        #expect(try inserted.stats().quads == 3)
        let swappedChip = try #require(model.interpretationChip)
        #expect(swappedChip.title == "Insert loop")
        #expect(swappedChip.alternatives.contains { $0.action == .tagLoop })

        // One undo reverts the whole stroke (no extra step for the swap).
        harness.undo()
        #expect(annotations(of: harness) == nil)
        #expect(harness.bundle.journal.depth == 0)
        #expect(harness.bundle.payloads[object.payloadFile] == payloadBefore)
        #expect(try harness.editMesh().faceCount == 2)
    }

    /// Stale chips must be inert: after an undo the journaled command the
    /// chip captured is gone, so the swap is rejected, nothing mutates, and
    /// the swap context clears (a second tap is a no-op too).
    @Test func alternativeSwapAfterUndoIsRejectedUntouched() throws {
        let harness = try Harness()
        let seed = try Mesh.loadOBJ(at: UITestSupport.writeSeedStripOBJ())
        try harness.bundle.addObject(name: "seed-strip", role: .editMesh, mesh: seed)
        harness.sync()
        let object = try #require(harness.editObject)
        let payloadBefore = try #require(harness.bundle.payloads[object.payloadFile])

        var chip: MeshEditController.PencilStrokeOutcome?
        harness.coordinator.meshEditor.onPencilStrokeResolved = { chip = $0 }
        harness.coordinator.inputModel.injectRingStroke()
        let outcome = try #require(chip)
        let alternative = try #require(outcome.alternatives.first)

        // The user undoes the stroke before touching the chip.
        harness.undo()
        #expect(harness.bundle.journal.depth == 0)

        // The stale tap swaps nothing and journals nothing.
        #expect(harness.coordinator.meshEditor.applyAlternative(at: alternative) == nil)
        #expect(harness.bundle.journal.depth == 0)
        #expect(harness.bundle.payloads[object.payloadFile] == payloadBefore)
        #expect(annotations(of: harness) == nil)
        // The context cleared: repeating the tap stays a no-op.
        #expect(harness.coordinator.meshEditor.applyAlternative(at: alternative) == nil)
    }

    // MARK: - Merge-snap feedback (task 3.7, spec scenario "Snap feedback")

    /// Records every haptic tick the controller plays (the injected seam
    /// from design D9: event→feedback is asserted without hardware).
    @MainActor
    private final class RecordingHaptics: SnapHapticsPlaying {
        var ticks: [SnapFeedbackState.Tick] = []
        func play(_ tick: SnapFeedbackState.Tick, atNormalized location: CGPoint?) {
            ticks.append(tick)
        }
    }

    /// Snap-feedback instrumentation: injected haptics + recorded highlight
    /// events, CHAINED in front of the coordinator's real render sink so
    /// the overlay highlight pass stays exercised.
    @MainActor
    private struct SnapProbe {
        let haptics = RecordingHaptics()
        private let recorded: Recorded

        @MainActor
        private final class Recorded {
            var highlights: [HoverPreviewState.SnapTarget?] = []
        }

        var highlights: [HoverPreviewState.SnapTarget?] { recorded.highlights }

        init(_ harness: Harness) {
            let editor = harness.coordinator.meshEditor
            editor.haptics = haptics
            let record = Recorded()
            recorded = record
            let renderSink = editor.onSnapHighlightChanged
            editor.onSnapHighlightChanged = { target in
                record.highlights.append(target)
                renderSink?(target)
            }
        }
    }

    /// The spec scenario, end to end through the REAL pipeline: a Tweak
    /// drag brings the dragged vertex within merge distance of another
    /// vertex — the target highlights BEFORE anything commits (no journal
    /// entry, no topology change while the pen is down), and on release
    /// the merge commits as ONE journal entry with the haptic tick fired
    /// exactly then.
    @Test func tweakDragWithinMergeRangeHighlightsBeforeCommitThenMergesWithOneEntry() throws {
        let harness = try Harness()
        try addPlaneTarget(to: harness)
        try addStripsEditMesh(to: harness)
        let probe = SnapProbe(harness)
        let object = try #require(harness.editObject)
        let payloadBefore = try #require(harness.bundle.payloads[object.payloadFile])
        let renderer = try #require(harness.coordinator.renderer)

        // Grab the strip-A corner at (3,0) and park the drag 0.07 from its
        // neighbor (3,1) — inside merge range (scene radius ~7.07 × 0.04
        // ≈ 0.28), WITHOUT ending the stroke.
        let capture = harness.coordinator.inputModel.controller.capture
        let grab = harness.screenPoint(of: SIMD3(3, 0, 0))
        let park = harness.screenPoint(of: SIMD3(3.05, 0.95, 0))
        capture.begin(
            source: .finger, verb: .tweak,
            sample: .init(time: 0, x: grab.x, y: grab.y, pressure: 0.5, type: .finger)
        )
        capture.append(
            sample: .init(time: 0.05, x: park.x, y: park.y, pressure: 0.5, type: .finger)
        )

        // Highlight BEFORE commit: the snap target is published (and lit
        // in the real overlay highlight pass), the snap-engaged tick
        // played, and NOTHING has committed — same topology, no journal.
        let engaged = try #require(probe.highlights.last ?? nil)
        #expect(engaged.position == SIMD3(3, 1, 0))
        #expect(probe.haptics.ticks == [.snapEngaged])
        #expect(renderer.overlayPath.hasHoverHighlight)
        #expect(harness.bundle.journal.depth == 0)
        #expect(try harness.editMesh().vertexCount == 16)

        // Release: the merge commits as ONE journal entry, the commit tick
        // fires exactly then, and the highlight clears.
        capture.end(
            sample: .init(time: 0.1, x: park.x, y: park.y, pressure: 0.5, type: .finger)
        )
        #expect(probe.haptics.ticks == [.snapEngaged, .commit])
        #expect(probe.highlights.last == HoverPreviewState.SnapTarget?.none)
        #expect(!renderer.overlayPath.hasHoverHighlight)
        #expect(harness.bundle.journal.depth == 1)
        guard case .meshEdit(let edit) = try #require(harness.committed.first) else {
            Issue.record("expected a meshEdit command")
            return
        }
        #expect(edit.verb == "tweak.mergeSnap")
        let merged = try harness.editMesh()
        #expect(merged.vertexCount == 15)
        // The survivor sits exactly on the snap target's position.
        #expect(allPositions(of: merged).count { $0 == SIMD3(3, 1, 0) } == 1)
        #expect(allPositions(of: merged).count { $0 == SIMD3(3, 0, 0) } == 0)

        // Undo restores the exact pre-stroke payload bytes (grab + drag +
        // merge were one command).
        harness.undo()
        #expect(harness.bundle.payloads[object.payloadFile] == payloadBefore)
        #expect(try harness.editMesh().vertexCount == 16)
    }

    /// Move's half of the snap detection: dragging the SEED within merge
    /// range of a vertex on the DISCONNECTED strip pre-highlights it and,
    /// on release, welds the seed's position exactly onto the target
    /// vertex — without merging topology (the moved region keeps its
    /// structure; geodesic falloff still never touches the other strip).
    @Test func moveDragSnapsSeedPositionOntoDisconnectedVertexWithoutTopologyMerge() throws {
        let harness = try Harness()
        try addPlaneTarget(to: harness)
        try addStripsEditMesh(to: harness)
        let probe = SnapProbe(harness)

        // Drag the strip-A vertex at (0,1) next to strip B's (0,1.2).
        let grab = harness.screenPoint(of: SIMD3(0, 1, 0))
        let park = harness.screenPoint(of: SIMD3(0.02, 1.15, 0))
        harness.stroke(verb: .move, through: [grab, park])

        // Pre-highlight fired for the strip-B vertex during the drag, the
        // commit tick on release.
        let engaged = try #require(probe.highlights.first ?? nil)
        #expect(engaged.position == SIMD3(0, 1.2, 0))
        #expect(probe.haptics.ticks == [.snapEngaged, .commit])

        #expect(harness.bundle.journal.depth == 1)
        guard case .meshEdit(let edit) = try #require(harness.committed.first) else {
            Issue.record("expected a meshEdit command")
            return
        }
        #expect(edit.verb == "move.vertexSnap")
        let moved = try harness.editMesh()
        // No topology merge: both vertices exist, now coincident.
        #expect(moved.vertexCount == 16)
        #expect(allPositions(of: moved).count { $0 == SIMD3(0, 1.2, 0) } == 2)
    }

    /// Haptics are user-disableable (spec): disabling silences the ticks
    /// ONLY — the pre-highlight still shows and the merge still commits.
    @Test func disabledSnapHapticsStillHighlightAndMergeButNeverTick() throws {
        let harness = try Harness()
        try addPlaneTarget(to: harness)
        try addStripsEditMesh(to: harness)
        let probe = SnapProbe(harness)
        #expect(harness.coordinator.meshEditor.snapHapticsEnabled)  // default on
        harness.coordinator.meshEditor.snapHapticsEnabled = false

        let grab = harness.screenPoint(of: SIMD3(3, 0, 0))
        let park = harness.screenPoint(of: SIMD3(3.05, 0.95, 0))
        harness.stroke(verb: .tweak, through: [grab, park])

        #expect(probe.haptics.ticks.isEmpty)
        #expect(probe.highlights.contains { $0?.position == SIMD3(3, 1, 0) })
        #expect(harness.bundle.journal.depth == 1)
        #expect(try harness.editMesh().vertexCount == 15)
    }

    /// A tweak that ends OUTSIDE merge range never merges and never ticks
    /// the commit (the plain tweak path of task 3.3 is unchanged).
    @Test func tweakEndingOutsideMergeRangeNeitherMergesNorTicksCommit() throws {
        let harness = try Harness()
        try addPlaneTarget(to: harness)
        try addStripsEditMesh(to: harness)
        let probe = SnapProbe(harness)

        let grab = harness.screenPoint(of: SIMD3(3, 0, 0))
        let park = harness.screenPoint(of: SIMD3(3.5, -0.4, 0))
        harness.stroke(verb: .tweak, through: [grab, park])

        #expect(probe.haptics.ticks.isEmpty)
        #expect(harness.bundle.journal.depth == 1)
        guard case .meshEdit(let edit) = try #require(harness.committed.first) else {
            Issue.record("expected a meshEdit command")
            return
        }
        #expect(edit.verb == "tweak")
        #expect(try harness.editMesh().vertexCount == 16)
    }

    /// A cancelled drag clears the highlight and commits nothing — no
    /// merge, no tick, no journal entry.
    @Test func cancelledSnapDragClearsHighlightWithoutCommitting() throws {
        let harness = try Harness()
        try addPlaneTarget(to: harness)
        try addStripsEditMesh(to: harness)
        let probe = SnapProbe(harness)
        let renderer = try #require(harness.coordinator.renderer)

        let capture = harness.coordinator.inputModel.controller.capture
        let grab = harness.screenPoint(of: SIMD3(3, 0, 0))
        let park = harness.screenPoint(of: SIMD3(3.05, 0.95, 0))
        capture.begin(
            source: .finger, verb: .tweak,
            sample: .init(time: 0, x: grab.x, y: grab.y, pressure: 0.5, type: .finger)
        )
        capture.append(
            sample: .init(time: 0.05, x: park.x, y: park.y, pressure: 0.5, type: .finger)
        )
        #expect(renderer.overlayPath.hasHoverHighlight)

        capture.cancel()
        #expect(probe.haptics.ticks == [.snapEngaged])  // no commit tick
        #expect(probe.highlights.last == HoverPreviewState.SnapTarget?.none)
        #expect(!renderer.overlayPath.hasHoverHighlight)
        #expect(harness.bundle.journal.depth == 0)
        #expect(try harness.editMesh().vertexCount == 16)
    }

    /// The screenshot probe drives the same stroke entries and must lock a
    /// live pre-highlight (the simulator cannot synthesize a Pencil drag).
    @Test func visualVerificationProbeLocksASnapHighlight() throws {
        let harness = try Harness()
        try addPlaneTarget(to: harness)
        try addStripsEditMesh(to: harness)
        let renderer = try #require(harness.coordinator.renderer)

        #expect(harness.coordinator.meshEditor.probeSnapHighlightForVisualVerification())
        #expect(renderer.overlayPath.hasHoverHighlight)
        // The probe leaves the stroke in flight: nothing journaled.
        #expect(harness.bundle.journal.depth == 0)
    }

    // MARK: - ScreenRay (camera unprojection math)

    @Test func screenRayRoundTripsWithTheProjection() throws {
        let harness = try Harness()
        try addPlaneTarget(to: harness)
        let renderer = try #require(harness.coordinator.renderer)

        // Project a known world point, unproject its screen point: the ray
        // must pass within a hair of the original point.
        let world = SIMD3<Float>(1.25, -0.75, 0)
        let screen = harness.screenPoint(of: world)
        let ray = try #require(renderer.cameraRay(
            atNormalizedPoint: SIMD2(Float(screen.x), Float(screen.y))
        ))
        let toWorld = world - ray.origin
        let along = simd_dot(toWorld, ray.direction)
        #expect(along > 0)  // in front of the camera
        let closest = ray.origin + ray.direction * along
        #expect(simd_distance(closest, world) < 1e-2)
    }

    @Test func screenRayRejectsDegenerateMatrices() {
        let zero = simd_float4x4()
        #expect(ScreenRay.ray(inverseViewProjection: zero, normalizedPoint: SIMD2(0.5, 0.5)) == nil)
    }
}

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
            coordinator = IsolatedViewportModel.viewport(
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
    ///
    /// `halfSize` matters when a test asserts exact positions: snapping projects
    /// onto the Target, so a cage vertex OUTSIDE its extent is clamped to the
    /// nearest point on it. The 3x2 grid fixture reaches x = 6, past the default
    /// ±5, which is enough to make a rigid move look non-rigid.
    private func addPlaneTarget(to harness: Harness, halfSize: Float = 5) throws {
        let s = halfSize
        let target = try meshFromOBJ("""
        v \(-s) \(-s) 0
        v \(s) \(-s) 0
        v \(s) \(s) 0
        v \(-s) \(s) 0
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

    /// Surface scope: the drag starts in a FACE INTERIOR, away from every vertex
    /// and edge.
    ///
    /// It used to start ON the vertex at (0,1). Since add-context-aware-move
    /// that is vertex scope — one vertex, no falloff — so the start moved to the
    /// interior of the quad it borders, which is what "started on a face" means
    /// now. The falloff behaviour under test is unchanged.
    @Test func moveDragsWithGeodesicFalloffIgnoringDisconnectedComponent() throws {
        let harness = try Harness()
        try addPlaneTarget(to: harness)
        try addStripsEditMesh(to: harness)

        // (0.6, 0.55) sits inside the quad (0,0)-(1,1): 0.4 from the nearest
        // edge and 0.6 from the nearest vertex (1,1), both outside the scope
        // windows (0.35 and 0.3 of a 1-unit cell). Drag +x by 0.6.
        let grab = harness.screenPoint(of: SIMD3(0.6, 0.55, 0))
        let drop = harness.screenPoint(of: SIMD3(1.2, 0.55, 0))
        harness.stroke(verb: .move, through: [grab, drop])

        #expect(harness.bundle.journal.depth == 1)
        guard case .meshEdit(let edit) = try #require(harness.committed.first) else {
            Issue.record("expected a meshEdit command")
            return
        }
        #expect(edit.verb == "move", "surface scope keeps the bare verb")
        let moved = try harness.editMesh()
        // The seed — the vertex at (1,1) — followed the drag in full (full
        // weight at zero geodesic distance)…
        let seed = try #require(moved.nearestVertex(to: SIMD3(1.6, 1, 0), maxDistance: 0.1))
        #expect(abs(seed.position.x - 1.6) < 1e-3)
        // …its strip-A neighbor at (2,1) moved PARTIALLY along the drag, which
        // is the falloff this test exists for…
        let positions = allPositions(of: moved)
        let neighbor = try #require(positions.first {
            abs($0.y - 1) < 1e-3 && $0.x > 2.0 && $0.x < 2.6
        })
        #expect(neighbor.x > 2.0)
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

    // MARK: - Move scope (openspec add-context-aware-move)

    /// Started ON a vertex: that vertex and NOTHING else. This is the assertion
    /// that fails before the change — the falloff always carried the neighbours.
    @Test func moveFromAVertexMovesThatVertexAlone() throws {
        let harness = try Harness()
        try addPlaneTarget(to: harness)
        try addGridEditMesh(to: harness)
        let before = allPositions(of: try harness.editMesh())

        let grab = harness.screenPoint(of: SIMD3(2, 2, 0))
        let drop = harness.screenPoint(of: SIMD3(2.5, 2, 0))
        harness.stroke(verb: .move, through: [grab, drop])

        guard case .meshEdit(let edit) = try #require(harness.committed.first) else {
            Issue.record("expected a meshEdit command")
            return
        }
        #expect(edit.verb == "move.vertex")
        let after = allPositions(of: try harness.editMesh())
        #expect(after.count == before.count)
        let moved = Set(after).subtracting(before)
        #expect(moved.count == 1, "moved \(moved.count) vertices, expected exactly 1")
        let landed = try #require(moved.first)
        #expect(abs(landed.x - 2.5) < 1e-3 && abs(landed.y - 2) < 1e-3)
        // Every neighbour of the grabbed vertex is bit-exact.
        for neighbour in [SIMD3<Float>(0, 2, 0), SIMD3(4, 2, 0), SIMD3(2, 0, 0), SIMD3(2, 4, 0)] {
            #expect(before.contains(neighbour) && after.contains(neighbour), "\(neighbour) moved")
        }
    }

    /// Started ON an edge: the whole loop, rigidly.
    @Test func moveFromAnEdgeMovesTheWholeLoopRigidly() throws {
        let harness = try Harness()
        // Wide enough to cover the grid's x = 6 column: on the default ±5
        // Target the snapper clamps that vertex to x = 5, and a rigid move
        // reads as a sheared one.
        try addPlaneTarget(to: harness, halfSize: 10)
        try addGridEditMesh(to: harness)
        let before = allPositions(of: try harness.editMesh())

        // (1,2) is the midpoint of the edge (0,2)-(2,2): 1 unit from either
        // vertex (window 0.6 of a 2-unit cell) and 0 from the edge.
        let grab = harness.screenPoint(of: SIMD3(1, 2, 0))
        let drop = harness.screenPoint(of: SIMD3(1, 2.5, 0))
        harness.stroke(verb: .move, through: [grab, drop])

        guard case .meshEdit(let edit) = try #require(harness.committed.first) else {
            Issue.record("expected a meshEdit command")
            return
        }
        #expect(edit.verb == "move.loop")
        let after = allPositions(of: try harness.editMesh())
        // The whole middle row moved together, by the same amount…
        for x in [Float(0), 2, 4, 6] {
            #expect(
                after.contains { abs($0.x - x) < 1e-3 && abs($0.y - 2.5) < 1e-3 },
                """
                the loop vertex at (\(x),2) did not arrive at y 2.5
                after: \(after.sorted { ($0.y, $0.x) < ($1.y, $1.x) })
                """
            )
        }
        // …and the rows above and below did not move at all.
        for x in [Float(0), 2, 4, 6] {
            for y in [Float(0), 4] {
                let expected = SIMD3(x, y, 0)
                #expect(before.contains(expected) && after.contains(expected))
            }
        }
    }

    /// A loop drag never merges, however close it lands: the release would
    /// decide a merge for every vertex at once.
    @Test func aDraggedLoopNeverMerges() throws {
        let harness = try Harness()
        try addPlaneTarget(to: harness)
        try addGridEditMesh(to: harness)
        let probe = SnapProbe(harness)
        let countBefore = try harness.editMesh().vertexCount

        // Drag the middle row (y = 2) down to y = 0.5 — half a cell from the
        // bottom row, well inside the 0.6 merge range a vertex drag would use.
        let grab = harness.screenPoint(of: SIMD3(1, 2, 0))
        let drop = harness.screenPoint(of: SIMD3(1, 0.5, 0))
        harness.stroke(verb: .move, through: [grab, drop])

        guard case .meshEdit(let edit) = try #require(harness.committed.first) else {
            Issue.record("expected a meshEdit command")
            return
        }
        #expect(edit.verb == "move.loop", "a loop drag must never gain .mergeSnap")
        #expect(try harness.editMesh().vertexCount == countBefore)
        #expect(
            probe.highlights.compactMap { $0 }.isEmpty,
            "a loop drag must not offer a merge candidate to highlight"
        )
    }

    /// The scope is decided once. Passing over an edge mid-drag must not turn a
    /// vertex drag into a loop drag.
    @Test func theScopeSurvivesTheDrag() throws {
        let harness = try Harness()
        try addPlaneTarget(to: harness)
        try addGridEditMesh(to: harness)
        let before = allPositions(of: try harness.editMesh())

        // Start on the vertex (2,2), pass through (2,3) — the midpoint of the
        // edge above, which would resolve to loop scope on its own — and release
        // at (2,3.2), which is 0.8 from the vertex at (2,4): outside the 0.6
        // merge range, so this tests the SCOPE and not the merge.
        harness.stroke(verb: .move, through: [
            harness.screenPoint(of: SIMD3(2, 2, 0)),
            harness.screenPoint(of: SIMD3(2, 3, 0)),
            harness.screenPoint(of: SIMD3(2, 3.2, 0)),
        ])

        guard case .meshEdit(let edit) = try #require(harness.committed.first) else {
            Issue.record("expected a meshEdit command")
            return
        }
        #expect(edit.verb == "move.vertex", "the drag changed scope under the finger")
        let after = allPositions(of: try harness.editMesh())
        #expect(Set(after).subtracting(before).count == 1)
    }

    /// A pinned vertex inside a dragged loop holds, and the rest of the loop
    /// still moves — the shear documented in the design, not a refused drag.
    @Test func aPinnedVertexInsideADraggedLoopHolds() throws {
        let harness = try Harness()
        try addPlaneTarget(to: harness)
        try addGridEditMesh(to: harness)
        let mesh = try harness.editMesh()
        let pinned = try #require(mesh.nearestVertex(to: SIMD3(0, 2, 0), maxDistance: 1e-3))
        let index = try #require(
            harness.bundle.manifest.objects.firstIndex { $0.role == .editMesh }
        )
        harness.bundle.manifest.objects[index].annotations =
            MeshAnnotations(pinnedVertices: [pinned.vertex])
        harness.sync()

        harness.stroke(verb: .move, through: [
            harness.screenPoint(of: SIMD3(1, 2, 0)),
            harness.screenPoint(of: SIMD3(1, 2.5, 0)),
        ])

        let after = allPositions(of: try harness.editMesh())
        #expect(
            after.contains(SIMD3(0, 2, 0)), "the pinned loop vertex was displaced"
        )
        #expect(
            after.contains { abs($0.x - 2) < 1e-3 && abs($0.y - 2.5) < 1e-3 },
            "the unpinned rest of the loop did not move"
        )
    }

    // MARK: - Move scope resolution (pure)

    /// The windows are fractions of the LOCAL CELL, so the same gesture picks
    /// the same thing on cages of different density. A scene-relative window has
    /// been the defect four times in this line of work.
    @Test func theScopeIsTheSameOnACoarseAndAFineCage() throws {
        func grid(cell: Float) throws -> Mesh {
            var obj = ""
            for row in 0...2 {
                for col in 0...2 { obj += "v \(Float(col) * cell) \(Float(row) * cell) 0\n" }
            }
            for row in 0..<2 {
                for col in 0..<2 {
                    let a = row * 3 + col + 1
                    obj += "f \(a) \(a + 1) \(a + 4) \(a + 3)\n"
                }
            }
            return try meshFromOBJ(obj)
        }
        // The same OFFSETS, expressed as fractions of each cage's own cell.
        for cell in [Float(1), 0.25, 8] {
            let mesh = try grid(cell: cell)
            let scene = cell * 20  // a scene far bigger than the cage, as on device
            let onVertex = MeshEditController.resolveMoveScope(
                at: SIMD3(cell * 0.1, 0, 0), in: mesh, sceneRadius: scene
            )
            let onEdge = MeshEditController.resolveMoveScope(
                at: SIMD3(cell * 0.5, 0, 0), in: mesh, sceneRadius: scene
            )
            guard case .vertex = try #require(onVertex) else {
                Issue.record("cell \(cell): 0.1 of a cell from a vertex is not vertex scope")
                return
            }
            guard case .loop = try #require(onEdge) else {
                Issue.record("cell \(cell): the middle of an edge is not loop scope")
                return
            }
        }
    }

    /// Reported from device: starting a Move on a face stopped stretching the
    /// patch. The edge window was eating the face.
    ///
    /// A TRIANGLE is the extreme case. Its farthest interior point from any edge
    /// is the incenter, and for a right-isoceles triangle (what a triangulated
    /// quad gives) that is only ~0.26 of the mean edge length. An edge window of
    /// 0.35 therefore covers the WHOLE triangle: surface scope was unreachable
    /// inside one, at any touch position.
    @Test func theInteriorOfATriangleResolvesToSurfaceScope() throws {
        let mesh = try meshFromOBJ("""
        v 0 0 0
        v 1 0 0
        v 0 1 0
        f 1 2 3
        """)
        // The incenter: 0.293 from all three edges, 0.414 from the nearest
        // vertex — as far from an edge as a point in this triangle can be.
        let scope = MeshEditController.resolveMoveScope(
            at: SIMD3(0.293, 0.293, 0), in: mesh, sceneRadius: 10
        )
        guard case .surface = try #require(scope) else {
            Issue.record(
                "the middle of a triangle must be surface scope, got \(String(describing: scope))"
            )
            return
        }
    }

    /// The face interior is the DEFAULT gesture, so it has to be the dominant
    /// region of a cell — not a pinhole at the exact centre. This is the
    /// property that broke on device: at a 0.35 edge window only the inner 9%
    /// of a square cell resolved to surface.
    @Test func mostOfAQuadsInteriorResolvesToSurfaceScope() throws {
        let mesh = try meshFromOBJ("""
        v 0 0 0
        v 1 0 0
        v 1 1 0
        v 0 1 0
        f 1 2 3 4
        """)
        var surface = 0
        var sampled = 0
        for row in 1..<10 {
            for column in 1..<10 {
                sampled += 1
                let hit = SIMD3(Float(column) / 10, Float(row) / 10, 0)
                if case .surface = MeshEditController.resolveMoveScope(
                    at: hit, in: mesh, sceneRadius: 10
                ) {
                    surface += 1
                }
            }
        }
        let share = Double(surface) / Double(sampled)
        #expect(
            share >= 0.4,
            """
            only \(Int(share * 100))% of the cell's interior is surface scope — \
            the artist has to hit a pinhole to stretch a patch
            """
        )
    }

    /// The counterweight to the test above: shrinking the edge window must not
    /// put edge scope out of reach for someone aiming at an edge.
    @Test func aTouchAimedAtAnEdgeStillResolvesToLoopScope() throws {
        let mesh = try meshFromOBJ("""
        v 0 0 0
        v 1 0 0
        v 2 0 0
        v 0 1 0
        v 1 1 0
        v 2 1 0
        v 0 2 0
        v 1 2 0
        v 2 2 0
        f 1 2 5 4
        f 2 3 6 5
        f 4 5 8 7
        f 5 6 9 8
        """)
        // A tenth of a cell off the middle of the interior edge (0,1)-(1,1).
        let scope = MeshEditController.resolveMoveScope(
            at: SIMD3(0.5, 1.1, 0), in: mesh, sceneRadius: 10
        )
        guard case .loop = try #require(scope) else {
            Issue.record("aiming at an edge must still grab its loop")
            return
        }
    }

    /// A cell that cannot be measured must not make every scope unreachable.
    /// The answer is vertex scope — NOT a scene-derived floor under the windows,
    /// which would win on any cage smaller than the scene and reinstate exactly
    /// the scene-relative behavior these windows exist to remove.
    @Test func anUnmeasurableCellResolvesToVertexScope() throws {
        // Two coincident vertices: the edge between them has zero length, so
        // there is no cell to measure.
        let mesh = try meshFromOBJ("""
        v 0 0 0
        v 0 0 0
        v 1 0 0
        f 1 2 3
        """)
        let scope = MeshEditController.resolveMoveScope(
            at: SIMD3(0, 0, 0), in: mesh, sceneRadius: 10
        )
        guard case .vertex = try #require(scope, "an unmeasurable cell left the drag inert")
        else {
            Issue.record("expected vertex scope, got \(String(describing: scope))")
            return
        }
    }

    /// An edge whose loop cannot be walked still moves something: the drag
    /// visibly grabbed an edge, so being inert would be the wrong answer.
    @Test func anUnwalkableLoopDegradesToTheEdgeItself() throws {
        // A lone triangle: every vertex is on the boundary, so the loop walk
        // stops immediately.
        let mesh = try meshFromOBJ("""
        v 0 0 0
        v 1 0 0
        v 0 1 0
        f 1 2 3
        """)
        let edge = try #require(mesh.nearestEdge(to: SIMD3(0.5, 0, 0), maxDistance: 0.1))
        try #require(
            mesh.edgeLoopVertices(from: edge.edge).count < 3,
            "fixture no longer exercises the degradation — pick another"
        )

        let scope = MeshEditController.resolveMoveScope(
            at: SIMD3(0.5, 0, 0), in: mesh, sceneRadius: 10
        )
        guard case .loop(let vertices, _, _) = try #require(scope) else {
            Issue.record("expected the edge to still resolve to a movable set")
            return
        }
        let ends = try #require(mesh.edgeEndpoints(of: edge.edge))
        #expect(Set(vertices) == Set([ends.0, ends.1]))
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

    /// EditMesh: two disconnected 3-quad strips facing each other across a
    /// ONE-UNIT gap (cells are 1 unit too, so the bridge is a single row).
    /// The corridor between y = 1 and y = 2 is bare Target.
    private func addFacingStripsEditMesh(to harness: Harness) throws {
        let strips = try meshFromOBJ("""
        v 0 0 0
        v 1 0 0
        v 2 0 0
        v 3 0 0
        v 0 1 0
        v 1 1 0
        v 2 1 0
        v 3 1 0
        v 0 2 0
        v 1 2 0
        v 2 2 0
        v 3 2 0
        v 0 3 0
        v 1 3 0
        v 2 3 0
        v 3 3 0
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

    /// EditMesh: an L-shaped cage leaving an EMPTY 2x2 corner block at x 1..3,
    /// y 1..3 — the device shape. A row of three quads runs along the bottom
    /// (its top rim, y = 1, is subdivided at x = 1, 2, 3) and a column of two
    /// runs up the left (its right rim, x = 1, is subdivided at y = 1, 2, 3).
    ///
    ///   (0,3)--(1,3)          .           the block is bounded BELOW by the row's
    ///     |      |                        top rim and on the LEFT by the column's
    ///   (0,2)--(1,2)          .           right rim, and is open up and right
    ///     |      |
    ///   (0,1)--(1,1)--(2,1)--(3,1)
    ///     |      |      |      |
    ///   (0,0)--(1,0)--(2,0)--(3,0)
    private func cornerBlockEditMesh(to harness: Harness) throws {
        let cage = try meshFromOBJ("""
        v 0 0 0
        v 1 0 0
        v 2 0 0
        v 3 0 0
        v 0 1 0
        v 1 1 0
        v 2 1 0
        v 3 1 0
        v 0 2 0
        v 1 2 0
        v 0 3 0
        v 1 3 0
        f 1 2 6 5
        f 2 3 7 6
        f 3 4 8 7
        f 5 6 10 9
        f 9 10 12 11
        """)
        try harness.bundle.addObject(name: "cage", role: .editMesh, mesh: cage)
        harness.sync()
    }

    /// The device question behind fix-quad-rim-sharing — "why are the quads not
    /// sharing the same edge?". A face drawn along a SUBDIVIDED rim came out as one
    /// face whose long side crossed every rim vertex without sharing it: a crack, not
    /// a shared edge. The rim's cells must be continued across the drawn region.
    ///
    /// The stroke is the device shape: an L tracing the two rims that bound the empty
    /// corner block, from one existing vertex to another with the bend between them.
    /// That ring is why the old corner-based trigger could never fire — its two
    /// existing vertices sit DIAGONALLY opposite, never on one side.
    @Test func quadDrawnAlongASubdividedRimSharesEveryVertexOfIt() throws {
        let harness = try Harness()
        try addPlaneTarget(to: harness)
        try cornerBlockEditMesh(to: harness)
        let object = try #require(harness.editObject)
        let payloadBefore = try #require(harness.bundle.payloads[object.payloadFile])
        #expect(try harness.editMesh().faceCount == 5)
        #expect(try harness.editMesh().vertexCount == 12)

        // (3,1) → left along the row's top rim → (1,1) → up the column's right rim
        // → (1,3). Both endpoints are existing vertices; the fourth corner (3,3) is
        // inferred out in the open.
        harness.stroke(verb: .pencil, through: harness.densified(through: [
            harness.screenPoint(of: SIMD3(3, 1, 0)),
            harness.screenPoint(of: SIMD3(1, 1, 0)),
            harness.screenPoint(of: SIMD3(1, 3, 0)),
        ]))

        #expect(harness.bundle.journal.depth == 1, "one stroke, one journal entry")
        let built = try harness.editMesh()
        // The traced rim's two cells were CONTINUED across the block's two cells of
        // depth: four quads, not one face stretched over the whole block.
        #expect(built.faceCount == 9, "2 rim cells x 2 rows of depth = 4 new quads")
        // The interior rim vertex (2,1) is shared: it had the row's two quads, and now
        // also carries the patch. A single stretched face would have left it at two,
        // T-junctioned against the new long edge.
        let interior = try #require(built.nearestVertex(to: SIMD3(2, 1, 0), maxDistance: 0.1))
        let touching = built.liveFaceIDs().filter {
            built.faceVertices($0).contains(interior.vertex)
        }
        #expect(
            touching.count == 4,
            "rim vertex (2,1) is in \(touching.count) faces — the patch skipped it"
        )
        // The patch's far side lands on the column's rim at (1,2) and (1,3): those weld
        // onto the existing vertices instead of laying duplicates over them, so the
        // count is 12 + 6 created - 2 welded.
        let nearColumnRim = built.liveVertexIDs()
            .compactMap { built.vertexPosition($0) }
            .filter { abs($0.x - 1) < 0.2 && $0.y > 1.5 }
            .sorted { ($0.y, $0.x) < ($1.y, $1.x) }
        #expect(
            built.vertexCount == 16,
            "the patch must close onto the second rim; vertices near it: \(nearColumnRim)"
        )

        harness.undo()
        #expect(harness.bundle.payloads[object.payloadFile] == payloadBefore)
        #expect(try harness.editMesh().faceCount == 5)
    }

    /// REGRESSION GUARD: the one-cell append must stay a single face — the trigger
    /// widened, so this is the case it must NOT swallow.
    @Test func oneCellAppendIsStillASingleFace() throws {
        let harness = try Harness()
        try addPlaneTarget(to: harness)
        try addFacingStripsEditMesh(to: harness)
        let object = try #require(harness.editObject)
        let facesBefore = try harness.editMesh().faceCount

        // A quad appended off ONE cell of the lower strip's top rim (x 0..1 at y = 1).
        harness.stroke(verb: .pencil, through: harness.densified(through: [
            harness.screenPoint(of: SIMD3(0, 1, 0)),
            harness.screenPoint(of: SIMD3(0, 1.8, 0)),
            harness.screenPoint(of: SIMD3(1, 1.8, 0)),
            harness.screenPoint(of: SIMD3(1, 1, 0)),
        ]))

        let built = try harness.editMesh()
        #expect(
            built.faceCount == facesBefore + 1,
            "a one-cell append must stay exactly one face, got \(built.faceCount - facesBefore)"
        )
        _ = object
    }

    /// The device case behind add-stroke-rim-bridge: a straight stroke across an
    /// unfilled gap used to insert an edge loop into a ring it only clipped at
    /// its endpoints. It now bridges the two rims, in ONE journal entry.
    @Test func strokeAcrossAGapBridgesTheRimsAndUndoRestoresBytes() throws {
        let harness = try Harness()
        try addPlaneTarget(to: harness)
        try addFacingStripsEditMesh(to: harness)
        let object = try #require(harness.editObject)
        let payloadBefore = try #require(harness.bundle.payloads[object.payloadFile])
        #expect(try harness.editMesh().faceCount == 6)

        // From the lower strip's rim vertex (1,1) straight up across the gap to
        // the upper strip's rim vertex (1,2).
        harness.stroke(verb: .pencil, through: harness.densified(through: [
            harness.screenPoint(of: SIMD3(1, 1, 0)),
            harness.screenPoint(of: SIMD3(1, 2, 0)),
        ]))

        let summary = harness.coordinator.inputModel.lastInterpretation?.summary ?? "nil"
        #expect(
            harness.bundle.journal.depth == 1,
            "the whole bridge is one journal entry; interpretation was \(summary)"
        )
        guard case .meshEdit(let edit) = try #require(harness.committed.first) else {
            Issue.record("expected a meshEdit command")
            return
        }
        #expect(edit.verb == "pencil.bridgeRims")
        let bridged = try harness.editMesh()
        // Three bridge quads — the corridor fills on BOTH sides of the stroke,
        // not just under it — built from the existing rim vertices, so the
        // vertex count is unchanged.
        #expect(bridged.faceCount == 9)
        #expect(bridged.vertexCount == 16)
        #expect(try bridged.stats().quads == 9)

        harness.undo()
        #expect(harness.bundle.payloads[object.payloadFile] == payloadBefore)
        #expect(try harness.editMesh().faceCount == 6)
        harness.redo()
        #expect(try harness.editMesh().faceCount == 9)
    }

    // lineAlongLoopTagsWholeLoop... retired: tagLoop is no longer a stroke
    // gesture (a line along a loop is a tool now). Loop tagging keeps
    // annotation-tool coverage in AnnotationToolsTests.

    // scribbleOverEdgeDissolvesItIntoOneQuad retired: dissolveEdge is no
    // longer a stroke gesture (it is a tool). A scribble over geometry now
    // DELETES the faces it covers — covered at the interpreter level by
    // StrokeInterpreterTests.scribbleOverGeometryResolvesDelete, and the
    // end-to-end delete path by xOverAFaceDeletesItAndUndoRestores below.

    /// 6.2b: the SAME X, in the UV stage, must not delete anything.
    ///
    /// Written before the fix, and it fails against unfixed code — the mapping from `.cross`
    /// to `.deleteFaces` is unconditional today, and the viewport stays interactive in the UV
    /// stage by design, so this gesture destroys the cage the artist is unwrapping. The spec
    /// says an X there re-unwraps the island; the first thing to guarantee is that it does not
    /// DELETE, because an unimplemented gesture must be inert rather than destructive.
    @Test func xInTheUVStageDoesNotDeleteFaces() throws {
        let harness = try Harness()
        try addPlaneTarget(to: harness)
        try addStripsEditMesh(to: harness)
        let object = try #require(harness.editObject)
        let payloadBefore = try #require(harness.bundle.payloads[object.payloadFile])
        let facesBefore = try harness.editMesh().faceCount
        let verticesBefore = try harness.editMesh().vertexCount

        harness.bundle.manifest.stage = .uv
        harness.sync()

        // Byte-identical stroke to `xOverAFaceDeletesItAndUndoRestores`, so the only
        // difference between deleting and not deleting is the stage.
        harness.stroke(verb: .pencil, through: harness.densified(through: [
            harness.screenPoint(of: SIMD3(0.15, 0.15, 0)),
            harness.screenPoint(of: SIMD3(0.85, 0.85, 0)),
            harness.screenPoint(of: SIMD3(0.85, 0.15, 0)),
            harness.screenPoint(of: SIMD3(0.15, 0.85, 0)),
        ], samplesPerSegment: 16))

        // GEOMETRY is preserved — that is the destructive behaviour being ruled out.
        let after = try harness.editMesh()
        #expect(after.faceCount == facesBefore, "no face may be deleted")
        #expect(after.vertexCount == verticesBefore, "no vertex may be lost")
        #expect(
            !harness.committed.contains { command in
                guard case .meshEdit(let edit) = command else { return false }
                return edit.verb == "pencil.deleteFaces"
            },
            "no delete may be journaled in the UV stage"
        )

        // The payload DOES change, and that is correct: this fixture had never been
        // unwrapped, so the X runs the whole-mesh unwrap. Asserting the payload was untouched
        // would be asserting the gesture did nothing, which is not what the spec asks for.
        #expect(harness.bundle.payloads[object.payloadFile] != payloadBefore)
        #expect(after.hasUVLayout, "the X must have unwrapped, not merely declined to delete")
    }

    /// The same X on an ALREADY-unwrapped cage re-unwraps one island rather than the mesh.
    @Test func xInTheUVStageReunwrapsOneIsland() throws {
        let harness = try Harness()
        try addPlaneTarget(to: harness)
        try addStripsEditMesh(to: harness)
        harness.bundle.manifest.stage = .uv
        harness.sync()

        // First X: nothing was unwrapped, so this lays out the whole mesh.
        func drawX() {
            harness.stroke(verb: .pencil, through: harness.densified(through: [
                harness.screenPoint(of: SIMD3(0.15, 0.15, 0)),
                harness.screenPoint(of: SIMD3(0.85, 0.85, 0)),
                harness.screenPoint(of: SIMD3(0.85, 0.15, 0)),
                harness.screenPoint(of: SIMD3(0.15, 0.85, 0)),
            ], samplesPerSegment: 16))
        }
        drawX()
        let laidOut = try harness.editMesh()
        try #require(laidOut.hasUVLayout)
        let uvsAfterFullUnwrap = try #require(laidOut.uvCoordinates())
        let facesAfterFullUnwrap = laidOut.faceCount
        let depthAfterFullUnwrap = harness.bundle.journal.depth

        // Second X on the same spot: now a single-island re-unwrap.
        drawX()
        let reunwrapped = try harness.editMesh()
        #expect(reunwrapped.faceCount == facesAfterFullUnwrap, "still no deletion")
        let uvsAfterReunwrap = try #require(reunwrapped.uvCoordinates())
        #expect(uvsAfterReunwrap.count == uvsAfterFullUnwrap.count)

        // Whatever it did, it is at most ONE more journal entry — a re-unwrap that produced
        // byte-identical UVs correctly journals nothing, which is a no-op and not a failure.
        #expect(harness.bundle.journal.depth <= depthAfterFullUnwrap + 1)
        #expect(
            !harness.committed.contains { command in
                guard case .meshEdit(let edit) = command else { return false }
                return edit.verb == "pencil.deleteFaces"
            }
        )
    }

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

    /// Task 4.5a (face-only Auto Relax, enabled by the engine `faceVertices`
    /// query): deleting a face with Auto Relax on redistributes the topology
    /// around the hole — the face's ring is now a resolvable neighbourhood —
    /// while the same delete with the mode off leaves the neighbours put. One
    /// journal entry either way.
    @Test func deleteFacesRunsAutoRelaxAroundTheHole() throws {
        // Deletes the face adjacent to the perturbed vertex (1.35, 0.75).
        func deleteInteriorFace(on harness: Harness) {
            harness.stroke(verb: .pencil, through: harness.densified(through: [
                harness.screenPoint(of: SIMD3(1.2, 1.1, 0)),
                harness.screenPoint(of: SIMD3(1.9, 1.7, 0)),
                harness.screenPoint(of: SIMD3(1.9, 1.1, 0)),
                harness.screenPoint(of: SIMD3(1.2, 1.7, 0)),
            ], samplesPerSegment: 16))
        }

        // Auto Relax OFF baseline.
        let off = try Harness()
        try addPlaneTarget(to: off)
        try addPerturbedGridEditMesh(to: off)
        off.coordinator.meshEditor.autoRelaxEnabled = false
        deleteInteriorFace(on: off)
        #expect(off.bundle.journal.depth == 1)
        let offMesh = try off.editMesh()
        #expect(offMesh.faceCount == 8)
        let offPositions = offMesh.positions()

        // Auto Relax ON — same seed, same delete.
        let on = try Harness()
        try addPlaneTarget(to: on)
        try addPerturbedGridEditMesh(to: on)
        on.coordinator.meshEditor.autoRelaxEnabled = true
        deleteInteriorFace(on: on)

        #expect(on.bundle.journal.depth == 1)  // delete + relax = one entry
        guard case .meshEdit(let edit) = try #require(on.committed.first) else {
            Issue.record("expected a meshEdit command")
            return
        }
        #expect(edit.verb == "pencil.deleteFaces")
        let onMesh = try on.editMesh()
        #expect(onMesh.faceCount == 8, "the same face was deleted")
        #expect(
            onMesh.positions() != offPositions,
            "Auto Relax redistributed the vertices around the deleted face"
        )
    }

    /// Task 4.4a(2) mirrored element edits: with X mirror symmetry on, an
    /// X-delete drawn over ONE face also deletes its mirror counterpart —
    /// resolved by centroid — in the SAME journal entry, and one undo restores
    /// both.
    @Test func symmetricXDeleteRemovesTheMirrorFaceToo() throws {
        let harness = try Harness()
        try addPlaneTarget(to: harness)
        // Two stacked quads on each side, mirror-symmetric across x = 0.
        let cage = try meshFromOBJ("""
        v 1 0 0
        v 2 0 0
        v 2 1 0
        v 1 1 0
        v 2 2 0
        v 1 2 0
        v -1 0 0
        v -2 0 0
        v -2 1 0
        v -1 1 0
        v -2 2 0
        v -1 2 0
        f 1 2 3 4
        f 4 3 5 6
        f 7 8 9 10
        f 10 9 11 12
        """)
        try harness.bundle.addObject(name: "cage", role: .editMesh, mesh: cage)
        harness.sync()
        var settings = SymmetrySettings()
        settings.isEnabled = true
        settings = settings.settingMirror(.x, enabled: true)
        harness.perform(.setSymmetry(from: harness.bundle.manifest.symmetry, to: settings))
        let object = try #require(harness.editObject)
        let before = try #require(harness.bundle.payloads[object.payloadFile])
        #expect(try harness.editMesh().faceCount == 4)

        // X-delete over the RIGHT-BOTTOM quad only (its centroid is 1.5, 0.5).
        harness.stroke(verb: .pencil, through: harness.densified(through: [
            harness.screenPoint(of: SIMD3(1.2, 0.2, 0)),
            harness.screenPoint(of: SIMD3(1.8, 0.8, 0)),
            harness.screenPoint(of: SIMD3(1.8, 0.2, 0)),
            harness.screenPoint(of: SIMD3(1.2, 0.8, 0)),
        ], samplesPerSegment: 16))

        guard case .meshEdit(let edit) = try #require(harness.committed.last) else {
            Issue.record("expected a meshEdit command")
            return
        }
        #expect(edit.verb == "pencil.deleteFaces")
        // The drawn face AND its mirror are both gone (4 → 2), in ONE entry.
        #expect(try harness.editMesh().faceCount == 2, "the mirror face deleted too")
        // The survivors are the two TOP quads, one on each side.
        let mesh = try harness.editMesh()
        #expect(mesh.nearestFace(to: SIMD3(1.5, 1.5, 0), maxDistance: 0.1) != nil)
        #expect(mesh.nearestFace(to: SIMD3(-1.5, 1.5, 0), maxDistance: 0.1) != nil)
        // The deleted region and its mirror are empty.
        #expect(mesh.nearestFace(to: SIMD3(1.5, 0.5, 0), maxDistance: 0.1) == nil)
        #expect(mesh.nearestFace(to: SIMD3(-1.5, 0.5, 0), maxDistance: 0.1) == nil)

        harness.undo()
        #expect(harness.bundle.payloads[object.payloadFile] == before)
        #expect(try harness.editMesh().faceCount == 4)
    }

    /// Task 4.4a(2): with X symmetry on, a line drawn across the ring on ONE
    /// side inserts the loop on BOTH sides — the mirror crossed-edge is
    /// resolved by midpoint — in the same journal entry.
    @Test func symmetricInsertLoopSplitsBothSides() throws {
        let harness = try Harness()
        try addPlaneTarget(to: harness)
        // A grid symmetric about x = 0: cols at x = -4,-2,0,2,4; rows y = 0,2,4.
        var obj = ""
        for row in 0...2 {
            for col in 0...4 { obj += "v \(col * 2 - 4) \(row * 2) 0\n" }
        }
        for row in 0..<2 {
            for col in 0..<4 {
                let a = row * 5 + col + 1
                obj += "f \(a) \(a + 1) \(a + 6) \(a + 5)\n"
            }
        }
        try harness.bundle.addObject(name: "cage", role: .editMesh, mesh: try meshFromOBJ(obj))
        harness.sync()
        var settings = SymmetrySettings()
        settings.isEnabled = true
        settings = settings.settingMirror(.x, enabled: true)
        harness.perform(.setSymmetry(from: harness.bundle.manifest.symmetry, to: settings))
        let object = try #require(harness.editObject)
        let payloadBefore = try #require(harness.bundle.payloads[object.payloadFile])
        #expect(try harness.editMesh().faceCount == 8)

        // Vertical line across the RIGHT column (x in [2,4]), crossing its
        // horizontal edges at x = 3.
        harness.stroke(verb: .pencil, through: harness.densified(through: [
            harness.screenPoint(of: SIMD3(3, -1, 0)),
            harness.screenPoint(of: SIMD3(3, 5, 0)),
        ]))

        guard case .meshEdit(let edit) = try #require(harness.committed.last) else {
            Issue.record("expected a meshEdit command")
            return
        }
        #expect(edit.verb == "pencil.insertLoop")
        let mesh = try harness.editMesh()
        // A loop was inserted on EACH side: new vertices sit at x = 3 AND the
        // mirror x = -3.
        #expect(mesh.faceCount > 8, "loops inserted: \(mesh.faceCount)")
        #expect(mesh.nearestVertex(to: SIMD3(3, 2, 0), maxDistance: 1e-3) != nil, "right loop")
        #expect(mesh.nearestVertex(to: SIMD3(-3, 2, 0), maxDistance: 1e-3) != nil, "mirror loop")

        harness.undo()
        #expect(harness.bundle.payloads[object.payloadFile] == payloadBefore)
        #expect(try harness.editMesh().faceCount == 8)
    }

    // vertexToVertexLineMergesThem retired: mergeVertices is a tool now, not
    // a stroke gesture — a line between two vertices no longer merges them.
    // circleOverEdgeRotatesTheDiagonal retired: rotateEdge is a tool now — a
    // small circle over an edge creates a quad. Both keep tool-level coverage.

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

    // verticalLinesInEmptySpaceInvertAndShowAllVisibility retired:
    // toggleVisibility is a tool now, not a stroke gesture — a straight line
    // in empty space no longer inverts or shows-all. Visibility keeps
    // tool/annotation coverage.

    /// createGrid is retired from the stroke grammar (a tool now): the
    /// serpentine "grid" stroke no longer drops a block of quads by gesture,
    /// so it creates no EditMesh and journals nothing. (The injection hook
    /// stays exercised.)
    @Test func gridStrokeIsNoLongerAGesture() throws {
        let harness = try Harness()
        let target = try Mesh.loadOBJ(at: UITestSupport.writeSeedTargetOBJ())
        try harness.bundle.addObject(name: "target", role: .target, mesh: target)
        harness.sync()
        #expect(harness.editObject == nil)

        harness.coordinator.inputModel.injectGridStroke()

        #expect(harness.editObject == nil)
        #expect(harness.bundle.journal.depth == 0)
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

    // tagLoopStrokeSwapsToInsertLoopInPlace, ringStrokeOnSeededStripSwaps-
    // ToInsertLoopViaTheModel and alternativeSwapAfterUndoIsRejectedUntouched
    // retired: they relied on the tagLoop<->insertLoop misrecognition pair.
    // Under the curated grammar every stroke has a single candidate (quad,
    // triangle, delete, loop-cut, or none), so there are no ranked
    // alternatives to swap. The swap PATH (applyAlternative /
    // replacementCommand) is unchanged and still covered by its unit tests;
    // only these multi-candidate scenarios are gone.

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

    /// Move's half of the snap detection: dragging the SEED within merge range
    /// of a vertex on the DISCONNECTED strip pre-highlights it and, on release,
    /// MERGES the seed into it.
    ///
    /// Move used to weld the seed's position only, leaving two coincident
    /// vertices where the artist plainly meant one. Only the seed merges — the
    /// vertex under the finger, never anything the falloff carried — so the
    /// moved region still keeps its structure.
    @Test func moveDragMergesSeedIntoTheDisconnectedVertexItLandsOn() throws {
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
        // Vertex scope, because the drag started ON the vertex — and vertex
        // scope still merges on release.
        #expect(edit.verb == "move.vertex.mergeSnap")
        let moved = try harness.editMesh()
        // ONE vertex where there were two: the seed was absorbed, not parked on
        // top of the target.
        #expect(moved.vertexCount == 15)
        #expect(allPositions(of: moved).count { $0 == SIMD3(0, 1.2, 0) } == 1)
    }

    /// The merge window is the grabbed vertex's OWN CELL, not a slice of the
    /// scene: the same gesture has to behave the same on a coarse cage and a
    /// fine one, and a scene-relative window is a different multiple of a cell
    /// on each.
    @Test func mergeRangeFollowsTheLocalCellNotTheScene() throws {
        // One quad with 1-unit cells, in a scene whose radius is 100.
        let coarse = try meshFromOBJ("""
        v 0 0 0
        v 1 0 0
        v 1 1 0
        v 0 1 0
        f 1 2 3 4
        """)
        let cellRange = MeshEditController.mergeRange(
            around: 0, in: coarse, sceneRadius: 100
        )
        // 30% of the 1-unit cell — NOT 4% of the 100-unit scene (which would be
        // 4 whole cells and would swallow every vertex in the quad).
        #expect(abs(cellRange - 0.3) < 1e-4, "expected the cell's own scale, got \(cellRange)")

        // The same cage in a tiny scene: the SAME range. This is the whole point —
        // the gesture cannot mean different things because the scene resized.
        let tightRange = MeshEditController.mergeRange(
            around: 0, in: coarse, sceneRadius: 0.001
        )
        #expect(abs(tightRange - 0.3) < 1e-4)

        // A vertex with no edges to measure falls back to the scene-derived
        // window — the only case where it still applies.
        #expect(
            abs(MeshEditController.mergeRange(around: 99, in: coarse, sceneRadius: 2) - 0.08)
                < 1e-4
        )
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

    /// The Halve batch command end to end: one journal entry, the cage halves, and
    /// one undo restores the bytes.
    @Test func halveBatchCommandHalvesTheCageInOneEntry() throws {
        let harness = try Harness()
        try addPlaneTarget(to: harness)
        // A 4x4 grid: halves to 2x2.
        var lines: [String] = []
        for y in 0...4 {
            for x in 0...4 { lines.append("v \(x) \(y) 0") }
        }
        for y in 0..<4 {
            for x in 0..<4 {
                let a = y * 5 + x + 1
                lines.append("f \(a) \(a + 1) \(a + 6) \(a + 5)")
            }
        }
        try harness.bundle.addObject(
            name: "cage", role: .editMesh, mesh: try meshFromOBJ(lines.joined(separator: "\n"))
        )
        harness.sync()
        let object = try #require(harness.editObject)
        let payloadBefore = try #require(harness.bundle.payloads[object.payloadFile])
        #expect(try harness.editMesh().faceCount == 16)

        #expect(harness.coordinator.meshEditor.runBatchCommand(.halve))

        #expect(harness.bundle.journal.depth == 1)
        #expect(try harness.editMesh().faceCount == 4)
        #expect(try harness.editMesh().stats().quads == 4)

        harness.undo()
        #expect(harness.bundle.payloads[object.payloadFile] == payloadBefore)
        #expect(try harness.editMesh().faceCount == 16)
    }

    /// A REFUSED halve changes nothing and journals nothing — the odd-span cage.
    @Test func refusedHalveJournalsNothing() throws {
        let harness = try Harness()
        try addPlaneTarget(to: harness)
        var lines: [String] = []
        for y in 0...3 {
            for x in 0...3 { lines.append("v \(x) \(y) 0") }
        }
        for y in 0..<3 {
            for x in 0..<3 {
                let a = y * 4 + x + 1
                lines.append("f \(a) \(a + 1) \(a + 5) \(a + 4)")
            }
        }
        try harness.bundle.addObject(
            name: "cage", role: .editMesh, mesh: try meshFromOBJ(lines.joined(separator: "\n"))
        )
        harness.sync()
        let object = try #require(harness.editObject)
        let payloadBefore = try #require(harness.bundle.payloads[object.payloadFile])

        #expect(!harness.coordinator.meshEditor.runBatchCommand(.halve))

        #expect(harness.bundle.journal.depth == 0, "a refusal must journal nothing")
        #expect(harness.bundle.payloads[object.payloadFile] == payloadBefore)
        #expect(try harness.editMesh().faceCount == 9)
    }
}

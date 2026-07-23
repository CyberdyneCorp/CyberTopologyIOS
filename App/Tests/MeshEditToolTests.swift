import CyberKit
import CyberKitTesting
import Foundation
import Testing
import simd
@testable import CyberTopology

/// Task 4.1: the retopology build tools (Build Quad / Build Triangle /
/// Merge Pair / Path Distribute / Surface Cut) wired end to end — committed
/// stroke fixtures and synthetic tool strokes replay through the REAL
/// pipeline (capture → MeshEditController tool sessions → engine ops →
/// journaled DocumentCommand) against a real coordinator, renderer camera,
/// and engine meshes; exactly ONE journal entry per stroke, undo byte-exact
/// (spec: retopology-tools / "Core RT action roster").
@MainActor
struct MeshEditToolTests {
    /// Coordinator + document-journal harness (same shape as
    /// `MeshEditControllerTests.Harness`; duplicated because that one is
    /// deliberately private to its suite).
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

        func redo() {
            if let command = bundle.journal.redo() {
                command.apply(to: &bundle)
                sync()
            }
        }

        /// Normalized viewport point of a world position under the live
        /// camera.
        func screenPoint(of world: SIMD3<Float>) -> SIMD2<Double> {
            let m = coordinator.renderer!.viewProjectionColumns()
            let point = ScreenRay.normalizedPoint(of: world, viewProjectionColumns: m)!
            return SIMD2(Double(point.x), Double(point.y))
        }

        /// Arms a tool through the model (the toolbar path).
        func selectTool(_ tool: RetopoTool) {
            coordinator.inputModel.selectTool(tool)
        }

        /// Drives a stroke through the real capture pipeline.
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
            .appendingPathComponent("tool-tests-\(UUID().uuidString).obj")
        try text.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try Mesh.loadOBJ(at: url)
    }

    /// Big flat Target at z = 0.
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

    /// Two-quad strip with an UNEVEN middle column (engine ids 0-5): the
    /// committed tool fixtures were recorded against this exact seeding
    /// (`StrokeGestureCorpus` tool recordings), and the uneven spacing
    /// gives Path Distribute real work to do.
    ///
    ///   v3(0,2) --- v4(1.4,2) ------- v5(4,2)
    ///    |            |                 |
    ///   v0(0,0) --- v1(1.4,0) ------- v2(4,0)
    private func addToolStripEditMesh(to harness: Harness) throws {
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
    }

    /// Standard seeded harness for the tool suites.
    private func makeSeededHarness() throws -> Harness {
        let harness = try Harness()
        try addPlaneTarget(to: harness)
        try addToolStripEditMesh(to: harness)
        return harness
    }

    private func payloadBefore(_ harness: Harness) throws -> Data {
        let object = try #require(harness.editObject)
        return try #require(harness.bundle.payloads[object.payloadFile])
    }
}

// MARK: - Build Quad

extension MeshEditToolTests {
    private func committedMeshEditVerb(_ harness: Harness, at index: Int = 0) throws -> String {
        guard case .meshEdit(let edit) = try #require(harness.committed[safe: index]) else {
            Issue.record("expected a meshEdit command")
            return ""
        }
        return edit.verb
    }

    /// Committed fixture replay: Build Quad dragged from a QUAD's boundary
    /// edge tents a triangle off it, journaled once; undo is byte-exact.
    @Test func committedBuildQuadEdgeFixtureTentsTriangleAndUndoRestores() throws {
        let harness = try makeSeededHarness()
        let before = try payloadBefore(harness)
        harness.selectTool(.buildQuad)
        harness.coordinator.inputModel.inject(
            fixture: StrokeGestureCorpus.toolBuildQuadEdgeDrag()
        )

        #expect(harness.bundle.journal.depth == 1)
        #expect(try committedMeshEditVerb(harness) == "tool.buildQuad.edge")
        let mesh = try harness.editMesh()
        #expect(mesh.faceCount == 3)
        #expect(mesh.vertexCount == 7)
        let stats = try mesh.stats()
        #expect(stats.quads == 2)
        #expect(stats.triangles == 1)
        // The tent apex landed at the drag end, snapped on the Target.
        let apex = try #require(mesh.nearestVertex(to: SIMD3(0.7, -1.4, 0), maxDistance: 0.15))
        #expect(abs(apex.position.z) < 1e-4)

        harness.undo()
        let object = try #require(harness.editObject)
        #expect(harness.bundle.payloads[object.payloadFile] == before)
        #expect(try harness.editMesh().faceCount == 2)
        harness.redo()
        #expect(try harness.editMesh().faceCount == 3)
    }

    /// Build Quad dragged from a TRIANGLE's boundary edge grows it into a
    /// quad (the CozyBlanket BuildQ progression: quad edge → tent →
    /// tent edge → quad).
    @Test func buildQuadGrowsTriangleEdgeIntoQuad() throws {
        let harness = try makeSeededHarness()
        harness.selectTool(.buildQuad)
        harness.coordinator.inputModel.inject(
            fixture: StrokeGestureCorpus.toolBuildQuadEdgeDrag()
        )
        #expect(try harness.editMesh().stats().triangles == 1)

        // Drag from the tent's v0→apex boundary edge midpoint outward.
        harness.stroke(verb: .pencil, through: harness.densified(through: [
            harness.screenPoint(of: SIMD3(0.35, -0.7, 0)),
            harness.screenPoint(of: SIMD3(-0.7, -1.4, 0)),
        ]))

        #expect(harness.bundle.journal.depth == 2)
        #expect(try committedMeshEditVerb(harness, at: 1) == "tool.buildQuad.grow")
        let mesh = try harness.editMesh()
        #expect(mesh.faceCount == 3)
        #expect(mesh.vertexCount == 8)
        #expect(try mesh.stats().quads == 3)
        #expect(try mesh.stats().triangles == 0)
    }

    /// Build Quad dragged from a corner vertex spawns a full new quad
    /// whose diagonal follows the drag.
    @Test func buildQuadCornerDragSpawnsQuad() throws {
        let harness = try makeSeededHarness()
        harness.selectTool(.buildQuad)
        harness.stroke(verb: .pencil, through: harness.densified(through: [
            harness.screenPoint(of: SIMD3(4, 2, 0)),  // v5, the far corner
            harness.screenPoint(of: SIMD3(4.8, 2.8, 0)),
        ]))

        #expect(harness.bundle.journal.depth == 1)
        #expect(try committedMeshEditVerb(harness) == "tool.buildQuad.corner")
        let mesh = try harness.editMesh()
        #expect(mesh.faceCount == 3)
        #expect(mesh.vertexCount == 9)
        #expect(try mesh.stats().quads == 3)
        // The far corner sits under the drag end.
        #expect(mesh.nearestVertex(to: SIMD3(4.8, 2.8, 0), maxDistance: 0.15) != nil)
    }

    /// Auto-merge on release: an apex dropped within merge range of an
    /// existing vertex welds onto it — same journal entry, no new vertex.
    @Test func buildDragAutoMergesApexOntoExistingVertex() throws {
        let harness = try makeSeededHarness()
        harness.selectTool(.buildQuad)
        // Tent off the RIGHT quad's bottom edge (v1-v2, midpoint x=2.7),
        // dropping the apex right next to v0 (0, 0, 0).
        harness.stroke(verb: .pencil, through: harness.densified(through: [
            harness.screenPoint(of: SIMD3(2.7, 0, 0)),
            harness.screenPoint(of: SIMD3(0.1, -0.1, 0)),
        ]))

        #expect(harness.bundle.journal.depth == 1)
        let mesh = try harness.editMesh()
        #expect(mesh.faceCount == 3)
        #expect(mesh.vertexCount == 6, "apex must weld onto v0, not add a 7th vertex")
        #expect(try mesh.stats().triangles == 1)
    }
}

// MARK: - Build Triangle

extension MeshEditToolTests {
    /// Committed fixture replay: Build Triangle dragged from a corner
    /// vertex spawns TWO triangles spanning the drag; undo byte-exact.
    @Test func committedBuildTriangleCornerFixtureSpawnsTwoTriangles() throws {
        let harness = try makeSeededHarness()
        let before = try payloadBefore(harness)
        harness.selectTool(.buildTriangle)
        harness.coordinator.inputModel.inject(
            fixture: StrokeGestureCorpus.toolBuildTriangleCornerDrag()
        )

        #expect(harness.bundle.journal.depth == 1)
        #expect(try committedMeshEditVerb(harness) == "tool.buildTriangle.corner")
        let mesh = try harness.editMesh()
        #expect(mesh.faceCount == 4)
        #expect(mesh.vertexCount == 9)
        let stats = try mesh.stats()
        #expect(stats.quads == 2)
        #expect(stats.triangles == 2)

        harness.undo()
        let object = try #require(harness.editObject)
        #expect(harness.bundle.payloads[object.payloadFile] == before)
        #expect(try harness.editMesh().faceCount == 2)
    }

    /// Build Triangle from ANY boundary edge tents one triangle (even off
    /// a quad, where Build Quad would also tent; off a triangle, where
    /// Build Quad would grow instead).
    @Test func buildTriangleEdgeDragTentsSingleTriangle() throws {
        let harness = try makeSeededHarness()
        harness.selectTool(.buildTriangle)
        harness.stroke(verb: .pencil, through: harness.densified(through: [
            harness.screenPoint(of: SIMD3(0.7, 2, 0)),  // top edge v3-v4 midpoint
            harness.screenPoint(of: SIMD3(0.7, 3.2, 0)),
        ]))

        #expect(harness.bundle.journal.depth == 1)
        #expect(try committedMeshEditVerb(harness) == "tool.buildTriangle.edge")
        let mesh = try harness.editMesh()
        #expect(mesh.faceCount == 3)
        #expect(try mesh.stats().triangles == 1)

        // From the NEW triangle's boundary edge, Build Triangle tents
        // another triangle (no quad growth — that is Build Quad).
        let apex = try #require(
            mesh.nearestVertex(to: SIMD3(0.7, 3.2, 0), maxDistance: 0.15)
        )
        harness.stroke(verb: .pencil, through: harness.densified(through: [
            harness.screenPoint(of: (SIMD3(0, 2, 0) + apex.position) * 0.5),
            harness.screenPoint(of: SIMD3(-1.2, 3.2, 0)),
        ]))
        #expect(harness.bundle.journal.depth == 2)
        #expect(try committedMeshEditVerb(harness, at: 1) == "tool.buildTriangle.edge")
        #expect(try harness.editMesh().stats().triangles == 2)
    }
}

// MARK: - Merge Pair

extension MeshEditToolTests {
    /// Committed fixture replay: a vertex-to-vertex stroke collapses the
    /// pair at its midpoint; undo byte-exact.
    @Test func committedMergePairFixtureCollapsesVerticesAtMidpoint() throws {
        let harness = try makeSeededHarness()
        let before = try payloadBefore(harness)
        harness.selectTool(.mergePair)
        harness.coordinator.inputModel.inject(
            fixture: StrokeGestureCorpus.toolMergePairLine()
        )

        #expect(harness.bundle.journal.depth == 1)
        #expect(try committedMeshEditVerb(harness) == "tool.mergePair.vertices")
        let mesh = try harness.editMesh()
        #expect(mesh.vertexCount == 5)
        #expect(mesh.faceCount == 2)
        let stats = try mesh.stats()
        #expect(stats.triangles == 1)  // the left quad degenerated to a tri
        #expect(stats.quads == 1)
        // Midpoint collapse: the survivor sits halfway between v0 and v1.
        #expect(mesh.nearestVertex(to: SIMD3(0.7, 0, 0), maxDistance: 1e-3) != nil)

        harness.undo()
        let object = try #require(harness.editObject)
        #expect(harness.bundle.payloads[object.payloadFile] == before)
        #expect(try harness.editMesh().vertexCount == 6)
    }

    /// Task 4.5a: the Merge Pair TOOL runs Auto Relax when the mode is on,
    /// INSIDE its one journal entry — the collapse is exactly the local
    /// unevenness the pass exists to smooth. Same stroke with the mode off
    /// leaves the neighbours where they were.
    @Test func mergePairToolRunsAutoRelaxInsideItsOneEntry() throws {
        // Baseline: merge with Auto Relax OFF. Set the controller flag
        // DIRECTLY, not through the model's `setAutoRelax`, so this test never
        // writes the shared persisted preference (which sibling tests read at
        // init) — each harness owns its own controller.
        let off = try makeSeededHarness()
        off.coordinator.meshEditor.autoRelaxEnabled = false
        off.selectTool(.mergePair)
        off.coordinator.inputModel.inject(fixture: StrokeGestureCorpus.toolMergePairLine())
        let offPositions = try off.editMesh().positions()

        // Same seed, same stroke, Auto Relax ON.
        let on = try makeSeededHarness()
        on.coordinator.meshEditor.autoRelaxEnabled = true
        on.selectTool(.mergePair)
        on.coordinator.inputModel.inject(fixture: StrokeGestureCorpus.toolMergePairLine())

        // The relax rode inside the merge's transaction — still ONE entry.
        #expect(on.bundle.journal.depth == 1)
        #expect(try committedMeshEditVerb(on) == "tool.mergePair.vertices")
        // ...and it redistributed geometry the OFF run left in place.
        #expect(
            try on.editMesh().positions() != offPositions,
            "Auto Relax redistributed the neighbours after the merge"
        )
    }

    /// A stroke across the shared edge of two triangles merges them into
    /// one quad (the MergeP face-pair mode).
    @Test func mergePairAcrossTrianglePairDissolvesIntoQuad() throws {
        let harness = try Harness()
        try addPlaneTarget(to: harness)
        let pair = try meshFromOBJ("""
        v 0 0 0
        v 2 0 0
        v 2 2 0
        v 0 2 0
        f 1 2 4
        f 2 3 4
        """)
        try harness.bundle.addObject(name: "cage", role: .editMesh, mesh: pair)
        harness.sync()
        harness.selectTool(.mergePair)

        // Endpoints clear of every vertex pick radius; the stroke's
        // midpoint sits on the shared diagonal v1-v3.
        harness.stroke(verb: .pencil, through: harness.densified(through: [
            harness.screenPoint(of: SIMD3(1.3, 0.9, 0)),
            harness.screenPoint(of: SIMD3(0.9, 1.3, 0)),
        ]))

        #expect(harness.bundle.journal.depth == 1)
        #expect(try committedMeshEditVerb(harness) == "tool.mergePair.quad")
        let mesh = try harness.editMesh()
        #expect(mesh.faceCount == 1)
        #expect(try mesh.stats().quads == 1)
    }
}

// MARK: - Path Distribute

extension MeshEditToolTests {
    /// Committed fixture replay: the stroke's endpoint vertices bound the
    /// closest edge path (v0-v1-v2) and its uneven interior vertex
    /// redistributes evenly, re-snapped to the Target; undo byte-exact.
    @Test func committedPathDistributeFixtureEvensChain() throws {
        let harness = try makeSeededHarness()
        let before = try payloadBefore(harness)
        harness.selectTool(.pathDistribute)
        harness.coordinator.inputModel.inject(
            fixture: StrokeGestureCorpus.toolPathDistributeLine()
        )

        #expect(harness.bundle.journal.depth == 1)
        #expect(try committedMeshEditVerb(harness) == "tool.pathDistribute")
        let mesh = try harness.editMesh()
        #expect(mesh.vertexCount == 6)  // positions only, no topology change
        #expect(mesh.faceCount == 2)
        // v1 moved from x = 1.4 to the even x = 2 (endpoints fixed).
        let moved = try #require(mesh.vertexPosition(1))
        #expect(abs(moved.x - 2) < 1e-3)
        #expect(try #require(mesh.vertexPosition(0)) == SIMD3(0, 0, 0))
        #expect(try #require(mesh.vertexPosition(2)) == SIMD3(4, 0, 0))

        harness.undo()
        let object = try #require(harness.editObject)
        #expect(harness.bundle.payloads[object.payloadFile] == before)
        #expect(abs(try #require(harness.editMesh().vertexPosition(1)).x - 1.4) < 1e-4)
    }

    /// Strokes that do not land on two distinct vertices journal nothing.
    @Test func pathDistributeMissesAreInert() throws {
        let harness = try makeSeededHarness()
        harness.selectTool(.pathDistribute)
        // Both endpoints over empty Target surface, far from the strip.
        harness.stroke(verb: .pencil, through: harness.densified(through: [
            harness.screenPoint(of: SIMD3(-4, -4, 0)),
            harness.screenPoint(of: SIMD3(-2, -4, 0)),
        ]))
        #expect(harness.bundle.journal.depth == 0)
        #expect(harness.committed.isEmpty)
    }
}

// MARK: - Surface Cut

extension MeshEditToolTests {
    /// Committed fixture replay: the knife line across the left quad
    /// splits its two crossed edges and the face; undo byte-exact.
    @Test func committedSurfaceCutFixtureSplitsQuadAndUndoRestores() throws {
        let harness = try makeSeededHarness()
        let before = try payloadBefore(harness)
        harness.selectTool(.surfaceCut)
        harness.coordinator.inputModel.inject(
            fixture: StrokeGestureCorpus.toolSurfaceCutLine()
        )

        #expect(harness.bundle.journal.depth == 1)
        #expect(try committedMeshEditVerb(harness) == "tool.surfaceCut")
        let mesh = try harness.editMesh()
        #expect(mesh.faceCount == 3)
        #expect(mesh.vertexCount == 8)
        #expect(try mesh.stats().quads == 3)  // vertex-to-vertex cut: all quads

        harness.undo()
        let object = try #require(harness.editObject)
        #expect(harness.bundle.payloads[object.payloadFile] == before)
        #expect(try harness.editMesh().faceCount == 2)
        harness.redo()
        #expect(try harness.editMesh().faceCount == 3)
    }

    /// A knife that exits through an adjacent side leaves a pentagon —
    /// auto-triangulated per the spec.
    @Test func surfaceCutTriangulatesResultingNGons() throws {
        let harness = try makeSeededHarness()
        harness.selectTool(.surfaceCut)
        // Enters the left quad's bottom edge (~x=0.36) and exits its LEFT
        // edge (~y=0.42): corner triangle + pentagon → triangulated.
        harness.stroke(verb: .pencil, through: harness.densified(through: [
            harness.screenPoint(of: SIMD3(0.7, -0.4, 0)),
            harness.screenPoint(of: SIMD3(-0.5, 1.0, 0)),
        ]))

        #expect(harness.bundle.journal.depth == 1)
        let mesh = try harness.editMesh()
        let stats = try mesh.stats()
        #expect(stats.quads == 1)  // the right quad, untouched
        #expect(stats.triangles == 4)  // corner tri + triangulated pentagon
        #expect(mesh.faceCount == 5)
    }

    /// A knife entirely over empty surface journals nothing.
    @Test func surfaceCutOverNothingIsInert() throws {
        let harness = try makeSeededHarness()
        harness.selectTool(.surfaceCut)
        harness.stroke(verb: .pencil, through: harness.densified(through: [
            harness.screenPoint(of: SIMD3(-4, -4, 0)),
            harness.screenPoint(of: SIMD3(-4, -2, 0)),
        ]))
        #expect(harness.bundle.journal.depth == 0)
    }
}

// MARK: - Session routing

extension MeshEditToolTests {
    /// Cancelled tool strokes discard without journaling (tools mutate
    /// only at commit).
    @Test func cancelledToolStrokeJournalsNothing() throws {
        let harness = try makeSeededHarness()
        harness.selectTool(.buildQuad)
        let editor = try #require(harness.coordinator.inputModel.meshEditor)
        let start = harness.screenPoint(of: SIMD3(0.7, 0, 0))
        editor.strokeBegan(
            verb: .pencil,
            sample: editor.probeSample(
                at: SIMD2(Float(start.x), Float(start.y)), time: 0
            )
        )
        #expect(editor.toolStroke != nil)
        editor.strokeCancelled()
        #expect(editor.toolStroke == nil)
        #expect(harness.bundle.journal.depth == 0)
        #expect(try harness.editMesh().faceCount == 2)
    }

    /// A spring-loaded verb HOLD overrides an armed tool for its duration:
    /// the held verb's stroke runs a brush session, and the tool stays
    /// armed afterwards.
    @Test func heldVerbOverridesArmedToolThenRestores() throws {
        let harness = try makeSeededHarness()
        let inputModel = harness.coordinator.inputModel
        harness.selectTool(.buildQuad)
        inputModel.verbPressBegan(.tweak, at: 0)
        #expect(inputModel.activeVerb == .tweak)
        #expect(inputModel.activeTool == .buildQuad)

        // Tweak drag on v0 while holding: a brush session, not a tool
        // stroke.
        harness.stroke(verb: .tweak, through: harness.densified(through: [
            harness.screenPoint(of: SIMD3(0, 0, 0)),
            harness.screenPoint(of: SIMD3(-0.6, -0.6, 0)),
        ]))
        #expect(harness.bundle.journal.depth == 1)
        #expect(try committedMeshEditVerb(harness) == "tweak")

        // Releasing the hold restores Pencil + the armed tool.
        inputModel.verbPressEnded(.tweak, at: 1.0)  // > tapSelectThreshold
        #expect(inputModel.activeVerb == .pencil)
        #expect(inputModel.activeTool == .buildQuad)

        // A quick TAP on a verb disarms the tool.
        inputModel.verbPressBegan(.relax, at: 2.0)
        inputModel.verbPressEnded(.relax, at: 2.1)
        #expect(inputModel.activeTool == nil)
        #expect(harness.coordinator.inputModel.meshEditor?.activeTool == nil)
    }

    /// Tools require a Target and an existing EditMesh; without either the
    /// stroke never arms a session.
    @Test func toolStrokesAreInertWithoutTargetOrEditMesh() throws {
        let harness = try Harness()
        try addToolStripEditMesh(to: harness)  // EditMesh, NO Target
        harness.selectTool(.mergePair)
        let editor = try #require(harness.coordinator.inputModel.meshEditor)
        editor.strokeBegan(
            verb: .pencil, sample: editor.probeSample(at: SIMD2(0.5, 0.5), time: 0)
        )
        #expect(editor.toolStroke == nil)
        editor.strokeEnded(verb: .pencil, interpretation: nil, samples: [])
        #expect(harness.bundle.journal.depth == 0)
    }

    /// The visual-verification probes drive REAL journaled strokes for
    /// every tool (the screenshot hooks' entry point).
    @Test func visualVerificationProbesJournalEveryTool() throws {
        for tool in RetopoTool.allCases {
            let harness = try makeSeededHarness()
            let editor = try #require(harness.coordinator.inputModel.meshEditor)
            #expect(
                editor.probeToolStrokeForVisualVerification(tool),
                "probe for \(tool.rawValue) did not journal"
            )
            #expect(!harness.committed.isEmpty, "\(tool.rawValue) committed nothing")
        }
    }
}

extension Array {
    fileprivate subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// Pure tool geometry (headless — no engine, no camera).
struct RetopoToolGeometryTests {
    @Test func cornerQuadCornersSpanTheDiagonalPerpendicular() throws {
        let anchor = SIMD3<Float>(0, 0, 0)
        let drag = SIMD3<Float>(2, 0, 0)
        let view = SIMD3<Float>(0, 0, -1)
        let corners = try #require(RetopoToolGeometry.cornerQuadCorners(
            anchor: anchor, drag: drag, view: view
        ))
        // Corners sit on the perpendicular bisector, half a diagonal out.
        for corner in [corners.first, corners.second] {
            #expect(abs(corner.x - 1) < 1e-5)
            #expect(abs(abs(corner.y) - 1) < 1e-5)
            #expect(corner.z == 0)
        }
        #expect(simd_distance(corners.first, corners.second) > 1.9)
        // Winding: ring [anchor, first, drag, second] faces the camera
        // (normal opposes the into-screen view direction).
        let normal = simd_cross(corners.first - anchor, drag - anchor)
        #expect(simd_dot(normal, view) < 0)
    }

    @Test func cornerQuadCornersRejectDegenerateDrags() {
        let view = SIMD3<Float>(0, 0, -1)
        #expect(RetopoToolGeometry.cornerQuadCorners(
            anchor: .zero, drag: .zero, view: view
        ) == nil)
        // Drag parallel to the view direction: no stable perpendicular.
        #expect(RetopoToolGeometry.cornerQuadCorners(
            anchor: .zero, drag: SIMD3(0, 0, -3), view: view
        ) == nil)
    }

    @Test func normalizedPointInvertsScreenRay() throws {
        // Simple ortho-style projection: identity-ish matrix mapping
        // x/y in [-1, 1] to the full viewport.
        let columns: [Float] = [
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 0, 0,
            0, 0, 0.5, 1,
        ]
        let point = try #require(ScreenRay.normalizedPoint(
            of: SIMD3(0.5, 0.5, 0), viewProjectionColumns: columns
        ))
        #expect(abs(point.x - 0.75) < 1e-5)
        #expect(abs(point.y - 0.25) < 1e-5)
        // Wrong column count and w <= 0 are rejected.
        #expect(ScreenRay.normalizedPoint(of: .zero, viewProjectionColumns: []) == nil)
        let behind: [Float] = [
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 0, -1,
            0, 0, 0, 0,
        ]
        #expect(ScreenRay.normalizedPoint(
            of: SIMD3(0, 0, 1), viewProjectionColumns: behind
        ) == nil)
    }
}

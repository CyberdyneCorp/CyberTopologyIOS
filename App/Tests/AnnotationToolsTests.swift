import CyberKit
import CyberKitTesting
import Foundation
import Testing
import simd

@testable import CyberTopology

/// Task 4.3 app layer: the Pin Flip tool, the en-masse clears, the
/// annotation overlay render state, and the Loop Info inspector — all
/// driven through the REAL pipeline (capture → controller → engine →
/// journaled `DocumentCommand`) against a real coordinator, renderer
/// camera and engine mesh (specs: retopology-tools / "Pins immune to
/// smoothing", "Loop tags", "Core RT action roster" / Loop Info).
@MainActor
struct AnnotationToolsTests {
    /// Same coordinator+journal harness shape the 3.3/4.1 suites use: the
    /// commit sink records AND applies, then re-syncs the viewport exactly
    /// as the SwiftUI update pass does.
    @MainActor
    fileprivate final class Harness {
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
            coordinator.bundleProvider = { [weak self] in self?.bundle ?? DocumentBundle() }
        }

        func sync() { coordinator.syncMesh(from: bundle) }

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
            let cx = m[0] * world.x + m[4] * world.y + m[8] * world.z + m[12]
            let cy = m[1] * world.x + m[5] * world.y + m[9] * world.z + m[13]
            let cw = m[3] * world.x + m[7] * world.y + m[11] * world.z + m[15]
            return SIMD2(
                Double(cx / cw) * 0.5 + 0.5, 1 - (Double(cy / cw) * 0.5 + 0.5)
            )
        }

        /// Drives a stroke through the real capture pipeline. `duration`
        /// spreads the samples in time — a long dwell is what makes the
        /// Pin Flip tool read a HOLD rather than a tap. `verb` is the capture
        /// verb the touch layer stamps on the stroke: `.pencil` drives the
        /// armed tool / authoring grammar, the brush verbs (`.relax`, `.move`,
        /// …) drive their live brush directly.
        func stroke(
            verb: InputArbiter.Verb = .pencil,
            through points: [SIMD2<Double>], duration: Double = 0.02
        ) {
            let capture = coordinator.inputModel.controller.capture
            guard let first = points.first else { return }
            capture.begin(
                source: .finger, verb: verb,
                sample: .init(time: 0, x: first.x, y: first.y, pressure: 0.5, type: .finger)
            )
            let step = points.count > 1 ? duration / Double(points.count - 1) : duration
            for (index, point) in points.dropFirst().enumerated() {
                capture.append(sample: .init(
                    time: Double(index + 1) * step, x: point.x, y: point.y,
                    pressure: 0.5, type: .finger
                ))
            }
            capture.end()
        }

        var editObject: DocumentManifest.Object? {
            bundle.manifest.objects.first { $0.role == .editMesh }
        }

        var annotations: MeshAnnotations? { editObject?.annotations }

        func editMesh() throws -> Mesh { try bundle.mesh(for: #require(editObject)) }
    }

    fileprivate func meshFromOBJ(_ text: String) throws -> Mesh {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("annotations-\(UUID().uuidString).obj")
        try text.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try Mesh.loadOBJ(at: url)
    }

    /// Flat Target at z = 0 plus a 3x3-quad grid EditMesh on it: enough
    /// interior loops for both the pin-loop hold and the Loop Info chip.
    fileprivate func seedGrid(_ harness: Harness) throws {
        let target = try meshFromOBJ("""
        v -5 -5 0
        v 5 -5 0
        v 5 5 0
        v -5 5 0
        f 1 2 3 4
        """)
        try harness.bundle.addObject(name: "target", role: .target, mesh: target)
        var obj = ""
        for row in 0...3 {
            for col in 0...3 { obj += "v \(col) \(row) 0\n" }
        }
        for row in 0..<3 {
            for col in 0..<3 {
                let a = row * 4 + col + 1
                obj += "f \(a) \(a + 1) \(a + 5) \(a + 4)\n"
            }
        }
        try harness.bundle.addObject(name: "cage", role: .editMesh, mesh: try meshFromOBJ(obj))
        harness.sync()
    }

    /// An interior (non-boundary) edge of the seeded grid, plus a screen
    /// point over its midpoint that is clear of any vertex.
    fileprivate func interiorEdgeMidpoint(_ harness: Harness) throws
        -> (edge: UInt32, screen: SIMD2<Double>)
    {
        let mesh = try harness.editMesh()
        for edge in 0..<UInt32(mesh.edgeCount) {
            guard
                mesh.isBoundaryEdge(edge) == false,
                let ends = mesh.edgeEndpoints(of: edge),
                let a = mesh.vertexPosition(ends.0), let b = mesh.vertexPosition(ends.1),
                !mesh.edgeLoop(from: edge).isEmpty
            else { continue }
            return (edge, harness.screenPoint(of: (a + b) * 0.5))
        }
        Issue.record("the seeded grid has no interior edge")
        struct NoInteriorEdge: Error {}
        throw NoInteriorEdge()
    }

    // MARK: - Pin Flip: hold on a loop (spec: pinning per vertex AND per loop)

    @Test("Holding on an interior edge pins the whole loop in one journal entry")
    func holdOnInteriorEdgePinsTheLoop() throws {
        let harness = try Harness()
        try seedGrid(harness)
        harness.coordinator.inputModel.selectTool(.pinFlip)
        let (edge, screen) = try interiorEdgeMidpoint(harness)
        let expected = try harness.editMesh().edgeLoopVertices(from: edge)
        #expect(expected.count > 1, "a loop hold must pin more than one vertex")

        // A dwelling stroke: stationary samples spanning past the hold
        // threshold, exactly what a resting Pencil delivers.
        harness.stroke(
            through: Array(repeating: screen, count: 6),
            duration: MeshEditController.pinHoldDuration * 1.5
        )

        #expect(harness.committed.count == 1, "one hold journals exactly one entry")
        guard case .annotationEdit(let edit) = try #require(harness.committed.first) else {
            Issue.record("pin flip must journal an annotationEdit, not a meshEdit")
            return
        }
        #expect(edit.verb == "tool.pinFlip")
        #expect(harness.annotations?.pinnedVertices == expected.sorted())

        // Geometry untouched: pinning is annotation state, not an edit.
        #expect(try harness.editMesh().vertexCount == 16)

        // Undo restores the un-pinned state in ONE user-visible step.
        harness.undo()
        #expect(harness.annotations?.pinnedVertices.isEmpty ?? true)
    }

    @Test("A second hold on the same loop unpins it (flip, not set)")
    func secondHoldUnpinsTheLoop() throws {
        let harness = try Harness()
        try seedGrid(harness)
        harness.coordinator.inputModel.selectTool(.pinFlip)
        let (_, screen) = try interiorEdgeMidpoint(harness)
        let hold = Array(repeating: screen, count: 6)
        harness.stroke(through: hold, duration: MeshEditController.pinHoldDuration * 1.5)
        #expect(!(harness.annotations?.pinnedVertices.isEmpty ?? true))

        harness.stroke(through: hold, duration: MeshEditController.pinHoldDuration * 1.5)
        #expect(harness.annotations?.pinnedVertices.isEmpty ?? true)
        #expect(harness.committed.count == 2, "each flip is its own journal entry")
    }

    @Test("A quick tap on a vertex pins just that vertex")
    func tapPinsASingleVertex() throws {
        let harness = try Harness()
        try seedGrid(harness)
        harness.coordinator.inputModel.selectTool(.pinFlip)
        let mesh = try harness.editMesh()
        let interior = try #require(mesh.nearestVertex(to: SIMD3(1, 1, 0), maxDistance: 0.1))
        let screen = harness.screenPoint(of: interior.position)

        // Short dwell: below the hold threshold, so it is a tap.
        harness.stroke(through: [screen, screen], duration: 0.02)

        #expect(harness.annotations?.pinnedVertices == [interior.vertex])
        #expect(harness.committed.count == 1)
    }

    @Test("A sweep pins every vertex it crosses")
    func sweepPinsCrossedVertices() throws {
        let harness = try Harness()
        try seedGrid(harness)
        harness.coordinator.inputModel.selectTool(.pinFlip)
        let mesh = try harness.editMesh()
        let start = try #require(mesh.nearestVertex(to: SIMD3(0, 0, 0), maxDistance: 0.1))
        let end = try #require(mesh.nearestVertex(to: SIMD3(3, 0, 0), maxDistance: 0.1))
        let from = harness.screenPoint(of: start.position)
        let to = harness.screenPoint(of: end.position)
        // Dense polyline along the bottom row, fast (a drag, not a hold).
        let points = (0...48).map { step -> SIMD2<Double> in
            let t = Double(step) / 48
            return from + (to - from) * t
        }
        harness.stroke(through: points, duration: 0.2)

        let pinned = try #require(harness.annotations?.pinnedVertices)
        #expect(pinned.contains(start.vertex))
        #expect(pinned.contains(end.vertex))
        #expect(pinned.count >= 3, "the sweep crosses the whole bottom row")
        #expect(harness.committed.count == 1, "one sweep is one journal entry")
    }

    @Test("A Pin Flip stroke over empty space journals nothing")
    func pinFlipOffMeshIsInert() throws {
        let harness = try Harness()
        try seedGrid(harness)
        harness.coordinator.inputModel.selectTool(.pinFlip)
        let far = harness.screenPoint(of: SIMD3(-4.5, -4.5, 0))
        harness.stroke(
            through: Array(repeating: far, count: 6),
            duration: MeshEditController.pinHoldDuration * 1.5
        )
        #expect(harness.committed.isEmpty)
    }

    // MARK: - Pins are honoured by the live brush verbs (end to end)

    @Test("Relax over a pinned loop leaves the pinned vertices where they were")
    func relaxThroughTheControllerHonoursPins() throws {
        let harness = try Harness()
        try seedGrid(harness)
        // Pin the loop through an interior edge via the real tool.
        harness.coordinator.inputModel.selectTool(.pinFlip)
        let (edge, screen) = try interiorEdgeMidpoint(harness)
        let pinned = try harness.editMesh().edgeLoopVertices(from: edge)
        harness.stroke(
            through: Array(repeating: screen, count: 6),
            duration: MeshEditController.pinHoldDuration * 1.5
        )
        #expect(harness.annotations?.pinnedVertices == pinned.sorted())

        // Compare POSITIONS, not id→position maps: the journaled mesh
        // edit re-serializes the payload, and deserialization is free to
        // reassign stable ids. What the spec promises is that the pinned
        // vertices do not MOVE, which is an id-independent claim.
        let before = try harness.editMesh()
        let pinnedPositionsBefore = Set(
            pinned.compactMap { before.vertexPosition($0) }.map(Self.key)
        )
        let allBefore = Set(
            (0..<UInt32(before.vertexCount)).compactMap { before.vertexPosition($0) }
                .map(Self.key)
        )

        // Scrub Relax across the whole cage with the loop pinned. The stroke
        // must carry the `.relax` capture verb: `.pencil` would drive the
        // authoring grammar (a horizontal sweep reads as Insert Loop) rather
        // than the relax brush, so selecting the verb is not enough — the
        // touch layer stamps the verb on the stroke itself.
        harness.coordinator.inputModel.selectVerb(.relax)
        let sweep = (0...24).map { step -> SIMD2<Double> in
            let t = Float(step) / 24
            return harness.screenPoint(of: SIMD3(t * 3, 1.5, 0))
        }
        harness.stroke(verb: .relax, through: sweep, duration: 0.5)

        let after = try harness.editMesh()
        // Relax moves vertices, it never adds them: the cage stays 16-strong.
        #expect(after.vertexCount == before.vertexCount)
        let allAfter = Set(
            (0..<UInt32(after.vertexCount)).compactMap { after.vertexPosition($0) }
                .map(Self.key)
        )
        // Every pinned position survives untouched.
        #expect(
            pinnedPositionsBefore.isSubset(of: allAfter),
            "a pinned vertex moved under a Relax scrub"
        )
        // And the scrub actually did something: some UNPINNED vertex moved,
        // so the assertion above is not vacuously true of a no-op relax.
        let unpinnedBefore = allBefore.subtracting(pinnedPositionsBefore)
        #expect(
            !unpinnedBefore.isSubset(of: allAfter),
            "Relax moved nothing — the pin assertion would be vacuous"
        )
    }

    /// Quantized position key: compares geometry independently of the
    /// stable ids a payload round-trip may reassign.
    private static func key(_ p: SIMD3<Float>) -> SIMD3<Int> {
        SIMD3(Int((p.x * 1e4).rounded()), Int((p.y * 1e4).rounded()), Int((p.z * 1e4).rounded()))
    }

    // MARK: - Clears

    @Test("Clear pins and clear loop tags each journal one undoable entry")
    func clearsJournalOneEntryEach() throws {
        let harness = try Harness()
        try seedGrid(harness)
        let model = harness.coordinator.inputModel
        model.selectTool(.pinFlip)
        let (edge, screen) = try interiorEdgeMidpoint(harness)
        harness.stroke(
            through: Array(repeating: screen, count: 6),
            duration: MeshEditController.pinHoldDuration * 1.5
        )
        // Tag a loop too, so the clears are proved independent.
        model.selectTagColor(2)
        harness.coordinator.meshEditor.applyAnnotationEdit(
            verb: "test.tagLoop", context: try #require(harness.coordinator.makeEditContext())
        ) { $0.togglingTags(on: try! harness.editMesh().edgeLoop(from: edge), color: 2) }
        #expect(!(harness.annotations?.taggedEdges.isEmpty ?? true))
        #expect(!(harness.annotations?.pinnedVertices.isEmpty ?? true))

        #expect(model.runCommand(.clearPins))
        #expect(harness.annotations?.pinnedVertices.isEmpty ?? true)
        #expect(
            !(harness.annotations?.taggedEdges.isEmpty ?? true),
            "clearing pins must not clear tags"
        )

        #expect(model.runCommand(.clearLoopTags))
        #expect(harness.annotations?.taggedEdges.isEmpty ?? true)

        // Both clears undo individually, restoring exactly what they took.
        harness.undo()
        #expect(!(harness.annotations?.taggedEdges.isEmpty ?? true))
        harness.undo()
        #expect(!(harness.annotations?.pinnedVertices.isEmpty ?? true))
    }

    @Test("A clear with nothing to clear journals nothing")
    func emptyClearIsInert() throws {
        let harness = try Harness()
        try seedGrid(harness)
        let model = harness.coordinator.inputModel
        #expect(!model.runCommand(.clearPins))
        #expect(!model.runCommand(.clearLoopTags))
        #expect(harness.committed.isEmpty)
    }

    // MARK: - Loop Info inspector (hover over an interior edge)

    @Test("Hovering an interior edge publishes that loop's metrics")
    func hoverPublishesLoopInfo() throws {
        let harness = try Harness()
        try seedGrid(harness)
        let (edge, screen) = try interiorEdgeMidpoint(harness)
        let expected = try #require(
            try harness.editMesh().loopMetrics(from: edge)
        )
        harness.coordinator.hoverPreview.hoverChanged(
            at: SIMD2(Float(screen.x), Float(screen.y))
        )

        let info = try #require(harness.coordinator.inputModel.loopInfo)
        #expect(info.metrics.edgeCount == expected.edgeCount)
        #expect(info.metrics.vertexCount == expected.vertexCount)
        #expect(info.metrics.isClosed == expected.isClosed)
        #expect(abs(info.metrics.length - expected.length) < 1e-5)
        // The seeded document HAS a Target, so snapping is measured.
        #expect(info.metrics.snapping != nil)

        // Hover end clears the chip: an inspector must not outlive its
        // gesture.
        harness.coordinator.hoverPreview.hoverEnded()
        #expect(harness.coordinator.inputModel.loopInfo == nil)
    }

    @Test("Hovering empty space shows no Loop Info chip")
    func hoverOffMeshShowsNoLoopInfo() throws {
        let harness = try Harness()
        try seedGrid(harness)
        let far = harness.screenPoint(of: SIMD3(-4.5, -4.5, 0))
        harness.coordinator.hoverPreview.hoverChanged(
            at: SIMD2(Float(far.x), Float(far.y))
        )
        #expect(harness.coordinator.inputModel.loopInfo == nil)
    }

    @Test("Loop Info reports the hovered loop's tag colour")
    func loopInfoCarriesTheTagColour() throws {
        let harness = try Harness()
        try seedGrid(harness)
        let (edge, screen) = try interiorEdgeMidpoint(harness)
        let loop = try harness.editMesh().edgeLoop(from: edge)
        harness.coordinator.meshEditor.applyAnnotationEdit(
            verb: "test.tagLoop",
            context: try #require(harness.coordinator.makeEditContext())
        ) { $0.togglingTags(on: loop, color: 3) }

        harness.coordinator.hoverPreview.hoverChanged(
            at: SIMD2(Float(screen.x), Float(screen.y))
        )
        #expect(harness.coordinator.inputModel.loopInfo?.tagColor == 3)
    }

    // MARK: - Overlay render state (pins + per-colour tags)

    @Test("Annotation render state emits pin points and one group per colour")
    func annotationRenderStateGroupsByColour() {
        let positions: [UInt32: SIMD3<Float>] = [
            0: SIMD3(0, 0, 0), 1: SIMD3(1, 0, 0), 2: SIMD3(1, 1, 0), 3: SIMD3(0, 1, 0),
        ]
        let edges: [UInt32: (UInt32, UInt32)] = [10: (0, 1), 11: (1, 2), 12: (2, 3)]
        let annotations = MeshAnnotations()
            .togglingPins(on: [0, 2])
            .togglingTags(on: [10, 11], color: 0)
            .togglingTags(on: [12], color: 4)

        let state = AnnotationRenderState.build(
            annotations: annotations,
            edgeEndpoints: { edges[$0] },
            vertexPosition: { positions[$0] }
        )
        // Two pins: 3 floats each.
        #expect(state.pinPoints.count == 6)
        #expect(state.pinPoints.prefix(3) == [0, 0, 0])
        // Two colour groups, ordered by palette index.
        #expect(state.tagGroups.count == 2)
        #expect(state.tagGroups[0].color == LoopTagPalette.color(0))
        #expect(state.tagGroups[0].segments.count == 12, "two edges = 4 vertices")
        #expect(state.tagGroups[1].color == LoopTagPalette.color(4))
        #expect(state.tagGroups[1].segments.count == 6)
        #expect(!state.isEmpty)
    }

    @Test("Stale annotation ids render as nothing, never as a crash")
    func staleAnnotationIDsAreSkipped() {
        let state = AnnotationRenderState.build(
            annotations: MeshAnnotations().togglingPins(on: [99]).togglingTags(
                on: [98], color: 1),
            edgeEndpoints: { _ in nil },
            vertexPosition: { _ in nil }
        )
        #expect(state.isEmpty)
        #expect(state.tagGroups.isEmpty)
    }

    @Test("The overlay uploads pins and per-colour tag groups in draw order")
    func overlayUploadsAnnotationGroups() throws {
        let harness = try Harness()
        try seedGrid(harness)
        let overlay = try #require(harness.coordinator.renderer).overlayPath
        overlay.setAnnotations(
            AnnotationRenderState(
                pinPoints: [0, 0, 0, 1, 0, 0],
                tagGroups: [
                    .init(color: LoopTagPalette.color(0), segments: [0, 0, 0, 1, 1, 1]),
                    .init(color: LoopTagPalette.color(2), segments: [1, 1, 1, 2, 2, 2]),
                ]
            )
        )
        #expect(overlay.pinPointCount == 2)
        #expect(overlay.tagColorGroups.count == 2)
        // Pins occupy the head of the buffer; groups follow in order.
        #expect(overlay.tagColorGroups[0].vertexStart == 2)
        #expect(overlay.tagColorGroups[0].vertexCount == 2)
        #expect(overlay.tagColorGroups[1].vertexStart == 4)
        #expect(overlay.hasAnnotations)

        overlay.setAnnotations(AnnotationRenderState())
        #expect(!overlay.hasAnnotations)
    }

    @Test("A journaled pin edit reaches the overlay's pin pass")
    func pinEditReachesTheOverlay() throws {
        let harness = try Harness()
        try seedGrid(harness)
        harness.coordinator.inputModel.selectTool(.pinFlip)
        let (edge, screen) = try interiorEdgeMidpoint(harness)
        let expected = try harness.editMesh().edgeLoopVertices(from: edge).count
        harness.stroke(
            through: Array(repeating: screen, count: 6),
            duration: MeshEditController.pinHoldDuration * 1.5
        )
        let overlay = try #require(harness.coordinator.renderer).overlayPath
        #expect(overlay.pinPointCount == expected)

        harness.undo()
        #expect(overlay.pinPointCount == 0)
    }

    // MARK: - Chip state + formatting

    @Test("The Loop Info chip dedupes identical metrics and clears on demand")
    func loopInfoChipDedupes() {
        var chip = LoopInfoChipState()
        let info = LoopInfoChipState.Info(
            metrics: LoopMetrics(
                edgeCount: 3, vertexCount: 4, isClosed: false, length: 3,
                endpoints: (1, 7), boundaryEdgeCount: 0,
                snapping: .init(snappedVertexCount: 4, maxDistance: 0)
            ),
            tagColor: nil
        )
        let shown = chip.show(info)
        #expect(shown)
        let repeated = chip.show(info)
        #expect(!repeated, "an unchanged loop must not restart the chip")
        let cleared = chip.clear()
        #expect(cleared)
        let clearedAgain = chip.clear()
        #expect(!clearedAgain)
        #expect(chip.info == nil)
    }

    @Test("Chip lines report counts, length/endpoints and snapping state")
    func chipFormatting() {
        let open = LoopInfoChipState.Info(
            metrics: LoopMetrics(
                edgeCount: 3, vertexCount: 4, isClosed: false, length: 2.5,
                endpoints: (1, 7), boundaryEdgeCount: 0,
                snapping: .init(snappedVertexCount: 4, maxDistance: 0.0001)
            ),
            tagColor: 2
        )
        #expect(open.countsLine == "4 verts · 3 edges · open")
        #expect(open.lengthLine == "length 2.500 · ends v1–v7")
        #expect(open.snappingLine == "snapped to Target")

        let closed = LoopInfoChipState.Info(
            metrics: LoopMetrics(
                edgeCount: 8, vertexCount: 8, isClosed: true, length: 6.25,
                endpoints: nil, boundaryEdgeCount: 0,
                snapping: .init(snappedVertexCount: 6, maxDistance: 0.125)
            ),
            tagColor: nil
        )
        #expect(closed.countsLine == "8 verts · 8 edges · closed")
        #expect(closed.lengthLine == "length 6.250 · no endpoints")
        #expect(closed.snappingLine == "2 of 8 off Target (max 0.125)")

        let noTarget = LoopInfoChipState.Info(
            metrics: LoopMetrics(
                edgeCount: 2, vertexCount: 3, isClosed: false, length: 1,
                endpoints: (0, 2), boundaryEdgeCount: 2, snapping: nil
            ),
            tagColor: nil
        )
        #expect(noTarget.snappingLine == "no Target to snap to")
    }

    // MARK: - Palette

    @Test("The palette covers exactly the document's colour range")
    func paletteMatchesDocumentRange() {
        #expect(LoopTagPalette.colors.count == Int(MeshAnnotations.tagColorCount))
        #expect(LoopTagPalette.names.count == LoopTagPalette.colors.count)
        #expect(LoopTagPalette.indices.count == Int(MeshAnnotations.tagColorCount))
        // Out-of-range indices clamp rather than trap.
        #expect(LoopTagPalette.color(200) == LoopTagPalette.colors[0])
        #expect(LoopTagPalette.name(200) == LoopTagPalette.names[0])
    }

    @Test("Selecting a tag colour mirrors into the mesh-edit controller")
    func selectingTagColourMirrors() throws {
        let harness = try Harness()
        try seedGrid(harness)
        let model = harness.coordinator.inputModel
        model.selectTagColor(3)
        #expect(model.activeTagColor == 3)
        #expect(harness.coordinator.meshEditor.activeTagColor == 3)
        // Out-of-palette selections are ignored, never stored.
        model.selectTagColor(MeshAnnotations.tagColorCount + 1)
        #expect(model.activeTagColor == 3)
    }

    @Test("Loop tags authored by the grammar carry the selected colour")
    func taggedLoopsCarryTheSelectedColour() throws {
        let harness = try Harness()
        try seedGrid(harness)
        let model = harness.coordinator.inputModel
        model.selectTagColor(4)
        let (edge, _) = try interiorEdgeMidpoint(harness)
        let loop = try harness.editMesh().edgeLoop(from: edge)
        harness.coordinator.meshEditor.applyAnnotationEdit(
            verb: "pencil.tagLoop",
            context: try #require(harness.coordinator.makeEditContext())
        ) { $0.togglingTags(on: loop, color: model.activeTagColor) }
        #expect(harness.annotations?.tagColor(of: edge) == 4)
    }

    // MARK: - Visual-verification probe

    @Test("The annotation probe pins one loop and tags another in one frame")
    func annotationProbePinsAndTags() throws {
        let harness = try Harness()
        try seedGrid(harness)
        harness.coordinator.inputModel.selectTagColor(1)
        #expect(harness.coordinator.meshEditor.probeAnnotationsForVisualVerification())

        let annotations = try #require(harness.annotations)
        #expect(!annotations.pinnedVertices.isEmpty)
        #expect(!annotations.taggedEdges.isEmpty)
        #expect(annotations.tagColorIndices.allSatisfy { $0 == 1 })
        #expect(harness.committed.count == 2, "pin and tag journal separately")

        let overlay = try #require(harness.coordinator.renderer).overlayPath
        #expect(overlay.pinPointCount == annotations.pinnedVertices.count)
        #expect(overlay.tagColorGroups.count == 1)
        #expect(overlay.tagColorGroups[0].color == LoopTagPalette.color(1))
    }
}

// MARK: - Fixture recording

extension AnnotationToolsTests {
    /// Committed fixture replay (spec: quality-assurance / "Gesture
    /// grammar regression suite"): the recorded Pin Flip HOLD pins the
    /// whole edge loop through the interior edge it dwells on, journaled
    /// once, and undo restores it in one step.
    @Test("Committed pin-loop hold fixture pins the loop and undoes in one step")
    func committedPinLoopHoldFixture() throws {
        let harness = try Harness()
        try seedGrid(harness)
        harness.coordinator.inputModel.selectTool(.pinFlip)
        let expected = try harness.editMesh().edgeLoopVertices(from: 1).sorted()
        #expect(expected.count > 1)

        harness.coordinator.inputModel.inject(
            fixture: StrokeGestureCorpus.annotationPinLoopHold()
        )

        #expect(harness.bundle.journal.depth == 1)
        #expect(harness.annotations?.pinnedVertices == expected)
        harness.undo()
        #expect(harness.annotations?.pinnedVertices.isEmpty ?? true)
    }

    /// Committed fixture replay: the recorded Loop Info hover traverses the
    /// interior edge and keeps ONE chip up for the whole traverse (the
    /// loop never changes), reporting that loop's engine metrics.
    @Test("Committed loop-info hover fixture raises one chip for the traversed loop")
    func committedLoopInfoHoverFixture() throws {
        let harness = try Harness()
        try seedGrid(harness)
        let expected = try #require(try harness.editMesh().loopMetrics(from: 1))

        var published: [LoopInfoChipState.Info?] = []
        harness.coordinator.hoverPreview.onLoopInfoChanged = { info in
            published.append(info)
            harness.coordinator.inputModel.setLoopInfo(info)
        }
        for sample in StrokeGestureCorpus.annotationLoopInfoHover().samples {
            harness.coordinator.hoverPreview.hoverChanged(
                at: SIMD2(Float(sample.x), Float(sample.y))
            )
        }

        let info = try #require(harness.coordinator.inputModel.loopInfo)
        #expect(info.metrics.edgeCount == expected.edgeCount)
        #expect(info.metrics.vertexCount == expected.vertexCount)
        #expect(abs(info.metrics.length - expected.length) < 1e-5)
        #expect(
            published.count == 1,
            "traversing ONE loop must publish one chip, not one per sample"
        )

        harness.coordinator.hoverPreview.hoverEnded()
        #expect(published.last == LoopInfoChipState.Info?.none)
        // A read-only inspector: hovering journals nothing.
        #expect(harness.committed.isEmpty)
    }

    /// Recording aid for the committed pin-loop / loop-info fixtures: prints
    /// the normalized viewport coordinates the seeded grid's elements project
    /// to under the harness camera. Disabled — re-enable when re-recording.
    @Test(.disabled("recording aid; run manually to re-record the fixtures"))
    func recordAnnotationFixtureCoordinates() throws {
        let harness = try Harness()
        try seedGrid(harness)
        let (edge, screen) = try interiorEdgeMidpoint(harness)
        print("RECORD interior edge \(edge) midpoint -> \(screen.x), \(screen.y)")
        let mesh = try harness.editMesh()
        for id in 0..<UInt32(mesh.vertexCount) {
            if let p = mesh.vertexPosition(id) {
                print("RECORD v\(id) \(p) -> \(harness.screenPoint(of: p))")
            }
        }
    }
}

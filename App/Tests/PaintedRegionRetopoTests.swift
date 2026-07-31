import CyberKit
import CyberKitTesting
import Foundation
import Testing
import simd
@testable import CyberTopology

/// Painting a region of the Target and retopologizing only that (openspec
/// add-painted-region-retopo), app side: the region state, what reaches the
/// solver, the extent geometry, and the merge on accept.
@MainActor
struct PaintedRegionRetopoTests {
    // MARK: - The painted region

    @Test func paintingAccumulatesInFirstTouchedOrder() {
        var region = PaintedRegion()
        #expect(region.isEmpty)

        region.add([7, 3, 7, 9])
        region.add([3, 11])

        // Order is first-touched, and a face painted twice is painted once: the
        // ids reach the solver as a carve list, so the same paint must produce the
        // same solve.
        #expect(region.faces == [7, 3, 9, 11])
        #expect(region.count == 4)
    }

    @Test func clearingEmptiesTheRegion() {
        var region = PaintedRegion()
        region.add([1, 2])
        region.clear()
        #expect(region.isEmpty)
        // …and the ids are genuinely forgotten, not merely hidden: re-painting one
        // must add it again.
        region.add([1])
        #expect(region.faces == [1])
    }

    // MARK: - What reaches the solver

    @Test func noPaintSolvesTheWholeTarget() throws {
        let controller = MeshEditController()
        #expect(controller.solveRegion == .wholeMesh)
    }

    @Test func paintedFacesBoundTheSolve() throws {
        let controller = MeshEditController()
        controller.paintedRegion.add([4, 5, 6])
        guard case .faces(let faces) = controller.solveRegion else {
            Issue.record("expected a region solve, got \(controller.solveRegion)")
            return
        }
        #expect(faces == [4, 5, 6])
    }

    /// The mask is a statement about what to do NEXT: a stale extent silently
    /// shaping the following solve is worse than repainting.
    @Test func clearingReportsThroughTheCallback() throws {
        let controller = MeshEditController()
        var published: [[UInt32]] = []
        controller.onPaintedRegionChanged = { published.append($0) }
        controller.paintedRegion.add([1, 2])

        controller.clearPaintedRegion()

        #expect(controller.solveRegion == .wholeMesh)
        #expect(published == [[]], "the viewport must be told to stop drawing it")
        // Clearing an empty region says nothing — the callback drives a re-upload.
        controller.clearPaintedRegion()
        #expect(published == [[]])
    }

    // MARK: - The visible extent

    @Test func theExtentFillsEveryPaintedFace() {
        // Two quads sharing an edge, in the z = 0 plane.
        let corners: [UInt32: SIMD3<Float>] = [
            0: SIMD3(0, 0, 0), 1: SIMD3(1, 0, 0), 2: SIMD3(1, 1, 0), 3: SIMD3(0, 1, 0),
            4: SIMD3(2, 0, 0), 5: SIMD3(2, 1, 0),
        ]
        let rings: [UInt32: [UInt32]] = [10: [0, 1, 2, 3], 11: [1, 4, 5, 2]]

        let fill = RegionPaintGeometry.fill(faces: [10, 11]) { face in
            (rings[face] ?? []).compactMap { corners[$0] }
        }

        // Two quads → two triangles each.
        #expect(fill.indices.count == 12)
        #expect(fill.positions.count == 8 * 3)
        #expect(fill.normals.count == fill.positions.count)
        // Every index addresses a real vertex.
        #expect(fill.indices.allSatisfy { $0 < UInt32(fill.positions.count / 3) })
    }

    @Test func degenerateAndUnknownFacesAreSkippedNotMalformed() {
        let corners: [UInt32: SIMD3<Float>] = [
            0: SIMD3(0, 0, 0), 1: SIMD3(1, 0, 0), 2: SIMD3(2, 0, 0),
        ]
        // A collinear ring encloses no area; an unknown face has no ring at all.
        let fill = RegionPaintGeometry.fill(faces: [10, 99]) { face in
            (face == 10 ? [0, 1, 2] : []).compactMap { corners[$0] }
        }
        #expect(fill.indices.isEmpty)
        #expect(fill.positions.isEmpty)
    }

    // MARK: - The solve domain crosses the thread boundary as GEOMETRY

    /// REPORTED FROM DEVICE: the painted extent drew correctly and "I ask to
    /// retopologize and nothing happens".
    ///
    /// The cause: face ids were being sent off-main to be carved there, but the
    /// mesh crosses that boundary as `payloadData()`, which round-trips through OBJ
    /// and RENUMBERS every element. The ids then named arbitrary faces of the
    /// deserialized mesh — or nothing, which the solve swallowed as a silent nil.
    /// So the carve happens on the LIVE mesh and only geometry crosses.
    @Test func theSolveDomainIsCarvedBeforeSerializing() throws {
        let target = try Mesh.loadOBJ(at: MeshFixtureCorpus.stanfordBunnyURL())
        let painted = Array(target.liveFaceIDs().sorted().prefix(400))

        let prepared = try MetalViewport.Coordinator.prepare(
            target: target, region: .faces(painted), params: .medium
        )

        // What crosses is the CARVE, not the whole Target…
        let domain = try Mesh(payloadData: prepared.payload)
        #expect(domain.faceCount == 400)
        #expect(target.faceCount > 400, "the Target itself is never carved")
        #expect(
            abs(prepared.share - Float(400) / Float(target.faceCount)) < 1e-5,
            "share \(prepared.share) should be 400 of \(target.faceCount) faces"
        )
        // The requested count applies to the PATCH — scaling it by the share starved
        // the solve and made the cage uneven (measured: 44 quads -> 15.4x area
        // spread, 500 -> 2.9x). Capped at four quads per source triangle so a
        // whole-model budget dropped on one ear cannot starve the machine.
        #expect(prepared.params.remesh.targetQuads == 1500, "500 painted faces support 1500")
        // …and the patch-specific quality policy is applied.
        #expect(prepared.params.remesh.adaptivity == 0, "a patch wants an EVEN grid")
        #expect(
            prepared.params.remesh.holeFillMaxBoundary == 0,
            "filling the region's own boundary seals the patch into a bubble"
        )
    }

    /// The cap: a tiny paint cannot be handed a whole model's budget.
    @Test func aTinyRegionCapsTheRequestedCount() throws {
        let target = try Mesh.loadOBJ(at: MeshFixtureCorpus.stanfordBunnyURL())
        let painted = Array(target.liveFaceIDs().sorted().prefix(10))

        let prepared = try MetalViewport.Coordinator.prepare(
            target: target, region: .faces(painted), params: .targetingQuads(50_000)
        )

        // Four quads per source triangle, not 50 000 — at the raw default a 12-face
        // carve did not finish inside a minute.
        #expect(prepared.params.remesh.targetQuads == 40)
    }

    @Test func aWholeMeshSolveIsPreparedUnchanged() throws {
        let target = try Mesh.loadOBJ(at: UITestSupport.writeSeedOBJ())
        let prepared = try MetalViewport.Coordinator.prepare(
            target: target, region: .wholeMesh, params: .medium
        )
        #expect(prepared.share == 1)
        #expect(prepared.params.remesh.targetQuads == SolverParameters.medium.remesh.targetQuads)
        #expect(try Mesh(payloadData: prepared.payload).faceCount == target.faceCount)
    }

    /// The trap itself, stated once so nobody re-introduces it: ids do not survive
    /// the payload round trip.
    @Test func faceIDsDoNotSurviveAPayloadRoundTrip() throws {
        let mesh = try Mesh.loadOBJ(at: UITestSupport.writeSeedDomeGridOBJ())
        // Delete a MIDDLE face so the live ids are genuinely SPARSE — deleting the
        // last one leaves 0..n-1 dense, and the renumbering is then invisible.
        let doomed = try #require(mesh.liveFaceIDs().sorted().dropFirst(2).first)
        try mesh.deleteFaces([doomed])
        let sparse = Set(mesh.liveFaceIDs())

        let roundTripped = try Mesh(payloadData: try mesh.payloadData())

        #expect(roundTripped.faceCount == mesh.faceCount)
        #expect(
            Set(roundTripped.liveFaceIDs()) != sparse,
            "ids survived the round trip — then carving off-main would have been safe"
        )
    }

    // MARK: - Merging on accept

    /// The patch merges into the cage the artist is building: one cage, its own
    /// faces plus the patch's, and nothing welded.
    @Test func acceptingARegionPatchMergesIntoTheCage() throws {
        var bundle = DocumentBundle()
        let cage = try Mesh.loadOBJ(at: UITestSupport.writeSeedOBJ())  // 1 quad
        let command = try bundle.objectCommand(
            for: cage, name: "EditMesh", role: .editMesh, verb: "test.seed"
        )
        command.apply(to: &bundle)
        let object = try #require(bundle.manifest.objects.first { $0.role == .editMesh })
        #expect(try bundle.mesh(for: object).faceCount == 1)

        // A patch of one quad, elsewhere in space.
        let patchURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("patch-\(UUID().uuidString).obj")
        try """
        v 5 5 0
        v 6 5 0
        v 6 6 0
        v 5 6 0
        f 1 2 3 4
        """.write(to: patchURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: patchURL) }
        let patch = try Mesh.loadOBJ(at: patchURL)

        let merge = try #require(
            MetalViewport.Coordinator.mergeCommand(patch, into: bundle)
        )
        merge.apply(to: &bundle)

        // ONE EditMesh object, holding both.
        #expect(bundle.manifest.objects.count { $0.role == .editMesh } == 1)
        let merged = try bundle.mesh(for: try #require(
            bundle.manifest.objects.first { $0.role == .editMesh }
        ))
        #expect(merged.faceCount == 2)
        #expect(merged.nearestVertex(to: SIMD3(5, 5, 0), maxDistance: 1e-5) != nil)
    }

    @Test func mergingNeedsACage() throws {
        let bundle = DocumentBundle()
        let patch = try Mesh.loadOBJ(at: UITestSupport.writeSeedOBJ())
        // No EditMesh: the caller falls back to creating one, so this reports nil
        // rather than inventing an object here.
        #expect(MetalViewport.Coordinator.mergeCommand(patch, into: bundle) == nil)
    }

    /// The banner must say what Accept will DO. Before painted regions it always
    /// said "replace the EditMesh", which for a region patch told the artist their
    /// hand-authored topology was about to be discarded when it is appended to.
    @Test func theBannerSaysWhetherAcceptMergesOrReplaces() {
        #expect(
            AutoRetopoBannerView.status(merges: true).localizedCaseInsensitiveContains("merge")
        )
        #expect(
            AutoRetopoBannerView.status(merges: false)
                .localizedCaseInsensitiveContains("replace")
        )
        #expect(
            AutoRetopoBannerView.status(merges: true)
                != AutoRetopoBannerView.status(merges: false)
        )
    }

    /// The paint tool is reachable: it maps to a tool and carries help text.
    @Test func thePaintToolIsReachable() {
        #expect(EditorAction.paintRegion.tool == .paintRegion)
        #expect(!EditorAction.paintRegion.gallery.notes.isEmpty)
        #expect(!EditorAction.clearPaintedRegion.gallery.notes.isEmpty)
        // Painting the Target is not a camera-manipulator tool.
        #expect(!RetopoTool.paintRegion.isCameraManipulator)
    }

    // MARK: - Paint UX (openspec improve-region-paint-ux)

    @Test func erasingRemovesFacesFromTheRegion() {
        var region = PaintedRegion()
        region.add([1, 2, 3, 4])
        region.remove([2, 4])
        // What remains keeps its first-touched order, so a paint-erase-paint
        // sequence still solves deterministically.
        #expect(region.faces == [1, 3])
        // …and an erased face can be painted again: `remove` forgets it, rather
        // than only hiding it from the list.
        region.add([2])
        #expect(region.faces == [1, 3, 2])
    }

    @Test func erasingWhatWasNeverPaintedIsHarmless() {
        var region = PaintedRegion()
        region.add([1])
        region.remove([99])
        #expect(region.faces == [1])
        region.remove([])
        #expect(region.faces == [1])
    }

    /// The mode is otherwise invisible — the tool is armed either way — so toggling
    /// must announce itself.
    @Test func togglingTheBrushModeAnnouncesItself() {
        let controller = MeshEditController()
        var announced: [Bool] = []
        controller.onPaintModeChanged = { announced.append($0) }

        controller.paintErases = true
        controller.paintErases = true  // no change, no announcement
        controller.paintErases = false

        #expect(announced == [true, false])
    }

    @Test func theBrushRingIsAClosedCircleFacingTheCamera() {
        let ring = HoverPreviewGeometry.brushRing(
            centre: SIMD3(1, 2, 3), radius: 0.5, facing: SIMD3(0, 0, 1), segments: 16
        )
        // 16 segments, each two points of three floats.
        #expect(ring.segments.count == 16 * 2 * 3)
        #expect(ring.points.isEmpty, "the cursor is a ring, not a dot")

        // Every vertex sits on the circle, and the ring closes.
        var radii: [Float] = []
        for base in stride(from: 0, to: ring.segments.count, by: 3) {
            let point = SIMD3(ring.segments[base], ring.segments[base + 1], ring.segments[base + 2])
            radii.append(simd_distance(point, SIMD3(1, 2, 3)))
        }
        #expect(radii.allSatisfy { abs($0 - 0.5) < 1e-5 })
        let first = SIMD3(ring.segments[0], ring.segments[1], ring.segments[2])
        let last = SIMD3(
            ring.segments[ring.segments.count - 3], ring.segments[ring.segments.count - 2],
            ring.segments[ring.segments.count - 1]
        )
        #expect(simd_distance(first, last) < 1e-5, "the ring must close")
    }

    @Test func aDegenerateBrushDrawsNothing() {
        #expect(
            HoverPreviewGeometry.brushRing(
                centre: .zero, radius: 0, facing: nil
            ).isEmpty
        )
        #expect(
            HoverPreviewGeometry.brushRing(
                centre: .zero, radius: 1, facing: nil, segments: 2
            ).isEmpty
        )
    }

    /// The brush is a CURSOR: while the paint tool is armed it outranks every
    /// element highlight, because "what would a Move drag grab" is not the question
    /// being asked.
    @Test func theBrushRingOutranksEveryOtherPreview() {
        var state = HoverPreviewState()
        let queries = BrushQueries(
            brush: (SIMD3(1, 1, 1), 0.25),
            snap: .init(vertex: 1, position: .zero),
            loop: [1, 2],
            face: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0)],
            ghost: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0)]
        )
        let changed = state.hoverChanged(at: SIMD2(0.5, 0.5), queries: queries)
        #expect(changed)
        guard case .brushRing(let centre, let radius) = state.preview else {
            Issue.record("expected the brush cursor, got \(String(describing: state.preview))")
            return
        }
        #expect(centre == SIMD3(1, 1, 1))
        #expect(radius == 0.25)
    }

    /// Fake queries answering every hover question at once, so priority is testable.
    private struct BrushQueries: HoverPreviewQuerying {
        var brush: (centre: SIMD3<Float>, radius: Float)?
        var snap: HoverPreviewState.SnapTarget?
        var loop: [UInt32]?
        var face: [SIMD3<Float>]?
        var ghost: [SIMD3<Float>]?

        func brushRing(at point: SIMD2<Float>) -> (centre: SIMD3<Float>, radius: Float)? { brush }
        func snapTargetVertex(at point: SIMD2<Float>) -> HoverPreviewState.SnapTarget? { snap }
        func slideLoop(at point: SIMD2<Float>) -> [UInt32]? { loop }
        func faceUnderPoint(at point: SIMD2<Float>) -> [SIMD3<Float>]? { face }
        func ghostQuadCorners(at point: SIMD2<Float>) -> [SIMD3<Float>]? { ghost }
    }

    /// The brush cursor renders in the paint colour family, so the ring and the
    /// extent it leaves behind read as one thing.
    @Test func theBrushCursorCarriesItsOwnElement() {
        let state = HoverPreviewGeometry.renderState(
            for: .brushRing(centre: .zero, radius: 1),
            edgeEndpoints: { _ in nil }, vertexPosition: { _ in nil },
            viewDirection: SIMD3(0, 0, 1)
        )
        #expect(state.element == .brush)
        #expect(state.highlight?.segments.isEmpty == false)
        #expect(state.ghost == nil, "a cursor is lines, not a fill")
    }

    // MARK: - The face-count keypad (openspec improve-region-paint-ux)

    @Test func typingBuildsTheCountAndStopsAtTheCeiling() {
        var model = RetopoFaceCountModel(count: 0, ceiling: 500)
        model.append(digit: 1)
        model.append(digit: 2)
        #expect(model.count == 12)
        // 123 fits, 1234 does not — and the digit that would overflow is IGNORED
        // rather than accepted then rewritten, which would silently change what the
        // artist typed.
        model.append(digit: 3)
        #expect(model.count == 123)
        model.append(digit: 4)
        #expect(model.count == 123)
    }

    @Test func backspaceAndClear() {
        var model = RetopoFaceCountModel(count: 456, ceiling: 5000)
        model.backspace()
        #expect(model.count == 45)
        model.clear()
        #expect(model.count == 0)
        #expect(model.display.isEmpty, "an empty field shows its placeholder, not a 0")
        // Backspacing an empty field is harmless.
        model.backspace()
        #expect(model.count == 0)
    }

    @Test func halveAndDoubleRespectTheirBounds() {
        var model = RetopoFaceCountModel(count: 100, ceiling: 150)
        model.double()
        #expect(model.count == 150, "double is capped at the ceiling")
        model.halve()
        #expect(model.count == 75)
        // Halving cannot go below the solver's floor…
        for _ in 0..<10 { model.halve() }
        #expect(model.count == RetopoFaceCountModel.minimum)
        // …and doubling from the floor still climbs.
        model.double()
        #expect(model.count == RetopoFaceCountModel.minimum * 2)
    }

    @Test func theInitialCountIsClampedIntoRange() {
        // A whole-Target count handed to a painted region's ceiling.
        let clamped = RetopoFaceCountModel(count: 69_451, ceiling: 532)
        #expect(clamped.count == 532)
        // And a ceiling below the floor cannot make the field unusable.
        let tiny = RetopoFaceCountModel(count: 1, ceiling: 1)
        #expect(tiny.ceiling == RetopoFaceCountModel.minimum)
    }

    @Test func runningNeedsAtLeastTheFloor() {
        var model = RetopoFaceCountModel(count: 0, ceiling: 500)
        #expect(!model.isRunnable, "an empty field cannot run a solve")
        model.append(digit: 3)
        #expect(!model.isRunnable, "3 quads is below the solver's floor")
        model.append(digit: 0)
        #expect(model.count == 30)
        #expect(model.isRunnable)
    }

    @Test func theDisplayIsGrouped() {
        let model = RetopoFaceCountModel(count: 69_451, ceiling: 2_000_000)
        // Grouped for readability at a glance — 69,451 rather than 69451.
        #expect(model.display.contains { !$0.isNumber })
    }

    // MARK: - Live painting and paint undo (openspec improve-region-paint-ux)

    /// One paint STROKE is one undo step, however many samples it covered.
    @Test func undoStepsBackOneStrokeAtATime() {
        let controller = MeshEditController()
        #expect(!controller.canUndoPaint)

        controller.beginPaintStrokeHistory()
        controller.paintedRegion.add([1, 2])
        controller.beginPaintStrokeHistory()
        controller.paintedRegion.add([3, 4])

        #expect(controller.canUndoPaint)
        #expect(controller.undoPaint())
        #expect(controller.paintedRegion.faces == [1, 2], "the second stroke came off")
        #expect(controller.undoPaint())
        #expect(controller.paintedRegion.isEmpty, "the first stroke came off")
        // Nothing left: the caller falls through to the DOCUMENT's undo.
        #expect(!controller.undoPaint())
        #expect(!controller.canUndoPaint)
    }

    @Test func redoReappliesAnUndonePaintStroke() {
        let controller = MeshEditController()
        controller.beginPaintStrokeHistory()
        controller.paintedRegion.add([7, 8])

        #expect(controller.undoPaint())
        #expect(controller.paintedRegion.isEmpty)
        #expect(controller.canRedoPaint)
        #expect(controller.redoPaint())
        #expect(controller.paintedRegion.faces == [7, 8])
        #expect(!controller.redoPaint())
    }

    /// A new stroke forks the history: redo cannot resurrect a branch the artist
    /// painted over.
    @Test func aNewStrokeDropsTheRedoBranch() {
        let controller = MeshEditController()
        controller.beginPaintStrokeHistory()
        controller.paintedRegion.add([1])
        #expect(controller.undoPaint())
        #expect(controller.canRedoPaint)

        controller.beginPaintStrokeHistory()
        controller.paintedRegion.add([2])

        #expect(!controller.canRedoPaint)
    }

    /// Clearing (which a solve does) drops the history too: those strokes described
    /// a mask that no longer exists, and stepping back into it would resurrect an
    /// extent the solve already consumed.
    @Test func clearingDropsThePaintHistory() {
        let controller = MeshEditController()
        controller.beginPaintStrokeHistory()
        controller.paintedRegion.add([1, 2])

        controller.clearPaintedRegion()

        #expect(controller.paintedRegion.isEmpty)
        #expect(!controller.canUndoPaint)
        #expect(!controller.canRedoPaint)
    }

    /// Undo also covers an ERASE stroke, since it is a paint stroke too.
    @Test func undoRestoresWhatAnEraseRemoved() {
        let controller = MeshEditController()
        controller.beginPaintStrokeHistory()
        controller.paintedRegion.add([1, 2, 3])
        controller.paintErases = true
        controller.beginPaintStrokeHistory()
        controller.paintedRegion.remove([2])
        #expect(controller.paintedRegion.faces == [1, 3])

        #expect(controller.undoPaint())
        #expect(controller.paintedRegion.faces == [1, 2, 3])
    }

    @Test func thePaintHistoryIsBounded() {
        let controller = MeshEditController()
        for index in 0...(MeshEditController.paintHistoryLimit + 10) {
            controller.beginPaintStrokeHistory()
            controller.paintedRegion.add([UInt32(index)])
        }
        // Bounded rather than unbounded: the mask is transient, and a long session
        // should not accumulate history nobody asked for.
        #expect(controller.paintUndoStack.count <= MeshEditController.paintHistoryLimit)
    }

    // MARK: - Paint responsiveness (openspec improve-region-paint-ux)

    /// REPORTED FROM DEVICE: "I paint and the faces are selected few seconds later."
    ///
    /// The extent is rebuilt on every paint sample, and each rebuild asked the engine
    /// for the geometry of EVERY painted face — for faces that had not moved since
    /// the previous sample. Worse, it fetched the Target through `bundle.mesh(for:)`,
    /// which deserializes the whole mesh from payload bytes: ~120 rebuilds of a
    /// 69 451-face model per second of stroking.
    @Test func eachFaceIsFetchedOnceHoweverManyRebuilds() {
        var cache = RegionPaintFaceCache()
        cache.prepare(key: "target#1")
        let corners = [SIMD3<Float>(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0)]

        // Ten rebuilds over a growing region, as a stroke would produce.
        for painted in 1...10 {
            for face in 0..<UInt32(painted) {
                _ = cache.corners(of: face) { _ in corners }
            }
        }

        // Ten faces ever seen, so ten fetches — not the 55 the loop performed.
        #expect(cache.fetches == 10)
    }

    @Test func aNewTargetInvalidatesTheCache() {
        var cache = RegionPaintFaceCache()
        cache.prepare(key: "target#1")
        _ = cache.corners(of: 1) { _ in [SIMD3(0, 0, 0)] }
        #expect(cache.fetches == 1)

        // Same key: still cached.
        cache.prepare(key: "target#1")
        _ = cache.corners(of: 1) { _ in [SIMD3(0, 0, 0)] }
        #expect(cache.fetches == 1)

        // A reimported or edited Target must NOT keep drawing the old shape.
        cache.prepare(key: "target#2")
        _ = cache.corners(of: 1) { _ in [SIMD3(9, 9, 9)] }
        #expect(cache.fetches == 1, "the counter resets with the cache")
        #expect(cache.key == "target#2")
    }

    /// The cache must return the geometry it was given, not merely avoid work.
    @Test func theCacheReturnsWhatItFetched() {
        var cache = RegionPaintFaceCache()
        cache.prepare(key: "t")
        let expected = [SIMD3<Float>(1, 2, 3), SIMD3(4, 5, 6), SIMD3(7, 8, 9)]
        let first = cache.corners(of: 7) { _ in expected }
        let second = cache.corners(of: 7) { _ in [] }
        #expect(first == expected)
        #expect(second == expected, "the second call must come from the cache")
    }

    // MARK: - Box selection (openspec add-box-region-selection)

    @Test func theBoxSelectsFacesInsideItThatFaceTheCamera() {
        let box = SelectionBox(origin: SIMD2(0.2, 0.2), corner: SIMD2(0.8, 0.8))
        let candidates = [
            // Inside, facing the camera: selected.
            RegionBoxSelection.Candidate(face: 1, screen: SIMD2(0.5, 0.5), isInFront: true, facingDot: -0.9),
            // Inside but turned AWAY: a box over one side must not take the far wall.
            RegionBoxSelection.Candidate(face: 2, screen: SIMD2(0.5, 0.5), isInFront: true, facingDot: 0.9),
            // Outside the box.
            RegionBoxSelection.Candidate(face: 3, screen: SIMD2(0.9, 0.5), isInFront: true, facingDot: -0.9),
            // BEHIND the camera: projects to a mirrored point that can land inside.
            RegionBoxSelection.Candidate(face: 4, screen: SIMD2(0.5, 0.5), isInFront: false, facingDot: -0.9),
        ]

        #expect(RegionBoxSelection.faces(in: box, from: candidates) == [1])
    }

    /// See-through mode takes BOTH walls of a thin feature — an ear is one thing to
    /// retopologize, and boxing each side means finding a camera angle for each.
    @Test func aSeeThroughBoxTakesTheFarSideToo() {
        let box = SelectionBox(origin: SIMD2(0.2, 0.2), corner: SIMD2(0.8, 0.8))
        let near = RegionBoxSelection.Candidate(
            face: 1, screen: SIMD2(0.5, 0.5), isInFront: true, facingDot: -0.9
        )
        let far = RegionBoxSelection.Candidate(
            face: 2, screen: SIMD2(0.5, 0.5), isInFront: true, facingDot: 0.9
        )
        // BEHIND the camera stays excluded even here: a mirrored projection landing
        // inside the box is an artefact, not a face the artist boxed.
        let behind = RegionBoxSelection.Candidate(
            face: 3, screen: SIMD2(0.5, 0.5), isInFront: false, facingDot: 0.9
        )
        let outside = RegionBoxSelection.Candidate(
            face: 4, screen: SIMD2(0.95, 0.5), isInFront: true, facingDot: 0.9
        )
        let all = [near, far, behind, outside]

        #expect(RegionBoxSelection.faces(in: box, from: all, seesThrough: true) == [1, 2])
        #expect(RegionBoxSelection.faces(in: box, from: all, seesThrough: false) == [1])
    }

    /// The pencil double-tap means different things per tool, because each region
    /// tool has its own most-wanted switch: the brush needs an eraser, a box needs
    /// the far side.
    @Test func theDoubleTapMeansWhateverTheArmedToolNeeds() {
        #expect(PencilTapAction.forTool(.paintRegion) == .toggleErase)
        #expect(PencilTapAction.forTool(.selectRegionBox) == .toggleSeeThrough)
        // No region tool armed: the tap is left alone rather than silently changing
        // a mode the artist cannot see.
        #expect(PencilTapAction.forTool(.transformVertices) == PencilTapAction.none)
        #expect(PencilTapAction.forTool(nil) == PencilTapAction.none)
    }

    @Test @MainActor func theModeSwitchIsAnnouncedAndTinted() {
        let model = ViewportInputModel()
        model.regionSelectionModeChanged(seesThrough: true)
        #expect(model.regionSelectionSeesThrough)
        #expect(model.paintModeHint == "Select through")
        model.regionSelectionModeChanged(seesThrough: false)
        #expect(!model.regionSelectionSeesThrough)
        #expect(model.paintModeHint == "Select visible")
    }

    /// Sorted, because the carve list feeds a solve whose determinism was hard won.
    @Test func theSelectionIsOrdered() {
        let box = SelectionBox(origin: .zero, corner: SIMD2(1, 1))
        let candidates = [9, 3, 7].map {
            RegionBoxSelection.Candidate(
                face: UInt32($0), screen: SIMD2(0.5, 0.5), isInFront: true, facingDot: -1
            )
        }
        #expect(RegionBoxSelection.faces(in: box, from: candidates) == [3, 7, 9])
    }

    /// A tap is the brush's job: a box of nearly zero area would select whatever
    /// happened to be under it.
    @Test func aTapSizedBoxSelectsNothing() {
        let tap = SelectionBox(origin: SIMD2(0.5, 0.5), corner: SIMD2(0.502, 0.501))
        #expect(!tap.isMeaningful)
        let candidate = RegionBoxSelection.Candidate(
            face: 1, screen: SIMD2(0.5, 0.5), isInFront: true, facingDot: -1
        )
        #expect(RegionBoxSelection.faces(in: tap, from: [candidate]).isEmpty)
    }

    @Test func theBoxIsDirectionAgnostic() {
        // Dragged up-left instead of down-right: the same rectangle.
        let forward = SelectionBox(origin: SIMD2(0.2, 0.3), corner: SIMD2(0.7, 0.8))
        let backward = SelectionBox(origin: SIMD2(0.7, 0.8), corner: SIMD2(0.2, 0.3))
        #expect(forward.minimum == backward.minimum)
        #expect(forward.maximum == backward.maximum)
        #expect(backward.contains(SIMD2(0.5, 0.5)))
    }

    @Test func projectionReportsPointsBehindTheCamera() {
        // A trivial view-projection: identity, so w = 1 and the point is in front.
        var identity = [Float](repeating: 0, count: 16)
        identity[0] = 1; identity[5] = 1; identity[10] = 1; identity[15] = 1
        let front = RegionBoxSelection.project(SIMD3(0, 0, 0), viewProjection: identity)
        #expect(front.isInFront)
        #expect(abs(front.screen.x - 0.5) < 1e-6 && abs(front.screen.y - 0.5) < 1e-6)

        // w driven negative: behind the camera, and reported as such rather than
        // silently projecting to a mirrored screen point inside the box.
        var flipped = identity
        flipped[15] = -1
        #expect(!RegionBoxSelection.project(SIMD3(0, 0, 0), viewProjection: flipped).isInFront)
        // A degenerate matrix cannot crash the selection.
        #expect(!RegionBoxSelection.project(.zero, viewProjection: []).isInFront)
    }

    /// The box feeds the SAME region the brush paints, and is undoable the same way.
    @Test func theBoxToolIsReachableAndSharesTheRegion() {
        #expect(EditorAction.selectRegionBox.tool == .selectRegionBox)
        #expect(!EditorAction.selectRegionBox.gallery.notes.isEmpty)
        #expect(!RetopoTool.selectRegionBox.isCameraManipulator)
    }
}

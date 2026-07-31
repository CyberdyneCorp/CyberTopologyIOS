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

        let fill = RegionPaintGeometry.fill(
            faces: [10, 11], ring: { rings[$0] ?? [] }, position: { corners[$0] }
        )

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
        let fill = RegionPaintGeometry.fill(
            faces: [10, 99], ring: { $0 == 10 ? [0, 1, 2] : [] }, position: { corners[$0] }
        )
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
        // …and the budget followed the painted share, so a patch is not asked for a
        // whole model's worth of quads.
        #expect(
            abs(prepared.share - Float(400) / Float(target.faceCount)) < 1e-5,
            "share \(prepared.share) should be 400 of \(target.faceCount) faces"
        )
        #expect(prepared.params.remesh.targetQuads < SolverParameters.medium.remesh.targetQuads)
        #expect(prepared.params.remesh.targetQuads >= 4, "never zero quads")
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

    /// The paint tool is reachable: it maps to a tool and carries help text.
    @Test func thePaintToolIsReachable() {
        #expect(EditorAction.paintRegion.tool == .paintRegion)
        #expect(!EditorAction.paintRegion.gallery.notes.isEmpty)
        #expect(!EditorAction.clearPaintedRegion.gallery.notes.isEmpty)
        // Painting the Target is not a camera-manipulator tool.
        #expect(!RetopoTool.paintRegion.isCameraManipulator)
    }
}

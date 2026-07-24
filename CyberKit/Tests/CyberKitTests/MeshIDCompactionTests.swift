import CyberKit
import Foundation
import Testing
import simd

/// Element-id compaction across the document payload round trip.
///
/// REGRESSION SUITE. The payload is the engine's OBJ writer round-tripped
/// through a scratch file, and the exporter emits only LIVE elements,
/// renumbered from zero. Every journaled command re-serializes the live
/// mesh and the viewport reloads the live handle from those bytes, so a
/// single retired vertex renumbers everything after it — while the
/// document's `MeshAnnotations` still name the OLD ids. Before the fix, a
/// pinned loop silently became a DIFFERENT set of vertices after any
/// delete/merge: Relax refused to move geometry the user never froze and
/// smoothed away the geometry they did.
///
/// No mocks: real engine meshes, the real OBJ round trip, the real
/// `cyber_retopo_merge_vertices` op.
@Suite("Payload id compaction and annotation reconciliation")
struct MeshIDCompactionTests {
    private func mesh(fromOBJ text: String) throws -> Mesh {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("compaction-\(UUID().uuidString).obj")
        try text.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try Mesh.loadOBJ(at: url)
    }

    /// A 1x3 quad strip: vertices 0..7, quads (0,1,5,4) (1,2,6,5) (2,3,7,6).
    private func strip() throws -> Mesh {
        var obj = ""
        for x in 0...3 { obj += "v \(x) 0 0\n" }
        for x in 0...3 { obj += "v \(x) 1 0\n" }
        obj += "f 1 2 6 5\nf 2 3 7 6\nf 3 4 8 7\n"
        return try mesh(fromOBJ: obj)
    }

    // MARK: - The map itself

    @Test func aMeshWithNoRetiredElementsRoundTripsUnderTheIdentity() throws {
        let mesh = try strip()
        #expect(mesh.payloadIDCompaction().isIdentity)
        // ...and the round trip really does preserve every position in id
        // order, which is what "identity" claims.
        let reloaded = try Mesh(payloadData: try mesh.payloadData())
        for id in 0..<UInt32(mesh.vertexCount) {
            #expect(mesh.vertexPosition(id) == reloaded.vertexPosition(id))
        }
    }

    /// The load-bearing assertion: the derived map predicts EXACTLY what
    /// the OBJ writer does, checked position-by-position against the real
    /// round trip rather than against a re-implementation of the rule.
    @Test func theMapPredictsTheRealRoundTripAfterADelete() throws {
        let mesh = try strip()
        let before = (0..<UInt32(mesh.vertexCount)).compactMap { id in
            mesh.vertexPosition(id).map { (id, $0) }
        }
        // Retire vertex 0 by merging it into vertex 1 (a Merge Pair).
        try mesh.mergeVertices(keep: 1, remove: 0)

        let compaction = mesh.payloadIDCompaction()
        #expect(!compaction.isIdentity)
        #expect(!compaction.vertices.isEmpty)

        let reloaded = try Mesh(payloadData: try mesh.payloadData())
        for (oldID, _) in before {
            guard let livePosition = mesh.vertexPosition(oldID) else {
                // Retired: it must have no entry in the map at all.
                #expect(compaction.vertices[oldID] == nil)
                continue
            }
            let newID = try #require(compaction.vertices[oldID])
            #expect(reloaded.vertexPosition(newID) == livePosition)
        }
    }

    // MARK: - Annotation reconciliation

    @Test func identityCompactionLeavesAnnotationsUntouched() throws {
        let annotations = MeshAnnotations(
            taggedEdges: [3, 4], tagColorIndices: [1, 1],
            hiddenFaces: [2], pinnedVertices: [5, 6]
        )
        #expect(annotations.reconciled(through: .identity) == annotations)
    }

    /// The exact failure scenario: pin a set of vertices, retire a vertex
    /// with a LOWER id, and check the pins still name the SAME geometry
    /// after the document round trip — not a set shifted down by one.
    @Test func pinsFollowTheirVerticesAcrossADelete() throws {
        let mesh = try strip()
        let pinned: [UInt32] = [5, 6, 7]
        let pinnedPositions = pinned.compactMap { mesh.vertexPosition($0) }
        #expect(pinnedPositions.count == pinned.count)
        let annotations = MeshAnnotations(pinnedVertices: pinned)

        try mesh.mergeVertices(keep: 1, remove: 0)
        let carried = try #require(annotations.reconciled(through: mesh.payloadIDCompaction()))
        let reloaded = try Mesh(payloadData: try mesh.payloadData())

        // ANTI-VACUITY: the ids genuinely moved — carrying them over
        // unchanged would be wrong, and this proves the test would notice.
        #expect(carried.pinnedVertices != pinned)
        #expect(carried.pinnedVertices.count == pinned.count)
        for (newID, expected) in zip(carried.pinnedVertices.sorted(), pinnedPositions.sorted(by: {
            $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x
        })) {
            _ = expected
            #expect(reloaded.vertexPosition(newID) != nil)
        }
        // Every carried pin lands on a position that WAS pinned.
        for newID in carried.pinnedVertices {
            let position = try #require(reloaded.vertexPosition(newID))
            #expect(pinnedPositions.contains { simd_distance($0, position) < 1e-5 })
        }
    }

    @Test func pinsOnRetiredVerticesAreDropped() throws {
        let mesh = try strip()
        let annotations = MeshAnnotations(pinnedVertices: [0, 7])
        try mesh.mergeVertices(keep: 1, remove: 0)
        let carried = try #require(annotations.reconciled(through: mesh.payloadIDCompaction()))
        #expect(carried.pinnedVertices.count == 1)
    }

    /// Task 4.5b: loop tags now SURVIVE a non-identity round trip. The
    /// payload stores no edges, but the loader rebuilds every edge id from
    /// face-construction order and the compaction replays that numbering (via
    /// `faceVertices`), so a tag remaps to the same physical edge instead of
    /// being cleared. Ground truth: the remapped id, in the ACTUAL reloaded
    /// mesh, is the edge at the tag's original midpoint.
    @Test func loopTagsSurviveANonIdentityRoundTrip() throws {
        let mesh = try strip()
        // Tag the bottom edge of the first quad (midpoint (0.5, 0, 0)).
        let tagged = try #require(mesh.nearestEdge(to: SIMD3(0.5, 0, 0), maxDistance: 0.01))
        let ends = try #require(mesh.edgeEndpoints(of: tagged.edge))
        let taggedMid =
            (try #require(mesh.vertexPosition(ends.0))
                + (try #require(mesh.vertexPosition(ends.1)))) * 0.5
        let annotations = MeshAnnotations(taggedEdges: [tagged.edge], tagColorIndices: [2])

        // Retire the MIDDLE face — a non-identity compaction that renumbers
        // every rebuilt edge id.
        try mesh.deleteFaces([1])
        let compaction = mesh.payloadIDCompaction()
        #expect(!compaction.isIdentity)
        #expect(!compaction.edges.isEmpty)

        let carried = try #require(annotations.reconciled(through: compaction))
        // The tag survived (it used to be cleared) and kept its colour.
        #expect(carried.taggedEdges.count == 1)
        #expect(carried.tagColorIndices == [2])

        // GROUND TRUTH: the remapped edge, in the real reloaded mesh, sits at
        // the original tag's midpoint — the exact same physical edge.
        let reloaded = try Mesh(payloadData: try mesh.payloadData())
        let newEnds = try #require(reloaded.edgeEndpoints(of: carried.taggedEdges[0]))
        let newMid =
            (try #require(reloaded.vertexPosition(newEnds.0))
                + (try #require(reloaded.vertexPosition(newEnds.1)))) * 0.5
        #expect(simd_distance(newMid, taggedMid) < 1e-5)
    }

    /// The full edge map is validated against the REAL round trip, edge by
    /// edge (like `theMapPredictsTheRealRoundTripAfterADelete` for vertices):
    /// every live old edge maps to the reloaded edge with the same endpoints,
    /// and every live edge is covered.
    @Test func theEdgeMapPredictsTheRealRoundTrip() throws {
        let mesh = try strip()
        try mesh.deleteFaces([1])
        let compaction = mesh.payloadIDCompaction()
        let reloaded = try Mesh(payloadData: try mesh.payloadData())

        func midpoint(_ m: Mesh, _ edge: UInt32) throws -> SIMD3<Float> {
            let e = try #require(m.edgeEndpoints(of: edge))
            return (try #require(m.vertexPosition(e.0))
                + (try #require(m.vertexPosition(e.1)))) * 0.5
        }
        var checked = 0
        for oldEdge in 0..<UInt32(mesh.edgeCount + 64) {
            guard mesh.edgeEndpoints(of: oldEdge) != nil else { continue }
            let newEdge = try #require(
                compaction.edges[oldEdge], "live edge \(oldEdge) is mapped"
            )
            #expect(try simd_distance(midpoint(mesh, oldEdge), midpoint(reloaded, newEdge)) < 1e-5)
            checked += 1
        }
        #expect(checked == mesh.edgeCount, "every live edge was covered")
    }

    // MARK: - Face compaction (REGRESSION: the vertex-only identity scan)
    //
    // Retiring a face without retiring a vertex is the ordinary case for
    // `dissolveEdge` and `deleteFaces` on an interior region: every vertex
    // stays used by a neighbour. A vertex-only liveness scan called that
    // the identity, so `reconciled()` passed the hidden-face set through
    // untouched — and since the OBJ writer emits only live faces in live-id
    // order, on reload the set named faces the user never hid while the
    // ones they did hid reappeared.

    @Test func aRetiredFaceCompactsEvenWhenNoVertexDies() throws {
        let mesh = try strip()
        let verticesBefore = mesh.vertexCount
        try mesh.deleteFaces([1])
        // ANTI-VACUITY: this really is the face-only case.
        #expect(mesh.vertexCount == verticesBefore)
        #expect(mesh.faceCount == 2)

        let compaction = mesh.payloadIDCompaction()
        #expect(!compaction.isIdentity)
        #expect(compaction.faces[0] == 0)
        #expect(compaction.faces[1] == nil)  // retired
        #expect(compaction.faces[2] == 1)  // shifted down

        // ...and the map predicts the REAL round trip, face by face.
        let reloaded = try Mesh(payloadData: try mesh.payloadData())
        #expect(reloaded.faceCount == 2)
        #expect(reloaded.liveFaceIDs() == [0, 1])
    }

    @Test func hiddenFacesFollowTheirFacesAcrossARetiredFace() throws {
        let mesh = try strip()
        let annotations = MeshAnnotations(hiddenFaces: [2])
        try mesh.deleteFaces([1])
        let carried = try #require(annotations.reconciled(through: mesh.payloadIDCompaction()))
        #expect(carried.hiddenFaces == [1])
    }

    @Test func hiddenFacesOnRetiredFacesAreDropped() throws {
        let mesh = try strip()
        let annotations = MeshAnnotations(hiddenFaces: [1, 2])
        try mesh.deleteFaces([1])
        let carried = try #require(annotations.reconciled(through: mesh.payloadIDCompaction()))
        #expect(carried.hiddenFaces == [1])
    }

    @Test func nothingSurvivingReconcilesToNil() throws {
        let mesh = try strip()
        // Annotations naming ONLY elements the edits retire: the merged-away
        // vertex and the deleted middle quad.
        let annotations = MeshAnnotations(hiddenFaces: [1], pinnedVertices: [0])
        try mesh.mergeVertices(keep: 1, remove: 0)
        try mesh.deleteFaces([1])
        #expect(mesh.vertexPosition(0) == nil)
        #expect(!mesh.liveFaceIDs().contains(1))
        #expect(annotations.reconciled(through: mesh.payloadIDCompaction()) == nil)
    }

    @Test func anIndeterminateCompactionDropsEverything() {
        let annotations = MeshAnnotations(
            taggedEdges: [1], tagColorIndices: [0], hiddenFaces: [1], pinnedVertices: [1]
        )
        #expect(annotations.reconciled(through: .indeterminate) == nil)
    }
}

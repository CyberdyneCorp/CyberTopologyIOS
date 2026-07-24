import CyberKit
import CyberKitTesting
import Foundation
import Testing
import simd

/// Task 4.5 engine patch 0022: the EditMesh batch commands through the REAL
/// engine (spec: retopology-tools / "EditMesh batch commands", scenario
/// "Subdivide and reproject"), plus the ELEMENT-ID STABILITY contract the
/// document layer's compound journal entry is built on.
///
/// No mocks: every assertion drives the capi (`cyber_retopo_snap_all`,
/// `cyber_retopo_subdivide`, `cyber_retopo_triangulate`,
/// `cyber_retopo_relax` at whole-mesh radius) against real engine meshes.
@Suite("EditMesh batch ops (engine)")
struct BatchOpsTests {
    // MARK: - Fixtures

    private func mesh(fromOBJ text: String) throws -> Mesh {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("batch-ops-\(UUID().uuidString).obj")
        try text.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try Mesh.loadOBJ(at: url)
    }

    /// The committed 3x2 quad grid strip (4x3 vertices) at z = 0.
    /// Inlined (byte-for-byte Fixtures/grid32.obj) to be device-safe: the
    /// app-hosted test target cannot read the SPM test bundle's Fixtures.
    private func grid32() throws -> Mesh {
        try mesh(fromOBJ: """
        v -0.375 -0.25 0
        v -0.125 -0.25 0
        v  0.125 -0.25 0
        v  0.375 -0.25 0
        v -0.375  0.00 0
        v -0.125  0.00 0
        v  0.125  0.00 0
        v  0.375  0.00 0
        v -0.375  0.25 0
        v -0.125  0.25 0
        v  0.125  0.25 0
        v  0.375  0.25 0
        f 1 2 6 5
        f 2 3 7 6
        f 3 4 8 7
        f 5 6 10 9
        f 6 7 11 10
        f 7 8 12 11
        """)
    }

    /// A DOMED Target above the grid: subdivide+reproject has to lift the
    /// new vertices off the flat cage onto real curvature, so a flat Target
    /// would make the scenario assertion vacuous.
    private func domeTarget() throws -> SurfaceSnapper {
        let n = 12
        var obj = ""
        for row in 0...n {
            for col in 0...n {
                let x = Double(col) / Double(n) * 8 - 4
                let y = Double(row) / Double(n) * 8 - 4
                let z = 1.5 - 0.06 * (x * x + y * y)
                obj += "v \(x) \(y) \(z)\n"
            }
        }
        for row in 0..<n {
            for col in 0..<n {
                let a = row * (n + 1) + col + 1
                obj += "f \(a) \(a + 1) \(a + n + 2) \(a + n + 1)\n"
            }
        }
        return try SurfaceSnapper(target: try mesh(fromOBJ: obj))
    }

    #if targetEnvironment(simulator)
    private var goldensDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Goldens", isDirectory: true)
            .appendingPathComponent("MeshEdits", isDirectory: true)
    }
    #endif

    /// Positions of every live vertex. A mesh loaded from OBJ (and one
    /// rebuilt by subdivide) numbers its vertices contiguously from 0.
    private func livePositions(_ mesh: Mesh) -> [SIMD3<Float>] {
        (0..<UInt32(mesh.vertexCount)).compactMap { mesh.vertexPosition($0) }
    }

    // MARK: - Snap all to Target

    @Test("snapAllToTarget projects every unpinned vertex onto the Target")
    func snapAllProjects() throws {
        let cage = try grid32()
        let snapper = try domeTarget()
        // The cage sits at z = 0; the dome is well above it.
        let report = try cage.snapAllToTarget(snapper)
        #expect(report.resnapped == cage.vertexCount)
        #expect(report.maxDistance > 1)
        for id in 0..<UInt32(cage.vertexCount) {
            let position = try #require(cage.vertexPosition(id))
            let hit = try #require(snapper.snapToSurface(position))
            #expect(simd_distance(hit.point, position) < 1e-3)
        }
    }

    @Test("snapAllToTarget leaves pinned vertices exactly where they are")
    func snapAllHonorsPins() throws {
        let cage = try grid32()
        let snapper = try domeTarget()
        let pinned: [UInt32] = [0, 3]
        let before = pinned.map { cage.vertexPosition($0)! }
        let report = try cage.snapAllToTarget(snapper, pinned: pinned)
        for (index, id) in pinned.enumerated() {
            #expect(cage.vertexPosition(id) == before[index])
        }
        #expect(report.resnapped == cage.vertexCount - pinned.count)
        // Anti-vacuity: the SAME vertices move when nothing is pinned.
        let control = try grid32()
        try control.snapAllToTarget(snapper)
        for (index, id) in pinned.enumerated() {
            #expect(control.vertexPosition(id) != before[index])
        }
    }

    @Test("snapAllToTarget without a Target fails and leaves the mesh alone")
    func snapAllRequiresTarget() throws {
        let cage = try grid32()
        let before = try cage.payloadData()
        #expect(throws: CyberKitError.self) {
            try cage.snapAllToTarget(nil)
        }
        #expect(try cage.payloadData() == before)
    }

    // MARK: - Relax all

    @Test("relaxAll smooths the whole cage but never a pinned vertex")
    func relaxAllHonorsPins() throws {
        let cage = try grid32()
        // Perturb so a relax has real work to do.
        for id in 0..<UInt32(cage.vertexCount) {
            let position = try #require(cage.vertexPosition(id))
            let sign: Float = id % 2 == 0 ? 1 : -1
            try cage.tweakVertex(id, to: position + SIMD3(0.05 * sign, 0.04 * sign, 0))
        }
        let snapshot = (0..<UInt32(cage.vertexCount)).map { cage.vertexPosition($0)! }
        // An INTERIOR vertex: grid corners auto-pin, so pinning a corner
        // would prove nothing.
        let pinnedID = try #require(
            cage.nearestVertex(to: SIMD3(-0.125, 0, 0), maxDistance: 0.12)
        ).vertex
        let pinnedBefore = try #require(cage.vertexPosition(pinnedID))
        try cage.relaxAll(strength: 0.8, iterations: 4, pinned: [pinnedID])
        #expect(cage.vertexPosition(pinnedID) == pinnedBefore)
        let moved = (0..<UInt32(cage.vertexCount)).filter {
            cage.vertexPosition($0) != snapshot[Int($0)]
        }
        #expect(moved.count > 1)
        #expect(!moved.contains(pinnedID))
    }

    // MARK: - Subdivide (+ reproject) — spec scenario "Subdivide and reproject"

    @Test("subdivide splits every quad into four")
    func subdivideQuadruples() throws {
        let cage = try grid32()
        let facesBefore = cage.faceCount
        let faces = try cage.subdivide()
        #expect(faces == facesBefore * 4)
        #expect(cage.faceCount == facesBefore * 4)
    }

    /// Spec scenario "Subdivide and reproject": the mesh is subdivided once
    /// and ALL its vertices — the new ones especially — land on the Target
    /// surface. Linear subdivision alone would leave the new midpoints on
    /// the flat cage facets, so this cannot pass without the reprojection.
    @Test("subdivide+reproject puts every new vertex on the Target surface")
    func subdivideAndReprojectLandsOnTarget() throws {
        let cage = try grid32()
        let snapper = try domeTarget()
        try cage.snapAllToTarget(snapper)  // start from a wrapped cage
        let coarse = livePositions(cage)
        try cage.subdivide(reprojectingOnto: snapper)
        #expect(cage.vertexCount > coarse.count)

        var newVertices = 0
        for position in livePositions(cage) {
            let hit = try #require(snapper.snapToSurface(position))
            #expect(simd_distance(hit.point, position) < 1e-3)
            if !coarse.contains(where: { simd_distance($0, position) < 1e-4 }) {
                newVertices += 1
            }
        }
        #expect(newVertices > 0)

        // Anti-vacuity: WITHOUT reprojection the same new vertices sit off
        // the dome (the chord of a convex surface lies under it), so the
        // assertion above is testing the reprojection, not the fixture.
        let flat = try grid32()
        try flat.snapAllToTarget(snapper)
        try flat.subdivide()
        let offSurface = try livePositions(flat).filter { position in
            let hit = try #require(snapper.snapToSurface(position))
            return simd_distance(hit.point, position) > 1e-3
        }
        #expect(!offSurface.isEmpty)
    }

    @Test("subdivide is deterministic (payload golden)")
    func subdivideDeterminism() throws {
        let cage = try grid32()
        try cage.subdivide()
        #if targetEnvironment(simulator)
        try GoldenFile.compare(
            try cage.payloadData(),
            golden: goldensDirectory.appendingPathComponent("subdivide_grid32.payload.golden")
        )
        #endif
        // Same input, same bytes — twice in one process.
        let again = try grid32()
        try again.subdivide()
        #expect(try again.payloadData() == (try cage.payloadData()))
    }

    @Test("subdivide rejects an empty mesh and leaves it unchanged")
    func subdivideRejectsEmpty() throws {
        let empty = try Mesh()
        #expect(throws: CyberKitError.self) { try empty.subdivide() }
        #expect(empty.faceCount == 0)
    }

    // MARK: - Triangulate

    @Test("triangulate fans every quad and preserves vertex ids")
    func triangulatePreservesVertexIDs() throws {
        let cage = try grid32()
        let vertexCount = cage.vertexCount
        let before = (0..<UInt32(vertexCount)).map { cage.vertexPosition($0)! }
        let faces = try cage.triangulate()
        #expect(faces == 12)  // 6 quads -> 12 triangles
        // The ELEMENT-ID STABILITY claim `AnnotationIDPolicy.pinsOnly`
        // rests on: triangulate mutates IN PLACE, so vertex ids (and hence
        // pins) survive verbatim.
        #expect(cage.vertexCount == vertexCount)
        for id in 0..<UInt32(vertexCount) {
            #expect(cage.vertexPosition(id) == before[Int(id)])
        }
    }

    @Test("triangulate is deterministic (payload golden)")
    func triangulateDeterminism() throws {
        let cage = try grid32()
        try cage.triangulate()
        #if targetEnvironment(simulator)
        try GoldenFile.compare(
            try cage.payloadData(),
            golden: goldensDirectory.appendingPathComponent("triangulate_grid32.payload.golden")
        )
        #endif
    }

    /// REGRESSION (major finding, task 4.5b): triangulate preserves edge ids
    /// IN THE LIVE HANDLE, but the document payload stores no edges — the
    /// loader rebuilds every edge id from FACE-CONSTRUCTION ORDER, and
    /// triangulate reshuffles the face stream (each n-gon's extra triangles
    /// append at the end while the split face keeps its slot). It retires
    /// nothing, so `payloadIDCompaction()` correctly reports `.identity` on
    /// the vertex and face spaces — which is precisely why the EDGE space
    /// needs its own answer: a loop tag carried across identity compaction
    /// would land on an unrelated edge after the viewport reloads.
    @Test("triangulate reshuffles the payload's rebuilt edge ids")
    func triangulateReshufflesRebuiltEdgeIDs() throws {
        let cage = try grid32()
        try cage.triangulate()
        // No holes in either mapped id space: the compaction is the identity
        // and would pass annotations through untouched.
        #expect(cage.payloadIDCompaction().isIdentity)

        let reloaded = try Mesh(payloadData: try cage.payloadData())
        #expect(reloaded.edgeCount == cage.edgeCount)
        var displaced = 0
        for id in 0..<UInt32(cage.edgeCount) {
            guard let live = edgeMidpoint(cage, id) else { continue }
            guard let round = edgeMidpoint(reloaded, id) else {
                displaced += 1
                continue
            }
            if simd_distance(live, round) > 1e-5 { displaced += 1 }
        }
        // The same id names a DIFFERENT edge after the round trip, so tags
        // must be cleared by the policy, not carried.
        #expect(displaced > 0)
    }

    private func edgeMidpoint(_ mesh: Mesh, _ edge: UInt32) -> SIMD3<Float>? {
        guard let ends = mesh.edgeEndpoints(of: edge),
            let a = mesh.vertexPosition(ends.0), let b = mesh.vertexPosition(ends.1)
        else { return nil }
        return (a + b) * 0.5
    }

    /// The counterpart of the vertex-id claim: subdivide REBUILDS the mesh,
    /// so ids mean something else afterwards. This is exactly why the
    /// document layer clears annotations instead of remapping them.
    @Test("subdivide reassigns element ids")
    func subdivideReassignsIDs() throws {
        let cage = try grid32()
        // Midpoint of every edge id BEFORE — the identity of an edge as far
        // as a loop tag is concerned.
        var edgesBefore: [(id: UInt32, midpoint: SIMD3<Float>)] = []
        for id in 0..<UInt32(cage.edgeCount) {
            guard let ends = cage.edgeEndpoints(of: id),
                let a = cage.vertexPosition(ends.0), let b = cage.vertexPosition(ends.1)
            else { continue }
            edgesBefore.append((id, (a + b) * 0.5))
        }
        #expect(!edgesBefore.isEmpty)
        try cage.subdivide()
        // The mesh was rebuilt: the SAME edge ids now describe different
        // edges, which is exactly why the document clears loop tags instead
        // of carrying them across.
        let moved = edgesBefore.filter { id, midpoint in
            guard let ends = cage.edgeEndpoints(of: id),
                let a = cage.vertexPosition(ends.0), let b = cage.vertexPosition(ends.1)
            else { return true }
            return simd_distance((a + b) * 0.5, midpoint) > 1e-5
        }
        #expect(!moved.isEmpty)
        #expect(cage.vertexCount > 12)
    }

    // MARK: - AnnotationIDPolicy (the clear-never-remap convention)

    @Test("annotation id policies keep exactly what survives")
    func annotationPolicies() {
        let annotations = MeshAnnotations(
            taggedEdges: [4, 7], tagColorIndices: [1, 2],
            hiddenFaces: [3], pinnedVertices: [0, 9]
        )
        #expect(AnnotationIDPolicy.preserved.surviving(annotations) == annotations)
        #expect(AnnotationIDPolicy.rebuilt.surviving(annotations) == nil)
        // Only pins survive triangulate: hidden faces lose their ids to the
        // split, and loop tags lose theirs to the payload's edge rebuild
        // (see `triangulateReshufflesRebuiltEdgeIDs`).
        let afterTriangulate = AnnotationIDPolicy.pinsOnly.surviving(annotations)
        #expect(afterTriangulate?.pinnedVertices == [0, 9])
        #expect(afterTriangulate?.taggedEdges.isEmpty == true)
        #expect(afterTriangulate?.tagColorIndices.isEmpty == true)
        #expect(afterTriangulate?.hiddenFaces.isEmpty == true)
        // Nothing to keep collapses to nil, so no empty annotation blob is
        // written back into the manifest.
        #expect(
            AnnotationIDPolicy.pinsOnly.surviving(MeshAnnotations(hiddenFaces: [1])) == nil
        )
        #expect(
            AnnotationIDPolicy.pinsOnly.surviving(
                MeshAnnotations(taggedEdges: [1], tagColorIndices: [2])
            ) == nil
        )
        #expect(AnnotationIDPolicy.preserved.surviving(nil) == nil)
    }
}

import CyberKit
import CyberKitTesting
import Foundation
import Testing
import simd

/// Task 3.4 engine patches 0009–0012: the gesture grammar's mesh operations
/// and annotation state exercised through the CyberKit facade against real
/// engine meshes — quad-ring / edge-loop topology walks, full-ring loop
/// insert (golden-filed), edge dissolve, vertex merge, edge rotate, and the
/// hidden-face / tagged-edge render filters behind partial visibility and
/// loop tags.
@Suite("Gesture grammar mesh ops (engine)")
struct GrammarMeshOpsTests {
    // MARK: - Fixtures

    private func mesh(fromOBJ text: String) throws -> Mesh {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("grammar-ops-\(UUID().uuidString).obj")
        try text.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try Mesh.loadOBJ(at: url)
    }

    /// The committed 3x2 quad grid strip (same fixture the recognizer
    /// tests replay strokes against).
    private func grid32() throws -> Mesh {
        let url = try #require(Bundle.module.url(
            forResource: "grid32", withExtension: "obj", subdirectory: "Fixtures"
        ))
        return try Mesh.loadOBJ(at: url)
    }

    private func cube() throws -> Mesh {
        let url = try #require(Bundle.module.url(
            forResource: "cube", withExtension: "obj", subdirectory: "Fixtures"
        ))
        return try Mesh.loadOBJ(at: url)
    }

    /// Two triangles sharing the diagonal v1–v3 (ids 1 and 3).
    private func trianglePair() throws -> Mesh {
        try mesh(fromOBJ: """
        v 0 0 0
        v 1 0 0
        v 1 1 0
        v 0 1 0
        f 1 2 4
        f 2 3 4
        """)
    }

    private var goldensDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Goldens", isDirectory: true)
            .appendingPathComponent("MeshEdits", isDirectory: true)
    }

    // MARK: - Loop topology queries (patch 0009)

    @Test("quad ring walks the open column ring; edge loop walks the middle row")
    func loopWalksMatchGridTopology() throws {
        let grid = try grid32()
        // Edge between engine vertices 1–2 (bottom middle horizontal).
        let seed = try #require(grid.nearestEdge(
            to: SIMD3(0, -0.25, 0), maxDistance: 0.01
        ))
        let ring = grid.quadRing(from: seed.edge)
        #expect(!ring.closed)
        #expect(ring.edges.count == 3)
        let ringEnds = ring.edges.map { Set(pair: grid.edgeEndpoints(of: $0)!) }
        #expect(ringEnds == [Set([1, 2]), Set([5, 6]), Set([9, 10])])

        // Middle horizontal row: a loop through two valence-4 vertices.
        let middle = try #require(grid.nearestEdge(
            to: SIMD3(0, 0, 0), maxDistance: 0.01
        ))
        let loop = grid.edgeLoop(from: middle.edge)
        let loopEnds = Set(loop.map { Set(pair: grid.edgeEndpoints(of: $0)!) })
        #expect(loopEnds == Set([Set([4, 5]), Set([5, 6]), Set([6, 7])]))

        // A dead seed yields empty walks.
        #expect(grid.edgeLoop(from: 9999).isEmpty)
        #expect(grid.quadRing(from: 9999).edges.isEmpty)
    }

    @Test("quad ring closes around the cube")
    func quadRingClosesOnCube() throws {
        let box = try cube()
        let seed = try #require(box.nearestEdge(
            to: SIMD3(0, -0.5, -0.5), maxDistance: 0.01
        ))
        let ring = box.quadRing(from: seed.edge)
        #expect(ring.closed)
        #expect(ring.edges.count == 4)
    }

    // MARK: - Full-ring loop insert (patch 0009; the recon NOTE: the old
    // engine insertLoop split exactly ONE quad — this is the ring version)

    @Test("insert loop splits EVERY quad around the open ring, golden-filed")
    func insertLoopSplitsWholeOpenRing() throws {
        let grid = try grid32()
        let before = try grid.payloadData()
        let seed = try #require(grid.nearestEdge(
            to: SIMD3(0, -0.25, 0), maxDistance: 0.01
        ))
        let newFaces = try grid.insertLoop(acrossEdge: seed.edge)
        #expect(newFaces == 2)  // one per ring quad
        #expect(grid.faceCount == 8)
        #expect(grid.vertexCount == 15)  // 3 split ring edges -> 3 midpoints
        let stats = try grid.stats()
        #expect(stats.quads == 8)  // all-quad result, no triangles
        #expect(stats.triangles == 0)
        let golden = goldensDirectory
            .appendingPathComponent("loop_insert_grid32.payload.golden")
        try GoldenFile.compare(try grid.payloadData(), golden: golden)
        // Undo at document scale is byte-exact payload replacement.
        let restored = try Mesh(payloadData: before)
        #expect(restored.faceCount == 6)
        #expect(restored.vertexCount == 12)
    }

    @Test("insert loop wraps a CLOSED ring (cube) back to its seed")
    func insertLoopWrapsClosedRing() throws {
        let box = try cube()
        let seed = try #require(box.nearestEdge(
            to: SIMD3(0, -0.5, -0.5), maxDistance: 0.01
        ))
        let newFaces = try box.insertLoop(acrossEdge: seed.edge)
        #expect(newFaces == 4)
        #expect(box.faceCount == 10)  // 6 - 4 ring quads + 8 halves
        #expect(box.vertexCount == 12)  // 4 midpoints
        #expect(try box.stats().quads == 10)
    }

    @Test("insert loop rejects dead edges and bad t, leaving the mesh untouched")
    func insertLoopValidates() throws {
        let grid = try grid32()
        let before = try grid.payloadData()
        #expect(throws: CyberKitError.self) {
            try grid.insertLoop(acrossEdge: 9999)
        }
        #expect(throws: CyberKitError.self) {
            try grid.insertLoop(acrossEdge: 0, t: 1.5)
        }
        #expect(try grid.payloadData() == before)
    }

    // MARK: - One-stroke grid creation (patch 0013)

    @Test("create grid builds ONE welded block of Target-snapped quads")
    func createGridBuildsWeldedBlock() throws {
        var lattice: [SIMD3<Float>] = []
        for row in 0...1 {
            for col in 0...3 {
                lattice.append(SIMD3(Float(col), Float(row), 0))
            }
        }

        // Off-plane Target: the lattice must land ON it (z = 0.5), proving
        // the snap actually ran.
        let target = try mesh(fromOBJ: """
        v -5 -5 0.5
        v 5 -5 0.5
        v 5 5 0.5
        v -5 5 0.5
        f 1 2 3 4
        """)
        let snapper = try SurfaceSnapper(target: target)
        let block = try Mesh()
        let faces = try block.createGrid(lattice: lattice, rows: 1, cols: 3, snapping: snapper)
        #expect(faces == 3)
        #expect(block.faceCount == 3)
        // Welded: 8 shared lattice vertices and ONE island — not the 12
        // vertices / 3 islands repeated createFace calls would produce.
        #expect(block.vertexCount == 8)
        let stats = try block.stats()
        #expect(stats.quads == 3)
        #expect(stats.islands == 1)
        for id in 0..<8 {
            #expect(try #require(block.vertexPosition(UInt32(id))).z == 0.5)
        }

        // Degenerate lattices are rejected, mesh untouched.
        let before = try block.payloadData()
        #expect(throws: CyberKitError.self) {
            try block.createGrid(
                lattice: Array(repeating: SIMD3(0, 0, 0), count: 4), rows: 1, cols: 1
            )
        }
        #expect(throws: CyberKitError.self) {
            try block.createGrid(lattice: lattice, rows: 2, cols: 3)
        }
        #expect(try block.payloadData() == before)
    }

    // MARK: - Dissolve / merge / rotate (patch 0010)

    @Test("dissolving the shared diagonal merges a triangle pair into a quad")
    func dissolveMergesTrianglePair() throws {
        let pair = try trianglePair()
        let diagonal = try #require(pair.nearestEdge(
            to: SIMD3(0.5, 0.5, 0), maxDistance: 0.01
        ))
        #expect(try pair.dissolveEdges([diagonal.edge]) == 1)
        #expect(pair.faceCount == 1)
        let stats = try pair.stats()
        #expect(stats.quads == 1)
        #expect(stats.triangles == 0)
        let golden = goldensDirectory
            .appendingPathComponent("dissolve_tri_pair.payload.golden")
        try GoldenFile.compare(try pair.payloadData(), golden: golden)
    }

    @Test("boundary and dead edges are skipped by dissolve, mesh untouched")
    func dissolveSkipsBoundaryAndDeadEdges() throws {
        let pair = try trianglePair()
        let before = try pair.payloadData()
        let boundary = try #require(pair.nearestEdge(
            to: SIMD3(0.5, 0, 0), maxDistance: 0.01
        ))
        #expect(try pair.dissolveEdges([boundary.edge, 9999]) == 0)
        #expect(try pair.payloadData() == before)
    }

    @Test("merge collapses remove onto keep at keep's position")
    func mergeVerticesCollapsesPair() throws {
        let grid = try grid32()
        // Merge bottom-left corner (0) into its right neighbor (1): the
        // leftmost bottom quad degenerates to a triangle.
        try grid.mergeVertices(keep: 1, remove: 0)
        #expect(grid.vertexCount == 11)
        #expect(grid.faceCount == 6)
        let stats = try grid.stats()
        #expect(stats.triangles == 1)
        #expect(stats.quads == 5)
        #expect(grid.vertexPosition(0) == nil)
        #expect(try #require(grid.vertexPosition(1)) == SIMD3(-0.125, -0.25, 0))

        // Midpoint variant.
        let pair = try trianglePair()
        try pair.mergeVertices(keep: 1, remove: 2, atMidpoint: true)
        #expect(try #require(pair.vertexPosition(1)) == SIMD3(1, 0.5, 0))

        // Dead/identical vertices are rejected, mesh untouched.
        let before = try pair.payloadData()
        #expect(throws: CyberKitError.self) {
            try pair.mergeVertices(keep: 1, remove: 1)
        }
        #expect(throws: CyberKitError.self) {
            try pair.mergeVertices(keep: 1, remove: 9999)
        }
        #expect(try pair.payloadData() == before)
    }

    @Test("rotate flips a triangle pair's diagonal")
    func rotateFlipsTriangleDiagonal() throws {
        let pair = try trianglePair()
        let diagonal = try #require(pair.nearestEdge(
            to: SIMD3(0.5, 0.5, 0), maxDistance: 0.01
        ))
        #expect(Set(pair: pair.edgeEndpoints(of: diagonal.edge)!) == Set([1, 3]))
        try pair.rotateEdge(diagonal.edge)
        #expect(pair.faceCount == 2)
        #expect(try pair.stats().triangles == 2)
        // The diagonal now connects the OTHER corner pair (0–2).
        let rotated = try #require(pair.nearestEdge(
            to: SIMD3(0.5, 0.5, 0), maxDistance: 0.01
        ))
        #expect(Set(pair: pair.edgeEndpoints(of: rotated.edge)!) == Set([0, 2]))
    }

    @Test("rotate turns a quad pair's loop flow; boundary edges are rejected")
    func rotateTurnsQuadPair() throws {
        let quads = try mesh(fromOBJ: """
        v 0 0 0
        v 1 0 0
        v 2 0 0
        v 0 1 0
        v 1 1 0
        v 2 1 0
        f 1 2 5 4
        f 2 3 6 5
        """)
        let shared = try #require(quads.nearestEdge(
            to: SIMD3(1, 0.5, 0), maxDistance: 0.01
        ))
        #expect(Set(pair: quads.edgeEndpoints(of: shared.edge)!) == Set([1, 4]))
        try quads.rotateEdge(shared.edge)
        #expect(quads.faceCount == 2)
        #expect(try quads.stats().quads == 2)
        // The interior edge rotated one ring corner over.
        var interior: Set<UInt32>?
        for edge in 0..<32 {
            let id = UInt32(edge)
            if let boundary = quads.isBoundaryEdge(id), !boundary {
                interior = Set(pair: quads.edgeEndpoints(of: id)!)
            }
        }
        #expect(try #require(interior) != Set([1, 4]))

        let boundary = try #require(quads.nearestEdge(
            to: SIMD3(0.5, 0, 0), maxDistance: 0.01
        ))
        #expect(throws: CyberKitError.self) {
            try quads.rotateEdge(boundary.edge)
        }
    }

    // MARK: - Annotation state + render filters (patch 0012)

    @Test("hidden faces drop out of every render stream; show-all restores")
    func hiddenFacesFilterRenderStreams() throws {
        let grid = try grid32()
        let fullTriangles = grid.withRenderBuffers { $0.triangleIndices.count }
        let fullEdges = grid.withRenderBuffers { $0.edgeIndices.count }
        let fullPositions = grid.withRenderBuffers { $0.positions.count }
        #expect(fullTriangles == 6 * 2 * 3)

        // Hide the bottom-left quad (face 0): its 2 triangles disappear,
        // its exclusive corner vertex (0) leaves the compaction, and its
        // exclusive edges leave the wireframe.
        try grid.applyAnnotations(MeshAnnotations(hiddenFaces: [0]))
        #expect(grid.hiddenFaceCount == 1)
        #expect(grid.withRenderBuffers { $0.triangleIndices.count } == fullTriangles - 6)
        #expect(grid.withRenderBuffers { $0.positions.count } == fullPositions - 3)
        #expect(grid.withRenderBuffers { $0.edgeIndices.count } < fullEdges)
        // Topology and stable ids are untouched: the hidden face is alive.
        #expect(grid.faceCount == 6)
        #expect(grid.liveFaceIDs() == [0, 1, 2, 3, 4, 5])

        // Show all restores the exact original streams.
        try grid.applyAnnotations(nil)
        #expect(grid.hiddenFaceCount == 0)
        #expect(grid.withRenderBuffers { $0.triangleIndices.count } == fullTriangles)
        #expect(grid.withRenderBuffers { $0.positions.count } == fullPositions)
        #expect(grid.withRenderBuffers { $0.edgeIndices.count } == fullEdges)
    }

    @Test("tagged edges surface as compacted index pairs; stale ids are skipped")
    func taggedEdgesSurfaceInRenderBuffers() throws {
        let grid = try grid32()
        let middle = try #require(grid.nearestEdge(
            to: SIMD3(0, 0, 0), maxDistance: 0.01
        ))
        let loop = grid.edgeLoop(from: middle.edge)
        #expect(loop.count == 3)
        try grid.applyAnnotations(MeshAnnotations(taggedEdges: loop + [9999]))
        let tagged = grid.withRenderBuffers { Array($0.taggedEdgeIndices) }
        #expect(tagged.count == 6)  // 3 live edges x 2 indices; 9999 skipped
        // Untagged meshes expose an empty stream.
        try grid.applyAnnotations(nil)
        #expect(grid.withRenderBuffers { $0.taggedEdgeIndices.count } == 0)
    }

    @Test("live face enumeration tracks deletions")
    func liveFaceIDsTrackDeletions() throws {
        let grid = try grid32()
        #expect(grid.liveFaceIDs() == [0, 1, 2, 3, 4, 5])
        try grid.deleteFaces([2])
        #expect(grid.liveFaceIDs() == [0, 1, 3, 4, 5])
    }

    // MARK: - MeshAnnotations transforms + journal command

    @Test("annotation transforms are deterministic and normalize ordering")
    func annotationTransforms() throws {
        let base = MeshAnnotations()
        let tagged = base.togglingTags(on: [7, 3, 5])
        #expect(tagged.taggedEdges == [3, 5, 7])
        // Toggling the same loop again clears it.
        #expect(tagged.togglingTags(on: [5, 3, 7]).taggedEdges == [])
        // A partially-overlapping loop unions in.
        #expect(tagged.togglingTags(on: [5, 9]).taggedEdges == [3, 5, 7, 9])

        let hidden = base.hiding(faces: [4, 1]).hiding(faces: [1, 2])
        #expect(hidden.hiddenFaces == [1, 2, 4])
        let inverted = hidden.invertingVisibility(allFaces: [0, 1, 2, 3, 4, 5])
        #expect(inverted.hiddenFaces == [0, 3, 5])
        #expect(inverted.showingAll().hiddenFaces == [])
        #expect(base.isEmpty)
        #expect(!hidden.isEmpty)

        // Codable round trip (journal persistence).
        let data = try JSONEncoder().encode(inverted)
        #expect(try JSONDecoder().decode(MeshAnnotations.self, from: data) == inverted)
    }

    @Test("annotationEdit commands apply and revert annotations exactly")
    func annotationEditCommandRoundTrips() throws {
        var bundle = DocumentBundle()
        let editMesh = try grid32()
        let object = try bundle.addObject(name: "cage", role: .editMesh, mesh: editMesh)
        #expect(bundle.manifest.objects[0].annotations == nil)

        let after = MeshAnnotations(taggedEdges: [1, 2], hiddenFaces: [0])
        let command = DocumentCommand.annotationEdit(.init(
            objectID: object.id, verb: "pencil.tagLoop", before: nil, after: after
        ))
        command.apply(to: &bundle)
        #expect(bundle.manifest.objects[0].annotations == after)
        // Payload bytes are untouched by annotation commands.
        #expect(bundle.payloads[object.payloadFile] != nil)

        command.revert(on: &bundle)
        #expect(bundle.manifest.objects[0].annotations == nil)

        // The command is Codable (journal persistence).
        let data = try JSONEncoder().encode(command)
        #expect(try JSONDecoder().decode(DocumentCommand.self, from: data) == command)
    }
}

extension Set where Element == UInt32 {
    /// Set from an endpoint tuple (readability sugar for the walk asserts).
    fileprivate init(pair: (UInt32, UInt32)) {
        self = [pair.0, pair.1]
    }
}

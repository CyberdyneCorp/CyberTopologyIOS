import CyberKit
import Foundation
import Testing
import simd

@testable import CyberTopology

/// Grid continuation (draw a quad against an existing SUBDIVIDED boundary →
/// welded rows that continue the neighbour's edge loops). A quad drawn against
/// a multi-row edge extends that boundary's chain across the drawn region; a
/// standalone quad, a one-cell append, or a triangle stays a single face.
@MainActor
struct PatchFillTests {
    private func mesh(fromOBJ text: String) throws -> Mesh {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("patch-\(UUID().uuidString).obj")
        try text.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try Mesh.loadOBJ(at: url)
    }

    /// A 1-column x 4-row grid (x in {0,1}, y in 0...4): its right edge (x = 1)
    /// is a 5-vertex boundary chain — the subdivided neighbour to draw against.
    private func columnGrid() throws -> Mesh {
        try mesh(fromOBJ: """
        v 0 0 0
        v 1 0 0
        v 0 1 0
        v 1 1 0
        v 0 2 0
        v 1 2 0
        v 0 3 0
        v 1 3 0
        v 0 4 0
        v 1 4 0
        f 1 2 4 3
        f 3 4 6 5
        f 5 6 8 7
        f 7 8 10 9
        """)
    }

    @Test("A quad drawn against a subdivided boundary continues its loops")
    func continuesAdjacentLoops() throws {
        let m = try columnGrid()
        #expect(m.faceCount == 4)
        #expect(m.vertexCount == 10)
        // A quad hugging the right edge (x 1→2, full height): its left side
        // snaps to the 5-vertex boundary chain, ~1 cell deep.
        let corners = [
            SIMD3<Float>(1, 0, 0), SIMD3(2, 0, 0), SIMD3(2, 4, 0), SIMD3(1, 4, 0),
        ]
        try MeshEditController.buildCreatedFace(
            mesh: m, corners: corners, snapper: nil, mergeRadius: 0.5
        )
        // One extruded column continuing the 4 rows: +4 quads, +5 vertices
        // (the shared column is REUSED, not duplicated).
        #expect(m.faceCount == 8, "4 new quads continuing the rows, got \(m.faceCount - 4)")
        #expect(m.vertexCount == 15, "only the outer column is new, got \(m.vertexCount - 10)")
    }

    @Test("A deeper drawn region continues into several welded columns")
    func continuesIntoMultipleColumns() throws {
        let m = try columnGrid()
        // Twice as deep (x 1→3): two columns of 4 rows.
        let corners = [
            SIMD3<Float>(1, 0, 0), SIMD3(3, 0, 0), SIMD3(3, 4, 0), SIMD3(1, 4, 0),
        ]
        try MeshEditController.buildCreatedFace(
            mesh: m, corners: corners, snapper: nil, mergeRadius: 0.5
        )
        #expect(m.faceCount == 4 + 8, "2 columns x 4 rows, got \(m.faceCount - 4)")
        #expect(m.vertexCount == 10 + 10)
    }

    @Test("A one-cell append against a single edge stays a single quad")
    func oneCellAppendStaysSingle() throws {
        // A lone unit quad: its right edge is a SINGLE boundary edge, not a
        // subdivided chain, so an adjacent unit quad just welds on as one face.
        let m = try mesh(fromOBJ: "v 0 0 0\nv 1 0 0\nv 1 1 0\nv 0 1 0\nf 1 2 3 4\n")
        let corners = [
            SIMD3<Float>(1, 0, 0), SIMD3(2, 0, 0), SIMD3(2, 1, 0), SIMD3(1, 1, 0),
        ]
        try MeshEditController.buildCreatedFace(
            mesh: m, corners: corners, snapper: nil, mergeRadius: 0.5
        )
        #expect(m.faceCount == 2, "a single-edge neighbour → one welded quad, not a grid")
    }

    @Test("A standalone quad on an empty mesh stays a single quad")
    func standaloneQuadStaysSingle() throws {
        let m = try Mesh()
        let corners = [
            SIMD3<Float>(0, 0, 0), SIMD3(4, 0, 0), SIMD3(4, 4, 0), SIMD3(0, 4, 0),
        ]
        try MeshEditController.buildCreatedFace(
            mesh: m, corners: corners, snapper: nil, mergeRadius: 0.5
        )
        #expect(m.faceCount == 1, "no neighbour to continue → a single quad")
    }

    @Test("A triangle ring stays a single face")
    func triangleStaysSingle() throws {
        let m = try columnGrid()
        let corners = [SIMD3<Float>(1, 0, 0), SIMD3(3, 0, 0), SIMD3(2, 4, 0)]
        try MeshEditController.buildCreatedFace(
            mesh: m, corners: corners, snapper: nil, mergeRadius: 0.5
        )
        #expect(m.faceCount == 5, "a triangle is never a continued patch")
    }
}

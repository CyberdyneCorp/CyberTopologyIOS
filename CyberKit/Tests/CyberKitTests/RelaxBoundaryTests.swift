import CyberKit
import Foundation
import Testing
import simd

/// Relax boundary preservation (fix-relax-boundary-preservation): relaxing a
/// patch evens its interior WITHOUT pulling the boundary inward — the reported
/// bug where a clean grid collapsed into a four-pointed star. Public-API + inline
/// mesh, so it runs on device too.
@Suite("Relax preserves the patch boundary")
struct RelaxBoundaryTests {
    private func mesh(fromOBJ text: String) throws -> Mesh {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("relaxb-\(UUID().uuidString).obj")
        try text.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try Mesh.loadOBJ(at: url)
    }

    /// A flat 4x4-quad grid (5x5 verts) in z=0 over [0,4]^2, with the interior
    /// vertex (2,2) perturbed off-grid so relax has something to even out.
    private func perturbedFlatGrid() throws -> Mesh {
        var obj = ""
        for row in 0...4 {
            for col in 0...4 {
                if row == 2 && col == 2 {
                    obj += "v 2.6 2.4 0\n"  // perturbed interior vertex
                } else {
                    obj += "v \(col) \(row) 0\n"
                }
            }
        }
        for row in 0..<4 {
            for col in 0..<4 {
                let a = row * 5 + col + 1
                obj += "f \(a) \(a + 1) \(a + 6) \(a + 5)\n"
            }
        }
        return try mesh(fromOBJ: obj)
    }

    private func bounds(_ m: Mesh) -> (lo: SIMD2<Float>, hi: SIMD2<Float>) {
        var lo = SIMD2<Float>(.greatestFiniteMagnitude, .greatestFiniteMagnitude)
        var hi = SIMD2<Float>(-.greatestFiniteMagnitude, -.greatestFiniteMagnitude)
        for id in 0..<UInt32(m.vertexCount) {
            guard let p = m.vertexPosition(id) else { continue }
            lo = simd_min(lo, SIMD2(p.x, p.y))
            hi = simd_max(hi, SIMD2(p.x, p.y))
        }
        return (lo, hi)
    }

    @Test("Relax does not collapse the patch boundary into a star")
    func boundaryPreserved() throws {
        let m = try perturbedFlatGrid()
        let before = bounds(m)
        #expect(before.lo.x < 0.01 && before.hi.x > 3.99)  // spans [0,4]

        // Relax the whole patch hard (many sweeps) — the star bug shows here.
        try m.relax(around: SIMD3(2, 2, 0), radius: 100, strength: 0.6, iterations: 12)

        let after = bounds(m)
        // The silhouette is preserved: the boundary did NOT migrate inward (the
        // star bug shrinks the extent toward the centre).
        #expect(after.lo.x < 0.05 && after.lo.y < 0.05,
            "lower-left boundary held (\(after.lo)) — no inward collapse")
        #expect(after.hi.x > 3.95 && after.hi.y > 3.95,
            "upper-right boundary held (\(after.hi)) — no inward collapse")
    }

    @Test("A right-edge boundary vertex stays on the right edge")
    func boundaryVertexStaysOnEdge() throws {
        let m = try perturbedFlatGrid()
        // The mid-right boundary vertex at (4,2).
        let v = try #require(m.nearestVertex(to: SIMD3(4, 2, 0), maxDistance: 0.1))
        try m.relax(around: SIMD3(2, 2, 0), radius: 100, strength: 0.6, iterations: 12)
        let after = try #require(m.vertexPosition(v.vertex))
        // It may slide ALONG the edge (y), but must not move inward (x stays ~4).
        #expect(after.x > 3.95, "right-edge vertex kept its x (\(after.x)) — didn't cave in")
    }

    @Test("The perturbed interior vertex evens toward its neighbours")
    func interiorEvensOut() throws {
        let m = try perturbedFlatGrid()
        let v = try #require(m.nearestVertex(to: SIMD3(2.6, 2.4, 0), maxDistance: 0.2))
        let before = simd_distance(try #require(m.vertexPosition(v.vertex)), SIMD3(2, 2, 0))
        try m.relax(around: SIMD3(2, 2, 0), radius: 100, strength: 0.6, iterations: 12)
        let after = simd_distance(try #require(m.vertexPosition(v.vertex)), SIMD3(2, 2, 0))
        #expect(after < before, "interior vertex moved toward its even position")
    }
}

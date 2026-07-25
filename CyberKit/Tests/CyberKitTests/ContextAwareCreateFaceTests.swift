import CyberKit
import Foundation
import Testing
import simd

/// Context-aware create-face (add-context-aware-create-face): an OPEN stroke
/// between two existing vertices becomes a welded quad (sharp bend) or triangle
/// (gentle bend); a straight stroke makes no face; a create over an existing
/// face is suppressed; and a build reproducing an existing face's vertices is
/// rejected. Public-API + inline mesh, so it runs on device too.
@Suite("Context-aware create-face")
struct ContextAwareCreateFaceTests {
    private func mesh(fromOBJ text: String) throws -> Mesh {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ctxface-\(UUID().uuidString).obj")
        try text.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try Mesh.loadOBJ(at: url)
    }

    /// A 3x3 vertex grid (verts 0..8 row-major, y up) with THREE of the four
    /// cells filled — the top-right cell (verts 4,5,8,7) is empty. Mirrors the
    /// reported screenshot: an L drawn around that empty cell should fill it.
    ///   v6 v7 v8      (2)
    ///   v3 v4 v5      (1)
    ///   v0 v1 v2      (0)
    private func gridEmptyTopRight() throws -> Mesh {
        try mesh(fromOBJ: """
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
        """)
    }

    /// Orthographic world→clip: x,y ∈ [0,2] → screen (0.4x+0.1, 0.9−0.4y)
    /// (column-major, w = 1). Matches the interpreter's NDC→screen mapping.
    private static let viewProjection: [Float] = [
        0.8, 0, 0, 0,
        0, 0.8, 0, 0,
        0, 0, 0, 0,
        -0.8, -0.8, 0, 1,
    ]

    /// Screen position of a world grid point under `viewProjection`.
    private func screen(_ x: Float, _ y: Float) -> SIMD2<Double> {
        SIMD2(Double(0.4 * x + 0.1), Double(0.9 - 0.4 * y))
    }

    /// Dense samples along a screen polyline.
    private func samples(_ waypoints: [SIMD2<Double>], per: Int = 12) -> [StrokeInterpreter.Sample] {
        var out: [StrokeInterpreter.Sample] = []
        var t = 0.0
        for i in 1..<waypoints.count {
            let a = waypoints[i - 1], b = waypoints[i]
            for s in 0..<per {
                let f = Double(s) / Double(per)
                out.append(.init(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f, time: t))
                t += 0.01
            }
        }
        out.append(.init(x: waypoints.last!.x, y: waypoints.last!.y, time: t))
        return out
    }

    private func interpret(_ pts: [SIMD2<Double>], _ mesh: Mesh) throws -> StrokeInterpretation {
        try StrokeInterpreter.interpret(
            samples: samples(pts), editMesh: mesh, viewProjection: Self.viewProjection
        )
    }

    @Test("An L-shaped stroke between two vertices makes a quad snapped to the grid")
    func sharpBendMakesQuad() throws {
        let m = try gridEmptyTopRight()
        // L around the empty top-right cell: v7(1,2) → v8(2,2) → v5(2,1).
        let result = try interpret([screen(1, 2), screen(2, 2), screen(2, 1)], m)
        #expect(result.best?.action == .createQuad,
            "sharp L between two verts should be a quad, got \(String(describing: result.best?.action))")
        #expect(result.quadCorners.count == 4)
        // All four corners snap to the empty cell's grid vertices — the bend
        // (v8), the two endpoints (v7, v5), AND the inferred 4th corner (v4),
        // so the quad is uniform with its neighbours (no floating corner).
        let want = [screen(1, 2), screen(2, 2), screen(2, 1), screen(1, 1)]
        for expected in want {
            let hit = result.quadCorners.contains { c in
                abs(Double(c.x) - expected.x) < 0.02 && abs(Double(c.y) - expected.y) < 0.02
            }
            #expect(hit, "a corner should snap to grid vertex \(expected); got \(result.quadCorners)")
        }
    }

    /// A bend point PERPENDICULAR to the v7–v5 chord by `offset` (screen units).
    /// The chord runs (0.5,0.1)→(0.9,0.5); its unit perpendicular is (0.707,−0.707).
    private func bend(perpendicular offset: Double) -> SIMD2<Double> {
        let midX = (screen(1, 2).x + screen(2, 1).x) / 2
        let midY = (screen(1, 2).y + screen(2, 1).y) / 2
        return SIMD2(midX + offset * 0.7071, midY - offset * 0.7071)
    }

    @Test("A gently-bent stroke between two vertices makes a triangle")
    func gentleBendMakesTriangle() throws {
        let m = try gridEmptyTopRight()
        // A moderate perpendicular bend off the chord → a shallow interior angle.
        let result = try interpret([screen(1, 2), bend(perpendicular: 0.09), screen(2, 1)], m)
        #expect(result.best?.action == .createTriangle,
            "gentle bend should be a triangle, got \(String(describing: result.best?.action))")
        #expect(result.quadCorners.count == 3)
    }

    @Test("A nearly-straight stroke makes no face")
    func straightMakesNoFace() throws {
        let m = try gridEmptyTopRight()
        // A tiny perpendicular deviation, under the bend threshold.
        let result = try interpret([screen(1, 2), bend(perpendicular: 0.03), screen(2, 1)], m)
        #expect(result.best?.action != .createQuad && result.best?.action != .createTriangle,
            "a straight stroke should not create a face, got \(String(describing: result.best?.action))")
    }

    @Test("A create over an existing face is suppressed")
    func overExistingFaceSuppressed() throws {
        let m = try gridEmptyTopRight()
        // L around the FILLED bottom-left cell: v3(0,1) → v0(0,0) → v1(1,0).
        let result = try interpret([screen(0, 1), screen(0, 0), screen(1, 0)], m)
        #expect(result.best?.action != .createQuad && result.best?.action != .createTriangle,
            "a create over an existing face should be suppressed")
    }

    @Test("Building a face that duplicates an existing one is rejected")
    func duplicateFaceRejected() throws {
        let m = try gridEmptyTopRight()
        #expect(m.faceCount == 3)
        // The bottom-left quad already exists as verts 0,1,4,3.
        #expect(throws: CyberKitError.self) {
            _ = try m.buildFace(ring: [.existing(0), .existing(1), .existing(4), .existing(3)])
        }
        #expect(m.faceCount == 3, "the mesh is unchanged after a rejected build")
    }
}

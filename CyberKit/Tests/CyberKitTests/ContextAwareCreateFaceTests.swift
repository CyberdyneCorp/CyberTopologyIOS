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

    /// The same grid but with the shared inner corner v4 pulled off the regular
    /// lattice to (1.3, 0.8). The parallelogram estimate A+B−C would land at the
    /// regular (1,1) spot and MISS v4, so only topological edge-walking finds it.
    private func gridOffsetCorner() throws -> Mesh {
        try mesh(fromOBJ: """
        v 0 0 0
        v 1 0 0
        v 2 0 0
        v 0 1 0
        v 1.3 0.8 0
        v 2 1 0
        v 0 2 0
        v 1 2 0
        v 2 2 0
        f 1 2 5 4
        f 2 3 6 5
        f 4 5 8 7
        """)
    }

    @Test("A nearly-closed acute L between two vertices is still a quad")
    func acuteNearlyClosedLMakesQuad() throws {
        // A sharp L whose arms are long relative to the endpoint gap, so its
        // endpoint/path ratio (~0.56) drops under the recognizer's 0.65
        // nearly-closed threshold and stage 1 RESCUES it as a ClosedLoop (which
        // used to misread as a 3-corner triangle — the reported quad_adjacent
        // regression). Endpoints v7, v5; bend pushed out to (2.25, 2.25) world.
        let m = try gridEmptyTopRight()
        let outerBend = SIMD2(0.98, 0.0)  // far up-right of v8: long arms → ratio ~0.57
        let result = try interpret([screen(1, 2), outerBend, screen(2, 1)], m)
        #expect(result.best?.action == .createQuad,
            "an acute L between two verts should be a quad, got \(String(describing: result.best?.action))")
        #expect(result.quadCorners.count == 4)
    }

    /// A single quad (verts 0,1,2,3 at (0,0),(1,0),(1,1),(0,1)).
    private func singleQuad() throws -> Mesh {
        try mesh(fromOBJ: """
        v 0 0 0
        v 1 0 0
        v 1 1 0
        v 0 1 0
        f 1 2 3 4
        """)
    }

    @Test("A three-sided (U-shaped) stroke uses its two corners as the quad")
    func uShapeThreeSidedFillMakesQuad() throws {
        // Extend right off the quad's right edge (v1→v2): draw right, up, left —
        // A(v1) → (2,0) → (2,1) → B(v2). Two real corners; the four quad corners
        // ARE the endpoints + the two bends (the reported quad_adjacent 24 case,
        // where a single-bend guess folded the quad).
        let m = try singleQuad()
        let result = try interpret(
            [screen(1, 0), screen(2, 0), screen(2, 1), screen(1, 1)], m
        )
        #expect(result.best?.action == .createQuad,
            "a U-shaped 3-sided fill should be a quad, got \(String(describing: result.best?.action))")
        #expect(result.quadCorners.count == 4)
        // The four corners are the new cell to the right: v1, (2,0), (2,1), v2 —
        // NOT a folded/estimated shape.
        for expected in [screen(1, 0), screen(2, 0), screen(2, 1), screen(1, 1)] {
            let hit = result.quadCorners.contains { c in
                abs(Double(c.x) - expected.x) < 0.03 && abs(Double(c.y) - expected.y) < 0.03
            }
            #expect(hit, "a corner should be at \(expected); got \(result.quadCorners)")
        }
    }

    @Test("Edge-walking finds the shared corner even off the regular lattice")
    func edgeWalkFindsSharedCorner() throws {
        let m = try gridOffsetCorner()
        // Same L around the empty top-right cell; the shared corner v4 is offset.
        let result = try interpret([screen(1, 2), screen(2, 2), screen(2, 1)], m)
        #expect(result.best?.action == .createQuad)
        #expect(result.quadCorners.count == 4)
        // The 4th corner is v4 at its OFFSET position (1.3, 0.8) — found by
        // edge-walking, not the parallelogram estimate (which points at (1,1)).
        let v4 = screen(1.3, 0.8)
        let hitOffset = result.quadCorners.contains { c in
            abs(Double(c.x) - v4.x) < 0.02 && abs(Double(c.y) - v4.y) < 0.02
        }
        #expect(hitOffset, "4th corner should edge-walk to the offset v4 \(v4); got \(result.quadCorners)")
        // And NOT the regular-lattice estimate (1,1).
        let regular = screen(1, 1)
        let hitRegular = result.quadCorners.contains { c in
            abs(Double(c.x) - regular.x) < 0.02 && abs(Double(c.y) - regular.y) < 0.02
        }
        #expect(!hitRegular, "the estimate at (1,1) should not be used when the real corner is offset")
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

    // MARK: - A face may never be created INSIDE another face

    @Test("A small closed loop drawn INSIDE one quad creates nothing")
    func closedLoopNestedInsideAFaceCreatesNothing() throws {
        let m = try singleQuad()
        // A small square well inside the quad (0.25..0.75 in mesh space), touching no edge and no
        // vertex. Creating here would leave a face geometrically nested inside another and
        // topologically disconnected from it — never a valid cage, which is why the create is
        // withheld rather than merely down-weighted. A low-confidence create is still a create, and
        // that is what stranded sliver faces inside users' cages.
        let result = try interpret(
            [
                screen(0.25, 0.25), screen(0.75, 0.25), screen(0.75, 0.75),
                screen(0.25, 0.75), screen(0.25, 0.25),
            ],
            m
        )
        #expect(
            result.best?.action != .createQuad && result.best?.action != .createTriangle,
            "a face nested inside another must not be created"
        )
    }

    @Test("A small TRIANGLE drawn inside one quad creates nothing either")
    func nestedTriangleCreatesNothing() throws {
        let m = try singleQuad()
        let result = try interpret(
            [screen(0.3, 0.3), screen(0.7, 0.3), screen(0.5, 0.7), screen(0.3, 0.3)],
            m
        )
        #expect(result.best?.action != .createQuad && result.best?.action != .createTriangle)
    }

    @Test("A round scribble inside one quad creates nothing — the circle path too")
    func nestedCircleCreatesNothing() throws {
        let m = try singleQuad()
        // Roughly circular, entirely interior. The circle path scored these at 0.4 x shapeConf and
        // created anyway; it now withholds on the same containment test as the closed loop.
        var points: [SIMD2<Double>] = []
        for step in 0...16 {
            let angle = Double(step) / 16 * 2 * Double.pi
            points.append(
                screen(Float(0.5 + 0.22 * cos(angle)), Float(0.5 + 0.22 * sin(angle)))
            )
        }
        let result = try interpret(points, m)
        #expect(result.best?.action != .createQuad && result.best?.action != .createTriangle)
    }

    @Test("A loop over the EMPTY cell still creates — the fix must not block real work")
    func loopOverEmptyCellStillCreates() throws {
        let m = try gridEmptyTopRight()
        // The top-right cell (v4,v5,v8,v7) is empty, so a loop there is over empty surface and must
        // still create. This is the regression guard: a containment test that also blocked genuine
        // creates would be worse than the bug it fixes.
        let result = try interpret(
            [screen(1.1, 1.1), screen(1.9, 1.1), screen(1.9, 1.9), screen(1.1, 1.9),
             screen(1.1, 1.1)],
            m
        )
        #expect(
            result.best?.action == .createQuad || result.best?.action == .createTriangle,
            "a loop over empty surface must still create"
        )
    }

    // MARK: - One ROUNDED bend is one corner (fix-quad-rim-sharing)

    /// Device, 2026-07-29: an L traced along the cage's rim and then across it built a
    /// face stretched over everything between its endpoints. The corner scan skips one
    /// window after a corner, and a hand-drawn ROUNDED turn is still turning after that
    /// skip, so it reported the same bend twice — 4 samples and 0.08 of the chord apart.
    /// The two-corner branch trusted them as a U's two bends and built
    /// `[A, bend, bend', B]`: two nearly coincident corners.
    /// The RECORDED device stroke (`quad_adjacent_pencil.stroke 28`), decimated to 48
    /// points and expressed in its own frame: `u` runs along the chord from start to
    /// end, `v` across it. A synthesized L will NOT do here — the corner scan skips one
    /// window after a corner, so only a turn as gradual as a real hand's re-triggers
    /// inside the same bend, and that is the whole defect.
    private static let deviceRoundedL: [SIMD2<Double>] = [
        SIMD2(0.0000, 0.0000), SIMD2(0.0114, -0.0244), SIMD2(0.0264, -0.0533),
        SIMD2(0.0442, -0.0809), SIMD2(0.0634, -0.1078), SIMD2(0.0837, -0.1336),
        SIMD2(0.1058, -0.1579), SIMD2(0.1274, -0.1826), SIMD2(0.1494, -0.2070),
        SIMD2(0.1711, -0.2317), SIMD2(0.1920, -0.2570), SIMD2(0.2118, -0.2833),
        SIMD2(0.2306, -0.3104), SIMD2(0.2494, -0.3374), SIMD2(0.2679, -0.3647),
        SIMD2(0.2870, -0.3915), SIMD2(0.3048, -0.4191), SIMD2(0.3216, -0.4470),
        SIMD2(0.3371, -0.4752), SIMD2(0.3555, -0.5023), SIMD2(0.3752, -0.5286),
        SIMD2(0.3948, -0.5547), SIMD2(0.4226, -0.5538), SIMD2(0.4504, -0.5371),
        SIMD2(0.4729, -0.5132), SIMD2(0.4934, -0.4876), SIMD2(0.5118, -0.4603),
        SIMD2(0.5319, -0.4344), SIMD2(0.5525, -0.4088), SIMD2(0.5751, -0.3853),
        SIMD2(0.6008, -0.3648), SIMD2(0.6256, -0.3434), SIMD2(0.6498, -0.3213),
        SIMD2(0.6742, -0.2993), SIMD2(0.6974, -0.2762), SIMD2(0.7201, -0.2522),
        SIMD2(0.7433, -0.2289), SIMD2(0.7666, -0.2058), SIMD2(0.7885, -0.1811),
        SIMD2(0.8112, -0.1574), SIMD2(0.8361, -0.1362), SIMD2(0.8623, -0.1164),
        SIMD2(0.8892, -0.0972), SIMD2(0.9142, -0.0762), SIMD2(0.9378, -0.0540),
        SIMD2(0.9576, -0.0292), SIMD2(0.9814, -0.0100), SIMD2(1.0000, 0.0000),
    ]

    /// Maps the recorded stroke onto the segment `from → to` in screen space,
    /// preserving its shape (a similarity transform: the chord becomes `from → to`).
    private func deviceStroke(from start: SIMD2<Double>, to end: SIMD2<Double>)
        -> [SIMD2<Double>]
    {
        let along = SIMD2(end.x - start.x, end.y - start.y)
        let across = SIMD2(-along.y, along.x)
        return Self.deviceRoundedL.map { point in
            SIMD2(
                start.x + along.x * point.x + across.x * point.y,
                start.y + along.y * point.x + across.y * point.y
            )
        }
    }

    @Test("the recorded device L yields a well-proportioned quad ring, no collapsed side")
    func roundedBendIsOneCorner() throws {
        let m = try gridEmptyTopRight()
        // The recorded device L, laid from v7(1,2) to v5(2,1) — the empty top-right
        // cell, so the create is not suppressed for being over a face.
        let result = try interpret(deviceStroke(from: screen(1, 2), to: screen(2, 1)), m)
        let corners = result.quadCorners
        try #require(corners.count == 4)
        // No two ring corners may be near-coincident: that is the signature of one
        // bend counted twice (and of the stretched face it produces).
        let shortest = (0..<4).map { simd_distance(corners[$0], corners[($0 + 1) % 4]) }.min() ?? 0
        let longest = (0..<4).map { simd_distance(corners[$0], corners[($0 + 1) % 4]) }.max() ?? 1
        #expect(
            shortest > longest * 0.2,
            """
            a side collapsed to \(shortest) against \(longest): the bend was counted twice.
            shape=\(result.shape) conf=\(result.shapeConfidence) ring=\(corners)
            """
        )
    }

    // MARK: - A stroke across a gap bridges the two rims (add-stroke-rim-bridge)

    /// Two 4-quad strips facing each other across a 1-unit gap, cells of 0.5:
    /// the upper strip's rim is y = 1.5 (verts 0...4), the lower strip's is
    /// y = 0.5 (verts 10...14). The corridor between them is bare surface — the
    /// device case where a straight stroke was inserting an edge loop.
    private func facingStrips() throws -> Mesh {
        var lines: [String] = []
        for y in [1.5, 2.0, 0.5, 0.0] {
            for step in 0...4 { lines.append("v \(Double(step) * 0.5) \(y) 0") }
        }
        for base in [1, 11] {
            for column in 0..<4 {
                let a = base + column
                lines.append("f \(a) \(a + 1) \(a + 6) \(a + 5)")
            }
        }
        return try mesh(fromOBJ: lines.joined(separator: "\n"))
    }

    @Test("A straight stroke across the gap between two rims resolves to a rim bridge")
    func gapCrossingStrokeResolvesToBridge() throws {
        let m = try facingStrips()
        // Straight down the corridor, from the upper rim's middle vertex (1, 1.5)
        // to the lower rim's (1, 0.5).
        let result = try interpret([screen(1, 1.5), screen(1, 0.5)], m)
        #expect(result.shape == .line)
        #expect(
            result.best?.action == .bridgeRims,
            "a gap crossing should bridge, got \(String(describing: result.best?.action))"
        )
        // The elements are the two CORRESPONDING rim vertices (v2 and v12).
        let vertices = result.best?.elements.filter { $0.kind == .vertex }.map(\.id)
        #expect(vertices == [2, 12])
    }

    /// The regression this change exists for: the stroke clips the rim edges at
    /// its endpoints, and that crossing alone used to read as a loop cut — putting
    /// a loop into a ring the stroke never ran along.
    @Test("A gap-crossing stroke offers NO insert-loop at all")
    func gapCrossingStrokeOffersNoLoopInsert() throws {
        let m = try facingStrips()
        let result = try interpret([screen(1, 1.5), screen(1, 0.5)], m)
        #expect(!result.candidates.map(\.action).contains(.insertLoop))
    }

    @Test("REGRESSION GUARD: a line across a group of faces still inserts a loop")
    func lineOverFacesStillInsertsLoop() throws {
        let m = try facingStrips()
        // Across the LOWER strip's quads (y = 0.25, inside the faces), left to
        // right: over faces the whole way, so this is still the loop-cut gesture.
        let result = try interpret([screen(0.1, 0.25), screen(1.9, 0.25)], m)
        #expect(result.shape == .line)
        #expect(
            result.best?.action == .insertLoop,
            "a line over faces is a loop cut, got \(String(describing: result.best?.action))"
        )
        #expect(!result.candidates.map(\.action).contains(.bridgeRims))
    }

    @Test("A stroke that runs ALONG a rim is not a bridge")
    func strokeAlongARimIsNotABridge() throws {
        let m = try facingStrips()
        // Along the upper strip's own rim (y = 1.5), from vertex 0 to vertex 4:
        // no face under it either, but it is tracing a rim, not crossing a gap.
        let result = try interpret([screen(0, 1.5), screen(2, 1.5)], m)
        #expect(!result.candidates.map(\.action).contains(.bridgeRims))
    }

    @Test("A straight stroke with no rim under an endpoint still creates nothing")
    func straightStrokeWithoutRimsCreatesNothing() throws {
        let m = try grid2x2Filled()
        // Interior lattice centre (1,1) to a corner: the centre carries no
        // boundary edge, so there is no rim to bridge from — and the stroke runs
        // over faces the whole way, so it is not a gap crossing either.
        let result = try interpret([screen(1, 1), screen(2, 2)], m)
        #expect(!result.candidates.map(\.action).contains(.bridgeRims))
        #expect(result.best?.action != .createQuad && result.best?.action != .createTriangle)
    }

    /// 2x2 quads over a 3x3 lattice — vertex 4 is interior.
    private func grid2x2Filled() throws -> Mesh {
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
        f 5 6 9 8
        """)
    }

    @Test("A loop that reaches an existing EDGE still creates: it shares topology")
    func loopTouchingAnEdgeStillCreates() throws {
        let m = try singleQuad()
        // Spans from inside the quad out past its right edge, so it crosses existing topology. That
        // is the legitimate draw-against-existing-geometry case (the grid continuation that shares a
        // boundary), and it is exactly why this is a CONTAINMENT test rather than a blanket
        // "no creating over faces" rule.
        let result = try interpret(
            [screen(0.5, 0.2), screen(1.6, 0.2), screen(1.6, 0.8), screen(0.5, 0.8),
             screen(0.5, 0.2)],
            m
        )
        #expect(
            result.best?.action == .createQuad || result.best?.action == .createTriangle,
            "a loop sharing topology must still create"
        )
    }
}

import CyberKit
import CyberKitTesting
import Foundation
import Testing
import simd

/// Task 4.6: the non-destructive subdivision preview through the REAL engine
/// (spec: retopology-tools / "Subdivision preview", scenario "Editing under
/// preview" — the app-layer half of that scenario lives in
/// `App/Tests/SubdivisionPreviewViewportTests.swift`).
///
/// **SMOOTH (task 4.6a):** the preview is a genuine Catmull-Clark surface
/// (engine `cyber_retopo_subdivide_smooth`, patch 0031). It smooths the cage
/// on its own — `smoothSubdivideCubeMatchesCatmullClark` pins the exact
/// interior mask against the closed-form cube result, and
/// `openCageBoundaryFollowsTheCreaseRule` pins the boundary rule — and with a
/// Target it then conforms onto the scan (`reprojectionLiftsThePreview`).
///
/// No mocks: real engine meshes, the real `cyber_retopo_subdivide_smooth` op
/// and a real `SurfaceSnapper` BVH throughout.
@Suite("Subdivision preview (engine)")
struct SubdivisionPreviewTests {
    // MARK: - Fixtures

    private func mesh(fromOBJ text: String) throws -> Mesh {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("subdiv-preview-\(UUID().uuidString).obj")
        try text.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try Mesh.loadOBJ(at: url)
    }

    /// The committed 3x2 quad-grid strip (4x3 vertices) at z = 0.
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

    /// A DOMED Target above the flat cage. Reprojection has to LIFT the new
    /// vertices onto real curvature — against a flat Target every smoothing
    /// assertion would be vacuous.
    private func domeTarget() throws -> SurfaceSnapper {
        // Scaled to the grid32 cage (which spans only ±0.375 × ±0.25): a
        // dome sized for a large model would be locally flat over the cage
        // and every curvature assertion below would be vacuous.
        let n = 16
        var obj = ""
        for row in 0...n {
            for col in 0...n {
                let x = Double(col) / Double(n) * 2 - 1
                let y = Double(row) / Double(n) * 2 - 1
                let z = 0.8 - 1.6 * (x * x + y * y)
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

    private func livePositions(_ mesh: Mesh) -> [SIMD3<Float>] {
        (0..<UInt32(mesh.vertexCount)).compactMap { mesh.vertexPosition($0) }
    }

    // MARK: - Non-destructiveness (the load-bearing contract)

    /// THE invariant behind "non-destructive": deriving a preview at the
    /// deepest level, repeatedly, leaves the base cage byte-identical.
    /// Element ids matter as much as bytes here — `cyber_retopo_subdivide`
    /// REASSIGNS every id, so a preview that ran on the base handle would
    /// silently orphan every pin and loop tag keyed on it.
    @Test("Deriving a preview never mutates the base cage")
    func previewNeverMutatesTheBase() throws {
        let cage = try grid32()
        let snapper = try domeTarget()
        let beforeBytes = try cage.payloadData()
        let beforePositions = livePositions(cage)
        let beforeFaces = cage.faceCount
        let beforeVertices = cage.vertexCount

        for level in [SubdivisionPreviewLevel.one, .two, .two, .one] {
            let preview = try #require(
                try cage.subdivisionPreview(level: level, reprojectingOnto: snapper)
            )
            #expect(preview.faceCount > beforeFaces)
        }

        #expect(try cage.payloadData() == beforeBytes)
        #expect(cage.faceCount == beforeFaces)
        #expect(cage.vertexCount == beforeVertices)
        #expect(livePositions(cage) == beforePositions)
    }

    /// The preview is a SEPARATE handle: mutating it (as a batch command
    /// would) cannot reach back into the cage it was derived from.
    @Test("The preview mesh is an independent handle")
    func previewIsAnIndependentHandle() throws {
        let cage = try grid32()
        let preview = try #require(try cage.subdivisionPreview(level: .one))
        let cageBytes = try cage.payloadData()
        try preview.subdivide()
        #expect(try cage.payloadData() == cageBytes)
    }

    // MARK: - Level semantics

    @Test("Level 0 and empty cages produce no preview")
    func offAndEmptyProduceNothing() throws {
        let cage = try grid32()
        #expect(try cage.subdivisionPreview(level: .off) == nil)
        #expect(try Mesh().subdivisionPreview(level: .two) == nil)
    }

    /// Linear subdivision splits every quad into four, so the face count
    /// follows the level's advertised multiplier exactly.
    @Test("Each level quadruples the face count")
    func levelsQuadrupleFaces() throws {
        let cage = try grid32()
        let base = cage.faceCount
        let one = try #require(try cage.subdivisionPreview(level: .one))
        let two = try #require(try cage.subdivisionPreview(level: .two))
        #expect(one.faceCount == base * 4)
        #expect(two.faceCount == base * 16)
        #expect(one.faceCount == SubdivisionPreviewPolicy.previewFaceCount(
            baseFaces: base, level: .one
        ))
        #expect(two.faceCount == SubdivisionPreviewPolicy.previewFaceCount(
            baseFaces: base, level: .two
        ))
    }

    @Test("Level clamps out-of-range persisted values")
    func levelClamps() {
        #expect(SubdivisionPreviewLevel(clamping: -3) == .off)
        #expect(SubdivisionPreviewLevel(clamping: 0) == .off)
        #expect(SubdivisionPreviewLevel(clamping: 1) == .one)
        #expect(SubdivisionPreviewLevel(clamping: 2) == .two)
        #expect(SubdivisionPreviewLevel(clamping: 9) == .two)
        #expect(SubdivisionPreviewLevel.off.faceMultiplier == 1)
        #expect(SubdivisionPreviewLevel.one.faceMultiplier == 4)
        #expect(SubdivisionPreviewLevel.two.faceMultiplier == 16)
        #expect(SubdivisionPreviewLevel.allCases.map(\.label) == ["Off", "1", "2"])
    }

    /// Catmull-Clark smooths on its own, so any non-off level smooths with or
    /// without a Target; a Target only additionally conforms the surface.
    @Test("Smoothing is available at any non-off level")
    func smoothingAvailableAtAnyLevel() {
        #expect(SubdivisionPreviewLevel.off.smoothingIsAvailable(hasTarget: true) == false)
        #expect(SubdivisionPreviewLevel.two.smoothingIsAvailable(hasTarget: false))
        #expect(SubdivisionPreviewLevel.two.smoothingIsAvailable(hasTarget: true))
    }

    // MARK: - Reprojection is where the smoothing comes from

    /// The cage is flat at z = 0 and the dome peaks at z = 1.5: a
    /// reprojected preview must LIFT every vertex onto the dome.
    @Test("Reprojection lifts the preview onto the Target's curvature")
    func reprojectionLiftsThePreview() throws {
        let cage = try grid32()
        let snapper = try domeTarget()
        let preview = try #require(
            try cage.subdivisionPreview(level: .two, reprojectingOnto: snapper)
        )
        let lifted = livePositions(preview)
        #expect(lifted.count > cage.vertexCount)
        for position in lifted {
            let expected = 0.8 - 1.6 * (position.x * position.x + position.y * position.y)
            #expect(abs(position.z - expected) < 0.08)
        }
        // The preview is genuinely CURVED, not a lifted plane: the sampled
        // z values must actually spread.
        let zs = lifted.map(\.z)
        #expect((zs.max() ?? 0) - (zs.min() ?? 0) > 0.2)
    }

    /// Catmull-Clark smooths WITHOUT a Target too (task 4.6a): a flat cage
    /// stays planar (no curvature to add out of plane), but the boundary
    /// crease rule pulls each corner vertex inward — which linear subdivision
    /// never does. So there is no longer a preview vertex sitting exactly on
    /// the base corner, and the surface is a real smooth surface, not a
    /// densified plane.
    @Test("Without a Target the cage still smooths (planar, corners pulled in)")
    func withoutATargetTheCageStillSmooths() throws {
        let cage = try grid32()
        let basePositions = livePositions(cage)
        let corner = try #require(basePositions.max { ($0.x + $0.y) < ($1.x + $1.y) })
        let preview = try #require(try cage.subdivisionPreview(level: .one))
        #expect(preview.faceCount == cage.faceCount * 4)
        // Planar: a flat cage has no out-of-plane curvature to smooth.
        for position in livePositions(preview) {
            #expect(abs(position.z) < 1e-5)
        }
        // But the corner MOVED (crease rule) — linear would leave it in place.
        #expect(
            preview.nearestVertex(to: corner, maxDistance: 1e-4) == nil,
            "the boundary corner was pulled inward (Catmull-Clark, not linear)"
        )
    }

    /// The interior Catmull-Clark mask, pinned against its closed-form result:
    /// one smooth subdivision of the unit cube [-0.5, 0.5]³ moves each
    /// valence-3 corner to (±5/18, ±5/18, ±5/18). (Q = avg of 3 adjacent face
    /// centroids = (1/6)³; R = avg of 3 adjacent edge midpoints = (1/3)³;
    /// V' = (Q + 2R)/3 since n = 3.) 8 corners + 12 edge points + 6 face
    /// points = 26 vertices, 24 quads.
    @Test("Catmull-Clark smooths a cube to its exact interior-mask result")
    func smoothSubdivideCubeMatchesCatmullClark() throws {
        let cube = try mesh(fromOBJ: """
        v -0.5 -0.5 -0.5
        v  0.5 -0.5 -0.5
        v  0.5  0.5 -0.5
        v -0.5  0.5 -0.5
        v -0.5 -0.5  0.5
        v  0.5 -0.5  0.5
        v  0.5  0.5  0.5
        v -0.5  0.5  0.5
        f 1 4 3 2
        f 5 6 7 8
        f 1 2 6 5
        f 2 3 7 6
        f 3 4 8 7
        f 4 1 5 8
        """)
        try cube.smoothSubdivide()
        #expect(cube.vertexCount == 26)
        #expect(cube.faceCount == 24)
        let c = Float(5.0 / 18.0)
        for sx in [-c, c] {
            for sy in [-c, c] {
                for sz in [-c, c] {
                    #expect(
                        cube.nearestVertex(to: SIMD3(sx, sy, sz), maxDistance: 1e-5) != nil,
                        "smoothed corner (\(sx), \(sy), \(sz))"
                    )
                }
            }
        }
    }

    /// The boundary crease rule (task 4.6a): on an OPEN cage the boundary is a
    /// cubic B-spline curve independent of the interior — a boundary vertex
    /// with two boundary neighbours moves to 0.75 P + 0.125 (b0 + b1), and
    /// boundary edge points stay midpoints. A single-quad cage makes this
    /// exact: every corner is a boundary vertex with neighbours one unit away
    /// along each axis, so each corner contracts by 1/8 of the span toward the
    /// centre.
    @Test("Open-cage boundary follows the Catmull-Clark crease rule")
    func openCageBoundaryFollowsTheCreaseRule() throws {
        let quad = try mesh(fromOBJ: """
        v 0 0 0
        v 1 0 0
        v 1 1 0
        v 0 1 0
        f 1 2 3 4
        """)
        try quad.smoothSubdivide()
        // Corner (0,0): neighbours (1,0) and (0,1) → 0.75(0,0)+0.125((1,0)+(0,1)).
        #expect(quad.nearestVertex(to: SIMD3(0.125, 0.125, 0), maxDistance: 1e-5) != nil)
        // The opposite corner (1,1) → (0.875, 0.875).
        #expect(quad.nearestVertex(to: SIMD3(0.875, 0.875, 0), maxDistance: 1e-5) != nil)
        // A boundary edge point stays the midpoint (e.g. edge (0,0)-(1,0)).
        #expect(quad.nearestVertex(to: SIMD3(0.5, 0, 0), maxDistance: 1e-5) != nil)
        // The single face point is the centroid.
        #expect(quad.nearestVertex(to: SIMD3(0.5, 0.5, 0), maxDistance: 1e-5) != nil)
    }

    /// Reprojecting after EVERY level (not once at the end) is what keeps a
    /// level-2 preview from chording across curvature: its worst deviation
    /// from the dome must not be worse than a level-1 preview's.
    @Test("Level 2 tracks the Target at least as tightly as level 1")
    func deeperLevelsTrackTheTargetTighter() throws {
        let cage = try grid32()
        let snapper = try domeTarget()
        func worstDeviation(_ level: SubdivisionPreviewLevel) throws -> Float {
            let preview = try #require(
                try cage.subdivisionPreview(level: level, reprojectingOnto: snapper)
            )
            return livePositions(preview).map { position in
                let expected = 0.8 - 1.6 * (position.x * position.x + position.y * position.y)
                return abs(position.z - expected)
            }.max() ?? 0
        }
        #expect(try worstDeviation(.two) <= worstDeviation(.one) + 1e-4)
    }

    // MARK: - Determinism goldens

    /// Derivation golden: the exact preview payload for the committed cage
    /// on the committed dome, level 1 and level 2. Any engine-side change to
    /// subdivision or to snapping moves these bytes.
    @Test("Preview derivation is deterministic (goldens)")
    func previewGoldens() throws {
        #if targetEnvironment(simulator)
        let cage = try grid32()
        let snapper = try domeTarget()
        let one = try #require(
            try cage.subdivisionPreview(level: .one, reprojectingOnto: snapper)
        )
        try GoldenFile.compare(
            try one.payloadData(),
            golden: goldensDirectory
                .appendingPathComponent("subdivision_preview_l1_grid32.payload.golden")
        )
        let two = try #require(
            try cage.subdivisionPreview(level: .two, reprojectingOnto: snapper)
        )
        try GoldenFile.compare(
            try two.payloadData(),
            golden: goldensDirectory
                .appendingPathComponent("subdivision_preview_l2_grid32.payload.golden")
        )
        // Re-deriving must reproduce the same bytes within one process too
        // (the live path re-derives on every base-cage edit).
        let again = try #require(
            try cage.subdivisionPreview(level: .two, reprojectingOnto: snapper)
        )
        #expect(try again.payloadData() == two.payloadData())
        #endif
    }

    // MARK: - Throttle policy

    /// The documented policy, as a table. See `SubdivisionPreviewPolicy` for
    /// why the two branches exist.
    @Test("Throttle policy: mid-stroke rebuilds are cost-gated, others are not")
    func throttlePolicy() {
        let budget = SubdivisionPreviewPolicy.liveFaceBudget
        // Off never rebuilds, at any cost, in any phase.
        #expect(SubdivisionPreviewPolicy.allowsRebuild(
            baseFaces: 4, level: .off, duringStroke: false
        ) == false)
        // An empty cage has nothing to preview.
        #expect(SubdivisionPreviewPolicy.allowsRebuild(
            baseFaces: 0, level: .two, duringStroke: false
        ) == false)
        // Outside a stroke the cost guard never applies: a stroke-end
        // rebuild must always produce an EXACT preview.
        #expect(SubdivisionPreviewPolicy.allowsRebuild(
            baseFaces: budget, level: .two, duringStroke: false
        ))
        // Inside a stroke: under budget rebuilds live, over budget is
        // skipped (the previous preview stays on screen).
        let underBudget = budget / 16
        #expect(SubdivisionPreviewPolicy.allowsRebuild(
            baseFaces: underBudget, level: .two, duringStroke: true
        ))
        #expect(SubdivisionPreviewPolicy.allowsRebuild(
            baseFaces: underBudget + 1, level: .two, duringStroke: true
        ) == false)
        // The SAME cage is affordable live at a shallower level — the guard
        // measures preview cost, not cage size.
        #expect(SubdivisionPreviewPolicy.allowsRebuild(
            baseFaces: underBudget + 1, level: .one, duringStroke: true
        ))
    }

    /// REGRESSION: the preview's non-destructive copy is a FILESYSTEM
    /// round trip (`Mesh.detachedCopy` — the capi has no `cyber_mesh_clone`),
    /// whose cost scales with the BASE cage, not with the preview. The
    /// face budget alone waved through big cages at level .one, whose
    /// per-rebuild disk round trip is the dominant expense.
    @Test("Throttle policy: the base cage's copy cost has its own budget")
    func throttlePolicyGuardsTheDetachedCopyCost() {
        let baseBudget = SubdivisionPreviewPolicy.liveBaseFaceBudget
        // A level-1 preview of a cage just over the base budget is only
        // 4x the base — comfortably inside `liveFaceBudget` — so ONLY the
        // base budget can reject it.
        #expect(SubdivisionPreviewPolicy.previewFaceCount(
            baseFaces: baseBudget + 1, level: .one
        ) < SubdivisionPreviewPolicy.liveFaceBudget)
        #expect(SubdivisionPreviewPolicy.allowsRebuild(
            baseFaces: baseBudget, level: .one, duringStroke: true
        ))
        #expect(SubdivisionPreviewPolicy.allowsRebuild(
            baseFaces: baseBudget + 1, level: .one, duringStroke: true
        ) == false)
        // Outside a stroke the guard never applies — stroke-end previews
        // are always exact.
        #expect(SubdivisionPreviewPolicy.allowsRebuild(
            baseFaces: baseBudget * 100, level: .two, duringStroke: false
        ))
    }

    /// REGRESSION: derivation rode the once-per-RENDERED-FRAME hook, so a
    /// live edit under preview paid the round trip up to 120 times a
    /// second on a ProMotion display. The rate guard bounds it.
    @Test("Throttle policy: mid-stroke rebuilds are rate-limited")
    func throttlePolicyRateLimitsLiveRebuilds() {
        let now = Date()
        let interval = SubdivisionPreviewPolicy.minimumLiveRebuildInterval
        #expect(SubdivisionPreviewPolicy.shouldRebuildNow(since: nil, now: now))
        // One 120 Hz frame later: far too soon.
        #expect(!SubdivisionPreviewPolicy.shouldRebuildNow(
            since: now, now: now.addingTimeInterval(1.0 / 120)
        ))
        // (a hair past the interval — `Date` arithmetic is not exact at the
        // boundary, and the policy is a rate limit, not a stopwatch)
        #expect(SubdivisionPreviewPolicy.shouldRebuildNow(
            since: now, now: now.addingTimeInterval(interval * 1.01)
        ))
    }

    /// `detachedCopy` is the preview's non-destructive base: an
    /// independent handle with the same geometry, which subdividing does
    /// not write back through.
    @Test("A detached copy is independent of the mesh it came from")
    func detachedCopyIsIndependent() throws {
        let cage = try grid32()
        let copy = try cage.detachedCopy()
        #expect(copy.vertexCount == cage.vertexCount)
        #expect(copy.faceCount == cage.faceCount)

        try copy.subdivide()
        #expect(copy.faceCount > cage.faceCount)
        #expect(cage.faceCount == 6, "the source cage is untouched")
    }
}

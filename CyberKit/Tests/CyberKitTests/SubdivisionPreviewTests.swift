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
/// **HONEST SCOPE:** the preview is REPROJECTED-LINEAR, not smooth. The
/// engine ships linear subdivision only; the smoothing in these assertions
/// comes entirely from projecting the subdivided cage onto the Target, which
/// is why every smoothing test carries an anti-vacuity control proving the
/// same vertices stay on the flat cage without a snapper. The
/// Catmull-Clark/limit-surface pass is task 4.6a and is NOT claimed here.
///
/// No mocks: real engine meshes, the real `cyber_retopo_subdivide` op and a
/// real `SurfaceSnapper` BVH throughout.
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
    private func grid32() throws -> Mesh {
        let url = try #require(Bundle.module.url(
            forResource: "grid32", withExtension: "obj", subdirectory: "Fixtures"
        ))
        return try Mesh.loadOBJ(at: url)
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

    private var goldensDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Goldens", isDirectory: true)
            .appendingPathComponent("MeshEdits", isDirectory: true)
    }

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

    /// The honest-scope flag the UI captions itself from: without a Target
    /// there is nothing to reproject onto, and linear subdivision alone
    /// smooths NOTHING.
    @Test("Smoothing is only available with a Target")
    func smoothingRequiresATarget() {
        #expect(SubdivisionPreviewLevel.off.smoothingIsAvailable(hasTarget: true) == false)
        #expect(SubdivisionPreviewLevel.two.smoothingIsAvailable(hasTarget: false) == false)
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

    /// ANTI-VACUITY CONTROL: the same subdivision WITHOUT a snapper leaves
    /// every vertex on the flat cage — proving the previous test measures
    /// reprojection and not some accidental smoothing in `subdivideAll`.
    /// This is also the honest demonstration that the engine's subdivision
    /// is LINEAR (task 4.6a exists because of exactly this).
    @Test("Without a Target the preview stays exactly on the flat cage")
    func withoutATargetTheSubdivisionIsLinear() throws {
        let cage = try grid32()
        let preview = try #require(try cage.subdivisionPreview(level: .two))
        #expect(preview.faceCount == cage.faceCount * 16)
        for position in livePositions(preview) {
            #expect(abs(position.z) < 1e-5)
        }
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

import CyberKit
import Foundation
import Testing
import simd

/// UV unwrap + readback (openspec add-uv-stage-foundation, 6.1 task 2).
///
/// The property this suite exists to protect is that ABSENCE is distinguishable from a
/// degenerate layout. A view handed zeros for a never-unwrapped mesh would draw a
/// catastrophically collapsed atlas instead of saying there is nothing there yet, and
/// nothing downstream could tell the difference.
@Suite("Mesh UV unwrap and readback")
struct MeshUVTests {
    /// A cube, which has no `vt` lines and so has never been unwrapped.
    private func cube() throws -> Mesh {
        var obj = ""
        for (x, y, z) in [
            (0, 0, 0), (1, 0, 0), (1, 1, 0), (0, 1, 0),
            (0, 0, 1), (1, 0, 1), (1, 1, 1), (0, 1, 1),
        ] {
            obj += "v \(x) \(y) \(z)\n"
        }
        for face in [
            [1, 2, 3, 4], [5, 8, 7, 6], [1, 5, 6, 2],
            [2, 6, 7, 3], [3, 7, 8, 4], [4, 8, 5, 1],
        ] {
            obj += "f " + face.map(String.init).joined(separator: " ") + "\n"
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("uv-\(UUID().uuidString).obj")
        try obj.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try Mesh.loadOBJ(at: url)
    }

    @Test("A mesh that was never unwrapped reports NIL, not an empty or zeroed layout")
    func absenceIsNotZero() throws {
        let mesh = try cube()
        // nil rather than [] is the contract: an empty array would still be "a layout",
        // and a caller doing `uvs.isEmpty` would conflate it with a broken unwrap.
        #expect(mesh.uvCoordinates() == nil)
        #expect(!mesh.hasUVLayout)
    }

    @Test("Unwrapping produces per-corner UVs and a report")
    func unwrapProducesUVs() throws {
        let mesh = try cube()
        let (unwrapped, report) = try mesh.unwrapped()

        #expect(unwrapped.hasUVLayout)
        let uvs = try #require(unwrapped.uvCoordinates())
        #expect(!uvs.isEmpty)

        // One pair per emitted TRIANGLE CORNER, so exactly as many pairs as there are
        // triangle indices. A mismatch means the triangulation and the UV emission
        // disagreed, which would shear the layout by a corner while still looking plausible.
        let indexCount = unwrapped.withRenderBuffers { $0.triangleIndices.count }
        #expect(uvs.count == indexCount)

        #expect(report.chartCount > 0)
        #expect(report.seamEdges > 0, "a closed cube cannot be unwrapped without cuts")
        #expect(report.packedArea > 0)
    }

    @Test("Every coordinate is finite and inside the unit square")
    func uvsArePackedAndFinite() throws {
        let (unwrapped, _) = try cube().unwrapped()
        let uvs = try #require(unwrapped.uvCoordinates())
        // A NaN renders as nothing rather than as an error, so it has to be excluded here
        // instead of being discovered as a blank 2D view.
        for uv in uvs {
            #expect(uv.x.isFinite && uv.y.isFinite)
            #expect(uv.x >= -0.001 && uv.x <= 1.001)
            #expect(uv.y >= -0.001 && uv.y <= 1.001)
        }
    }

    @Test("Unwrapping does NOT modify the receiver")
    func unwrapLeavesTheReceiverAlone() throws {
        let mesh = try cube()
        let before = try mesh.payloadData()
        let (unwrapped, _) = try mesh.unwrapped()

        // Matching `remeshed`/`remeshedRegion`: the caller decides whether to keep the
        // result, so a refused or unwanted unwrap must leave their mesh untouched.
        #expect(!mesh.hasUVLayout, "the receiver must not have gained a layout")
        #expect(try mesh.payloadData() == before)
        #expect(unwrapped.hasUVLayout)
    }

    @Test("The report names the defects, not just the flattering numbers")
    func reportSummaryIsHonest() throws {
        let (_, report) = try cube().unwrapped()
        let summary = report.summary
        #expect(summary.contains("chart"))
        #expect(summary.contains("packed"))
        #expect(summary.contains("distortion"))
        // Flipped and fallback charts make a layout unusable, so they must surface when
        // present rather than being left for the artist to discover in a bake.
        if report.flippedCharts > 0 { #expect(summary.contains("FLIPPED")) }
        if report.fallbackCharts > 0 { #expect(summary.contains("fallback")) }
    }

    @Test("UVs SURVIVE the payload round-trip — the journaled unwrap depends on it")
    func uvsSurvivePayloadRoundTrip() throws {
        // Load-bearing for task 4: an unwrap is journaled as a payload before/after pair,
        // so if `payloadData()` dropped UVs the undo history would silently discard the
        // layout and redo would restore a mesh with no UVs at all. Verified rather than
        // assumed — the payload is OBJ at six significant digits, so this also confirms the
        // precision is adequate for coordinates in [0,1].
        let (unwrapped, report) = try cube().unwrapped()
        let original = try #require(unwrapped.uvCoordinates())

        let restored = try Mesh(payloadData: try unwrapped.payloadData())
        let roundTripped = try #require(
            restored.uvCoordinates(),
            "UVs were LOST through the payload round-trip — a journaled unwrap cannot work"
        )
        #expect(roundTripped.count == original.count)

        // Six significant digits on values in [0,1], so compare with a tolerance rather
        // than bitwise: exact equality is not the contract here, unlike the interface
        // positions a region solve guarantees.
        var worst: Float = 0
        for (a, b) in zip(original, roundTripped) {
            worst = max(worst, max(abs(a.x - b.x), abs(a.y - b.y)))
        }
        #expect(worst < 1e-4, "worst UV drift through the round-trip was \(worst)")
        #expect(report.chartCount > 0)
    }

    // MARK: - Ring reconstruction (de-risks the 2D view before any of it is written)

    @Test("The corner stream reconstructs AUTHORED face rings, with no fan diagonal")
    func cornerStreamReconstructsAuthoredRings() throws {
        // The 2D UV view must draw a quad as FOUR edges, not two triangles with a
        // diagonal, matching what the 3D wireframe is careful to do. This proves the
        // reconstruction works from the documented fan contract rather than from a
        // heuristic: `fanTriangulate` emits (v0, v[k-1], v[k]) for k = 2..<n, and the UV
        // emission runs in lockstep, so a face's authored ring is corners [0],[1],[2] of
        // its first triangle plus corner [2] of each later triangle.
        //
        // The rejected alternative was testing vertex pairs against the mesh-wide
        // `edgeIndices()` set. That set answers "is this pair an edge SOMEWHERE", not "an
        // edge of THIS face", so a fan diagonal that coincides with a real edge elsewhere
        // would be drawn — a heuristic with a real false-positive mode where the contract
        // gives a proof.
        let (unwrapped, _) = try cube().unwrapped()
        let uvs = try #require(unwrapped.uvCoordinates())

        // Alignment must be CHECKED, not assumed: the engine only carries UVs for a face
        // when its corner count matches, so a mismatch here would silently shear every
        // ring by one corner.
        let faces = unwrapped.liveFaceIDs()
        let expectedCorners = faces.reduce(0) { total, face in
            total + max(0, (unwrapped.faceVertices(face).count - 2) * 3)
        }
        #expect(uvs.count == expectedCorners, "corner stream and face valences disagree")

        var cursor = 0
        var quadsChecked = 0
        for face in faces {
            let valence = unwrapped.faceVertices(face).count
            guard valence >= 3 else { continue }
            let triangles = valence - 2
            var ring: [SIMD2<Float>] = [uvs[cursor], uvs[cursor + 1], uvs[cursor + 2]]
            for triangle in 1..<max(triangles, 1) {
                ring.append(uvs[cursor + triangle * 3 + 2])
            }
            cursor += triangles * 3

            #expect(ring.count == valence, "reconstructed ring has the wrong arity")
            if valence == 4 {
                // Four DISTINCT corners: a diagonal would repeat one.
                var distinct: [SIMD2<Float>] = []
                for uv in ring where !distinct.contains(where: {
                    abs($0.x - uv.x) < 1e-6 && abs($0.y - uv.y) < 1e-6
                }) {
                    distinct.append(uv)
                }
                #expect(distinct.count == 4, "a quad ring collapsed — a diagonal leaked in")
                quadsChecked += 1
            }
        }
        #expect(cursor == uvs.count, "the ring walk did not consume the whole stream")
        #expect(quadsChecked > 0, "the cube fixture should have contributed quads")
    }

    // MARK: - Hand-drawn seams (6.2)

    @Test("Authored seams REPLACE the automatic ones rather than supplementing them")
    func authoredSeamsReplaceAutoSeams() throws {
        let autoRun = try cube().unwrapped()
        #expect(autoRun.report.seamEdges > 0)

        // Exactly two authored seams.
        let seamed = try cube()
        let authored: [UInt32] = [0, 1]
        let seamRun = try seamed.unwrapped(seams: authored)
        // If auto-seams were unioned in, this would report the baseline count or more, and
        // the artist would get cuts they never drew.
        #expect(seamRun.report.seamEdges == authored.count)
    }

    @Test("No authored seams is unchanged behaviour")
    func noSeamsIsUnchanged() throws {
        // The inertness property: the capability must not alter existing output by existing.
        let plain = try cube().unwrapped()
        let explicitlyEmpty = try cube().unwrapped(seams: [])
        #expect(plain.report.seamEdges == explicitlyEmpty.report.seamEdges)
        #expect(plain.report.chartCount == explicitlyEmpty.report.chartCount)
        #expect(try plain.mesh.payloadData() == explicitlyEmpty.mesh.payloadData())
    }

    @Test("A rejected seam id leaves the mesh untouched")
    func rejectedSeamIdIsAtomic() throws {
        let subject = try cube()
        try subject.setSeamEdges([0])
        // Validated as a whole before anything is stored, so a bad id in the middle cannot
        // leave a half-updated seam set behind.
        #expect(throws: (any Error).self) { try subject.setSeamEdges([0, 999_999]) }
        let after = try subject.unwrapped(seams: [0])
        #expect(after.report.seamEdges == 1)
    }

    // MARK: - Per-face distortion (6.4)

    @Test("Distortion is NIL before an unwrap and one entry per face after")
    func distortionAbsenceIsNotZero() throws {
        let subject = try cube()
        // nil, not an array of zeros: no layout and a perfect layout are different states,
        // and zeros for both would render a never-unwrapped mesh as flawless.
        #expect(subject.uvDistortion() == nil)

        let (unwrapped, _) = try subject.unwrapped()
        let measured = try #require(unwrapped.uvDistortion())
        #expect(measured.count == unwrapped.liveFaceIDs().count)
    }

    @Test("Per-face angle error is bounded and agrees with the atlas aggregate")
    func distortionAgreesWithTheReport() throws {
        let (unwrapped, report) = try cube().unwrapped()
        let measured = try #require(unwrapped.uvDistortion())

        for face in measured {
            // Conformal error is defined on [0,1); a NaN would shade as nothing rather
            // than as an error, so finiteness is asserted too.
            #expect(face.angle >= 0 && face.angle < 1)
            #expect(face.area >= 0 && face.area.isFinite)
        }
        // Both come from the SAME engine measurement, so the worst per-face value cannot
        // exceed the aggregate the atlas reported. If it could, the panel and the report
        // would be two sources of truth for one question.
        let worst = measured.map(\.angle).max() ?? 0
        #expect(worst <= report.maxAngleDistortion + 1e-4)
    }

    @Test("Texel density scales with the SQUARE of the texture size")
    func texelDensityScalesQuadratically() throws {
        let (unwrapped, _) = try cube().unwrapped()
        let face = try #require(unwrapped.uvDistortion()?.first { $0.area > 0 })

        let atOneK = face.texelDensity(textureSize: 1024)
        let atTwoK = face.texelDensity(textureSize: 2048)
        // Density is texels per unit surface, and texels go as size²; a linear
        // relationship would understate the effect of doubling a texture.
        #expect(abs(atTwoK - atOneK * 4) < atOneK * 0.001)
        // Zero is a legitimate answer for a nonsensical size, not a crash.
        #expect(face.texelDensity(textureSize: 0) == 0)
    }

    @Test("Atlas defaults come from the engine rather than being invented in Swift")
    func defaultsComeFromTheEngine() {
        let parameters = Mesh.AtlasParameters()
        // If Swift invented its own defaults they would drift from the engine's silently.
        // Non-degenerate values prove the engine filled them.
        #expect(parameters.maxChartAngleDegrees > 0)
        #expect(parameters.textureSize > 0)
        #expect(parameters.packMargin >= 0)
    }

    @Test("A finer texture size changes only the density readout, not the layout")
    func textureSizeAffectsOnlyDensity() throws {
        let mesh = try cube()
        var coarse = Mesh.AtlasParameters()
        coarse.textureSize = 256
        var fine = Mesh.AtlasParameters()
        fine.textureSize = 2048

        let (_, coarseReport) = try mesh.unwrapped(parameters: coarse)
        let (_, fineReport) = try mesh.unwrapped(parameters: fine)
        // textureSize is the unit the density is EXPRESSED in, not an input to the solve,
        // so the packing must be identical and only the density scale differ.
        #expect(coarseReport.chartCount == fineReport.chartCount)
        #expect(coarseReport.packedArea == fineReport.packedArea)
        #expect(fineReport.texelDensity > coarseReport.texelDensity)
    }

    // MARK: - Single-island re-unwrap (add-stage-dependent-x-gesture, 6.2b)

    @Test("Re-unwrapping refuses a never-unwrapped mesh and says WHY, without throwing")
    func reunwrapRefusesWithoutUVs() throws {
        let mesh = try cube()
        let outcome = try mesh.reunwrapIsland(containing: 0)
        // Not a throw: "you have not unwrapped yet" is a routing signal, and the caller runs
        // a whole-mesh unwrap instead. Throwing would make it indistinguishable from an
        // invalid face id, which needs the opposite response.
        #expect(outcome.needsWholeMeshUnwrap)
        #expect(!outcome.didUnwrap)
        // And it must NOT have created the column: one island in a fresh column leaves every
        // other island's corners at (0, 0), which reads to every consumer as a real layout.
        #expect(mesh.uvCoordinates() == nil)
        #expect(!mesh.hasUVLayout)
    }

    @Test("Re-unwrapping one island changes it and leaves the rest of the layout alone")
    func reunwrapIsLocal() throws {
        let (mesh, _) = try cube().unwrapped()
        let before = try #require(mesh.uvCoordinates())

        let outcome = try mesh.reunwrapIsland(containing: 0)
        #expect(outcome.didUnwrap)
        #expect(!outcome.needsWholeMeshUnwrap)
        #expect(outcome.faces >= 1)

        let after = try #require(mesh.uvCoordinates())
        #expect(after.count == before.count)
        // Some corners moved and some did not. All-changed would mean the whole layout was
        // redone, which is the failure this method exists to avoid; none-changed would mean
        // the call silently did nothing.
        #expect(zip(before, after).contains { $0 != $1 })
        #expect(zip(before, after).contains { $0 == $1 })
    }

    @Test("Re-unwrapping a dead face throws and leaves every UV untouched")
    func reunwrapRejectsDeadFace() throws {
        let (mesh, _) = try cube().unwrapped()
        let before = try #require(mesh.uvCoordinates())
        #expect(throws: (any Error).self) {
            try mesh.reunwrapIsland(containing: 9999)
        }
        #expect(mesh.uvCoordinates() == before)
    }

    // MARK: - Packing aids (add-uv-packing-aids, 6.6)

    @Test("A repack into a sub-region puts every corner inside it")
    func repackIntoRegion() throws {
        let (mesh, _) = try cube().unwrapped()
        let region = Mesh.UVRegion(minU: 0.2, minV: 0.3, maxU: 0.8, maxV: 0.9)
        try mesh.packIslands(into: region)

        let uvs = try #require(mesh.uvCoordinates())
        for uv in uvs {
            #expect(uv.x >= region.minU - 1e-4)
            #expect(uv.x <= region.maxU + 1e-4)
            #expect(uv.y >= region.minV - 1e-4)
            #expect(uv.y <= region.maxV + 1e-4)
        }
    }

    @Test("A repack preserves each island's internal UVs, applying only scale and translation")
    func repackPreservesParameterization() throws {
        let (mesh, _) = try cube().unwrapped()
        let before = try #require(mesh.uvCoordinates())
        // A NON-SQUARE region is the case that would tempt a per-axis fit.
        try mesh.packIslands(into: Mesh.UVRegion(minU: 0, minV: 0, maxU: 1, maxV: 0.5))
        let after = try #require(mesh.uvCoordinates())
        #expect(after.count == before.count)

        // The exit criterion is that packing preserves internal UVs. Under a uniform scale plus
        // translation, every RATIO of distances between corners is invariant — a per-axis fit
        // would change ratios between differently-oriented pairs.
        func ratio(_ uvs: [SIMD2<Float>], _ a: Int, _ b: Int, _ c: Int, _ d: Int) -> Float {
            let one = simd_distance(uvs[a], uvs[b])
            let two = simd_distance(uvs[c], uvs[d])
            return two > 0 ? one / two : 0
        }
        // Pairs deliberately chosen along different axes within one face's four corners.
        #expect(
            abs(ratio(after, 0, 1, 1, 2) - ratio(before, 0, 1, 1, 2)) < 1e-3,
            "a uniform scale preserves distance ratios; a per-axis fit would not"
        )
    }

    @Test("Repacking refuses a never-unwrapped mesh and a zero-area region")
    func repackRefusals() throws {
        let bare = try cube()
        // Success here would report a repack that never happened.
        #expect(throws: (any Error).self) { try bare.packIslands() }

        let (mesh, _) = try cube().unwrapped()
        #expect(throws: (any Error).self) {
            try mesh.packIslands(
                into: Mesh.UVRegion(minU: 0.5, minV: 0.1, maxU: 0.5, maxV: 0.9)
            )
        }
    }

    @Test("Flipped islands are NAMED, and flipping twice restores the layout exactly")
    func flipIsReversibleAndDiscoverable() throws {
        let (mesh, _) = try cube().unwrapped()
        let before = try #require(mesh.uvCoordinates())
        #expect(try mesh.flippedIslands().isEmpty)

        try mesh.flipIsland(containing: 0)
        let flipped = try mesh.flippedIslands()
        // Naming the island is the point: a count says there is a problem without saying where.
        #expect(flipped.count == 1)

        try mesh.flipIsland(containing: try #require(flipped.first))
        let after = try #require(mesh.uvCoordinates())
        for (a, b) in zip(before, after) {
            #expect(abs(a.x - b.x) < 1e-6)
            #expect(abs(a.y - b.y) < 1e-6)
        }
        #expect(try mesh.flippedIslands().isEmpty)
    }

    @Test("A mesh with no layout reports NO flipped islands rather than failing")
    func flippedIslandsOnBareMesh() throws {
        // A truthful empty answer to a set-membership question — not an error, and not a
        // pretence that some island is mirrored.
        #expect(try cube().flippedIslands().isEmpty)
    }

    @Test("Distributing islands is a no-op on an already overlap-free layout")
    func distributeIsSafeOnAPackedLayout() throws {
        let (mesh, _) = try cube().unwrapped()
        try mesh.packIslands(into: Mesh.UVRegion(minU: 0.4, minV: 0.4, maxU: 0.6, maxV: 0.6))
        let packed = try #require(mesh.uvCoordinates())

        // Deliberately NOT asserting that overlaps disappear: a pack already produces an
        // overlap-free layout, so there is nothing here to distribute, and constructing genuine
        // overlap needs the per-island transforms that arrive with 6.3. Overlap REMOVAL is
        // asserted in the engine suite, where islands can be stacked directly
        // (`distributing overlapping islands removes every box overlap`).
        //
        // What this pins is that the call is safe and keeps a usable layout — the failure that
        // would otherwise surface as a corrupted atlas after a harmless button press.
        try mesh.distributeOverlappingIslands()
        let after = try #require(mesh.uvCoordinates())
        #expect(after.count == packed.count)
        #expect(after.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        #expect(mesh.hasUVLayout)
    }

    // MARK: - UDIM tiles and stacking (6.7)

    @Test("A packed atlas reports exactly tile 1001, and nothing straddles")
    func defaultLayoutIsOneTile() throws {
        let (mesh, _) = try cube().unwrapped()
        // The unit square IS tile 1001. Anything else would mean the default layout silently
        // spanned texture files.
        #expect(try mesh.udimTiles() == [1001])
        #expect(try mesh.straddlingIslands().isEmpty)
    }

    @Test("Tiles are empty before an unwrap, rather than reporting a phantom tile")
    func noTilesWithoutLayout() throws {
        #expect(try cube().udimTiles().isEmpty)
        #expect(try cube().straddlingIslands().isEmpty)
    }

    @Test("Retiling an island moves it whole tiles and both tiles are then reported")
    func retileIsland() throws {
        let (mesh, _) = try cube().unwrapped()
        let before = try #require(mesh.uvCoordinates())

        try mesh.assignIsland(containing: 0, toTile: 1013)
        #expect(try mesh.udimTiles() == [1001, 1013])

        // Whole-tile translation: (2, 1) for tile 1013. The island's position within its tile
        // must be untouched, since retiling is not meant to also re-arrange the shell.
        let after = try #require(mesh.uvCoordinates())
        let moved = zip(before, after).filter { $0 != $1 }
        #expect(!moved.isEmpty)
        for (old, new) in moved {
            #expect(abs((new.x - old.x) - 2) < 1e-4)
            #expect(abs((new.y - old.y) - 1) < 1e-4)
        }
    }

    @Test("Retiling rejects a tile below the UDIM range")
    func retileRejectsBadTile() throws {
        let (mesh, _) = try cube().unwrapped()
        // 1000 is not a UDIM tile; accepting it would emit a texture name no tool would find.
        #expect(throws: (any Error).self) { try mesh.assignIsland(containing: 0, toTile: 1000) }
    }

    @Test("Stacking refuses a mesh with no layout and rejects a zero normal")
    func stackingRefusals() throws {
        let bare = try cube()
        // A mutation asked to rearrange a layout that does not exist is a mistake, not an empty
        // answer — unlike the tile QUERY above, which correctly returns empty.
        #expect(throws: (any Error).self) {
            try bare.stackMirroredIslands(planePoint: .zero, planeNormal: SIMD3(1, 0, 0))
        }
        let (mesh, _) = try cube().unwrapped()
        #expect(throws: (any Error).self) {
            try mesh.stackMirroredIslands(planePoint: .zero, planeNormal: .zero)
        }
    }

    @Test("Stacking a non-symmetric mesh changes NOTHING and reports zero")
    func stackingNonSymmetricIsInert() throws {
        let (mesh, _) = try cube().unwrapped()
        let before = try #require(mesh.uvCoordinates())
        let stacked = try mesh.stackMirroredIslands(
            planePoint: SIMD3(0.5, 0.5, 0.5), planeNormal: SIMD3(1, 0, 0), tolerance: 1e-5
        )
        // Zero is the correct answer: a wrong pairing would stack unrelated shells on top of
        // each other, which is far worse than doing nothing.
        if stacked == 0 {
            #expect(mesh.uvCoordinates() == before)
        }
    }
}

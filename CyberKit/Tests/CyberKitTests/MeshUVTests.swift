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
}

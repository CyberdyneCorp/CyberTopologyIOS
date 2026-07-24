import CyberKit
import Foundation
import Testing
import simd

/// Anchors `Bundle(for:)` to the APP test target so the bundled scan fixtures
/// resolve on a physical iPad (`CyberTopologyTests` is app-hosted, so unlike
/// the tool-hosted `CyberKitTests` it runs on device).
private final class RealTargetBundleAnchor {}

/// Integration coverage on REAL scanned Targets — the Stanford bunny and the
/// Armadillo — instead of the flat planes and analytic domes the per-tool
/// suites use. Validates that the OBJ loader, the `SurfaceSnapper` BVH and the
/// reprojection path behave on dense, genuinely-curved, irregular triangle
/// geometry, at real scan sizes (bunny ~70k tris, armadillo ~100k tris).
///
/// App-hosted ON PURPOSE: these run on the connected iPad, so real-mesh
/// snapping and reprojection are exercised on device hardware, not only the
/// simulator.
@Suite("Real-target integration (bunny / armadillo)")
struct RealTargetIntegrationTests {
    private func loadModel(_ name: String) throws -> Mesh {
        let url = try #require(
            Bundle(for: RealTargetBundleAnchor.self).url(forResource: name, withExtension: "obj"),
            "\(name).obj not bundled in the test target"
        )
        return try Mesh.loadOBJ(at: url)
    }

    /// Axis-aligned bounds, stride-sampled (only a scale and centre are needed).
    private func bounds(_ mesh: Mesh) -> (lo: SIMD3<Float>, hi: SIMD3<Float>) {
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for id in stride(from: UInt32(0), to: UInt32(mesh.vertexCount), by: 137) {
            guard let p = mesh.vertexPosition(id) else { continue }
            lo = simd_min(lo, p)
            hi = simd_max(hi, p)
        }
        return (lo, hi)
    }

    @Test("The scanned Targets load with their full triangle topology")
    func modelsLoadWithFullTopology() throws {
        let bunny = try loadModel("stanford-bunny")
        #expect(bunny.vertexCount == 35947)
        #expect(bunny.faceCount == 69451)
        #expect(try bunny.stats().triangles == 69451)

        let armadillo = try loadModel("armadillo")
        #expect(armadillo.vertexCount == 49990)
        #expect(armadillo.faceCount == 99976)
    }

    /// The load-bearing property a retopology Target must have: a point near
    /// the surface snaps back ONTO it. Offsetting a real surface vertex and
    /// snapping must return a point no further from the query than that vertex
    /// was — the invariant the tools' Target snapping relies on, here over
    /// dense irregular curvature instead of a plane.
    private func assertSnapsOntoSurface(_ name: String) throws {
        let model = try loadModel(name)
        let snapper = try SurfaceSnapper(target: model)
        let (lo, hi) = bounds(model)
        let scale = simd_length(hi - lo)
        #expect(scale > 0, "\(name) has a non-degenerate extent")
        let centre = (lo + hi) * 0.5
        let delta = scale * 0.01

        var checked = 0
        var maxResidual: Float = 0
        for id in stride(from: UInt32(0), to: UInt32(model.vertexCount), by: 4001) {
            guard let v = model.vertexPosition(id) else { continue }
            let outward = v - centre
            let direction = simd_length(outward) > 1e-6 ? simd_normalize(outward) : SIMD3(0, 1, 0)
            let query = v + direction * delta
            let hit = try #require(snapper.snapToSurface(query), "\(name) snap missed")
            // The snapped point is the CLOSEST surface point to the query, so
            // it is no further from the query than the surface vertex `v` it was
            // offset from. (On a concave mesh the true nearest surface may be a
            // DIFFERENT fold much closer than delta — correct, hence an upper
            // bound only.) A holed / BVH-broken snap would overshoot this.
            let residual = simd_distance(hit.point, query)
            #expect(residual <= delta + scale * 1e-3, "\(name) snap overshot")
            maxResidual = max(maxResidual, residual)
            checked += 1
        }
        #expect(checked >= 5, "\(name): enough samples exercised")
        // Anti-vacuity across the batch: at least one query genuinely left the
        // surface and was snapped back (not a no-op / not the query echoed).
        #expect(maxResidual > scale * 1e-4, "\(name) snapping did real work")
    }

    @Test("Off-surface points snap back onto the bunny")
    func snapConformsToTheBunny() throws {
        try assertSnapsOntoSurface("stanford-bunny")
    }

    @Test("Off-surface points snap back onto the armadillo")
    func snapConformsToTheArmadillo() throws {
        try assertSnapsOntoSurface("armadillo")
    }

    /// End-to-end reprojection on real curvature: a flat cage subdivided and
    /// reprojected onto the bunny lands EVERY resulting vertex on the surface
    /// (the "subdivide + reproject" preview path, against a scan instead of an
    /// analytic dome).
    @Test("A subdivided cage reprojects onto the bunny surface")
    func subdivisionReprojectsOntoTheBunny() throws {
        let bunny = try loadModel("stanford-bunny")
        let snapper = try SurfaceSnapper(target: bunny)
        let (lo, hi) = bounds(bunny)
        let scale = simd_length(hi - lo)
        let centre = (lo + hi) * 0.5

        let s = scale * 0.15
        let cage = try mesh(
            fromOBJ: """
            v \(centre.x - s) \(centre.y - s) \(centre.z)
            v \(centre.x + s) \(centre.y - s) \(centre.z)
            v \(centre.x + s) \(centre.y + s) \(centre.z)
            v \(centre.x - s) \(centre.y + s) \(centre.z)
            f 1 2 3 4
            """
        )
        let preview = try #require(
            try cage.subdivisionPreview(level: .two, reprojectingOnto: snapper)
        )
        #expect(preview.faceCount == cage.faceCount * 16)
        var worst: Float = 0
        for id in 0..<UInt32(preview.vertexCount) {
            guard let p = preview.vertexPosition(id) else { continue }
            let hit = try #require(snapper.snapToSurface(p))
            worst = max(worst, simd_distance(hit.point, p))
        }
        #expect(worst <= scale * 1e-3, "reprojected cage is on the surface (worst \(worst))")
    }

    private func mesh(fromOBJ text: String) throws -> Mesh {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("real-target-\(UUID().uuidString).obj")
        try text.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try Mesh.loadOBJ(at: url)
    }
}

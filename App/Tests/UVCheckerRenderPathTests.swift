import CyberKit
import Metal
import Testing
import simd

@testable import CyberTopology

/// The checker texture preview (openspec add-uv-texture-preview, 6.3c): corner-expanded geometry
/// as pure code, plus an offscreen render proving the checker actually reaches the framebuffer.
@MainActor
struct UVCheckerRenderPathTests {
    private func makeRenderer() throws -> ViewportRenderer {
        try #require(ViewportRenderer(), "Metal device unavailable")
    }

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
            .appendingPathComponent("checker-\(UUID().uuidString).obj")
        try obj.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try Mesh.loadOBJ(at: url)
    }

    // MARK: - Geometry

    @Test("A never-unwrapped mesh builds NO checker geometry, rather than an empty preview")
    func absenceIsNotEmpty() throws {
        // nil, not []: the same contract `uvCoordinates()` follows, so a caller can tell "no
        // layout" from "a layout with nothing in it".
        #expect(UVCheckerGeometry.build(from: try cube()) == nil)
    }

    @Test("An unwrapped mesh expands to three unique vertices per triangle")
    func expandsPerCorner() throws {
        let (mesh, _) = try cube().unwrapped()
        let vertices = try #require(UVCheckerGeometry.build(from: mesh))
        // Corner-expanded and non-indexed: UVs are per-CORNER because a seam gives one vertex
        // several UVs, so a vertex-indexed stream would have to pick one and weld every seam shut.
        #expect(vertices.count % 3 == 0)
        // A cube is 6 quads = 12 triangles = 36 corners.
        #expect(vertices.count == 36)
        // Every UV is inside the packed unit square.
        for vertex in vertices {
            #expect(vertex.uv.x >= -1e-4 && vertex.uv.x <= 1 + 1e-4)
            #expect(vertex.uv.y >= -1e-4 && vertex.uv.y <= 1 + 1e-4)
        }
    }

    @Test("Mismatched streams build NOTHING rather than a plausible-looking wrong preview")
    func mismatchedStreamsAreRejected() {
        let positions: [Float] = [0, 0, 0, 1, 0, 0, 0, 1, 0]
        let normals: [Float] = [0, 0, 1, 0, 0, 1, 0, 0, 1]
        let indices: [UInt32] = [0, 1, 2]

        // One UV per emitted CORNER is the documented contract. A different count means the UV
        // stream was built for other topology, so nothing derived from it can be trusted.
        #expect(
            UVCheckerGeometry.build(
                positions: positions, normals: normals, triangleIndices: indices,
                uvs: [SIMD2(0, 0), SIMD2(1, 0)]
            ) == nil
        )
        // A non-multiple-of-three index stream is not a triangle list.
        #expect(
            UVCheckerGeometry.build(
                positions: positions, normals: normals, triangleIndices: [0, 1],
                uvs: [SIMD2(0, 0), SIMD2(1, 0)]
            ) == nil
        )
        // Normals of the wrong length are a mismatch, not something to pad.
        #expect(
            UVCheckerGeometry.build(
                positions: positions, normals: [0, 0, 1], triangleIndices: indices,
                uvs: [SIMD2(0, 0), SIMD2(1, 0), SIMD2(0, 1)]
            ) == nil
        )
    }

    @Test("An out-of-range index is rejected instead of reading past the buffer")
    func outOfRangeIndexIsRejected() {
        #expect(
            UVCheckerGeometry.build(
                positions: [0, 0, 0], normals: [0, 0, 1], triangleIndices: [0, 1, 99],
                uvs: [SIMD2(0, 0), SIMD2(1, 0), SIMD2(0, 1)]
            ) == nil
        )
    }

    @Test("Corner UVs follow the index stream, not the vertex order")
    func uvsFollowCorners() {
        // Two triangles sharing vertex 0 but carrying DIFFERENT UVs there — which is exactly what a
        // seam produces, and what a vertex-indexed stream could not represent.
        let vertices = UVCheckerGeometry.build(
            positions: [0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 1, 0],
            normals: [0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1],
            triangleIndices: [0, 1, 2, 0, 3, 1],
            uvs: [
                SIMD2(0, 0), SIMD2(1, 0), SIMD2(0, 1),
                SIMD2(0.5, 0.5), SIMD2(1, 1), SIMD2(1, 0),
            ]
        )
        let built = vertices ?? []
        #expect(built.count == 6)
        // Same vertex (index 0) appears twice with different UVs, preserved independently.
        #expect(built[0].position == built[3].position)
        #expect(built[0].uv == SIMD2(0, 0))
        #expect(built[3].uv == SIMD2(0.5, 0.5))
    }

    // MARK: - Uniforms

    @Test("Density and opacity are clamped so a bad value cannot blank the preview")
    func uniformsAreClamped() {
        let identity = matrix_identity_float4x4
        // A zero or negative density would collapse the checker to one colour, which reads as "the
        // preview is broken" rather than "the UVs are wrong".
        #expect(UVCheckerUniformsFactory.uniforms(mvp: identity, density: 0).params.x >= 1)
        #expect(UVCheckerUniformsFactory.uniforms(mvp: identity, density: -8).params.x >= 1)
        #expect(UVCheckerUniformsFactory.uniforms(mvp: identity, opacity: 2).params.y == 1)
        #expect(UVCheckerUniformsFactory.uniforms(mvp: identity, opacity: -1).params.y == 0)
        // The mvp is carried through untouched — the first version dropped it entirely and the
        // compiler caught it, but nothing would have caught a silently wrong one.
        #expect(UVCheckerUniformsFactory.uniforms(mvp: identity).mvp == identity)
    }

    // MARK: - Render path

    @Test("The checker pipeline builds and loading is driven by the mesh's layout")
    func pipelineBuildsAndLoads() throws {
        let renderer = try makeRenderer()
        #expect(!renderer.hasUVChecker)

        // No layout: nothing loads, and it reports that rather than pretending.
        #expect(!renderer.loadUVChecker(from: try cube()))
        #expect(!renderer.hasUVChecker)

        let (unwrapped, _) = try cube().unwrapped()
        #expect(renderer.loadUVChecker(from: unwrapped))
        #expect(renderer.hasUVChecker)

        // nil clears, so leaving the UV stage cannot leave a checker resident.
        #expect(!renderer.loadUVChecker(from: nil))
        #expect(!renderer.hasUVChecker)
    }

    @Test("An empty vertex list clears rather than uploading a zero-length draw")
    func emptyLoadClears() throws {
        let renderer = try makeRenderer()
        let (unwrapped, _) = try cube().unwrapped()
        #expect(renderer.loadUVChecker(from: unwrapped))
        #expect(!renderer.uvCheckerPath.load(vertices: []))
        #expect(!renderer.hasUVChecker)
    }

    @Test("The checker changes the image, and the pattern DEPENDS on UV and density")
    func checkerDependsOnUVAndDensity() throws {
        let renderer = try makeRenderer()
        let (unwrapped, _) = try cube().unwrapped()
        renderer.load(mesh: unwrapped)
        // Shading off: the checker parity is then the only thing that can vary tone within the
        // preview.
        renderer.uvCheckerSettings.shading = 0

        func render() throws -> [UInt8] {
            try #require(renderer.renderOffscreen(width: 128, height: 128), "offscreen failed")
        }
        func differingPixels(_ a: [UInt8], _ b: [UInt8]) -> Int {
            guard a.count == b.count else { return .max }
            var count = 0
            for index in stride(from: 0, to: a.count - 3, by: 4) where a[index + 1] != b[index + 1] {
                count += 1
            }
            return count
        }

        // 1. The checker must actually reach the framebuffer: loading it changes the image.
        let withoutChecker = try render()
        #expect(renderer.loadUVChecker(from: unwrapped))
        renderer.uvCheckerSettings.density = 4
        let coarse = try render()
        #expect(
            differingPixels(withoutChecker, coarse) > 100,
            "loading the checker did not change the image"
        )

        // 2. And the pattern must DEPEND on UV. Changing only the density changes the image, which
        //    a single-tone shader or one ignoring UV cannot do — both would render identically at
        //    every density. A tone histogram cannot show this: the Target pass underneath supplies
        //    bright and dark pixels of its own, so "two distinct tones" passes for a broken shader.
        //    Two earlier versions of this test did exactly that, and mutations exposed both.
        renderer.uvCheckerSettings.density = 32
        let fine = try render()
        #expect(
            differingPixels(coarse, fine) > 100,
            "the pattern does not depend on UV: density changed but the image did not"
        )
    }
}

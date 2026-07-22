import CyberKit
import Metal
import MetalKit
import Testing
import simd
@testable import CyberTopology

/// Renderer tests, including the offscreen smoke render required by the
/// visual-verification protocol (runs on the simulator: the plain vertex
/// pipeline is the simulator/fallback path by design).
@MainActor
struct ViewportRendererTests {
    private func makeRenderer() throws -> ViewportRenderer {
        try #require(ViewportRenderer(), "Metal device unavailable")
    }

    private func seedMesh() throws -> Mesh {
        try Mesh.loadOBJ(at: UITestSupport.writeSeedOBJ())
    }

    private func colorlessTriangleMesh() throws -> Mesh {
        let obj = """
        v 0 0 0
        v 1 0 0
        v 0 1 0
        f 1 2 3
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("colorless-tri-\(UUID().uuidString).obj")
        try obj.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try Mesh.loadOBJ(at: url)
    }

    /// Count of 4-byte pixels that differ between two frames.
    private func differingPixels(_ a: [UInt8], _ b: [UInt8]) -> Int {
        var count = 0
        for base in stride(from: 0, to: min(a.count, b.count), by: 4)
        where a[base..<base + 4] != b[base..<base + 4] {
            count += 1
        }
        return count
    }

    @Test func initFailsWithoutDevice() {
        #expect(ViewportRenderer(device: nil) == nil)
    }

    @Test func emptyFrameIsUniformBackground() throws {
        let renderer = try makeRenderer()
        let frame = try #require(renderer.renderOffscreen(width: 64, height: 64))
        #expect(frame.count == 64 * 64 * 4)
        let first = Array(frame[0..<4])
        let uniform = stride(from: 0, to: frame.count, by: 4)
            .allSatisfy { Array(frame[$0..<$0 + 4]) == first }
        #expect(uniform)
    }

    /// Renderer smoke test: one frame of the seeded quad must produce a
    /// meaningful number of non-background pixels.
    @Test func smokeRenderSeededQuadProducesNonBackgroundPixels() throws {
        let renderer = try makeRenderer()
        let background = try #require(renderer.renderOffscreen(width: 128, height: 128))
        renderer.load(mesh: try seedMesh())
        let frame = try #require(renderer.renderOffscreen(width: 128, height: 128))
        // The framed quad covers a large part of a 128×128 frame; require a
        // sturdy pixel count so a sliver artifact cannot pass.
        #expect(differingPixels(frame, background) > 1000)
    }

    @Test func meshWithoutColorsRendersInFallbackGray() throws {
        let renderer = try makeRenderer()
        let background = try #require(renderer.renderOffscreen(width: 96, height: 96))
        renderer.load(mesh: try colorlessTriangleMesh())
        let frame = try #require(renderer.renderOffscreen(width: 96, height: 96))
        #expect(differingPixels(frame, background) > 300)
    }

    /// Visual verification of per-vertex color interpolation (task 2.2):
    /// the seeded quad's corners are red/green/blue/white, so the rendered
    /// frame must contain regions dominated by each primary AND a wide
    /// gradient of in-between colors (flat shading would yield few).
    @Test func seededQuadShowsPerVertexColorInterpolation() throws {
        let renderer = try makeRenderer()
        let background = try #require(renderer.renderOffscreen(width: 256, height: 256))
        renderer.load(mesh: try seedMesh())
        let frame = try #require(renderer.renderOffscreen(width: 256, height: 256))

        var redDominant = 0, greenDominant = 0, blueDominant = 0
        var distinctColors = Set<[UInt8]>()
        for base in stride(from: 0, to: frame.count, by: 4)
        where Array(frame[base..<base + 4]) != Array(background[base..<base + 4]) {
            let blue = Int(frame[base]), green = Int(frame[base + 1]), red = Int(frame[base + 2])
            distinctColors.insert([frame[base], frame[base + 1], frame[base + 2]])
            if red > green + 40, red > blue + 40 { redDominant += 1 }
            if green > red + 40, green > blue + 40 { greenDominant += 1 }
            if blue > red + 40, blue > green + 40 { blueDominant += 1 }
        }
        #expect(redDominant > 100)
        #expect(greenDominant > 100)
        #expect(blueDominant > 100)
        // Smooth interpolation produces a dense gradient of colors.
        #expect(distinctColors.count > 200)
    }

    /// Large-mesh contract (task 2.2): after a load, drawing frames and
    /// reloading a same-sized mesh must not allocate new GPU buffers.
    @Test func framesAndSameSizeReloadsDoNotReallocate() throws {
        let renderer = try makeRenderer()
        renderer.load(mesh: try seedMesh())
        let allocations = renderer.geometryPool.allocationCount

        for _ in 0..<3 {
            #expect(renderer.renderOffscreen(width: 64, height: 64) != nil)
        }
        renderer.load(mesh: try seedMesh())
        #expect(renderer.renderOffscreen(width: 64, height: 64) != nil)
        #expect(renderer.geometryPool.allocationCount == allocations)
    }

    /// The perf harness's replicated-buffer fixture must render correctly
    /// (validated on simulator so device perf runs never chase fixture
    /// bugs).
    @Test func replicatedGridGeometryRenders() throws {
        let renderer = try makeRenderer()
        let background = try #require(renderer.renderOffscreen(width: 128, height: 128))
        let geometry = ViewportPerfTests.replicatedGridGeometry(segments: 8, tiles: 3)
        renderer.loadGeometry(
            positions: geometry.positions,
            normals: geometry.normals,
            colors: geometry.colors,
            indices: geometry.indices
        )
        #expect(renderer.hasMesh)
        #expect(geometry.indices.count == 8 * 8 * 3 * 2 * 3)
        let frame = try #require(renderer.renderOffscreen(width: 128, height: 128))
        #expect(differingPixels(frame, background) > 1000)
    }

    @Test func loadMeshComputesBoundsAndFramesCamera() throws {
        let renderer = try makeRenderer()
        renderer.load(mesh: try seedMesh())
        #expect(renderer.hasMesh)
        #expect(renderer.bounds.lower == SIMD3(0, 0, 0))
        #expect(renderer.bounds.upper == SIMD3(1, 1, 0))
        #expect(renderer.camera.focus == renderer.bounds.center)
        #expect(renderer.camera.distance > renderer.bounds.radius)
    }

    @Test func loadEmptyMeshClearsGeometry() throws {
        let renderer = try makeRenderer()
        renderer.load(mesh: try seedMesh())
        renderer.load(mesh: try Mesh())
        #expect(!renderer.hasMesh)
        #expect(renderer.bounds == .unit)
    }

    @Test func clearMeshResetsState() throws {
        let renderer = try makeRenderer()
        renderer.load(mesh: try seedMesh())
        renderer.clearMesh()
        #expect(!renderer.hasMesh)
        let frame = try #require(renderer.renderOffscreen(width: 32, height: 32))
        let first = Array(frame[0..<4])
        #expect(stride(from: 0, to: frame.count, by: 4)
            .allSatisfy { Array(frame[$0..<$0 + 4]) == first })
    }

    @Test func gestureEntryPointsMutateCamera() throws {
        let renderer = try makeRenderer()
        renderer.load(mesh: try seedMesh())
        let start = renderer.camera

        renderer.orbit(byPoints: SIMD2(30, 0))
        #expect(renderer.camera.azimuth != start.azimuth)

        renderer.zoom(byPinchScale: 2)
        #expect(renderer.camera.distance < start.distance)

        let beforePan = renderer.camera.focus
        renderer.pan(byPoints: SIMD2(50, 20))
        #expect(renderer.camera.focus != beforePan)

        // Speed settings feed through.
        renderer.orbitSpeed = 2
        let azBefore = renderer.camera.azimuth
        renderer.orbit(byPoints: SIMD2(10, 0))
        #expect(abs((azBefore - renderer.camera.azimuth) - 20 * CameraState.orbitRadiansPerPoint) < 1e-5)
    }

    /// Task 3.2: the matrix handed to the engine stroke recognizer is the
    /// exact camera matrix frames are drawn with, flattened column-major
    /// (`simd_float4x4` memory order), plus the matching viewport aspect.
    @Test func viewProjectionColumnsMatchTheRenderCameraMatrix() throws {
        let renderer = try makeRenderer()
        renderer.load(mesh: try seedMesh())
        renderer.setViewportSize(CGSize(width: 400, height: 300))
        renderer.orbit(byPoints: SIMD2(37, -12))  // arbitrary non-default pose

        #expect(abs(renderer.viewportAspect - 400.0 / 300.0) < 1e-6)
        let columns = renderer.viewProjectionColumns()
        #expect(columns.count == 16)
        let mvp = renderer.camera.projectionMatrix(
            aspect: renderer.viewportAspect, bounds: renderer.bounds
        ) * renderer.camera.viewMatrix()
        for column in 0..<4 {
            for row in 0..<4 {
                #expect(abs(columns[column * 4 + row] - mvp[column][row]) < 1e-6)
            }
        }
    }

    @Test func animatedReframeReachesTargetPose() throws {
        let renderer = try makeRenderer()
        renderer.load(mesh: try seedMesh())
        renderer.orbit(byPoints: SIMD2(100, 40))
        renderer.zoom(byPinchScale: 8)
        let expected = renderer.camera.reframed(
            to: renderer.bounds,
            aspect: Float(renderer.viewportSize.width / renderer.viewportSize.height)
        )

        renderer.reframe(animated: true, at: 100)
        #expect(renderer.stepAnimation(at: 100.1))  // still animating
        #expect(!renderer.stepAnimation(at: 101))  // finished
        #expect(renderer.camera == expected)
        #expect(!renderer.stepAnimation(at: 102))  // idempotent once done
    }

    /// Renderer-level camera rescue: a degenerate pose (inside/collapsed)
    /// reframes to a valid view that visibly shows the mesh again.
    @Test func reframeRescuesDegenerateCameraAndShowsMesh() throws {
        let renderer = try makeRenderer()
        renderer.load(mesh: try seedMesh())
        renderer.camera.distance = 0  // collapsed onto/inside the mesh
        renderer.camera.azimuth = .nan
        #expect(renderer.camera.isDegenerate)

        renderer.reframe(animated: false)
        #expect(!renderer.camera.isDegenerate)

        let background = ViewportRenderer()!
        let empty = try #require(background.renderOffscreen(width: 128, height: 128))
        let frame = try #require(renderer.renderOffscreen(width: 128, height: 128))
        #expect(differingPixels(frame, empty) > 1000)
    }

    /// Regression (review finding): meshes load during the first SwiftUI
    /// update pass, before the MTKView's first layout, so the initial
    /// framing is computed at the placeholder 1×1 viewport (aspect 1). When
    /// the real drawable size arrives the untouched framing must re-fit to
    /// the actual aspect — otherwise a wide mesh stays clipped on portrait
    /// screens until the user double-taps.
    @Test func initialFramingRefitsWhenRealDrawableSizeArrives() throws {
        let renderer = try makeRenderer()
        renderer.load(mesh: try seedMesh())  // placeholder viewport, aspect 1
        let squareFit = renderer.camera

        renderer.setViewportSize(CGSize(width: 400, height: 873))  // portrait
        let expected = CameraState.framing(
            renderer.bounds, aspect: Float(400.0 / 873.0)
        )
        #expect(renderer.camera == expected)
        // Portrait narrows the horizontal FOV: the fit must back off.
        #expect(renderer.camera.distance > squareFit.distance)

        // A later size change keeps re-fitting while the camera is untouched.
        renderer.setViewportSize(CGSize(width: 873, height: 400))
        #expect(
            renderer.camera
                == CameraState.framing(renderer.bounds, aspect: Float(873.0 / 400.0))
        )
    }

    /// The re-fit only applies to the untouched initial framing: once the
    /// user moved the camera, size changes never yank it.
    @Test func framingRefitNeverTouchesAUserMovedCamera() throws {
        let renderer = try makeRenderer()
        renderer.load(mesh: try seedMesh())
        renderer.orbit(byPoints: SIMD2(25, 10))
        let moved = renderer.camera
        renderer.setViewportSize(CGSize(width: 400, height: 873))
        #expect(renderer.camera == moved)
    }

    @Test func viewportSizeIgnoresNonPositiveSizes() throws {
        let renderer = try makeRenderer()
        renderer.setViewportSize(CGSize(width: 640, height: 480))
        renderer.setViewportSize(CGSize(width: 0, height: 100))
        renderer.setViewportSize(CGSize(width: 100, height: -1))
        #expect(renderer.viewportSize == CGSize(width: 640, height: 480))
    }

    @Test func mtkViewDelegateDrawAndResize() throws {
        let renderer = try makeRenderer()
        renderer.load(mesh: try seedMesh())

        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: renderer.device)
        view.colorPixelFormat = ViewportRenderer.colorPixelFormat
        view.depthStencilPixelFormat = ViewportRenderer.depthPixelFormat
        view.isPaused = true
        view.enableSetNeedsDisplay = false

        renderer.mtkView(view, drawableSizeWillChange: CGSize(width: 64, height: 64))
        #expect(renderer.viewportSize == CGSize(width: 64, height: 64))
        // Encodes and presents a frame (drawable availability permitting);
        // must not crash or wedge either way.
        renderer.draw(in: view)
    }
}

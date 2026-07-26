import CyberKit
import XCTest
@testable import CyberTopology

/// Device-only viewport frame-time harness (design D9: performance
/// acceptance runs on hardware; simulator GPU timing is meaningless, so
/// these tests skip there LOUDLY with an explicit reason — never silently.
/// Spec: quality-assurance / "No silent skips").
///
/// Task 2.2 measures the indexed-vertex path against a large replicated
/// procedural mesh via the `FrameTimeProbe` GPU timestamps. The full
/// 5-million-triangle @60fps acceptance (spec scenario "Multi-million-
/// triangle target") belongs to the meshlet/LOD follow-up and the device
/// release gate (task 9.6); it stays in the traceability pending list.
final class ViewportPerfTests: XCTestCase {
    static let simulatorSkipReason =
        "device-only: GPU frame timing on the simulator is not representative "
        + "(design D9 device release gate; QA spec 'No silent skips')"

    /// Writes a dense grid OBJ (`segments`² quads) for frame-time sampling
    /// through the full engine OBJ → render-buffer path.
    private func writeGridOBJ(segments: Int) throws -> URL {
        var obj = ""
        for y in 0...segments {
            for x in 0...segments {
                obj += "v \(Float(x)) \(Float(y)) 0\n"
            }
        }
        let stride = segments + 1
        for y in 0..<segments {
            for x in 0..<segments {
                let a = y * stride + x + 1  // OBJ indices are 1-based
                let b = a + 1
                let c = a + stride + 1
                let d = a + stride
                obj += "f \(a) \(b) \(c) \(d)\n"
            }
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("perf-grid-\(segments).obj")
        try obj.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Builds a large procedural mesh by replicating a `segments`² grid
    /// tile `tiles` times along x (replicated-buffer strategy: fixture
    /// generation only — no mesh algorithms in Swift, design D1).
    static func replicatedGridGeometry(
        segments: Int, tiles: Int
    ) -> (positions: [Float], normals: [Float], colors: [Float], indices: [UInt32]) {
        let stride = segments + 1
        let verticesPerTile = stride * stride
        var positions = [Float]()
        var normals = [Float]()
        var colors = [Float]()
        var indices = [UInt32]()
        positions.reserveCapacity(verticesPerTile * tiles * 3)
        normals.reserveCapacity(verticesPerTile * tiles * 3)
        colors.reserveCapacity(verticesPerTile * tiles * 3)
        indices.reserveCapacity(segments * segments * tiles * 6)

        for tile in 0..<tiles {
            let xOffset = Float(tile) * Float(segments + 2)
            for y in 0...segments {
                for x in 0...segments {
                    positions += [Float(x) + xOffset, Float(y), 0]
                    normals += [0, 0, 1]
                    colors += [
                        Float(x) / Float(segments),
                        Float(y) / Float(segments),
                        Float(tile) / Float(max(tiles - 1, 1)),
                    ]
                }
            }
            let base = UInt32(tile * verticesPerTile)
            for y in 0..<segments {
                for x in 0..<segments {
                    let a = base + UInt32(y * stride + x)
                    let b = a + 1
                    let c = a + UInt32(stride) + 1
                    let d = a + UInt32(stride)
                    indices += [a, b, c, a, c, d]
                }
            }
        }
        return (positions, normals, colors, indices)
    }

    /// Renders `frames` offscreen frames and returns the probe statistics
    /// over exactly those frames (polls for the async completion handlers).
    @MainActor
    private func measure(
        renderer: ViewportRenderer, frames: Int, width: Int, height: Int
    ) throws -> FrameTimeProbe.Statistics {
        // Warm-up frame (pipeline/heap priming), then measure.
        XCTAssertNotNil(renderer.renderOffscreen(width: width, height: height))
        renderer.frameProbe.reset()
        for _ in 0..<frames {
            XCTAssertNotNil(renderer.renderOffscreen(width: width, height: height))
        }
        var stats = renderer.frameProbe.statistics()
        let deadline = Date(timeIntervalSinceNow: 5)
        while (stats?.sampleCount ?? 0) < frames, Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
            stats = renderer.frameProbe.statistics()
        }
        let final = try XCTUnwrap(stats, "probe recorded no samples")
        XCTAssertEqual(final.sampleCount, frames, "missing frame samples")
        return final
    }

    /// Baseline: 80k-triangle grid through the real engine OBJ path.
    @MainActor
    func testFrameTimeOnDevice() throws {
        #if targetEnvironment(simulator)
            throw XCTSkip(Self.simulatorSkipReason)
        #else
            let renderer = try XCTUnwrap(ViewportRenderer(), "Metal unavailable")
            let url = try writeGridOBJ(segments: 200)  // 40k quads → 80k tris
            defer { try? FileManager.default.removeItem(at: url) }
            renderer.load(mesh: try Mesh.loadOBJ(at: url))

            let stats = try measure(renderer: renderer, frames: 30, width: 1024, height: 768)
            // GPU time per offscreen render+blit; 60 fps budget.
            XCTAssertLessThan(stats.averageSeconds, 1.0 / 60.0, "fallback pipeline frame time")
        #endif
    }

    /// Large-mesh path: ~2.1M triangles of replicated procedural buffers
    /// through the pooled indexed-vertex pipeline, timed by GPU timestamps.
    @MainActor
    func testLargeReplicatedTargetFrameTimeOnDevice() throws {
        #if targetEnvironment(simulator)
            throw XCTSkip(Self.simulatorSkipReason)
        #else
            let renderer = try XCTUnwrap(ViewportRenderer(), "Metal unavailable")
            // 16 tiles × 2 × 256² tris = 2,097,152 triangles.
            let geometry = Self.replicatedGridGeometry(segments: 256, tiles: 16)
            renderer.loadGeometry(
                positions: geometry.positions,
                normals: geometry.normals,
                colors: geometry.colors,
                indices: geometry.indices
            )
            XCTAssertTrue(renderer.hasMesh)
            XCTAssertEqual(geometry.indices.count, 2_097_152 * 3)

            let allocationsAfterLoad = renderer.geometryPool.allocationCount
            let stats = try measure(renderer: renderer, frames: 30, width: 1280, height: 960)
            // 60 fps budget on the vertex pipeline; the 5M-tri acceptance
            // moves to the meshlet/LOD path (traceability: pending).
            XCTAssertLessThan(stats.averageSeconds, 1.0 / 60.0, "large-mesh frame time")
            XCTAssertEqual(
                renderer.geometryPool.allocationCount, allocationsAfterLoad,
                "rendering must not allocate GPU buffers per frame"
            )
        #endif
    }

    /// MEASUREMENT for task 2.2a: what does the EXISTING indexed-vertex path
    /// actually do at 5M triangles on real hardware?
    ///
    /// The task assumes the 5M @60fps acceptance needs the meshlet/LOD path. That
    /// assumption has never been measured — the largest device test is 2.1M. If the
    /// fallback path already clears the budget at 5M, the acceptance gate can be met
    /// without a mesh-shader pipeline, and meshlets become an optimisation rather
    /// than a v0.1 blocker. Reports rather than asserts.
    @MainActor
    func testFiveMillionTriangleMeasurementOnDevice() throws {
        #if targetEnvironment(simulator)
            throw XCTSkip(Self.simulatorSkipReason)
        #else
            let renderer = try XCTUnwrap(ViewportRenderer(), "Metal unavailable")
            // 40 tiles x 2 x 256^2 = 5,242,880 triangles.
            let geometry = Self.replicatedGridGeometry(segments: 256, tiles: 40)
            renderer.loadGeometry(
                positions: geometry.positions, normals: geometry.normals,
                colors: geometry.colors, indices: geometry.indices
            )
            XCTAssertTrue(renderer.hasMesh)
            let triangles = geometry.indices.count / 3

            let capabilities = RenderPathCapabilities(device: renderer.device)
            for (label, w, h) in [("1280x960", 1280, 960), ("2732x2048 (full iPad)", 2732, 2048)] {
                let stats = try measure(renderer: renderer, frames: 30, width: w, height: h)
                let fps = 1.0 / stats.averageSeconds
                print("""
                [5M-measure] \(label)
                  triangles        = \(triangles)
                  avg frame        = \(String(format: "%.3f", stats.averageSeconds * 1000)) ms  (\(String(format: "%.1f", fps)) fps)
                  max frame        = \(String(format: "%.3f", stats.maxSeconds * 1000)) ms
                  60fps budget     = 16.667 ms  -> \(stats.averageSeconds < 1.0 / 60.0 ? "MET" : "MISSED")
                  meshShaders      = \(capabilities.supportsMeshShaders)
                  preferred path   = \(TargetRenderPathSelection.preferredKind(for: capabilities).rawValue)
                  available path   = \(TargetRenderPathSelection.availableKind(for: capabilities).rawValue)
                """)
            }
        #endif
    }

    /// The same measurement over a REAL asset, which is the number the acceptance
    /// should actually be judged on.
    ///
    /// `replicatedGridGeometry` tiles identical grids: perfect cache locality, uniform
    /// triangle size, uniform normals. That is a fair throughput test and an unfair
    /// stand-in for a scan — it flatters any pipeline, and would flatter a meshlet
    /// pipeline most, since culling and vertex reuse are exactly what irregular
    /// geometry stresses. Armadillo (~100k tris) linearly subdivided three times is
    /// ~6.4M triangles of genuinely irregular topology.
    @MainActor
    func testFiveMillionRealAssetMeasurementOnDevice() throws {
        #if targetEnvironment(simulator)
            throw XCTSkip(Self.simulatorSkipReason)
        #else
            let renderer = try XCTUnwrap(ViewportRenderer(), "Metal unavailable")
            let url = try XCTUnwrap(
                Bundle(for: type(of: self)).url(
                    forResource: "armadillo", withExtension: "obj"
                ),
                "armadillo.obj not bundled in the test target"
            )
            let mesh = try Mesh.loadOBJ(at: url)
            // 100k x 4^3 = ~6.4M triangles. No reprojection: raw density is the point.
            for _ in 0..<3 { _ = try mesh.subdivide() }
            renderer.load(mesh: mesh)
            XCTAssertTrue(renderer.hasMesh)

            let capabilities = RenderPathCapabilities(device: renderer.device)
            for (label, w, h) in [("1280x960", 1280, 960), ("2732x2048 (full iPad)", 2732, 2048)] {
                let stats = try measure(renderer: renderer, frames: 30, width: w, height: h)
                print("""
                [5M-real] \(label)
                  faces            = \(mesh.faceCount)
                  avg frame        = \(String(format: "%.3f", stats.averageSeconds * 1000)) ms  (\(String(format: "%.1f", 1.0 / stats.averageSeconds)) fps)
                  max frame        = \(String(format: "%.3f", stats.maxSeconds * 1000)) ms
                  60fps budget     = 16.667 ms  -> \(stats.averageSeconds < 1.0 / 60.0 ? "MET" : "MISSED")
                  path             = \(TargetRenderPathSelection.availableKind(for: capabilities).rawValue)
                """)
            }
        #endif
    }
}

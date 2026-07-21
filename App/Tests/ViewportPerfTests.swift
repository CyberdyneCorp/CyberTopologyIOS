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
}

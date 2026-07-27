import CyberKit
import Foundation
import XCTest
import os
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
        // Warm-up frame (pipeline/heap priming), then measure. TIMING-ONLY renders: the
        // 22 MB readback per frame at 2732x2048 was pure waste for a frame-time
        // measurement, and it dominated this suite's runtime.
        XCTAssertTrue(renderer.renderOffscreenForTiming(width: width, height: height))
        renderer.frameProbe.reset()
        for frame in 0..<frames {
            // Per-frame autorelease pool: the Metal command buffer and the 22 MB readback
            // array are autoreleased, so without this they accumulate for the whole loop
            // and the footprint grows monotonically until the OS kills the process.
            autoreleasepool {
                // Frame-level trace, flushed, so a SIGKILL leaves evidence of WHICH frame
                // it died on. Frame 0 and 1 are the interesting ones (first use of freshly
                // allocated render targets at this size); after that every 10th is enough
                // to distinguish "died immediately" from "died part-way through".
                if frame < 2 || frame % 10 == 0 {
                    let memory = Self.memoryMB()
                    print(
                        String(
                            format: "[frame] %4dx%-4d #%02d  footprint %7.1f MB  avail %7.1f MB",
                            width, height, frame, memory.footprint, memory.availableToProcess
                        )
                    )
                    fflush(stdout)
                }
                XCTAssertTrue(renderer.renderOffscreenForTiming(width: width, height: height))
            }
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

    /// App memory footprint and the OS's remaining allowance, in MB.
    ///
    /// Added to settle WHY `testFiveMillionRealAssetMeasurementOnDevice` was dying with
    /// `signal kill` at `meshlet @ 2732x2048`. Two hypotheses had already been offered
    /// without evidence — clustering cost (refuted: linear, 3.4 s at 5.1M) and memory —
    /// so this measures rather than guesses again. `signal kill` with no jetsam line in
    /// the log is consistent with either an OOM termination or a watchdog, and the
    /// footprint-versus-allowance pair distinguishes them: if footprint climbs toward
    /// `os_proc_available_memory` reaching zero, it is memory.
    static func memoryMB() -> (footprint: Double, availableToProcess: Double) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        let mb = 1024.0 * 1024.0
        let footprint = status == KERN_SUCCESS ? Double(info.phys_footprint) / mb : -1
        return (footprint, Double(os_proc_available_memory()) / mb)
    }

    /// The OS's own thermal assessment, which is the direct way to settle whether
    /// sustained load is throttling this device rather than inferring it from frame times.
    /// Frame times at 1280x960 were IDENTICAL hot and cool (14.35 vs 14.27 ms), so
    /// throughput throttling was already doubtful — this says what the OS thinks.
    static func thermalStateName() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    /// Prints the footprint at a labelled point, flushed so the last line before a
    /// SIGKILL survives — an unflushed buffer is exactly what loses the evidence.
    static func reportMemory(_ label: String) {
        let (footprint, available) = memoryMB()
        print(
            String(
                format: "[mem] %-38s footprint %8.1f MB   available %8.1f MB   thermal %@",
                (label as NSString).utf8String!, footprint, available,
                thermalStateName() as NSString
            )
        )
        fflush(stdout)
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
            // Array-loaded geometry cannot drive the meshlet path (it has no source
            // Mesh, and clustering lives in the engine), so this asks for the indexed
            // path explicitly rather than silently rendering nothing.
            let renderer = try XCTUnwrap(
                ViewportRenderer(forcedTargetPathKind: .indexedVertex), "Metal unavailable"
            )
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

    /// THE ACCEPTANCE (add-meshlet-target-path task 1.1; master 2.2a): a
    /// multi-million-triangle Target derived from a REAL asset holds the 60fps budget
    /// on the meshlet path, at the iPad's native resolution.
    ///
    /// Asserts the WORST frame, not just the average. Measured on the indexed path the
    /// average was 16.06 ms (inside budget) while the worst frame was 19.65 ms — a
    /// dropped frame at 60 Hz. An average-only gate would have certified that as "runs
    /// at 60fps", which the user can see is false.
    ///
    /// Also asserts the path that RAN, because the renderer falls back when the mesh
    /// pipeline will not build: without this, a silent fallback would report the
    /// indexed path's numbers as the meshlet path's achievement.
    @MainActor
    func testMultiMillionTriangleAcceptanceOnDevice() throws {
        #if targetEnvironment(simulator)
            throw XCTSkip(Self.simulatorSkipReason)
        #else
            let url = try XCTUnwrap(
                Bundle(for: type(of: self)).url(forResource: "armadillo", withExtension: "obj"),
                "armadillo.obj not bundled in the test target"
            )
            let mesh = try Mesh.loadOBJ(at: url)
            for _ in 0..<3 { _ = try mesh.subdivide() }
            // "Multi-million" per the authoritative capability statement; the fixture
            // lands at ~4.8M. See the change's task 3.7 for why no committed asset hits
            // the 5M-plus band exactly.
            XCTAssertGreaterThan(mesh.faceCount, 4_000_000, "fixture is not multi-million")

            let renderer = try XCTUnwrap(
                ViewportRenderer(forcedTargetPathKind: .meshlet), "Metal unavailable"
            )
            renderer.load(mesh: mesh)
            XCTAssertTrue(renderer.hasMesh)
            XCTAssertEqual(
                renderer.renderPath.kind, .meshlet,
                "the mesh pipeline fell back; this would measure the indexed path"
            )

            let allocationsAfterLoad = renderer.geometryPool.allocationCount
            let budget = 1.0 / 60.0
            let stats = try measure(renderer: renderer, frames: 30, width: 2732, height: 2048)

            XCTAssertLessThan(stats.averageSeconds, budget, "average frame time")
            XCTAssertLessThan(
                stats.maxSeconds, budget,
                "WORST frame \(stats.maxSeconds * 1000) ms exceeds the 16.667 ms budget — "
                + "a hitch the user sees, however good the average"
            )
            XCTAssertEqual(
                renderer.geometryPool.allocationCount, allocationsAfterLoad,
                "rendering must not allocate GPU buffers per frame"
            )
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
            let url = try XCTUnwrap(
                Bundle(for: type(of: self)).url(
                    forResource: "armadillo", withExtension: "obj"
                ),
                "armadillo.obj not bundled in the test target"
            )
            Self.reportMemory("start")
            let mesh = try Mesh.loadOBJ(at: url)
            Self.reportMemory("armadillo loaded")
            // 100k x 4^3 = ~6.4M triangles. No reprojection: raw density is the point.
            for level in 0..<3 {
                _ = try mesh.subdivide()
                Self.reportMemory("subdivided x\(level + 1) (\(mesh.faceCount) faces)")
            }

            // BOTH paths over the same mesh, so the comparison is a like-for-like
            // measurement rather than two runs of different things.
            for kind in [TargetRenderPathKind.indexedVertex, .meshlet] {
                // Each path in its own pool so the FIRST renderer's GPU buffers are
                // actually released before the second is built. Measured: without this the
                // footprint carried 2.99 GB from the indexed path straight into the
                // meshlet path, so both paths' buffers were resident at once.
                try autoreleasepool {
                let renderer = try XCTUnwrap(
                    ViewportRenderer(forcedTargetPathKind: kind), "Metal unavailable"
                )
                Self.reportMemory("\(kind.rawValue): renderer created")
                renderer.load(mesh: mesh)
                Self.reportMemory("\(kind.rawValue): mesh loaded")
                XCTAssertTrue(renderer.hasMesh, "\(kind.rawValue) failed to load")
                // A fallback would silently compare a path with itself.
                XCTAssertEqual(renderer.renderPath.kind, kind, "path fell back")
                let clusters = mesh.meshletCount
                Self.reportMemory("\(kind.rawValue): \(clusters) clusters built")

                for (label, w, h) in [
                    ("1280x960", 1280, 960), ("2732x2048 (full iPad)", 2732, 2048),
                ] {
                    Self.reportMemory("\(kind.rawValue) @ \(label): before measure")
                    let stats = try measure(renderer: renderer, frames: 30, width: w, height: h)
                    Self.reportMemory("\(kind.rawValue) @ \(label): after measure")
                    print("""
                    [5M-real] \(kind.rawValue) @ \(label)
                      faces            = \(mesh.faceCount)   clusters = \(clusters)
                      avg frame        = \(String(format: "%.3f", stats.averageSeconds * 1000)) ms  (\(String(format: "%.1f", 1.0 / stats.averageSeconds)) fps)
                      max frame        = \(String(format: "%.3f", stats.maxSeconds * 1000)) ms
                      60fps budget     = 16.667 ms  -> \(stats.averageSeconds < 1.0 / 60.0 ? "MET" : "MISSED")
                    """)
                }
                }  // autoreleasepool: releases this path's renderer before the next
            }
        #endif
    }
}

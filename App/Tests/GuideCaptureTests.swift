import CyberKit
import Foundation
import Testing
import simd

@testable import CyberTopology

/// Guide-stroke capture (add-guide-stroke-authoring): arming the Guide tool and
/// drawing on the Target stores a world-space guide polyline on the surface; a
/// stroke that misses the Target stores nothing; clear empties them. Driven
/// through the real capture → controller pipeline. App-hosted, so it runs on the
/// iPad too.
@MainActor
struct GuideCaptureTests {
    @MainActor
    private final class Harness {
        var bundle = DocumentBundle()
        let coordinator: MetalViewport.Coordinator

        init() throws {
            coordinator = IsolatedViewportModel.viewport(
                bundle: DocumentBundle(), orbitSpeed: 1, zoomSpeed: 1, onUndo: {}, onRedo: {}
            ).makeCoordinator()
            _ = coordinator.makeView()
            try #require(coordinator.renderer != nil, "Metal device unavailable")
            coordinator.onCommit = { [weak self] command in
                self?.bundle.journal.record(command)
                command.apply(to: &self!.bundle)
                self?.sync()
            }
            coordinator.bundleProvider = { [weak self] in self?.bundle ?? DocumentBundle() }
        }

        func sync() { coordinator.syncMesh(from: bundle) }

        /// A flat ±5 Target plane at z = 0, framed so screen points project
        /// back onto it.
        func addTargetPlane() throws {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("guide-\(UUID().uuidString).obj")
            try "v -5 -5 0\nv 5 -5 0\nv 5 5 0\nv -5 5 0\nf 1 2 3 4\n"
                .write(to: url, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: url) }
            try bundle.addObject(name: "target", role: .target, mesh: try Mesh.loadOBJ(at: url))
            sync()
        }

        func screenPoint(of world: SIMD3<Float>) -> SIMD2<Double> {
            let m = coordinator.renderer!.viewProjectionColumns()
            let cx = m[0] * world.x + m[4] * world.y + m[8] * world.z + m[12]
            let cy = m[1] * world.x + m[5] * world.y + m[9] * world.z + m[13]
            let cw = m[3] * world.x + m[7] * world.y + m[11] * world.z + m[15]
            return SIMD2(Double(cx / cw) * 0.5 + 0.5, 1 - (Double(cy / cw) * 0.5 + 0.5))
        }

        func stroke(through points: [SIMD2<Double>]) {
            let capture = coordinator.inputModel.controller.capture
            guard let first = points.first else { return }
            capture.begin(
                source: .finger, verb: .pencil,
                sample: .init(time: 0, x: first.x, y: first.y, pressure: 0.5, type: .finger)
            )
            for (index, point) in points.dropFirst().enumerated() {
                capture.append(sample: .init(
                    time: Double(index + 1) * 0.02, x: point.x, y: point.y,
                    pressure: 0.5, type: .finger
                ))
            }
            capture.end()
        }

        var guides: [[SIMD3<Float>]] { coordinator.meshEditor.authoredGuides }
    }

    @Test("Drawing on the Target in guide mode stores a surface polyline")
    func guideStrokeStoredOnSurface() throws {
        let harness = try Harness()
        try harness.addTargetPlane()
        harness.coordinator.inputModel.armGuideMode()

        // A stroke across the plane at world y = 1.
        let sweep = (0...10).map { step -> SIMD2<Double> in
            harness.screenPoint(of: SIMD3(Float(step) / 10 * 4 - 2, 1, 0))
        }
        harness.stroke(through: sweep)

        #expect(harness.guides.count == 1, "one stroke stores one guide")
        let guide = try #require(harness.guides.first)
        #expect(guide.count >= 2)
        // Every captured point lies on the Target plane (z ≈ 0).
        for p in guide { #expect(abs(p.z) < 1e-3) }
        // The guide spans roughly the swept extent in x.
        let xs = guide.map(\.x)
        #expect((xs.max() ?? 0) - (xs.min() ?? 0) > 1)
    }

    @Test("A guide stroke over empty space stores nothing")
    func guideStrokeMissStoresNothing() throws {
        let harness = try Harness()
        try harness.addTargetPlane()
        harness.coordinator.inputModel.armGuideMode()

        // Screen corner, well off the framed plane — the raycast misses.
        harness.stroke(through: [SIMD2(0.02, 0.02), SIMD2(0.03, 0.03)])
        #expect(harness.guides.isEmpty)
    }

    @Test("Clear removes all authored guides")
    func clearRemovesGuides() throws {
        let harness = try Harness()
        try harness.addTargetPlane()
        harness.coordinator.inputModel.armGuideMode()
        let sweep = (0...10).map { harness.screenPoint(of: SIMD3(Float($0) / 10 * 4 - 2, 1, 0)) }
        harness.stroke(through: sweep)
        #expect(!harness.guides.isEmpty)

        harness.coordinator.inputModel.clearGuides()
        #expect(harness.guides.isEmpty)
    }
}

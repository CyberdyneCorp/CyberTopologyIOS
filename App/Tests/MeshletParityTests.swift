import CyberKit
import Metal
import XCTest

@testable import CyberTopology

/// Meshlet-path pixel parity (add-meshlet-target-path, task 3.5).
///
/// DEVICE-ONLY: mesh shaders do not exist on the simulator, so this skips there
/// LOUDLY (design D9; QA spec "No silent skips").
///
/// The meshlet path culls nothing the indexed path draws — no backface rejection,
/// because the Target renders double-sided — so the two must produce the SAME image.
/// This is the test that would catch a cone or sphere test that is subtly too tight:
/// over-aggressive culling shows up as holes in the model, not as a crash, and a
/// frame-time number from a path that renders incorrectly is worthless.
final class MeshletParityTests: XCTestCase {
    static let simulatorSkipReason =
        "device-only: mesh shaders are unavailable on the simulator "
        + "(design D9 device release gate; QA spec 'No silent skips')"

    private func loadModel(_ name: String) throws -> Mesh {
        let url = try XCTUnwrap(
            Bundle(for: type(of: self)).url(forResource: name, withExtension: "obj"),
            "\(name).obj not bundled in the test target"
        )
        return try Mesh.loadOBJ(at: url)
    }

    /// Renders one mesh through a renderer forced onto `kind`.
    @MainActor
    private func frame(
        _ mesh: Mesh, kind: TargetRenderPathKind, width: Int, height: Int
    ) throws -> (pixels: [UInt8], path: TargetRenderPathKind) {
        let renderer = try XCTUnwrap(
            ViewportRenderer(forcedTargetPathKind: kind), "Metal unavailable"
        )
        renderer.load(mesh: mesh)
        XCTAssertTrue(renderer.hasMesh, "\(kind.rawValue) failed to load the mesh")
        let pixels = try XCTUnwrap(renderer.renderOffscreen(width: width, height: height))
        return (pixels, renderer.renderPath.kind)
    }

    /// Fraction of pixels that differ by more than `tolerance` in any channel.
    private func differingFraction(_ a: [UInt8], _ b: [UInt8], tolerance: Int) -> Double {
        XCTAssertEqual(a.count, b.count)
        var differing = 0
        for i in stride(from: 0, to: min(a.count, b.count), by: 4) {
            for c in 0..<3 where abs(Int(a[i + c]) - Int(b[i + c])) > tolerance {
                differing += 1
                break
            }
        }
        return Double(differing) / Double(a.count / 4)
    }

    @MainActor
    func testMeshletPathRendersTheSameImageAsTheIndexedPathOnDevice() throws {
        #if targetEnvironment(simulator)
            throw XCTSkip(Self.simulatorSkipReason)
        #else
            let mesh = try loadModel("armadillo")
            let indexed = try frame(mesh, kind: .indexedVertex, width: 512, height: 512)
            let meshlet = try frame(mesh, kind: .meshlet, width: 512, height: 512)

            // The forced kinds must actually have been used, or this compares a path
            // with itself and proves nothing.
            XCTAssertEqual(indexed.path, .indexedVertex)
            XCTAssertEqual(
                meshlet.path, .meshlet,
                "the meshlet pipeline did not build; parity would be vacuous"
            )

            // Some geometry must be on screen, else two blank frames match trivially.
            let background = try XCTUnwrap(
                ViewportRenderer(forcedTargetPathKind: .indexedVertex)
            ).renderOffscreen(width: 512, height: 512)
            let covered = differingFraction(indexed.pixels, try XCTUnwrap(background), tolerance: 8)
            XCTAssertGreaterThan(covered, 0.05, "the model barely covers the frame")

            // Rasterisation order differs between the paths, so exactly-equal bytes are
            // not a fair requirement; a hole or a dropped cluster would show as a large
            // differing area, which this bounds tightly.
            let differing = differingFraction(indexed.pixels, meshlet.pixels, tolerance: 8)
            XCTAssertLessThan(
                differing, 0.01,
                "meshlet and indexed paths disagree on \(differing * 100)% of pixels — "
                + "a dropped cluster or over-tight cull"
            )
        #endif
    }

    /// A cluster wholly outside the view must be culled, and that must not change the
    /// image — which is the only safe form of culling this path performs.
    @MainActor
    func testFrustumCullingDoesNotChangeTheImageOnDevice() throws {
        #if targetEnvironment(simulator)
            throw XCTSkip(Self.simulatorSkipReason)
        #else
            let mesh = try loadModel("stanford-bunny")
            let indexed = try frame(mesh, kind: .indexedVertex, width: 384, height: 384)
            let meshlet = try frame(mesh, kind: .meshlet, width: 384, height: 384)
            XCTAssertEqual(meshlet.path, .meshlet)
            let differing = differingFraction(indexed.pixels, meshlet.pixels, tolerance: 8)
            XCTAssertLessThan(differing, 0.01, "differing \(differing * 100)%")
        #endif
    }
}

extension MeshletParityTests {
    /// Reports why the meshlet pipeline is unavailable, if it is. Not a parity check —
    /// a diagnostic, so a silent fallback is never a mystery.
    @MainActor
    func testMeshletPipelineAvailabilityOnDevice() throws {
        #if targetEnvironment(simulator)
            throw XCTSkip(Self.simulatorSkipReason)
        #else
            let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
            let reason = MeshletRenderPath.unavailabilityReason(device: device)
            print("[meshlet-availability] \(reason ?? "available")")
            XCTAssertNil(reason, "meshlet pipeline unavailable: \(reason ?? "")")
        #endif
    }
}

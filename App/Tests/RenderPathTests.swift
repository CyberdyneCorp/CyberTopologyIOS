import CyberKit
import Metal
import Testing
@testable import CyberTopology

/// Capability detection + render-path selection tests (task 2.2: the
/// capability-gated pipeline split). The simulator exercises the fallback
/// selection by design; the meshlet branch of `preferredKind` is covered
/// through injected capabilities.
@MainActor
struct RenderPathTests {
    private func makeDevice() throws -> MTLDevice {
        try #require(MTLCreateSystemDefaultDevice(), "Metal unavailable")
    }

    // MARK: - Capability detection

    @Test func capabilityDetectionMatchesDevice() throws {
        let device = try makeDevice()
        let capabilities = RenderPathCapabilities(device: device)
        #expect(capabilities.hasUnifiedMemory == device.hasUnifiedMemory)
        #if targetEnvironment(simulator)
            // The simulator never implements mesh shaders, regardless of the
            // host GPU family it advertises.
            #expect(!capabilities.supportsMeshShaders)
        #else
            #expect(
                capabilities.supportsMeshShaders
                    == (device.supportsFamily(.metal3) && device.supportsFamily(.apple7))
            )
        #endif
    }

    // MARK: - Path selection

    @Test func meshShaderHardwarePrefersMeshletPath() {
        let capabilities = RenderPathCapabilities(
            supportsMeshShaders: true, hasUnifiedMemory: true
        )
        #expect(TargetRenderPathSelection.preferredKind(for: capabilities) == .meshlet)
    }

    @Test func preA14HardwarePrefersIndexedVertexPath() {
        let capabilities = RenderPathCapabilities(
            supportsMeshShaders: false, hasUnifiedMemory: true
        )
        #expect(TargetRenderPathSelection.preferredKind(for: capabilities) == .indexedVertex)
    }

    /// The meshlet pipeline landed (add-meshlet-target-path), so selection now
    /// follows the capability rather than resolving everything to the fallback.
    ///
    /// This test previously asserted `.indexedVertex` for BOTH cases — it encoded the
    /// pre-meshlet state, which its name ("Today") said out loud. Updated rather than
    /// deleted, because the half that still matters is the second case: the fallback
    /// remains mandated for the simulator and pre-A14 hardware.
    @Test(arguments: [true, false])
    func availableKindFollowsMeshShaderSupport(supportsMeshShaders: Bool) {
        let capabilities = RenderPathCapabilities(
            supportsMeshShaders: supportsMeshShaders, hasUnifiedMemory: true
        )
        #expect(
            TargetRenderPathSelection.availableKind(for: capabilities)
                == (supportsMeshShaders ? .meshlet : .indexedVertex)
        )
    }

    /// Selection is not the whole story: the RENDERER must fall back when the mesh
    /// pipeline will not build, because mesh-shader support is a capability claim and a
    /// shader-compile failure must never blank the viewport. On the simulator the
    /// pipeline is always unavailable, which makes this assertable there.
    @Test func rendererFallsBackWhenTheMeshPipelineIsUnavailable() throws {
        let renderer = try #require(ViewportRenderer(forcedTargetPathKind: .meshlet))
        let device = try #require(renderer.device as MTLDevice?)
        if MeshletRenderPath.unavailabilityReason(device: device) == nil {
            #expect(renderer.renderPath.kind == .meshlet)
        } else {
            #expect(
                renderer.renderPath.kind == .indexedVertex,
                "an unbuildable mesh pipeline must fall back, not render nothing"
            )
        }
    }

    /// The renderer activates the SELECTED path, or the indexed fallback when the
    /// selected one will not build.
    ///
    /// Previously this also asserted `.indexedVertex` unconditionally, which encoded the
    /// pre-meshlet state — and the equality on its own is too strict now, because a
    /// legitimate fallback (shader compile failure on some future OS) would fail it.
    /// Both halves are stated instead of one absolute.
    @Test func rendererActivatesSelectedPathOrFallsBack() throws {
        let renderer = try #require(ViewportRenderer())
        let selected = TargetRenderPathSelection.availableKind(for: renderer.capabilities)
        if renderer.activeRenderPathKind == selected {
            #expect(renderer.activeRenderPathKind == selected)
        } else {
            #expect(selected == .meshlet, "only the meshlet selection may fall back")
            #expect(renderer.activeRenderPathKind == .indexedVertex)
            let device = try #require(renderer.device as MTLDevice?)
            #expect(
                MeshletRenderPath.unavailabilityReason(device: device) != nil,
                "fell back even though the mesh pipeline was buildable"
            )
        }
    }

    // MARK: - Indexed vertex path behavior

    @Test func loadRejectsEmptyGeometry() throws {
        let device = try makeDevice()
        let queue = try #require(device.makeCommandQueue())
        let pool = GeometryBufferPool(
            device: device, commandQueue: queue, preferPrivateStorage: false
        )
        let path = try #require(IndexedVertexRenderPath(device: device, bufferPool: pool))

        let empty: [Float] = []
        let noIndices: [UInt32] = []
        let loaded = empty.withUnsafeBufferPointer { positions in
            noIndices.withUnsafeBufferPointer { indices in
                path.load(
                    TargetGeometry(
                        positions: positions, normals: positions, colors: nil, indices: indices
                    )
                )
            }
        }
        #expect(!loaded)
        #expect(!path.hasGeometry)
    }

    @Test func clearDropsGeometryButKeepsPoolCapacity() throws {
        let renderer = try #require(ViewportRenderer())
        renderer.loadGeometry(
            positions: [0, 0, 0, 1, 0, 0, 0, 1, 0],
            normals: [0, 0, 1, 0, 0, 1, 0, 0, 1],
            colors: [1, 0, 0, 0, 1, 0, 0, 0, 1],
            indices: [0, 1, 2]
        )
        #expect(renderer.hasMesh)
        let capacity = renderer.geometryPool.capacity(for: .position)
        renderer.clearMesh()
        #expect(!renderer.hasMesh)
        #expect(renderer.geometryPool.capacity(for: .position) == capacity)
    }

    /// hasColors == false ⇒ neutral-gray substitution: the rendered surface
    /// must be achromatic (equal-ish RGB), not black and not background.
    @Test func missingColorsRenderNeutralGray() throws {
        let renderer = try #require(ViewportRenderer())
        let background = try #require(ViewportRenderer())
        let empty = try #require(background.renderOffscreen(width: 96, height: 96))

        renderer.loadGeometry(
            positions: [0, 0, 0, 1, 0, 0, 0, 1, 0],
            normals: [0, 0, 1, 0, 0, 1, 0, 0, 1],
            colors: nil,
            indices: [0, 1, 2]
        )
        let frame = try #require(renderer.renderOffscreen(width: 96, height: 96))

        var grayPixels = 0
        for base in stride(from: 0, to: frame.count, by: 4)
        where Array(frame[base..<base + 4]) != Array(empty[base..<base + 4]) {
            let blue = Int(frame[base]), green = Int(frame[base + 1]), red = Int(frame[base + 2])
            if abs(red - green) <= 6, abs(green - blue) <= 6, red > 40 {
                grayPixels += 1
            }
        }
        #expect(grayPixels > 300)
    }

    /// The two storage strategies must be pixel-identical: private storage
    /// changes where geometry lives, never what renders.
    @Test func privateAndSharedStorageRenderIdenticalFrames() throws {
        let shared = try #require(ViewportRenderer(preferPrivateGeometryStorage: false))
        let priv = try #require(ViewportRenderer(preferPrivateGeometryStorage: true))
        #expect(!shared.geometryPool.usesPrivateStorage)
        #expect(priv.geometryPool.usesPrivateStorage)

        let seedURL = try UITestSupport.writeSeedOBJ()
        shared.load(mesh: try Mesh.loadOBJ(at: seedURL))
        priv.load(mesh: try Mesh.loadOBJ(at: seedURL))

        let frameShared = try #require(shared.renderOffscreen(width: 128, height: 128))
        let framePrivate = try #require(priv.renderOffscreen(width: 128, height: 128))
        #expect(frameShared == framePrivate)
    }
}

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

    /// The meshlet pipeline is a follow-up: until it exists, selection must
    /// resolve every preference to the working indexed vertex path (honest
    /// seam — never a faked meshlet).
    @Test(arguments: [true, false])
    func availableKindIsIndexedVertexToday(supportsMeshShaders: Bool) {
        let capabilities = RenderPathCapabilities(
            supportsMeshShaders: supportsMeshShaders, hasUnifiedMemory: true
        )
        #expect(TargetRenderPathSelection.availableKind(for: capabilities) == .indexedVertex)
    }

    @Test func rendererActivatesSelectedPath() throws {
        let renderer = try #require(ViewportRenderer())
        #expect(
            renderer.activeRenderPathKind
                == TargetRenderPathSelection.availableKind(for: renderer.capabilities)
        )
        #expect(renderer.activeRenderPathKind == .indexedVertex)
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

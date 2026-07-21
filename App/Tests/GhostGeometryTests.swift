import CyberKit
import Foundation
import Metal
import Testing
import simd
@testable import CyberTopology

/// Ghost geometry tests (task 2.4, spec: viewport-rendering / "Ghost
/// geometry rendering"): pure style/pulse/uniform math, the zero-copy
/// buffer-sharing decision, and offscreen renders asserting the ghost style
/// is measurably distinct from the committed EditMesh wireframe. All GPU
/// tests run on the simulator's plain vertex pipeline by design.
@MainActor
struct GhostGeometryTests {
    private func makeRenderer() throws -> ViewportRenderer {
        try #require(ViewportRenderer(), "Metal device unavailable")
    }

    private func seedMesh() throws -> Mesh {
        try Mesh.loadOBJ(at: UITestSupport.writeSeedOBJ())
    }

    /// Unit quad in the z=0 plane: ghost fill (2 triangles) + committed
    /// wireframe (4 authored edges) share these vertices.
    private static let quadPositions: [Float] = [
        0, 0, 0, /**/ 1, 0, 0, /**/ 1, 1, 0, /**/ 0, 1, 0,
    ]
    private static let quadNormals: [Float] = [
        0, 0, 1, /**/ 0, 0, 1, /**/ 0, 0, 1, /**/ 0, 0, 1,
    ]
    private static let quadTriangles: [UInt32] = [0, 1, 2, 0, 2, 3]
    private static let quadEdges: [UInt32] = [0, 1, 1, 2, 2, 3, 3, 0]

    /// Pulse sample times far past any overlay creation animation, at the
    /// exact peak/trough of the default style's pulse.
    private static let pulseBase = 700 * GhostStyle.proposal.pulsePeriod
    private static let peakTime = pulseBase + GhostStyle.proposal.pulsePeakPhase
    private static let troughTime = pulseBase + GhostStyle.proposal.pulseTroughPhase

    /// Frames the camera on the unit quad without loading target geometry
    /// (keeps the background a flat clear color for pixel classification).
    private func frameCameraOnQuad(_ renderer: ViewportRenderer) throws {
        renderer.setViewportSize(CGSize(width: 128, height: 128))
        let bounds = try #require(SceneBounds(positions: Self.quadPositions))
        renderer.camera = CameraState.framing(bounds, aspect: 1)
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

    /// Pixels differing from `background`, classified by channel dominance
    /// (BGRA layout): "warm" = red clearly above blue (ghost amber),
    /// "cool" = blue clearly above red (committed wireframe cyan).
    private func classifyAgainst(
        _ background: [UInt8], frame: [UInt8]
    ) -> (warm: Int, cool: Int) {
        var warm = 0, cool = 0
        for base in stride(from: 0, to: min(frame.count, background.count), by: 4)
        where frame[base..<base + 4] != background[base..<base + 4] {
            let blue = Int(frame[base]), red = Int(frame[base + 2])
            if red > blue + 30 { warm += 1 }
            if blue > red + 30 { cool += 1 }
        }
        return (warm, cool)
    }

    // MARK: - Pulse math (pure)

    @Test func pulsedAlphaHitsPeakAndTroughAtDocumentedPhases() {
        let style = GhostStyle.proposal
        let peak = style.pulsedAlpha(at: Self.peakTime)
        let trough = style.pulsedAlpha(at: Self.troughTime)
        #expect(abs(peak - style.baseAlpha) < 1e-4)
        #expect(abs(trough - style.baseAlpha * style.pulseFloor) < 1e-4)
        #expect(peak > trough)
    }

    @Test func pulsedAlphaIsBoundedAndPeriodic() {
        let style = GhostStyle.proposal
        let floorAlpha = style.baseAlpha * style.pulseFloor
        for step in 0...40 {
            let time = 123.4 + Double(step) / 40 * style.pulsePeriod
            let alpha = style.pulsedAlpha(at: time)
            #expect(alpha >= floorAlpha - 1e-4)
            #expect(alpha <= style.baseAlpha + 1e-4)
            #expect(abs(alpha - style.pulsedAlpha(at: time + style.pulsePeriod)) < 1e-4)
        }
    }

    @Test func zeroPulsePeriodDegradesToConstantBaseAlpha() {
        var style = GhostStyle.proposal
        style.pulsePeriod = 0
        #expect(style.pulsedAlpha(at: 1.23) == style.baseAlpha)
    }

    @Test func debugPreviewOffsetScalesWithSceneRadius() {
        #expect(GhostStyle.debugPreview(sceneRadius: 2).normalOffset == 0.04)
        #expect(GhostStyle.debugPreview(sceneRadius: 0).normalOffset > 0)
        // Everything else stays the standard proposal style.
        var expected = GhostStyle.proposal
        expected.normalOffset = GhostStyle.debugPreview(sceneRadius: 2).normalOffset
        #expect(GhostStyle.debugPreview(sceneRadius: 2) == expected)
    }

    @Test func uniformsCarryStyleViewDirectionAndPulsedAlpha() {
        var style = GhostStyle.proposal
        style.normalOffset = 0.03
        let uniforms = GhostUniformsFactory.uniforms(
            mvp: matrix_identity_float4x4,
            viewDirection: SIMD3(0, 0, -1),
            style: style,
            time: Self.troughTime
        )
        #expect(
            SIMD3(uniforms.color.x, uniforms.color.y, uniforms.color.z) == style.color
        )
        #expect(uniforms.color.w == style.pulsedAlpha(at: Self.troughTime))
        #expect(uniforms.params.x == 0.03)
        #expect(uniforms.params.y == style.rimStrength)
        #expect(uniforms.viewDir == SIMD4(0, 0, -1, 0))
    }

    /// The ghost tint must be distinct from the committed wireframe theme
    /// (spec: "clearly distinguishable from committed EditMesh geometry").
    @Test func ghostColorIsDistinctFromCommittedWireColor() {
        let distance = simd_length(
            GhostStyle.proposal.color - OverlayUniformsFactory.wireColor
        )
        #expect(distance > 0.5)
    }

    // MARK: - Buffer-sharing decision (pure; task 2.4 zero-copy)

    private static let page = 16384

    @Test func alignedPagePaddedUnifiedBuffersQualifyForZeroCopy() {
        #expect(
            EngineBufferSharing.path(
                baseAddress: UInt(4 * Self.page), byteCount: 2 * Self.page,
                hasUnifiedMemory: true, pageSize: Self.page
            ) == .zeroCopy
        )
    }

    @Test func misalignedBaseAddressFallsBackToPooledCopy() {
        #expect(
            EngineBufferSharing.path(
                baseAddress: UInt(4 * Self.page + 16), byteCount: 2 * Self.page,
                hasUnifiedMemory: true, pageSize: Self.page
            ) == .pooledCopy
        )
    }

    @Test func nonPageMultipleLengthFallsBackToPooledCopy() {
        // The engine's malloc-backed caches are sized to content — this is
        // the case that keeps pooled-copy the active path today.
        #expect(
            EngineBufferSharing.path(
                baseAddress: UInt(4 * Self.page), byteCount: 12_345,
                hasUnifiedMemory: true, pageSize: Self.page
            ) == .pooledCopy
        )
    }

    @Test func nonUnifiedMemoryFallsBackToPooledCopy() {
        #expect(
            EngineBufferSharing.path(
                baseAddress: UInt(4 * Self.page), byteCount: 2 * Self.page,
                hasUnifiedMemory: false, pageSize: Self.page
            ) == .pooledCopy
        )
    }

    @Test func degenerateInputsFallBackToPooledCopy() {
        #expect(
            EngineBufferSharing.path(
                baseAddress: 0, byteCount: Self.page,
                hasUnifiedMemory: true, pageSize: Self.page
            ) == .pooledCopy
        )
        #expect(
            EngineBufferSharing.path(
                baseAddress: UInt(Self.page), byteCount: 0,
                hasUnifiedMemory: true, pageSize: Self.page
            ) == .pooledCopy
        )
        #expect(
            EngineBufferSharing.path(
                baseAddress: UInt(Self.page), byteCount: Self.page,
                hasUnifiedMemory: true, pageSize: 0
            ) == .pooledCopy
        )
    }

    @Test func aggregateDecisionRequiresEveryStreamToQualify() {
        let good = (baseAddress: UInt(4 * Self.page), byteCount: Self.page)
        let bad = (baseAddress: UInt(4 * Self.page + 8), byteCount: Self.page)
        #expect(
            EngineBufferSharing.path(
                streams: [good, good, good], hasUnifiedMemory: true, pageSize: Self.page
            ) == .zeroCopy
        )
        #expect(
            EngineBufferSharing.path(
                streams: [good, bad, good], hasUnifiedMemory: true, pageSize: Self.page
            ) == .pooledCopy
        )
        #expect(
            EngineBufferSharing.path(
                streams: [], hasUnifiedMemory: true, pageSize: Self.page
            ) == .pooledCopy
        )
    }

    // MARK: - Buffer-path integration

    /// Engine render caches are malloc-backed and content-sized (known
    /// upstream issue), so a real mesh load takes the pooled single-memcpy
    /// path — and, per the lifetime contract, must NOT retain the mesh.
    @Test func engineMeshGhostLoadsViaPooledCopyToday() throws {
        let renderer = try makeRenderer()
        renderer.loadGhost(mesh: try seedMesh())
        #expect(renderer.hasGhost)
        #expect(renderer.ghostPath.activeSharing == .pooledCopy)
        #expect(renderer.ghostSourceMesh == nil)
        #expect(renderer.ghostPath.indexCount == 6)  // seed quad → 2 triangles
    }

    /// Page-aligned, page-padded buffers on unified memory take the true
    /// zero-copy path: `bytesNoCopy` wrappers, no pool allocation, and the
    /// wrapped pages render. The test owns the memory, so it clears the
    /// ghost (dropping the aliasing MTLBuffers) before freeing — the same
    /// ordering the renderer guarantees by retaining `ghostSourceMesh`.
    @Test func pageAlignedUnifiedBuffersLoadZeroCopy() throws {
        let renderer = try makeRenderer()
        try frameCameraOnQuad(renderer)
        let background = try #require(
            renderer.renderOffscreen(width: 128, height: 128, at: Self.peakTime)
        )

        let pageSize = Int(getpagesize())
        let floatsPerPage = pageSize / 4
        // Page-padded AND stream-valid counts: multiples of one page that
        // are also multiples of 3 (xyz triples / index triples).
        let positionCount = 3 * floatsPerPage
        let indexCount = 3 * floatsPerPage

        // `bytesNoCopy` requires VM-allocated pages (mmap/vm_allocate), not
        // malloc memory — the same allocation contract the engine must adopt
        // upstream for its render caches to qualify.
        func allocatePages(byteCount: Int) throws -> UnsafeMutableRawPointer {
            let raw = mmap(
                nil, byteCount, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0
            )
            let pointer = try #require(raw)
            #expect(pointer != MAP_FAILED)
            return pointer
        }
        let positionsRaw = try allocatePages(byteCount: positionCount * 4)
        let normalsRaw = try allocatePages(byteCount: positionCount * 4)
        let indicesRaw = try allocatePages(byteCount: indexCount * 4)
        defer {
            munmap(positionsRaw, positionCount * 4)
            munmap(normalsRaw, positionCount * 4)
            munmap(indicesRaw, indexCount * 4)
        }

        // Fill with the unit quad, repeated: vertices 0-3 are the quad,
        // the padding repeats vertex 0; indices repeat the quad's two
        // triangles (degenerate repeats draw the same pixels).
        let positions = positionsRaw.bindMemory(to: Float.self, capacity: positionCount)
        let normals = normalsRaw.bindMemory(to: Float.self, capacity: positionCount)
        for vertex in 0..<(positionCount / 3) {
            let source = vertex < 4 ? vertex : 0
            for axis in 0..<3 {
                positions[vertex * 3 + axis] = Self.quadPositions[source * 3 + axis]
                normals[vertex * 3 + axis] = Self.quadNormals[source * 3 + axis]
            }
        }
        let indices = indicesRaw.bindMemory(to: UInt32.self, capacity: indexCount)
        for index in 0..<indexCount {
            indices[index] = Self.quadTriangles[index % Self.quadTriangles.count]
        }

        let loaded = renderer.ghostPath.load(
            positions: UnsafeBufferPointer(start: positions, count: positionCount),
            normals: UnsafeBufferPointer(start: normals, count: positionCount),
            indices: UnsafeBufferPointer(start: indices, count: indexCount),
            hasUnifiedMemory: true,
            allowZeroCopy: true,
            pageSize: pageSize
        )
        #expect(loaded)
        #expect(renderer.ghostPath.activeSharing == .zeroCopy)
        // Zero-copy means zero pool allocations for this geometry.
        #expect(renderer.ghostPath.bufferPool.allocationCount == 0)

        let frame = try #require(
            renderer.renderOffscreen(width: 128, height: 128, at: Self.peakTime)
        )
        #expect(differingPixels(frame, background) > 500)

        // Drop the aliasing MTLBuffers before `defer` frees the pages.
        renderer.clearGhost()
        #expect(!renderer.hasGhost)
        #expect(renderer.ghostPath.activeSharing == nil)
    }

    /// Three page-aligned, page-padded, VM-allocated (`mmap`) streams — the
    /// allocation contract `makeBuffer(bytesNoCopy:)` requires. Contents are
    /// uninitialized (zero) pages: fine for load-path tests that never draw.
    private func withVMAllocatedStreams(
        _ body: @MainActor (
            _ positions: UnsafeBufferPointer<Float>,
            _ normals: UnsafeBufferPointer<Float>,
            _ indices: UnsafeBufferPointer<UInt32>,
            _ pageSize: Int
        ) throws -> Void
    ) throws {
        let pageSize = Int(getpagesize())
        // Page-multiple AND stream-valid: 3 pages of elements per stream.
        let count = 3 * (pageSize / 4)
        func allocatePages() throws -> UnsafeMutableRawPointer {
            let raw = try #require(
                mmap(nil, count * 4, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0)
            )
            #expect(raw != MAP_FAILED)
            return raw
        }
        let positionsRaw = try allocatePages()
        let normalsRaw = try allocatePages()
        let indicesRaw = try allocatePages()
        defer {
            munmap(positionsRaw, count * 4)
            munmap(normalsRaw, count * 4)
            munmap(indicesRaw, count * 4)
        }
        try body(
            UnsafeBufferPointer(
                start: positionsRaw.bindMemory(to: Float.self, capacity: count), count: count
            ),
            UnsafeBufferPointer(
                start: normalsRaw.bindMemory(to: Float.self, capacity: count), count: count
            ),
            UnsafeBufferPointer(
                start: indicesRaw.bindMemory(to: UInt32.self, capacity: count), count: count
            ),
            pageSize
        )
    }

    /// Regression (review finding): the page-alignment/size decision cannot
    /// detect the allocator, and Darwin's large-zone malloc returns
    /// page-aligned storage — so a coincidentally qualifying buffer must
    /// stay pooled whenever the caller cannot vouch for the VM-allocation
    /// contract (`allowZeroCopy: false`). `loadGhost` gates on
    /// `engineRenderCachesAreVMAllocated`, which stays false until the
    /// upstream page-aligned VM-allocation patch lands.
    @Test func qualifyingBuffersStayPooledWithoutVMAllocationGuarantee() throws {
        #expect(!EngineBufferSharing.engineRenderCachesAreVMAllocated)
        let renderer = try makeRenderer()
        try withVMAllocatedStreams { positions, normals, indices, pageSize in
            let loaded = renderer.ghostPath.load(
                positions: positions, normals: normals, indices: indices,
                hasUnifiedMemory: true,
                allowZeroCopy: false,  // what loadGhost passes today
                pageSize: pageSize
            )
            #expect(loaded)
            #expect(renderer.ghostPath.activeSharing == .pooledCopy)
            // Pooled means real allocations, not bytesNoCopy wrappers: one
            // per stream, plus the reusable staging buffer when the pool
            // blits into private storage (allocationCount counts staging by
            // contract; the simulator device reports no unified memory, so
            // the default-configured pool takes the private-storage path).
            let pool = renderer.ghostPath.bufferPool
            let expectedAllocations = 3 + (pool.usesPrivateStorage ? 1 : 0)
            #expect(pool.allocationCount == expectedAllocations)
            renderer.clearGhost()
        }
    }

    /// Regression (review finding): every transition away from live
    /// zero-copy wrappers (reload — zero-copy, pooled — or clear) must
    /// drain the command queue BEFORE the wrappers drop, because releasing
    /// the wrapped memory's owner right after would free pages an in-flight
    /// frame may still be reading (`deallocator: nil` wrappers do not own
    /// the memory). Pooled-only transitions must not pay the fence.
    @Test func zeroCopyTransitionsDrainTheQueueBeforeReleasingMemory() throws {
        let renderer = try makeRenderer()
        try withVMAllocatedStreams { positions, normals, indices, pageSize in
            @MainActor func loadZeroCopy() -> Bool {
                renderer.ghostPath.load(
                    positions: positions, normals: normals, indices: indices,
                    hasUnifiedMemory: true, allowZeroCopy: true, pageSize: pageSize
                )
            }

            // First zero-copy load: no prior wrappers, no fence.
            #expect(loadZeroCopy())
            #expect(renderer.ghostPath.activeSharing == .zeroCopy)
            #expect(renderer.ghostPath.zeroCopyReleaseSynchronizations == 0)

            // zeroCopy → zeroCopy reload: fence before old wrappers drop.
            #expect(loadZeroCopy())
            #expect(renderer.ghostPath.zeroCopyReleaseSynchronizations == 1)

            // zeroCopy → pooled (fresh pool allocation skips the pool's own
            // reuse fence — the ghost path must still fence the wrappers).
            renderer.loadGhostGeometry(
                positions: Array(positions), normals: Array(normals),
                indices: Array(indices)
            )
            #expect(renderer.ghostPath.activeSharing == .pooledCopy)
            #expect(renderer.ghostPath.zeroCopyReleaseSynchronizations == 2)

            // pooled → clear: no live wrappers, no fence.
            renderer.clearGhost()
            #expect(renderer.ghostPath.zeroCopyReleaseSynchronizations == 2)

            // zeroCopy → clear: fence before the owner is released.
            #expect(loadZeroCopy())
            renderer.clearGhost()
            #expect(renderer.ghostPath.zeroCopyReleaseSynchronizations == 3)
        }
    }

    /// The array-based entry must never wrap transient storage, even when
    /// a large Swift array happens to be page-aligned.
    @Test func transientArrayLoadsAlwaysCopy() throws {
        let renderer = try makeRenderer()
        let vertexCount = 4 * Int(getpagesize())
        var positions = [Float](), normals = [Float]()
        positions.reserveCapacity(vertexCount * 3)
        normals.reserveCapacity(vertexCount * 3)
        for vertex in 0..<vertexCount {
            let source = vertex % 4
            for axis in 0..<3 {
                positions.append(Self.quadPositions[source * 3 + axis])
                normals.append(Self.quadNormals[source * 3 + axis])
            }
        }
        let indices = (0..<vertexCount).flatMap { _ in Self.quadTriangles }
        renderer.loadGhostGeometry(positions: positions, normals: normals, indices: indices)
        #expect(renderer.hasGhost)
        #expect(renderer.ghostPath.activeSharing == .pooledCopy)
        #expect(renderer.ghostSourceMesh == nil)
    }

    @Test func emptyGhostLoadClearsAndClearGhostResets() throws {
        let renderer = try makeRenderer()
        renderer.loadGhostGeometry(
            positions: Self.quadPositions, normals: Self.quadNormals,
            indices: Self.quadTriangles
        )
        #expect(renderer.hasGhost)
        renderer.loadGhost(mesh: try Mesh())
        #expect(!renderer.hasGhost)
        #expect(renderer.ghostPath.activeSharing == nil)

        renderer.loadGhostGeometry(
            positions: Self.quadPositions, normals: Self.quadNormals,
            indices: Self.quadTriangles
        )
        renderer.clearGhost()
        #expect(!renderer.hasGhost)
        #expect(renderer.ghostSourceMesh == nil)
    }

    @Test func ghostLoadsDoNotReallocateOnSameSizeReload() throws {
        let renderer = try makeRenderer()
        renderer.loadGhostGeometry(
            positions: Self.quadPositions, normals: Self.quadNormals,
            indices: Self.quadTriangles
        )
        let allocations = renderer.ghostPath.bufferPool.allocationCount
        renderer.loadGhostGeometry(
            positions: Self.quadPositions, normals: Self.quadNormals,
            indices: Self.quadTriangles
        )
        #expect(renderer.renderOffscreen(width: 32, height: 32, at: Self.peakTime) != nil)
        #expect(renderer.ghostPath.bufferPool.allocationCount == allocations)
    }

    // MARK: - Offscreen renders (spec scenario "Ghost vs committed
    // distinction" — render half; the accept → standard-style transition
    // is the Weave accept flow, task 5.4)

    /// One frame with the committed wireframe and a ghost displayed
    /// alongside: the frame must contain BOTH a cool (cyan) committed
    /// population and a clearly larger warm (amber) translucent ghost fill
    /// — visually distinct styles in the same frame.
    @Test func ghostRendersVisiblyDistinctAlongsideCommittedWireframe() throws {
        let renderer = try makeRenderer()
        try frameCameraOnQuad(renderer)
        let background = try #require(
            renderer.renderOffscreen(width: 128, height: 128, at: Self.peakTime)
        )

        renderer.loadOverlayGeometry(
            positions: Self.quadPositions, edges: Self.quadEdges, at: 0
        )
        renderer.loadGhostGeometry(
            positions: Self.quadPositions, normals: Self.quadNormals,
            indices: Self.quadTriangles
        )
        renderer.ghostStyle = .debugPreview(sceneRadius: renderer.camera.distance / 3)

        let frame = try #require(
            renderer.renderOffscreen(width: 128, height: 128, at: Self.peakTime)
        )
        let (warm, cool) = classifyAgainst(background, frame: frame)
        #expect(warm > 400, "ghost fill (amber) must cover a visible area")
        #expect(cool > 60, "committed wireframe (cyan) must stay visible")
    }

    /// Ghost-only and committed-only renders of the same geometry must be
    /// measurably different images (translucent pulsing fill vs wireframe).
    @Test func ghostStyleDiffersMeasurablyFromCommittedStyle() throws {
        let renderer = try makeRenderer()
        try frameCameraOnQuad(renderer)

        renderer.loadOverlayGeometry(
            positions: Self.quadPositions, edges: Self.quadEdges, at: 0
        )
        let committed = try #require(
            renderer.renderOffscreen(width: 128, height: 128, at: Self.peakTime)
        )
        renderer.clearOverlay()

        renderer.loadGhostGeometry(
            positions: Self.quadPositions, normals: Self.quadNormals,
            indices: Self.quadTriangles
        )
        let ghost = try #require(
            renderer.renderOffscreen(width: 128, height: 128, at: Self.peakTime)
        )
        #expect(differingPixels(ghost, committed) > 400)
    }

    /// The pulse is a pure function of the frame-time uniform: frames
    /// sampled at the pulse peak and trough differ visibly, and the trough
    /// frame never disappears (alpha floor).
    @Test func ghostAlphaPulsesAcrossSampledTimes() throws {
        let renderer = try makeRenderer()
        try frameCameraOnQuad(renderer)
        let background = try #require(
            renderer.renderOffscreen(width: 128, height: 128, at: Self.peakTime)
        )
        renderer.loadGhostGeometry(
            positions: Self.quadPositions, normals: Self.quadNormals,
            indices: Self.quadTriangles
        )

        let peak = try #require(
            renderer.renderOffscreen(width: 128, height: 128, at: Self.peakTime)
        )
        let trough = try #require(
            renderer.renderOffscreen(width: 128, height: 128, at: Self.troughTime)
        )
        #expect(differingPixels(peak, trough) > 400)
        // Alpha floor: the ghost stays visible at the trough.
        #expect(differingPixels(trough, background) > 400)
    }
}

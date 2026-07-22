import CyberKit
import Foundation
import Testing
import UIKit
import simd
@testable import CyberTopology

/// Task 3.6 (spec: pencil-interaction / "Hover gesture preview"): the pure
/// `HoverPreviewState` machine via injected hover events and query answers,
/// the pure render-geometry builders, and the REAL query path end to end —
/// injected hover probes drive the coordinator's `HoverPreviewController`
/// through the live camera, the engine Target raycast, the engine EditMesh
/// element picks, and the engine edge-loop walk (`cyber_mesh_edge_loop`),
/// with the resulting render state applied to the real Metal pipelines and
/// the mesh asserted UNMODIFIED. Actual Pencil-hover event delivery is
/// hardware-only (`HoverHardwareTests`, explicit XCTSkip).
@MainActor
struct HoverPreviewTests {
    // MARK: - Pure state machine (injected hover events + query answers)

    /// Injectable query answers with call recording (laziness assertions).
    private struct FakeQueries: HoverPreviewQuerying {
        final class Calls {
            var snap = 0
            var loop = 0
            var ghost = 0
        }

        var snap: HoverPreviewState.SnapTarget?
        var loop: [UInt32]?
        var ghost: [SIMD3<Float>]?
        let calls = Calls()

        func snapTargetVertex(at point: SIMD2<Float>) -> HoverPreviewState.SnapTarget? {
            calls.snap += 1
            return snap
        }

        func slideLoop(at point: SIMD2<Float>) -> [UInt32]? {
            calls.loop += 1
            return loop
        }

        func ghostQuadCorners(at point: SIMD2<Float>) -> [SIMD3<Float>]? {
            calls.ghost += 1
            return ghost
        }
    }

    private let origin = SIMD2<Float>(0.5, 0.5)
    private let corners: [SIMD3<Float>] = [
        SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0),
    ]

    @Test func snapVertexOutranksLoopAndGhost() {
        var state = HoverPreviewState()
        let target = HoverPreviewState.SnapTarget(vertex: 7, position: SIMD3(1, 2, 3))
        let queries = FakeQueries(snap: target, loop: [1, 2], ghost: corners)

        let changed = state.hoverChanged(at: origin, queries: queries)
        #expect(changed)
        #expect(state.preview == .snapTarget(target))
        // Priority is lazy: the losing queries are never consulted.
        #expect(queries.calls.loop == 0)
        #expect(queries.calls.ghost == 0)
    }

    @Test func loopOutranksGhost() {
        var state = HoverPreviewState()
        let queries = FakeQueries(loop: [4, 5, 6], ghost: corners)

        let changed = state.hoverChanged(at: origin, queries: queries)
        #expect(changed)
        #expect(state.preview == .loopHighlight(edges: [4, 5, 6]))
        #expect(queries.calls.ghost == 0)
    }

    @Test func ghostQuadIsTheEmptySurfaceFallback() {
        var state = HoverPreviewState()
        let changed = state.hoverChanged(at: origin, queries: FakeQueries(ghost: corners))
        #expect(changed)
        #expect(state.preview == .ghostQuad(corners: corners))
    }

    @Test func unresolvedHoverShowsNothingAndDedupes() {
        var state = HoverPreviewState()
        // Nothing under the hover: no change from the initial empty state.
        let unresolved = state.hoverChanged(at: origin, queries: FakeQueries())
        #expect(!unresolved)
        #expect(state.preview == nil)
        #expect(state.isHovering)
        // A preview appears, then the element vanishes: change both times.
        let appeared = state.hoverChanged(at: origin, queries: FakeQueries(loop: [1]))
        let vanished = state.hoverChanged(at: origin, queries: FakeQueries())
        #expect(appeared)
        #expect(vanished)
        #expect(state.preview == nil)
    }

    @Test func identicalResolutionReportsNoChange() {
        var state = HoverPreviewState()
        let queries = FakeQueries(loop: [4, 5])
        let first = state.hoverChanged(at: origin, queries: queries)
        let repeated = state.hoverChanged(at: SIMD2(0.51, 0.5), queries: queries)
        #expect(first)
        #expect(!repeated)
        #expect(state.preview == .loopHighlight(edges: [4, 5]))
        // A different loop is a change again.
        let differentLoop = state.hoverChanged(at: origin, queries: FakeQueries(loop: [9]))
        #expect(differentLoop)
    }

    @Test func hoverEndClearsThePreview() {
        var state = HoverPreviewState()
        let emptyEnd = state.hoverEnded()
        #expect(!emptyEnd)  // nothing to clear
        let shown = state.hoverChanged(at: origin, queries: FakeQueries(ghost: corners))
        let cleared = state.hoverEnded()
        #expect(shown)
        #expect(cleared)
        #expect(state.preview == nil)
        #expect(!state.isHovering)
    }

    @Test func strokeBeginClearsThePreview() {
        var state = HoverPreviewState()
        let queries = FakeQueries(snap: .init(vertex: 1, position: .zero))
        let shown = state.hoverChanged(at: origin, queries: queries)
        let cleared = state.strokeBegan()
        #expect(shown)
        #expect(cleared)
        #expect(state.preview == nil)
        let repeated = state.strokeBegan()
        #expect(!repeated)  // idempotent
    }

    // MARK: - Pure render-geometry builders

    @Test func ghostQuadGeometryCarriesPlaneNormalAndTwoTriangles() throws {
        let quad = try #require(HoverPreviewGeometry.ghostQuad(corners: corners))
        #expect(quad.positions.count == 12)
        #expect(quad.indices == [0, 1, 2, 0, 2, 3])
        // Ring in the z = 0 plane, counter-clockwise in +z view: +z normal
        // on every vertex.
        for vertex in 0..<4 {
            #expect(quad.normals[vertex * 3 + 0] == 0)
            #expect(quad.normals[vertex * 3 + 1] == 0)
            #expect(abs(quad.normals[vertex * 3 + 2] - 1) < 1e-6)
        }
    }

    @Test func ghostQuadNormalIsOrientedTowardTheCamera() throws {
        // Screen-ordered corners on a +z-viewed surface wind clockwise:
        // their raw plane normal points AWAY from a camera looking down
        // -z. With the view direction the normal must flip toward the
        // camera (the render lift depends on it).
        let clockwise: [SIMD3<Float>] = [
            SIMD3(0, 1, 0), SIMD3(1, 1, 0), SIMD3(1, 0, 0), SIMD3(0, 0, 0),
        ]
        let raw = try #require(HoverPreviewGeometry.ghostQuad(corners: clockwise))
        #expect(raw.normals[2] == -1)
        let faced = try #require(HoverPreviewGeometry.ghostQuad(
            corners: clockwise, facing: SIMD3(0, 0, -1)
        ))
        #expect(faced.normals[2] == 1)
        // Already camera-facing normals are left alone.
        let kept = try #require(HoverPreviewGeometry.ghostQuad(
            corners: corners, facing: SIMD3(0, 0, -1)
        ))
        #expect(kept.normals[2] == 1)
    }

    @Test func degenerateGhostQuadIsRejected() {
        // Collinear ring: no plane normal.
        let collinear: [SIMD3<Float>] = [
            SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(2, 0, 0), SIMD3(3, 0, 0),
        ]
        #expect(HoverPreviewGeometry.ghostQuad(corners: collinear) == nil)
        #expect(HoverPreviewGeometry.ghostQuad(corners: Array(corners.prefix(3))) == nil)
    }

    @Test func loopHighlightSkipsRetiredEdgeIDs() {
        let positions: [UInt32: SIMD3<Float>] = [
            0: SIMD3(0, 0, 0), 1: SIMD3(1, 0, 0), 2: SIMD3(1, 1, 0),
        ]
        let endpoints: [UInt32: (UInt32, UInt32)] = [10: (0, 1), 11: (1, 2)]
        let highlight = HoverPreviewGeometry.loopHighlight(
            edges: [10, 99, 11],  // 99 is retired
            edgeEndpoints: { endpoints[$0] },
            vertexPosition: { positions[$0] }
        )
        // Two live segments, two vertices each, xyz per vertex.
        #expect(highlight.segments.count == 12)
        #expect(highlight.points.isEmpty)
    }

    @Test func renderStateForSnapTargetIsASinglePoint() {
        let state = HoverPreviewGeometry.renderState(
            for: .snapTarget(.init(vertex: 3, position: SIMD3(1, 2, 3))),
            edgeEndpoints: { _ in nil },
            vertexPosition: { _ in nil }
        )
        #expect(state.ghost == nil)
        #expect(state.highlight == HoverRenderState.Highlight(points: [1, 2, 3]))
        #expect(!state.isEmpty)
        #expect(HoverPreviewGeometry.renderState(
            for: nil, edgeEndpoints: { _ in nil }, vertexPosition: { _ in nil }
        ) == .empty)
    }

    // MARK: - Controller without a context (Metal-free glue behavior)

    @Test func controllerWithoutContextPublishesNothing() {
        let controller = HoverPreviewController()
        var published: [HoverRenderState] = []
        controller.onRenderStateChanged = { published.append($0) }

        controller.hoverChanged(at: SIMD2(0.5, 0.5))
        #expect(controller.preview == nil)
        #expect(published.isEmpty)
        controller.hoverEnded()
        #expect(published.isEmpty)  // nothing was shown, nothing to clear
    }

    // MARK: - End-to-end query path (real camera, engine, Metal pipelines)

    /// Viewport coordinator + seeded document, mirroring the
    /// MeshEditControllerTests harness: hover probes drive the SAME
    /// controller instance the UIKit hover recognizer feeds.
    @MainActor
    private final class Harness {
        var bundle = DocumentBundle()
        let coordinator: MetalViewport.Coordinator
        /// Retained: recognizers unhook (`recognizer.view` goes nil) when
        /// the viewport view deallocates.
        let view: UIView

        init() throws {
            coordinator = MetalViewport(
                bundle: DocumentBundle(), orbitSpeed: 1, zoomSpeed: 1,
                onUndo: {}, onRedo: {}
            ).makeCoordinator()
            view = coordinator.makeView()
            try #require(coordinator.renderer != nil, "Metal device unavailable")
            coordinator.bundleProvider = { [weak self] in
                self?.bundle ?? DocumentBundle()
            }
        }

        func sync() {
            coordinator.syncMesh(from: bundle)
        }

        /// Normalized viewport point of a world position under the live
        /// camera (the inverse of `ViewportRenderer.cameraRay`).
        func screenPoint(of world: SIMD3<Float>) -> SIMD2<Float> {
            let m = coordinator.renderer!.viewProjectionColumns()
            let cx = m[0] * world.x + m[4] * world.y + m[8] * world.z + m[12]
            let cy = m[1] * world.x + m[5] * world.y + m[9] * world.z + m[13]
            let cw = m[3] * world.x + m[7] * world.y + m[11] * world.z + m[15]
            return SIMD2((cx / cw) * 0.5 + 0.5, 1 - ((cy / cw) * 0.5 + 0.5))
        }

        func hover(over world: SIMD3<Float>) {
            coordinator.hoverPreview.hoverChanged(at: screenPoint(of: world))
        }

        var editObject: DocumentManifest.Object? {
            bundle.manifest.objects.first { $0.role == .editMesh }
        }
    }

    private func meshFromOBJ(_ text: String) throws -> Mesh {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hover-\(UUID().uuidString).obj")
        try text.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try Mesh.loadOBJ(at: url)
    }

    /// Big flat Target at z = 0 (hover queries anchor to its surface).
    private func addPlaneTarget(to harness: Harness) throws {
        let target = try meshFromOBJ("""
        v -5 -5 0
        v 5 -5 0
        v 5 5 0
        v -5 5 0
        f 1 2 3 4
        """)
        try harness.bundle.addObject(name: "target", role: .target, mesh: target)
        harness.sync()
    }

    /// Uniform 3x3-quad grid EditMesh on the Target plane: its interior
    /// vertices are regular (valence 4), so the engine edge-loop walk has
    /// real loops to follow.
    private func addGridEditMesh(to harness: Harness) throws {
        var obj = ""
        for row in 0...3 {
            for col in 0...3 {
                obj += "v \(col) \(row) 0\n"
            }
        }
        for row in 0..<3 {
            for col in 0..<3 {
                let a = row * 4 + col + 1
                obj += "f \(a) \(a + 1) \(a + 5) \(a + 4)\n"
            }
        }
        try harness.bundle.addObject(
            name: "cage", role: .editMesh, mesh: try meshFromOBJ(obj)
        )
        harness.sync()
    }

    /// Spec scenario "Hover over an edge": hovering an interior edge
    /// highlights the loop a double-tap would slide — resolved by the REAL
    /// engine loop walk through the real camera/raycast path — without
    /// modifying the mesh.
    @Test func hoverOverInteriorEdgeHighlightsTheSlideLoopWithoutModifyingTheMesh() throws {
        let harness = try Harness()
        try addPlaneTarget(to: harness)
        try addGridEditMesh(to: harness)
        let object = try #require(harness.editObject)
        let payloadBefore = try #require(harness.bundle.payloads[object.payloadFile])
        let mesh = try #require(harness.coordinator.recognizerEditMesh)

        // Midpoint of the interior horizontal edge (1,1)-(2,1).
        harness.hover(over: SIMD3(1.5, 1, 0))

        let preview = try #require(harness.coordinator.hoverPreview.preview)
        guard case .loopHighlight(let edges) = preview else {
            Issue.record("expected loopHighlight, got \(preview)")
            return
        }
        // The highlighted loop IS the engine's edge loop through the
        // hovered edge (independently recomputed from the world point).
        let picked = try #require(mesh.nearestEdge(to: SIMD3(1.5, 1, 0), maxDistance: 0.01))
        let expected = mesh.edgeLoop(from: picked.edge)
        #expect(!edges.isEmpty)
        #expect(edges == expected)
        // The full horizontal row of the 3x3 grid: three edges.
        #expect(edges.count == 3)
        #expect(mesh.isBoundaryEdge(picked.edge) == false)

        // Render state reached the real overlay pipeline: one segment per
        // loop edge, no ghost.
        let renderState = harness.coordinator.hoverPreview.renderState
        #expect(renderState.highlight?.segments.count == edges.count * 6)
        let renderer = try #require(harness.coordinator.renderer)
        #expect(renderer.overlayPath.hasHoverHighlight)
        #expect(renderer.overlayPath.hoverSegmentVertexCount == edges.count * 2)
        #expect(!renderer.hasHoverGhost)

        // "…without modifying the mesh": nothing journaled, live mesh
        // serializes byte-identically, document payload untouched.
        #expect(harness.bundle.journal.depth == 0)
        #expect(try mesh.payloadData() == payloadBefore)
        #expect(harness.bundle.payloads[object.payloadFile] == payloadBefore)
    }

    @Test func hoverOverBoundaryEdgeShowsNoPreview() throws {
        let harness = try Harness()
        try addPlaneTarget(to: harness)
        try addGridEditMesh(to: harness)

        // Midpoint of the bottom boundary edge (0,0)-(1,0): not slidable,
        // and not empty surface either — no preview at all.
        harness.hover(over: SIMD3(0.5, 0, 0))
        #expect(harness.coordinator.hoverPreview.preview == nil)
        let renderer = try #require(harness.coordinator.renderer)
        #expect(!renderer.overlayPath.hasHoverHighlight)
        #expect(!renderer.hasHoverGhost)
    }

    @Test func hoverNearVertexHighlightsTheSnapTarget() throws {
        let harness = try Harness()
        try addPlaneTarget(to: harness)
        try addGridEditMesh(to: harness)
        let mesh = try #require(harness.coordinator.recognizerEditMesh)

        harness.hover(over: SIMD3(2, 2, 0))

        let preview = try #require(harness.coordinator.hoverPreview.preview)
        guard case .snapTarget(let target) = preview else {
            Issue.record("expected snapTarget, got \(preview)")
            return
        }
        #expect(target.position == SIMD3(2, 2, 0))
        #expect(mesh.vertexPosition(target.vertex) == SIMD3(2, 2, 0))
        // The snap dot reached the overlay pipeline as a point primitive.
        let renderer = try #require(harness.coordinator.renderer)
        #expect(renderer.overlayPath.hoverPointVertexCount == 1)
        #expect(renderer.overlayPath.hoverSegmentVertexCount == 0)
    }

    @Test func hoverOverEmptySurfaceShowsGhostQuadOnTheTarget() throws {
        let harness = try Harness()
        try addPlaneTarget(to: harness)
        try addGridEditMesh(to: harness)

        // Far from every EditMesh element, still on the Target plane.
        harness.hover(over: SIMD3(-3, -3, 0))

        let preview = try #require(harness.coordinator.hoverPreview.preview)
        guard case .ghostQuad(let corners) = preview else {
            Issue.record("expected ghostQuad, got \(preview)")
            return
        }
        #expect(corners.count == 4)
        // Every corner sits ON the Target surface at the snap position.
        let snapper = try #require(harness.coordinator.targetSnapper)
        for corner in corners {
            #expect(abs(corner.z) < 1e-3)
            let hit = try #require(snapper.snapToSurface(corner))
            #expect(simd_distance(hit.point, corner) < 1e-3)
        }
        // The hint reached the real ghost pipeline (and keeps it animating),
        // lifted along its normal so curved Targets cannot swallow it.
        let renderer = try #require(harness.coordinator.renderer)
        #expect(renderer.hasHoverGhost)
        #expect(renderer.isAnimating())
        #expect(renderer.hoverGhostStyle.normalOffset > 0)
        #expect(!renderer.overlayPath.hasHoverHighlight)
        #expect(harness.bundle.journal.depth == 0)
    }

    /// A document with only a Target (no EditMesh yet) still gets the
    /// first-stroke ghost hint; without a Target there is no surface to
    /// preview against, so hover stays inert.
    @Test func ghostHintNeedsOnlyATargetAndNoTargetMeansNoPreview() throws {
        let bare = try Harness()
        bare.hover(over: SIMD3(0, 0, 0))
        #expect(bare.coordinator.hoverPreview.preview == nil)

        let targetOnly = try Harness()
        try addPlaneTarget(to: targetOnly)
        targetOnly.hover(over: SIMD3(0, 0, 0))
        guard case .ghostQuad = targetOnly.coordinator.hoverPreview.preview else {
            Issue.record("expected ghostQuad on a target-only document")
            return
        }
    }

    @Test func hoverEndAndStrokeBeginClearTheRenderedPreview() throws {
        let harness = try Harness()
        try addPlaneTarget(to: harness)
        try addGridEditMesh(to: harness)
        let renderer = try #require(harness.coordinator.renderer)

        harness.hover(over: SIMD3(1.5, 1, 0))
        #expect(renderer.overlayPath.hasHoverHighlight)
        harness.coordinator.hoverPreview.hoverEnded()
        #expect(harness.coordinator.hoverPreview.preview == nil)
        #expect(!renderer.overlayPath.hasHoverHighlight)
        #expect(harness.coordinator.hoverPreview.renderState == .empty)

        // Preview up again, then a stroke begins through the REAL capture
        // pipeline (the wiring the UIKit touch layer drives): cleared.
        harness.hover(over: SIMD3(-3, -3, 0))
        #expect(renderer.hasHoverGhost)
        let capture = harness.coordinator.inputModel.controller.capture
        capture.begin(
            source: .pencil, verb: .pencil,
            sample: .init(time: 0, x: 0.1, y: 0.1, pressure: 0.5, type: .pencil)
        )
        #expect(harness.coordinator.hoverPreview.preview == nil)
        #expect(!renderer.hasHoverGhost)
        capture.cancel()
    }

    /// Moving along the same loop re-resolves to the identical preview:
    /// the render state must not be re-uploaded (the dedupe the overlay's
    /// no-frame-time-allocation note relies on).
    @Test func movingAlongTheSameLoopDoesNotRepublishRenderState() throws {
        let harness = try Harness()
        try addPlaneTarget(to: harness)
        try addGridEditMesh(to: harness)
        var publishes = 0
        let previous = harness.coordinator.hoverPreview.onRenderStateChanged
        harness.coordinator.hoverPreview.onRenderStateChanged = { state in
            publishes += 1
            previous?(state)
        }

        harness.hover(over: SIMD3(1.5, 1, 0))
        #expect(publishes == 1)
        // A different point on the SAME edge row → same loop → no publish.
        harness.hover(over: SIMD3(1.6, 1.02, 0))
        #expect(publishes == 1)
        // Crossing to a vertical edge's loop is a change again.
        harness.hover(over: SIMD3(1, 1.5, 0))
        #expect(publishes == 2)
    }

    @Test func hoverRecognizerIsInstalledOnTheViewport() throws {
        let harness = try Harness()
        let recognizer = try #require(harness.coordinator.hoverRecognizer)
        #expect(recognizer.view === harness.view)
        #expect(recognizer.isEnabled)
    }
}

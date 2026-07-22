import CyberKit
import Foundation
import simd

// Hover gesture preview (task 3.6, spec: pencil-interaction / "Hover gesture
// preview"; design D5: the single input arbiter also owns hover).
//
// On hover-capable hardware (Pencil 2 on M2+ iPads, Pencil Pro, and pointer
// devices) hovering previews what a stroke or tap at that location would do,
// BEFORE contact and WITHOUT modifying the mesh:
//
//   - empty surface        → ghost quad hint at the snap position (rendered
//                            through the task-2.4 ghost pipeline),
//   - interior edge        → the edge loop a double-tap would slide,
//                            highlighted over the wireframe,
//   - near-merge vertex    → snap-target vertex highlight.
//
// Split exactly like the arbiter (design D5): `HoverPreviewState` is the
// PURE policy (event in, preview out — headless unit tests inject events and
// query answers), `HoverPreviewController` is the glue that resolves queries
// against the real engine (Target raycast, EditMesh element picks, engine
// loop walk) and publishes render state. The UIKit hover recognizer lives in
// `MetalViewport.Coordinator`; actual hover event delivery is hardware-only
// (device test plan, task 9.6).

/// Answers the three hover queries at a normalized viewport point. The pure
/// state machine consults them in priority order (vertex > loop > ghost)
/// and stops at the first hit, so implementations never pay for previews
/// that lose the priority race. The production implementation is
/// `EngineHoverQueries`; tests inject fakes.
protocol HoverPreviewQuerying {
    /// EditMesh vertex within merge-snap range of the hover point, if any.
    func snapTargetVertex(at point: SIMD2<Float>) -> HoverPreviewState.SnapTarget?
    /// The edge loop a double-tap at the hover point would slide: engine
    /// edge ids of the loop through the INTERIOR edge under the point.
    /// nil for no edge / a boundary edge (not slidable).
    func slideLoop(at point: SIMD2<Float>) -> [UInt32]?
    /// Ghost-quad corner positions ON the Target surface, when the point
    /// hovers over empty surface (no EditMesh element in reach).
    func ghostQuadCorners(at point: SIMD2<Float>) -> [SIMD3<Float>]?
}

/// Pure hover-preview state machine: hover events (with injected query
/// answers) in, the published preview out. No UIKit, no engine — every
/// transition is headless-testable (task 3.6 mirror of `InputArbiter`).
struct HoverPreviewState: Equatable {
    /// A merge-snap target under the hover point.
    struct SnapTarget: Equatable {
        var vertex: UInt32
        var position: SIMD3<Float>
    }

    /// What the hover location previews.
    enum Preview: Equatable {
        /// Empty surface: the quad a stroke would create, on the Target.
        case ghostQuad(corners: [SIMD3<Float>])
        /// Interior edge: the loop a double-tap would slide (engine ids).
        case loopHighlight(edges: [UInt32])
        /// Near-merge vertex: the snap target a drag/merge would commit to.
        case snapTarget(SnapTarget)
    }

    private(set) var isHovering = false
    private(set) var preview: Preview?

    /// Hover entered or moved: resolves the preview for `point` in priority
    /// order — snap vertex beats loop beats ghost quad (the closer the
    /// element class, the more specific the action a tap would take).
    /// Returns true when the published preview CHANGED (the caller only
    /// re-uploads render state on change).
    mutating func hoverChanged(
        at point: SIMD2<Float>, queries: some HoverPreviewQuerying
    ) -> Bool {
        isHovering = true
        let resolved: Preview?
        if let snap = queries.snapTargetVertex(at: point) {
            resolved = .snapTarget(snap)
        } else if let loop = queries.slideLoop(at: point) {
            resolved = .loopHighlight(edges: loop)
        } else if let corners = queries.ghostQuadCorners(at: point) {
            resolved = .ghostQuad(corners: corners)
        } else {
            resolved = nil
        }
        guard resolved != preview else { return false }
        preview = resolved
        return true
    }

    /// Hover left the surface (or the recognizer cancelled/failed).
    /// Returns true when a visible preview was cleared.
    mutating func hoverEnded() -> Bool {
        isHovering = false
        guard preview != nil else { return false }
        preview = nil
        return true
    }

    /// A stroke began (pen contact, or a finger stroke while the pen still
    /// hovers): the preview must never linger under live authoring.
    mutating func strokeBegan() -> Bool {
        hoverEnded()
    }
}

/// GPU-ready hover render state: the ghost-quad triangles for the ghost
/// pipeline and/or the highlight line/point vertices for the overlay
/// pipeline. Built purely from a `Preview` + element accessors
/// (`HoverPreviewGeometry`), applied by `ViewportRenderer.setHoverPreview`.
struct HoverRenderState: Equatable {
    struct GhostQuad: Equatable {
        /// x,y,z per vertex (4 vertices, ring order).
        var positions: [Float]
        /// Per-vertex quad-plane normal.
        var normals: [Float]
        /// Two triangles over the ring.
        var indices: [UInt32]
    }

    struct Highlight: Equatable {
        /// Line-list vertices, x,y,z each; consecutive pairs are segments.
        var segments: [Float] = []
        /// Point-primitive vertices (snap-target dot), x,y,z each.
        var points: [Float] = []

        var isEmpty: Bool { segments.isEmpty && points.isEmpty }
    }

    var ghost: GhostQuad?
    var highlight: Highlight?

    static let empty = HoverRenderState()

    var isEmpty: Bool { ghost == nil && (highlight?.isEmpty ?? true) }
}

/// Pure geometry construction for hover previews (unit-tested headless;
/// the element accessors are injected so no engine handle is needed).
enum HoverPreviewGeometry {
    /// Render state for `preview`. `edgeEndpoints`/`vertexPosition` resolve
    /// engine element ids against the live EditMesh; ids retired by a
    /// concurrent topology change resolve to nil and are skipped, never
    /// crash (same contract as `MeshAnnotations`). `viewDirection` (the
    /// camera's forward vector) orients the ghost quad's normal toward the
    /// camera — see `ghostQuad(corners:facing:)`.
    static func renderState(
        for preview: HoverPreviewState.Preview?,
        edgeEndpoints: (UInt32) -> (UInt32, UInt32)?,
        vertexPosition: (UInt32) -> SIMD3<Float>?,
        viewDirection: SIMD3<Float>? = nil
    ) -> HoverRenderState {
        switch preview {
        case .none:
            return .empty
        case .ghostQuad(let corners):
            return HoverRenderState(
                ghost: ghostQuad(corners: corners, facing: viewDirection)
            )
        case .loopHighlight(let edges):
            let highlight = loopHighlight(
                edges: edges, edgeEndpoints: edgeEndpoints, vertexPosition: vertexPosition
            )
            return HoverRenderState(highlight: highlight.isEmpty ? nil : highlight)
        case .snapTarget(let target):
            return HoverRenderState(highlight: Highlight(
                points: [target.position.x, target.position.y, target.position.z]
            ))
        }
    }

    typealias Highlight = HoverRenderState.Highlight

    /// Two ghost triangles over 4 ring-ordered corners, with the quad-plane
    /// normal on every vertex (the ghost shader offsets/rims along it).
    /// When `viewDirection` (camera forward) is given, the normal is
    /// oriented TOWARD the camera: the render path lifts the hint along the
    /// normal so it clears the curved Target between its snapped corners —
    /// a normal pointing away from the camera would push it under the
    /// surface instead (fully depth-occluded on convex Targets). nil for
    /// degenerate rings (collinear corners).
    static func ghostQuad(
        corners: [SIMD3<Float>], facing viewDirection: SIMD3<Float>? = nil
    ) -> HoverRenderState.GhostQuad? {
        guard corners.count == 4 else { return nil }
        let cross = simd_cross(corners[1] - corners[0], corners[3] - corners[0])
        let length = simd_length(cross)
        guard length.isFinite, length > .ulpOfOne else { return nil }
        var normal = cross / length
        if let viewDirection, simd_dot(normal, viewDirection) > 0 {
            normal = -normal
        }
        var positions: [Float] = []
        var normals: [Float] = []
        for corner in corners {
            positions.append(contentsOf: [corner.x, corner.y, corner.z])
            normals.append(contentsOf: [normal.x, normal.y, normal.z])
        }
        return HoverRenderState.GhostQuad(
            positions: positions, normals: normals, indices: [0, 1, 2, 0, 2, 3]
        )
    }

    /// Line-list vertices for the loop edges (one segment per live edge).
    static func loopHighlight(
        edges: [UInt32],
        edgeEndpoints: (UInt32) -> (UInt32, UInt32)?,
        vertexPosition: (UInt32) -> SIMD3<Float>?
    ) -> Highlight {
        var segments: [Float] = []
        segments.reserveCapacity(edges.count * 6)
        for edge in edges {
            guard
                let (a, b) = edgeEndpoints(edge),
                let start = vertexPosition(a),
                let end = vertexPosition(b)
            else { continue }
            segments.append(contentsOf: [start.x, start.y, start.z])
            segments.append(contentsOf: [end.x, end.y, end.z])
        }
        return Highlight(segments: segments)
    }
}

/// Engine-backed hover queries: normalized viewport point → camera ray →
/// Target raycast → EditMesh element picks / engine loop walk / snapped
/// ghost corners. All spatial queries run engine-side (design D1); this
/// struct only sequences them. Read-only by construction: every capi entry
/// used here is a query (`cyber_snapper_*`, `cyber_mesh_nearest_*`,
/// `cyber_mesh_edge_loop`) — the mesh is never mutated.
struct EngineHoverQueries: HoverPreviewQuerying {
    let context: MeshEditController.Context
    /// Merge-snap pick radius (world units).
    let vertexRadius: Float
    /// Edge pick radius (world units).
    let edgeRadius: Float
    /// Ghost-quad half extent in normalized viewport units.
    let ghostHalfExtent: Float

    func snapTargetVertex(at point: SIMD2<Float>) -> HoverPreviewState.SnapTarget? {
        guard
            let mesh = context.editMesh,
            let hit = surfaceHit(at: point),
            let pick = mesh.nearestVertex(to: hit.point, maxDistance: vertexRadius)
        else { return nil }
        return HoverPreviewState.SnapTarget(vertex: pick.vertex, position: pick.position)
    }

    func slideLoop(at point: SIMD2<Float>) -> [UInt32]? {
        guard
            let mesh = context.editMesh,
            let hit = surfaceHit(at: point),
            let pick = mesh.nearestEdge(to: hit.point, maxDistance: edgeRadius),
            mesh.isBoundaryEdge(pick.edge) == false
        else { return nil }
        let loop = mesh.edgeLoop(from: pick.edge)
        return loop.isEmpty ? nil : loop
    }

    func ghostQuadCorners(at point: SIMD2<Float>) -> [SIMD3<Float>]? {
        guard let snapper = context.snapper, let hit = surfaceHit(at: point) else {
            return nil
        }
        // "Empty surface" only: near ANY EditMesh element (including
        // boundary edges, which the slide-loop query deliberately rejects)
        // a create hint would be misleading.
        if let mesh = context.editMesh {
            if mesh.nearestVertex(to: hit.point, maxDistance: vertexRadius) != nil {
                return nil
            }
            if mesh.nearestEdge(to: hit.point, maxDistance: edgeRadius) != nil {
                return nil
            }
        }
        // Nominal screen-space square around the hover point, landed on the
        // Target exactly like a drawn quad's corners (task 3.3): raycast
        // per corner, grazing misses fall back to the closest surface point
        // at the center hit's depth.
        let offsets: [SIMD2<Float>] = [
            SIMD2(-ghostHalfExtent, -ghostHalfExtent),
            SIMD2(ghostHalfExtent, -ghostHalfExtent),
            SIMD2(ghostHalfExtent, ghostHalfExtent),
            SIMD2(-ghostHalfExtent, ghostHalfExtent),
        ]
        var corners: [SIMD3<Float>] = []
        corners.reserveCapacity(4)
        for offset in offsets {
            guard let ray = context.ray(point + offset) else { return nil }
            if let cornerHit = snapper.raycast(origin: ray.origin, direction: ray.direction) {
                corners.append(cornerHit.point)
            } else {
                let probe = ray.origin + ray.direction * hit.distance
                guard let snapped = snapper.snapToSurface(probe) else { return nil }
                corners.append(snapped.point)
            }
        }
        return corners
    }

    /// Where the camera ray through `point` meets the Target surface.
    private func surfaceHit(at point: SIMD2<Float>) -> SurfaceSnapper.RayHit? {
        guard let snapper = context.snapper, let ray = context.ray(point) else {
            return nil
        }
        return snapper.raycast(origin: ray.origin, direction: ray.direction)
    }
}

/// Glue between hover events (UIKit recognizer / injected probes), the pure
/// state machine, the engine queries, and the renderer. Owned by the
/// viewport coordinator, which installs the context provider (the SAME
/// context the verb layer uses) and the render sink.
@MainActor
final class HoverPreviewController {
    /// Pick radii as fractions of the scene radius; deliberately tighter
    /// than the verbs' grab radius (`MeshEditController
    /// .vertexPickRadiusFraction`) so a hover can distinguish vertex, edge
    /// and empty surface within one quad.
    static let vertexRadiusFraction: Float = 0.05
    static let edgeRadiusFraction: Float = 0.07
    /// Ghost-quad half extent in normalized viewport units.
    static let ghostHalfExtent: Float = 0.04

    /// Fresh document/camera context per event (same provider as the verb
    /// layer, installed by the coordinator).
    var contextProvider: (() -> MeshEditController.Context?)?
    /// Render sink: fired only when the render state actually changed.
    var onRenderStateChanged: ((HoverRenderState) -> Void)?
    /// Loop Info sink (task 4.3, spec roster: "Loop Info inspection"):
    /// fired when the inspected loop changes; nil clears the chip. Holding
    /// the Pencil over an INTERIOR EDGE is the gesture — exactly the case
    /// that already resolves to `.loopHighlight`, so the inspector and the
    /// highlight always describe the same loop.
    var onLoopInfoChanged: ((LoopInfoChipState.Info?) -> Void)?
    /// Measures the loop under a point (installed by the coordinator as
    /// `MeshEditController.loopInfo(at:in:)`; nil = no inspector).
    var loopInfoProvider: ((SIMD2<Float>, MeshEditController.Context) -> LoopInfoChipState.Info?)?

    private(set) var loopInfoChip = LoopInfoChipState()

    private(set) var state = HoverPreviewState()
    private(set) var renderState = HoverRenderState.empty

    var preview: HoverPreviewState.Preview? { state.preview }

    /// Hover entered or moved to `point` (normalized viewport, 0...1,
    /// origin top-left).
    func hoverChanged(at point: SIMD2<Float>) {
        guard let context = contextProvider?() else {
            clearAfter { self.state.hoverEnded() }
            return
        }
        let radiusBase = context.sceneRadius
        let queries = EngineHoverQueries(
            context: context,
            vertexRadius: radiusBase * Self.vertexRadiusFraction,
            edgeRadius: radiusBase * Self.edgeRadiusFraction,
            ghostHalfExtent: Self.ghostHalfExtent
        )
        if state.hoverChanged(at: point, queries: queries) {
            publish(context: context, at: point)
        }
        // The chip updates on EVERY hover sample, not only on preview
        // change: sliding along one loop keeps the same metrics (the state
        // machine dedupes), but crossing onto a different loop must swap
        // the chip even when both resolve to `.loopHighlight`.
        publishLoopInfo(context: context, at: point)
    }

    /// The hover left the viewport (recognizer ended/cancelled/failed).
    func hoverEnded() {
        clearAfter { self.state.hoverEnded() }
    }

    /// A stroke began: any preview clears immediately (it must never
    /// linger under live authoring).
    func strokeBegan() {
        clearAfter { self.state.strokeBegan() }
    }

    private func clearAfter(_ transition: () -> Bool) {
        if transition() {
            publish(context: nil, at: nil)
        }
        if loopInfoChip.clear() {
            onLoopInfoChanged?(nil)
        }
    }

    /// Resolves and publishes the Loop Info chip for `point`. Only an
    /// interior-edge hover (a live loop highlight) inspects a loop —
    /// anything else clears the chip.
    private func publishLoopInfo(context: MeshEditController.Context, at point: SIMD2<Float>) {
        var next: LoopInfoChipState.Info?
        if case .loopHighlight = state.preview {
            next = loopInfoProvider?(point, context)
        }
        if loopInfoChip.show(next) {
            onLoopInfoChanged?(loopInfoChip.info)
        }
    }

    private func publish(context: MeshEditController.Context?, at point: SIMD2<Float>?) {
        let mesh = context?.editMesh
        // Camera forward at the hover point: orients the ghost hint's
        // normal toward the camera so the render path can lift it clear of
        // the curved Target (see `HoverPreviewGeometry.ghostQuad`).
        let viewDirection = point.flatMap { context?.ray($0)?.direction }
        let next = HoverPreviewGeometry.renderState(
            for: state.preview,
            edgeEndpoints: { mesh?.edgeEndpoints(of: $0) },
            vertexPosition: { mesh?.vertexPosition($0) },
            viewDirection: viewDirection
        )
        guard next != renderState else { return }
        renderState = next
        onRenderStateChanged?(renderState)
    }

    // MARK: - Visual-verification probes (UI-test/screenshot hooks)

    /// What the screenshot probe scans for.
    enum ProbeTarget {
        case loopHighlight
        case ghostQuad
    }

    /// Scans a coarse viewport lattice and locks the first hover point
    /// whose preview matches `target` (screenshot hook — the simulator has
    /// no Pencil hover hardware, so the visual-verification launch drives
    /// this instead; see `UITestSupport`). Returns whether a match locked.
    @discardableResult
    func probeForVisualVerification(_ target: ProbeTarget) -> Bool {
        let steps = 24
        for row in 0...steps {
            for col in 0...steps {
                let point = SIMD2(
                    Float(col) / Float(steps), Float(row) / Float(steps)
                )
                hoverChanged(at: point)
                switch (target, state.preview) {
                case (.loopHighlight, .loopHighlight):
                    return true
                case (.ghostQuad, .ghostQuad):
                    return true
                default:
                    continue
                }
            }
        }
        hoverEnded()
        return false
    }
}

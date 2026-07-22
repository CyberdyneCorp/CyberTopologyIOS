import CyberKit
import CyberKitTesting
import Foundation
import simd

// Pins, loop-tag colours and the Loop Info inspector (task 4.3; spec:
// retopology-tools / "Pins immune to smoothing", "Loop tags", and the
// roster's "Loop Info inspection … in O(loop) time").
//
// All three are ANNOTATION state, not geometry: they live on the manifest
// object as `MeshAnnotations` and change only through journaled
// `DocumentCommand.annotationEdit` commands, so one undo restores them
// exactly and they persist through the document bundle for free. The
// engine consumes the pin set on every Relax/Move call (see
// `MeshEditController.applyBrush`), which is what makes pins immune to
// smoothing end to end.

/// The small loop-tag palette (spec: "color-tag edge loops"). Indices are
/// DOCUMENT state (`MeshAnnotations.tagColorIndices`); the RGB values here
/// are presentation only, so recolouring the palette never rewrites a
/// document.
enum LoopTagPalette {
    /// RGB per palette index, chosen to stay legible over the cyan wire
    /// and apart from the yellow pin markers.
    static let colors: [SIMD3<Float>] = [
        SIMD3(0.35, 1.00, 0.45),  // 0 green (the pre-4.3 tag colour)
        SIMD3(1.00, 0.45, 0.45),  // 1 red
        SIMD3(0.55, 0.65, 1.00),  // 2 blue
        SIMD3(1.00, 0.60, 0.20),  // 3 orange
        SIMD3(0.85, 0.50, 1.00),  // 4 violet
        SIMD3(1.00, 1.00, 1.00),  // 5 white
    ]

    /// Human-readable names (accessibility labels on the palette swatches).
    static let names = ["Green", "Red", "Blue", "Orange", "Violet", "White"]

    /// Colour for a palette index, clamped to the palette.
    static func color(_ index: UInt8) -> SIMD3<Float> {
        colors[Int(index) < colors.count ? Int(index) : 0]
    }

    static func name(_ index: UInt8) -> String {
        names[Int(index) < names.count ? Int(index) : 0]
    }

    /// Every valid palette index (drives the swatch row and the tests that
    /// assert document/palette agreement).
    static var indices: [UInt8] { (0..<MeshAnnotations.tagColorCount).map { $0 } }
}

/// Loop Info chip content (spec roster: "Loop Info inspection (vertex/edge
/// counts, boundary length, snapping state in O(loop) time)"). A pure
/// value built from the engine's `LoopMetrics` — the formatting lives here
/// so the chip view stays declarative and the strings stay unit-testable.
struct LoopInfoChipState: Equatable {
    struct Info: Equatable {
        /// Seed edge the hover resolved (identity: a new seed on the SAME
        /// loop still measures the same loop, so the chip does not flicker
        /// — the metrics compare equal and the state machine dedupes).
        var metrics: LoopMetrics
        /// Palette index when the loop carries a tag, else nil.
        var tagColor: UInt8?

        /// "12 verts · 12 edges · closed" — the counts line.
        var countsLine: String {
            let shape = metrics.isClosed ? "closed" : "open"
            return "\(metrics.vertexCount) verts · \(metrics.edgeCount) edges · \(shape)"
        }

        /// "length 3.42" plus the endpoints of an open chain (a closed
        /// loop has none, and says so rather than showing blanks).
        var lengthLine: String {
            let length = String(format: "%.3f", metrics.length)
            guard let endpoints = metrics.endpoints else {
                return "length \(length) · no endpoints"
            }
            return "length \(length) · ends v\(endpoints.0)–v\(endpoints.1)"
        }

        /// Snapping state against the Target. Without a Target there is
        /// nothing to snap to, and the chip says exactly that instead of
        /// implying the loop is adrift.
        var snappingLine: String {
            guard let snapping = metrics.snapping else { return "no Target to snap to" }
            if snapping.snappedVertexCount == metrics.vertexCount {
                return "snapped to Target"
            }
            let off = metrics.vertexCount - snapping.snappedVertexCount
            let gap = String(format: "%.3f", snapping.maxDistance)
            return "\(off) of \(metrics.vertexCount) off Target (max \(gap))"
        }
    }

    private(set) var info: Info?

    /// Publishes `next`, returning true when the visible chip CHANGED (the
    /// caller only re-renders on change — hovering along one loop keeps
    /// the same chip rather than restarting it every sample).
    mutating func show(_ next: Info?) -> Bool {
        guard next != info else { return false }
        info = next
        return true
    }

    /// Hover ended / a stroke began: the chip must never outlive the
    /// gesture that produced it.
    mutating func clear() -> Bool { show(nil) }
}

extension MeshEditController {
    // MARK: - Pin Flip (task 4.3)

    /// How far (fraction of the scene radius) the pen may travel and still
    /// count as a HOLD rather than a drag. The hold-on-loop gesture pins a
    /// whole loop; a moving stroke is a per-vertex sweep.
    static let pinHoldDriftFraction: Float = 0.02
    /// How long the pen must dwell for a hold. Below this a stationary
    /// stroke is a tap, which flips the single vertex under it.
    static let pinHoldDuration: TimeInterval = 0.4

    /// Applies a Pin Flip stroke (spec: "Pinning SHALL be applicable per
    /// vertex and per edge loop"), journaled as ONE `annotationEdit`:
    ///
    ///   * **hold** over an interior edge → flips that edge LOOP's vertices
    ///     (the hold-on-loop gesture); over a vertex → flips the loops
    ///     through it is ambiguous, so a hold on a vertex flips just it;
    ///   * **tap** → flips the single vertex under the pen;
    ///   * **drag** → flips every vertex the stroke swept over.
    ///
    /// Flip semantics (not "set"): an all-pinned selection unpins, so a
    /// second pass over the same loop always undoes the first.
    func commitPinFlipStroke(_ stroke: ToolStroke, samples: [StrokeSample]) {
        let context = stroke.context
        guard let mesh = context.editMesh, let first = samples.first, let last = samples.last
        else { return }
        let pickRadius = context.sceneRadius * Self.vertexPickRadiusFraction
        let vertices: [UInt32]
        if Self.isPinHold(samples: samples, sceneRadius: context.sceneRadius, in: context) {
            vertices = holdPinTargets(
                at: point(of: first), mesh: mesh, context: context, pickRadius: pickRadius
            )
        } else if Self.strokeDrift(samples: samples, in: self, context: context)
            > context.sceneRadius * Self.pinHoldDriftFraction
        {
            vertices = sweptVertices(
                samples: samples, mesh: mesh, context: context, pickRadius: pickRadius * 0.5
            )
        } else {
            vertices = sweptVertices(
                samples: [last], mesh: mesh, context: context, pickRadius: pickRadius * 0.5
            )
        }
        guard !vertices.isEmpty else { return }
        applyAnnotationEdit(verb: "tool.pinFlip", context: context) {
            $0.togglingPins(on: vertices)
        }
    }

    /// A hold: the pen dwelled past `pinHoldDuration` without drifting
    /// past `pinHoldDriftFraction` of the scene radius.
    static func isPinHold(
        samples: [StrokeSample], sceneRadius: Float, in context: Context
    ) -> Bool {
        guard let first = samples.first, let last = samples.last else { return false }
        guard last.time - first.time >= pinHoldDuration else { return false }
        let dx = Float(last.x - first.x)
        let dy = Float(last.y - first.y)
        // Screen drift in normalized units; the hold tolerance is a
        // fraction of the viewport, not of world space (the pen holds
        // still on SCREEN).
        return simd_length(SIMD2(dx, dy)) <= pinHoldDriftFraction * 4
    }

    /// World-space distance the stroke covered on the Target (0 when the
    /// stroke never hit the surface).
    static func strokeDrift(
        samples: [StrokeSample], in controller: MeshEditController, context: Context
    ) -> Float {
        guard
            let first = samples.first, let last = samples.last,
            let start = controller.surfacePoint(at: controller.point(of: first), in: context),
            let end = controller.surfacePoint(at: controller.point(of: last), in: context)
        else { return 0 }
        return simd_distance(start, end)
    }

    /// Hold targets: the whole edge LOOP through the interior edge under
    /// the pen, else the single vertex under it. Boundary edges have no
    /// loop to walk, so they fall through to the vertex rule.
    private func holdPinTargets(
        at point: SIMD2<Float>, mesh: Mesh, context: Context, pickRadius: Float
    ) -> [UInt32] {
        guard let hit = surfacePoint(at: point, in: context) else { return [] }
        if let vertex = mesh.nearestVertex(to: hit, maxDistance: pickRadius * 0.5) {
            return [vertex.vertex]
        }
        guard
            let edge = mesh.nearestEdge(to: hit, maxDistance: pickRadius),
            mesh.isBoundaryEdge(edge.edge) == false
        else { return [] }
        // The loop walk runs engine-side (design D1) and is O(loop).
        return mesh.edgeLoopVertices(from: edge.edge)
    }

    /// Every distinct vertex the stroke passed within `pickRadius` of, in
    /// first-touched order.
    private func sweptVertices(
        samples: [StrokeSample], mesh: Mesh, context: Context, pickRadius: Float
    ) -> [UInt32] {
        var ordered: [UInt32] = []
        var seen: Set<UInt32> = []
        for sample in samples {
            guard
                let hit = surfacePoint(at: point(of: sample), in: context),
                let pick = mesh.nearestVertex(to: hit, maxDistance: pickRadius)
            else { continue }
            if seen.insert(pick.vertex).inserted { ordered.append(pick.vertex) }
        }
        return ordered
    }

    // MARK: - Clears (spec: tags clearable individually and en masse)

    /// Clears every loop tag on the EditMesh as ONE journaled entry. Also
    /// reachable from the task-4.5 batch-commands panel.
    @discardableResult
    func clearAllLoopTags() -> Bool {
        applyAnnotationEditNow(verb: "batch.clearLoopTags") { $0.clearingAllTags() }
    }

    /// Clears the tag on the loop under `point` (the individual clear).
    @discardableResult
    func clearLoopTag(at point: SIMD2<Float>) -> Bool {
        guard let context = contextProvider?(), let mesh = context.editMesh,
            let hit = surfacePoint(at: point, in: context),
            let edge = mesh.nearestEdge(
                to: hit, maxDistance: context.sceneRadius * Self.vertexPickRadiusFraction)
        else { return false }
        let loop = mesh.edgeLoop(from: edge.edge)
        guard !loop.isEmpty else { return false }
        return applyAnnotationEditNow(verb: "annotation.clearLoopTag", context: context) {
            $0.clearingTags(on: loop)
        }
    }

    /// Clears every pin as ONE journaled entry (spec batch "clear pins").
    @discardableResult
    func clearAllPins() -> Bool {
        applyAnnotationEditNow(verb: "batch.clearPins") { $0.clearingAllPins() }
    }

    /// Journals an annotation transform against the CURRENT context,
    /// reporting whether anything changed (the menu items disable
    /// themselves off the same answer rather than journaling no-ops).
    @discardableResult
    private func applyAnnotationEditNow(
        verb: String, context: Context? = nil,
        _ transform: (MeshAnnotations) -> MeshAnnotations
    ) -> Bool {
        guard let context = context ?? contextProvider?(), let object = context.editObject
        else { return false }
        let before = object.annotations
        let transformed = transform(before ?? MeshAnnotations())
        guard (transformed.isEmpty ? nil : transformed) != before else { return false }
        applyAnnotationEdit(verb: verb, context: context, transform)
        return true
    }

    // MARK: - Visual-verification probe (task 4.3 screenshot hook)

    /// Pins one edge loop and tags a DIFFERENT loop in the currently
    /// selected palette colour, both through the real journaled command
    /// path (the simulator cannot synthesize the Pencil hold this
    /// normally takes). Returns whether both landed.
    @discardableResult
    func probeAnnotationsForVisualVerification() -> Bool {
        guard let context = contextProvider?(), let mesh = context.editMesh else { return false }
        // Two DISJOINT loops so the screenshot shows pins and a coloured
        // tag as separate features rather than one overdrawn line.
        var loops: [[UInt32]] = []
        var covered: Set<UInt32> = []
        for edge in 0..<UInt32(mesh.edgeCount) where mesh.isBoundaryEdge(edge) == false {
            let loop = mesh.edgeLoop(from: edge)
            guard !loop.isEmpty, !loop.contains(where: covered.contains) else { continue }
            covered.formUnion(loop)
            loops.append(loop)
            if loops.count == 2 { break }
        }
        guard loops.count == 2 else { return false }
        let pinTargets = mesh.edgeLoopVertices(from: loops[0][0])
        guard !pinTargets.isEmpty else { return false }
        let color = activeTagColor
        applyAnnotationEdit(verb: "probe.pinLoop", context: context) {
            $0.togglingPins(on: pinTargets)
        }
        // Re-read the context: the pin edit changed the manifest object,
        // and the tag must journal against THAT state, not the stale one.
        guard let tagContext = contextProvider?() else { return false }
        applyAnnotationEdit(verb: "probe.tagLoop", context: tagContext) {
            $0.togglingTags(on: loops[1], color: color)
        }
        return true
    }

    // MARK: - Loop Info (hover over an interior edge)

    /// Measures the loop under `point` for the inspector chip. Runs the
    /// engine's O(loop) `cyber_mesh_loop_metrics` query (patch 0020) —
    /// read-only, so hovering never touches the mesh or the render cache.
    func loopInfo(at point: SIMD2<Float>) -> LoopInfoChipState.Info? {
        guard let context = contextProvider?() else { return nil }
        return loopInfo(at: point, in: context)
    }

    func loopInfo(at point: SIMD2<Float>, in context: Context) -> LoopInfoChipState.Info? {
        guard
            let mesh = context.editMesh,
            let hit = surfacePoint(at: point, in: context),
            let edge = mesh.nearestEdge(
                to: hit, maxDistance: context.sceneRadius * Self.vertexPickRadiusFraction),
            // Interior edges only: a boundary edge is not a loop the
            // inspector can walk (same rule the hover loop highlight uses).
            mesh.isBoundaryEdge(edge.edge) == false,
            let metrics = mesh.loopMetrics(from: edge.edge, snapping: context.snapper)
        else { return nil }
        return LoopInfoChipState.Info(
            metrics: metrics, tagColor: context.annotations?.tagColor(of: edge.edge)
        )
    }
}

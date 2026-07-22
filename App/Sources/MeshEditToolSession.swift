import CyberKit
import CyberKitTesting
import Foundation
import os
import simd

/// The retopology tools (spec: retopology-tools / "Core RT action
/// roster"): the task-4.1 build tools (Build Quad, Build Triangle, Merge
/// Pair, Path Distribute, Surface Cut) and the task-4.2
/// camera-as-manipulator tools (Patch Clone, Extend Boundary, Draw Strip,
/// Transform Vertices). Selectable like verbs (toolbar slot / Action
/// Gallery); while armed, Pencil strokes drive the tool instead of the
/// gesture grammar — and for the camera tools, camera input BOTH moves
/// the camera AND drives the armed session (routed through the
/// InputArbiter, never around it).
enum RetopoTool: String, CaseIterable, Equatable, Sendable {
    case buildQuad
    case buildTriangle
    case mergePair
    case pathDistribute
    case surfaceCut
    case patchClone
    case extendBoundary
    case drawStrip
    case transformVertices
    /// Pin Flip (task 4.3): flips pins per vertex, per swept run, or —
    /// on a HOLD over an interior edge — for the whole edge loop.
    case pinFlip

    /// Camera-as-manipulator tools: a selection stroke arms a session,
    /// then the CAMERA is the manipulator until commit/cancel. Draw Strip
    /// belongs to the 4.2 roster but stays stroke-driven (the strip
    /// follows the stroke itself).
    var isCameraManipulator: Bool {
        switch self {
        case .patchClone, .extendBoundary, .transformVertices:
            return true
        case .buildQuad, .buildTriangle, .mergePair, .pathDistribute,
            .surfaceCut, .drawStrip, .pinFlip:
            return false
        }
    }
}

/// Pure tool geometry (headless unit tests — no engine, no camera).
enum RetopoToolGeometry {
    /// The two off-diagonal corners of the square whose diagonal runs
    /// `anchor -> drag`, lying in the plane perpendicular to `view`
    /// (the corner-drag Build Quad/Triangle shape: anchor corner on the
    /// existing vertex, far corner under the pen). Ordered so the ring
    /// `[anchor, first, drag, second]` winds toward the camera (its normal
    /// opposes `view`, the into-screen ray direction). nil when the drag is
    /// degenerate or parallel to the view direction.
    static func cornerQuadCorners(
        anchor: SIMD3<Float>, drag: SIMD3<Float>, view: SIMD3<Float>
    ) -> (first: SIMD3<Float>, second: SIMD3<Float>)? {
        let diagonal = drag - anchor
        let across = simd_cross(diagonal, view)
        let acrossLength = simd_length(across)
        guard simd_length(diagonal) > .ulpOfOne, acrossLength > .ulpOfOne else {
            return nil
        }
        let mid = (anchor + drag) * 0.5
        let half = across / acrossLength * (simd_length(diagonal) * 0.5)
        var first = mid + half
        var second = mid - half
        // Ring [anchor, first, drag, second]: flip when its normal points
        // WITH the view ray (away from the camera).
        let normal = simd_cross(first - anchor, drag - anchor)
        if simd_dot(normal, view) > 0 {
            swap(&first, &second)
        }
        return (first, second)
    }
}

extension MeshEditController {
    /// An in-flight tool stroke: the armed tool plus the context pinned at
    /// stroke begin (tools act on the document state and camera the stroke
    /// started over; the raw polyline arrives with `strokeEnded`).
    struct ToolStroke {
        var tool: RetopoTool
        var context: Context
    }

    /// Minimum drag length (fraction of the scene radius) for the Build
    /// tools — a tap must not spawn a degenerate face.
    static let toolMinimumDragFraction: Float = 0.01

    // MARK: - Commit (one journal entry per tool stroke)

    /// Applies the finished tool stroke. Every mutation runs inside ONE
    /// journaled transaction (`journalOrDiscard` failure contract); a
    /// stroke that resolves to nothing (missed picks, empty knife) journals
    /// nothing.
    func commitToolStroke(_ stroke: ToolStroke, samples: [StrokeSample]) {
        guard let first = samples.first, let last = samples.last else { return }
        switch stroke.tool {
        case .buildQuad:
            applyBuildDrag(stroke, first: first, last: last, style: .quad)
        case .buildTriangle:
            applyBuildDrag(stroke, first: first, last: last, style: .triangle)
        case .mergePair:
            applyMergePair(stroke, samples: samples)
        case .pathDistribute:
            applyPathDistribute(stroke, first: first, last: last)
        case .surfaceCut:
            applySurfaceCut(stroke, samples: samples)
        case .patchClone, .extendBoundary, .transformVertices:
            // Camera-as-manipulator tools (task 4.2): the stroke selects
            // (or, as a tap on an armed session, commits) — the camera
            // does the manipulation between strokes.
            handleCameraToolStroke(stroke, samples: samples)
        case .drawStrip:
            applyDrawStrip(stroke, samples: samples)
        case .pinFlip:
            commitPinFlipStroke(stroke, samples: samples)
        }
    }

    // MARK: - Build Quad / Build Triangle (drag from existing topology)

    private enum BuildStyle {
        case quad
        case triangle
    }

    /// CozyBlanket BuildQ/BuildT drag semantics (docs/COZYBLANKET_REFERENCE
    /// §4.1): the drag START picks the anchor — a vertex (interior corner)
    /// beats an edge — and the drag END places the new geometry:
    ///   - Build Quad from a QUAD's boundary edge → new triangle (tent).
    ///   - Build Quad from a TRIANGLE's boundary edge → grows it to a quad.
    ///   - Build Quad from a corner vertex → new quad (drag = diagonal).
    ///   - Build Triangle from any boundary edge → new triangle.
    ///   - Build Triangle from a corner vertex → two triangles.
    /// New vertices auto-merge onto nearby EXISTING vertices on release,
    /// all inside the same journal entry.
    private func applyBuildDrag(
        _ stroke: ToolStroke, first: StrokeSample, last: StrokeSample, style: BuildStyle
    ) {
        let context = stroke.context
        guard
            let mesh = context.editMesh,
            let hitStart = surfacePoint(at: point(of: first), in: context),
            let hitEnd = surfacePoint(at: point(of: last), in: context),
            simd_distance(hitStart, hitEnd)
                > context.sceneRadius * Self.toolMinimumDragFraction
        else { return }
        let pickRadius = context.sceneRadius * Self.vertexPickRadiusFraction
        if let corner = mesh.nearestVertex(to: hitStart, maxDistance: pickRadius * 0.5) {
            applyCornerBuild(
                stroke, anchor: corner, dragEnd: hitEnd, dragSample: last, style: style
            )
        } else if let edge = mesh.nearestEdge(to: hitStart, maxDistance: pickRadius) {
            applyEdgeBuild(stroke, edge: edge.edge, dragEnd: hitEnd, style: style)
        }
        // No vertex or edge under the drag start: inert (the tools extend
        // EXISTING topology; fresh quads come from the Pencil grammar).
    }

    private func applyEdgeBuild(
        _ stroke: ToolStroke, edge: UInt32, dragEnd: SIMD3<Float>, style: BuildStyle
    ) {
        let context = stroke.context
        guard
            let mesh = context.editMesh,
            let object = context.editObject,
            let payload = context.editPayload,
            let endpoints = mesh.edgeEndpoints(of: edge)
        else { return }
        let adjacent = mesh.edgeFaces(of: edge)
        guard adjacent.count == 1 else { return }  // interior edges: inert
        let transaction = MeshEditTransaction(
            object: object, mesh: mesh, currentPayload: payload
        )
        if style == .quad && adjacent[0].sides == 3 {
            // Triangle-edge drag: grow the triangle into a quad.
            journalOrDiscard(verb: "tool.buildQuad.grow") {
                try mesh.growBoundaryEdge(edge, to: dragEnd, snapping: context.snapper)
                try runAutoRelaxIfEnabled(
                    mesh: mesh, context: context, around: [dragEnd]
                )
                onLiveEdit?()
                return try transaction.command(verb: "tool.buildQuad.grow")
            }
            return
        }
        // Quad-edge (Build Quad) or any-edge (Build Triangle) drag: a new
        // triangle tented off the edge, apex under the pen.
        let verb = style == .quad ? "tool.buildQuad.edge" : "tool.buildTriangle.edge"
        journalOrDiscard(verb: verb) {
            let built = try mesh.buildFace(
                ring: [
                    .existing(endpoints.0), .existing(endpoints.1), .point(dragEnd),
                ],
                snapping: context.snapper
            )
            try autoMergeNewVertices(
                built.newVertices, excluding: Set(built.ringVertices),
                mesh: mesh, context: context
            )
            try runAutoRelaxIfEnabled(mesh: mesh, context: context, around: [dragEnd])
            onLiveEdit?()
            return try transaction.command(verb: verb)
        }
    }

    private func applyCornerBuild(
        _ stroke: ToolStroke, anchor: Mesh.VertexPick, dragEnd: SIMD3<Float>,
        dragSample: StrokeSample, style: BuildStyle
    ) {
        let context = stroke.context
        guard
            let mesh = context.editMesh,
            let object = context.editObject,
            let payload = context.editPayload,
            let ray = context.ray(point(of: dragSample)),
            let corners = RetopoToolGeometry.cornerQuadCorners(
                anchor: anchor.position, drag: dragEnd, view: ray.direction
            )
        else { return }
        let transaction = MeshEditTransaction(
            object: object, mesh: mesh, currentPayload: payload
        )
        let verb = style == .quad ? "tool.buildQuad.corner" : "tool.buildTriangle.corner"
        journalOrDiscard(verb: verb) {
            var ringIDs = Set<UInt32>()
            var created: [UInt32] = []
            switch style {
            case .quad:
                let built = try mesh.buildFace(
                    ring: [
                        .existing(anchor.vertex), .point(corners.first),
                        .point(dragEnd), .point(corners.second),
                    ],
                    snapping: context.snapper
                )
                ringIDs.formUnion(built.ringVertices)
                created = built.newVertices
            case .triangle:
                // Two triangles sharing the anchor→drag diagonal. The first
                // ring has ONE existing vertex, so the engine never flips
                // it: ring ids map positionally and the drag vertex can be
                // reused by the second triangle.
                let firstTri = try mesh.buildFace(
                    ring: [
                        .existing(anchor.vertex), .point(corners.first),
                        .point(dragEnd),
                    ],
                    snapping: context.snapper
                )
                let dragVertex = firstTri.ringVertices[2]
                let secondTri = try mesh.buildFace(
                    ring: [
                        .existing(anchor.vertex), .existing(dragVertex),
                        .point(corners.second),
                    ],
                    snapping: context.snapper
                )
                ringIDs.formUnion(firstTri.ringVertices)
                ringIDs.formUnion(secondTri.ringVertices)
                created = firstTri.newVertices + secondTri.newVertices
            }
            try autoMergeNewVertices(
                created, excluding: ringIDs, mesh: mesh, context: context
            )
            try runAutoRelaxIfEnabled(
                mesh: mesh, context: context, around: [anchor.position, dragEnd]
            )
            onLiveEdit?()
            return try transaction.command(verb: verb)
        }
    }

    /// Auto-merge on release (CozyBlanket BuildQ/BuildT): every vertex the
    /// drag created welds onto the nearest EXISTING vertex within merge
    /// range — never onto the built ring itself or a sibling new vertex
    /// (`excluding` carries both), which would degenerate the new face.
    private func autoMergeNewVertices(
        _ created: [UInt32], excluding: Set<UInt32>, mesh: Mesh, context: Context
    ) throws {
        let radius = context.sceneRadius * Self.mergeSnapRadiusFraction
        for vertex in created {
            guard
                let position = mesh.vertexPosition(vertex),
                let pick = mesh.nearestVertex(
                    to: position, maxDistance: radius, excluding: vertex
                ),
                !excluding.contains(pick.vertex)
            else { continue }
            try mesh.mergeVertices(keep: pick.vertex, remove: vertex)
        }
    }

    // MARK: - Merge Pair

    /// Vertex-to-vertex stroke → collapse the pair at its midpoint;
    /// otherwise a stroke across the shared edge of two triangles →
    /// dissolve it into a quad (CozyBlanket MergeP's two modes).
    private func applyMergePair(_ stroke: ToolStroke, samples: [StrokeSample]) {
        let context = stroke.context
        guard
            let mesh = context.editMesh,
            let first = samples.first, let last = samples.last,
            let hitStart = surfacePoint(at: point(of: first), in: context),
            let hitEnd = surfacePoint(at: point(of: last), in: context)
        else { return }
        let pickRadius = context.sceneRadius * Self.vertexPickRadiusFraction
        if let from = mesh.nearestVertex(to: hitStart, maxDistance: pickRadius),
            let to = mesh.nearestVertex(to: hitEnd, maxDistance: pickRadius),
            from.vertex != to.vertex {
            applyElementEdit(verb: "tool.mergePair.vertices", context: context) { mesh in
                try mesh.mergeVertices(
                    keep: to.vertex, remove: from.vertex, atMidpoint: true
                )
            }
            return
        }
        // Two adjacent triangles: the stroke crosses their shared edge —
        // dissolve it into one quad.
        let mid = samples[samples.count / 2]
        guard
            let hitMid = surfacePoint(at: point(of: mid), in: context),
            let edge = mesh.nearestEdge(to: hitMid, maxDistance: pickRadius)
        else { return }
        let adjacent = mesh.edgeFaces(of: edge.edge)
        guard adjacent.count == 2, adjacent.allSatisfy({ $0.sides == 3 }) else { return }
        applyElementEdit(verb: "tool.mergePair.quad", context: context) { mesh in
            try mesh.dissolveEdges([edge.edge])
        }
    }

    // MARK: - Path Distribute

    /// Evenly distributes the vertices along the closest (shortest edge)
    /// path between the vertices under the stroke's endpoints; moved
    /// vertices re-snap onto the Target. Endpoints stay fixed.
    private func applyPathDistribute(
        _ stroke: ToolStroke, first: StrokeSample, last: StrokeSample
    ) {
        let context = stroke.context
        guard
            let mesh = context.editMesh,
            let object = context.editObject,
            let payload = context.editPayload,
            let hitStart = surfacePoint(at: point(of: first), in: context),
            let hitEnd = surfacePoint(at: point(of: last), in: context)
        else { return }
        let pickRadius = context.sceneRadius * Self.vertexPickRadiusFraction
        guard
            let from = mesh.nearestVertex(to: hitStart, maxDistance: pickRadius),
            let to = mesh.nearestVertex(to: hitEnd, maxDistance: pickRadius),
            from.vertex != to.vertex
        else { return }
        let path = mesh.shortestVertexPath(from: from.vertex, to: to.vertex)
        guard path.count >= 3 else { return }  // no interior vertices to move
        let transaction = MeshEditTransaction(
            object: object, mesh: mesh, currentPayload: payload
        )
        journalOrDiscard(verb: "tool.pathDistribute") {
            try mesh.distributePath(path, snapping: context.snapper)
            onLiveEdit?()
            return try transaction.command(verb: "tool.pathDistribute")
        }
    }

    // MARK: - Surface Cut

    /// Straight-knife cut between the stroke's first and last surface
    /// hits, as seen through the camera; crossed edges split and resulting
    /// n-gons auto-triangulate (engine op). A knife that crosses nothing
    /// journals nothing. Curved (per-segment) knife strokes are honest
    /// deferred scope — see tasks.md 4.1a.
    private func applySurfaceCut(_ stroke: ToolStroke, samples: [StrokeSample]) {
        let context = stroke.context
        guard
            let mesh = context.editMesh,
            let object = context.editObject,
            let payload = context.editPayload,
            let start = samples.firstNonNil({ self.surfacePoint(at: self.point(of: $0), in: context) }),
            let end = samples.reversed()
                .firstNonNil({ self.surfacePoint(at: self.point(of: $0), in: context) }),
            simd_distance(start, end) > context.sceneRadius * Self.toolMinimumDragFraction,
            let ray = context.ray(point(of: samples[samples.count / 2]))
        else { return }
        let transaction = MeshEditTransaction(
            object: object, mesh: mesh, currentPayload: payload
        )
        journalOrDiscard(verb: "tool.surfaceCut") {
            try mesh.surfaceCut(
                from: start, to: end, viewDirection: ray.direction,
                triangulatingNGons: true, snapping: context.snapper
            )
            onLiveEdit?()
            return try transaction.command(verb: "tool.surfaceCut")
        }
    }
}

// MARK: - Visual-verification probes (task 4.1 screenshot hooks)

extension MeshEditController {
    /// A live vertex whose pick is VALIDATED through the same path the
    /// tools use: its screen projection raycasts onto the Target within
    /// pick range of the vertex (the Target surface can sit off the cage,
    /// so an unvalidated projection could miss the pick).
    private struct ProbeVertex {
        var id: UInt32
        var position: SIMD3<Float>
        var screen: SIMD2<Float>
    }

    /// Arms `tool` and drives ONE real tool stroke computed from the live
    /// mesh and camera through the controller's stroke entry points (the
    /// simulator cannot synthesize Pencil drags — same precedent as the
    /// task-3.7 snap probe). Returns whether the stroke journaled a
    /// command. Path Distribute first drives a real Tweak stroke to make
    /// the chain uneven — an already-even chain would journal nothing.
    @discardableResult
    func probeToolStrokeForVisualVerification(_ tool: RetopoTool) -> Bool {
        guard let context = contextProvider?(), context.editMesh != nil,
            context.project != nil
        else { return false }
        activeTool = tool
        let vertices = validatedProbeVertices(in: context)
        guard vertices.count >= 2 else { return false }
        lastCommit = nil
        switch tool {
        case .buildQuad:
            probeEdgeDrag(vertices: vertices, context: context)
        case .buildTriangle:
            probeCornerDrag(vertices: vertices, context: context)
        case .mergePair:
            probeMergeLine(vertices: vertices, context: context)
        case .pathDistribute:
            probePathDistribute(vertices: vertices, context: context)
        case .surfaceCut:
            probeKnife(vertices: vertices, context: context)
        case .patchClone:
            probePatchClone(vertices: vertices, context: context)
        case .extendBoundary:
            probeExtendBoundary(vertices: vertices, context: context)
        case .drawStrip:
            probeDrawStrip(vertices: vertices, context: context)
        case .transformVertices:
            probeTransformVertices(vertices: vertices, context: context)
        case .pinFlip:
            probePinLoopHold(vertices: vertices, context: context)
        }
        return lastCommit != nil
    }

    // MARK: Camera-tool probes (task 4.2): selection stroke -> synthesized
    // camera orbit feed -> commit, all through the controller's real entry
    // points (the simulator can synthesize neither Pencil drags nor a
    // concurrent orbit).

    /// Orbits the LIVE viewport camera and feeds each new pose into the
    /// armed session, `steps` times — the frame and the session stay in
    /// agreement, so the commit (which re-reads the live camera) places
    /// exactly what the screenshot shows.
    private func feedProbeCameraOrbit(context: Context, steps: Int) {
        guard let orbit = context.orbitCamera else { return }
        for _ in 0..<steps {
            orbit(SIMD2(60, 30))
            guard let camera = contextProvider?()?.camera else { return }
            cameraPoseChanged(camera: camera)
        }
    }

    /// Patch Clone: select the faces under a stroke through the validated
    /// vertices, orbit, paste.
    private func probePatchClone(vertices: [ProbeVertex], context: Context) {
        driveProbeStroke(verb: .pencil, through: vertices.map(\.screen))
        guard cameraSession != nil else { return }
        feedProbeCameraOrbit(context: context, steps: 4)
        commitCameraToolSession()
    }

    /// Extend Boundary: hold on a boundary vertex (whole-loop
    /// auto-select), orbit in automatic mode until rows stepped, commit.
    private func probeExtendBoundary(vertices: [ProbeVertex], context: Context) {
        preferredExtendBoundaryMode = .automatic
        guard let start = vertices.first else { return }
        driveProbeStroke(verb: .pencil, through: [start.screen, start.screen])
        guard cameraSession != nil else { return }
        for _ in 0..<12 where !(cameraToolBanner?.canCommit ?? false) {
            feedProbeCameraOrbit(context: context, steps: 2)
        }
        commitCameraToolSession()
    }

    /// Draw Strip: drag outward from a boundary edge midpoint through
    /// several waypoints (stroke-driven — commits at stroke end).
    private func probeDrawStrip(vertices: [ProbeVertex], context: Context) {
        guard let mesh = context.editMesh, let project = context.project else { return }
        let center = centroid(of: vertices)
        for a in vertices {
            for b in vertices where a.id < b.id {
                let mid = (a.position + b.position) * 0.5
                guard
                    let pick = mesh.nearestEdge(
                        to: mid, maxDistance: simd_distance(a.position, b.position) * 0.1
                    ),
                    let ends = mesh.edgeEndpoints(of: pick.edge),
                    Set([ends.0, ends.1]) == Set([a.id, b.id]),
                    mesh.edgeFaces(of: pick.edge).count == 1
                else { continue }
                let along = simd_normalize(b.position - a.position)
                var outward = mid - center
                outward -= along * simd_dot(outward, along)
                guard simd_length(outward) > .ulpOfOne else { continue }
                let width = simd_distance(a.position, b.position)
                let direction = simd_normalize(outward)
                var screenPoints: [SIMD2<Float>] = []
                for step in 0...3 {
                    let world = mid + direction * (width * Float(step))
                    guard
                        let screen = project(world),
                        surfacePoint(at: screen, in: context) != nil
                    else { break }
                    screenPoints.append(screen)
                }
                guard screenPoints.count >= 3 else { continue }
                driveProbeStroke(verb: .pencil, through: screenPoints)
                if lastCommit != nil { return }
            }
        }
    }

    /// Transform Vertices: select two vertices with a stroke, orbit so
    /// they lock to the screen and move over the model, commit (re-snap).
    private func probeTransformVertices(vertices: [ProbeVertex], context: Context) {
        guard vertices.count >= 2 else { return }
        driveProbeStroke(
            verb: .pencil, through: [vertices[0].screen, vertices[1].screen]
        )
        guard cameraSession != nil else { return }
        feedProbeCameraOrbit(context: context, steps: 4)
        commitCameraToolSession()
    }

    private func validatedProbeVertices(in context: Context) -> [ProbeVertex] {
        guard let mesh = context.editMesh, let project = context.project else { return [] }
        let raw = mesh.positions()
        let pickRadius = context.sceneRadius * Self.vertexPickRadiusFraction
        var out: [ProbeVertex] = []
        var index = 0
        while index + 2 < raw.count, out.count < 64 {
            let position = SIMD3(raw[index], raw[index + 1], raw[index + 2])
            index += 3
            guard
                let pick = mesh.nearestVertex(to: position, maxDistance: pickRadius * 0.01),
                let screen = project(position),
                let hit = surfacePoint(at: screen, in: context),
                simd_distance(hit, pick.position) < pickRadius * 0.4
            else { continue }
            if !out.contains(where: { $0.id == pick.vertex }) {
                out.append(ProbeVertex(id: pick.vertex, position: pick.position, screen: screen))
            }
        }
        return out
    }

    private func centroid(of vertices: [ProbeVertex]) -> SIMD3<Float> {
        vertices.reduce(SIMD3<Float>.zero) { $0 + $1.position } / Float(vertices.count)
    }

    /// Farthest-apart validated pair (knife span / distribute endpoints).
    private func farthestPair(in vertices: [ProbeVertex]) -> (ProbeVertex, ProbeVertex)? {
        var best: (ProbeVertex, ProbeVertex)?
        var bestDistance: Float = -1
        for i in vertices.indices {
            for j in vertices.indices where j > i {
                let d = simd_distance(vertices[i].position, vertices[j].position)
                if d > bestDistance {
                    bestDistance = d
                    best = (vertices[i], vertices[j])
                }
            }
        }
        return best
    }

    /// Drives a stroke through the controller's real entry points with the
    /// current verb/tool routing.
    private func driveProbeStroke(
        verb: InputArbiter.Verb, through screenPoints: [SIMD2<Float>]
    ) {
        guard let first = screenPoints.first else { return }
        var samples = [probeSample(at: first, time: 0)]
        strokeBegan(verb: verb, sample: samples[0])
        for (index, point) in screenPoints.dropFirst().enumerated() {
            let sample = probeSample(at: point, time: Double(index + 1) * 0.02)
            strokeContinued(sample: sample)
            samples.append(sample)
        }
        strokeEnded(verb: verb, interpretation: nil, samples: samples)
    }

    /// Pin Flip (task 4.3): a HOLD over an INTERIOR edge, which flips
    /// that edge loop's pins in one journaled entry — the screenshot hook
    /// for "pins render as distinct markers". Stationary samples spanning
    /// more than `pinHoldDuration` are what makes it a hold rather than a
    /// tap, exactly as a real dwelling Pencil would.
    private func probePinLoopHold(vertices: [ProbeVertex], context: Context) {
        guard let mesh = context.editMesh, let project = context.project else { return }
        let pickRadius = context.sceneRadius * Self.vertexPickRadiusFraction
        for from in vertices {
            for to in vertices where to.id != from.id {
                let midpoint = (from.position + to.position) * 0.5
                guard
                    let screen = project(midpoint),
                    let hit = surfacePoint(at: screen, in: context),
                    // The hold must land on an INTERIOR edge and clear of
                    // any vertex — a vertex hold flips just that vertex,
                    // which is not what this probe is demonstrating.
                    mesh.nearestVertex(to: hit, maxDistance: pickRadius * 0.25) == nil,
                    let edge = mesh.nearestEdge(to: hit, maxDistance: pickRadius),
                    mesh.isBoundaryEdge(edge.edge) == false,
                    !mesh.edgeLoopVertices(from: edge.edge).isEmpty
                else { continue }
                driveProbeHold(at: screen)
                if lastCommit != nil { return }
            }
        }
    }

    /// Drives a stationary HOLD stroke at one screen point through the
    /// real begin/continue/end entry points.
    private func driveProbeHold(at screen: SIMD2<Float>) {
        let duration = MeshEditController.pinHoldDuration * 1.5
        var samples = [probeSample(at: screen, time: 0)]
        strokeBegan(verb: .pencil, sample: samples[0])
        for step in 1...4 {
            let sample = probeSample(at: screen, time: duration * Double(step) / 4)
            strokeContinued(sample: sample)
            samples.append(sample)
        }
        strokeEnded(verb: .pencil, interpretation: nil, samples: samples)
    }

    /// Build Quad: drag outward from a boundary edge midpoint.
    private func probeEdgeDrag(vertices: [ProbeVertex], context: Context) {
        guard let mesh = context.editMesh, let project = context.project else { return }
        let center = centroid(of: vertices)
        for a in vertices {
            for b in vertices where a.id < b.id {
                let mid = (a.position + b.position) * 0.5
                guard
                    let pick = mesh.nearestEdge(
                        to: mid, maxDistance: simd_distance(a.position, b.position) * 0.1
                    ),
                    let ends = mesh.edgeEndpoints(of: pick.edge),
                    Set([ends.0, ends.1]) == Set([a.id, b.id]),
                    mesh.edgeFaces(of: pick.edge).count == 1
                else { continue }
                // Outward, in the plane perpendicular to the edge.
                let along = simd_normalize(b.position - a.position)
                var outward = mid - center
                outward -= along * simd_dot(outward, along)
                guard simd_length(outward) > .ulpOfOne else { continue }
                let end = mid + simd_normalize(outward)
                    * simd_distance(a.position, b.position)
                guard
                    let startScreen = project(mid),
                    let endScreen = project(end),
                    surfacePoint(at: endScreen, in: context) != nil
                else { continue }
                driveProbeStroke(verb: .pencil, through: [startScreen, endScreen])
                if lastCommit != nil { return }
            }
        }
    }

    /// Build Triangle: drag outward from a corner vertex.
    private func probeCornerDrag(vertices: [ProbeVertex], context: Context) {
        guard let mesh = context.editMesh, let project = context.project else { return }
        let center = centroid(of: vertices)
        let ordered = vertices.sorted {
            simd_distance($0.position, center) > simd_distance($1.position, center)
        }
        for corner in ordered {
            guard
                let neighbor = mesh.nearestVertex(
                    to: corner.position, maxDistance: context.sceneRadius,
                    excluding: corner.id
                )
            else { continue }
            let outward = corner.position - center
            guard simd_length(outward) > .ulpOfOne else { continue }
            let end = corner.position + simd_normalize(outward)
                * simd_distance(corner.position, neighbor.position)
            guard
                let endScreen = project(end),
                surfacePoint(at: endScreen, in: context) != nil
            else { continue }
            driveProbeStroke(verb: .pencil, through: [corner.screen, endScreen])
            if lastCommit != nil { return }
        }
    }

    /// Merge Pair: line from a vertex to its nearest neighbor.
    private func probeMergeLine(vertices: [ProbeVertex], context: Context) {
        for from in vertices {
            guard
                let to = vertices.filter({ $0.id != from.id }).min(by: {
                    simd_distance($0.position, from.position)
                        < simd_distance($1.position, from.position)
                })
            else { continue }
            driveProbeStroke(verb: .pencil, through: [from.screen, to.screen])
            if lastCommit != nil { return }
        }
    }

    /// Path Distribute: perturb an interior chain vertex with a REAL Tweak
    /// stroke, then distribute the chain back to even spacing.
    private func probePathDistribute(vertices: [ProbeVertex], context: Context) {
        guard
            let mesh = context.editMesh, let project = context.project,
            let (from, to) = farthestPair(in: vertices)
        else { return }
        let path = mesh.shortestVertexPath(from: from.id, to: to.id)
        guard path.count >= 3, let interior = mesh.vertexPosition(path[1]) else { return }
        // Perturb: drag the first interior vertex 30% toward the start.
        let toolBefore = activeTool
        activeTool = nil
        let dragged = interior + (from.position - interior) * 0.3
        if let start = project(interior), let end = project(dragged) {
            driveProbeStroke(verb: .tweak, through: [start, end])
        }
        activeTool = toolBefore
        lastCommit = nil
        driveProbeStroke(verb: .pencil, through: [from.screen, to.screen])
    }

    /// Surface Cut: straight knife across the mesh between its two
    /// farthest vertices, nudged off the exact vertex line.
    private func probeKnife(vertices: [ProbeVertex], context: Context) {
        guard
            let project = context.project,
            let (from, to) = farthestPair(in: vertices),
            let midRay = context.ray((from.screen + to.screen) * 0.5)
        else { return }
        let span = to.position - from.position
        let sideways = simd_cross(span, midRay.direction)
        guard simd_length(sideways) > .ulpOfOne else { return }
        let nudge = simd_normalize(sideways) * simd_length(span) * 0.05
        let start = from.position - span * 0.2 + nudge
        let end = to.position + span * 0.2 + nudge
        guard
            let startScreen = project(start),
            let midScreen = project((start + end) * 0.5),
            let endScreen = project(end)
        else { return }
        driveProbeStroke(verb: .pencil, through: [startScreen, midScreen, endScreen])
    }
}

extension Sequence {
    /// First non-nil transform result (the Surface Cut endpoint scan).
    func firstNonNil<T>(_ transform: (Element) -> T?) -> T? {
        for element in self {
            if let value = transform(element) {
                return value
            }
        }
        return nil
    }
}

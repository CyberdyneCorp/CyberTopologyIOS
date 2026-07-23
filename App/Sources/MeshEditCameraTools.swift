import CyberKit
import CyberKitTesting
import Foundation
import os
import simd

// Camera-as-manipulator tool sessions (task 4.2; spec: retopology-tools /
// "Core RT action roster" — Patch Clone, Extend Boundary, Transform
// Vertices; Draw Strip is the roster's stroke-driven sibling and lives at
// the bottom of this file).
//
// Session shape (deliberately mirroring the brush `Session` discipline):
//   - a Pencil SELECTION stroke arms the session (faces / boundary chain /
//     vertices under the stroke),
//   - while armed, camera input BOTH moves the camera AND drives the tool
//     (the coordinator feeds poses only while the InputArbiter's
//     camera→tool gate is open — the arbiter owns the routing, design D5),
//   - the session preview renders as ghost geometry (`GhostRenderPath`
//     hover channel) or, for Transform Vertices, as the live mesh itself
//     (brush-style live edits, discarded on cancel),
//   - COMMIT journals exactly ONCE per committed session action (a Patch
//     Clone paste, an Extend Boundary extrusion — automatic mode's whole
//     row stack lands in one entry), CANCEL discards everything.

extension MeshEditController {
    /// Published snapshot of the active session for the editor banner.
    struct CameraToolBanner: Equatable {
        var tool: RetopoTool
        var status: String
        /// Extend Boundary only: the active mode.
        var mode: ExtendBoundaryPlan.Mode?
        /// Patch Clone only: the flip option's state.
        var flipped: Bool?
        var canCommit: Bool
    }

    /// The armed camera-as-manipulator session.
    struct CameraToolSession {
        enum Plan {
            case patchClone(PatchClonePlan)
            case extendBoundary(ExtendBoundaryPlan)
            case transformVertices(TransformVerticesPlan)
        }

        var tool: RetopoTool
        var plan: Plan
        /// Camera pose pinned at selection time.
        var initialView: simd_float4x4
        var initialDistance: Float
        /// Latest fed pose (commit re-reads the live camera anyway, so an
        /// unfed pose change — e.g. an animated reframe — never corrupts
        /// the result, it just isn't previewed until the next feed).
        var currentView: simd_float4x4
        var currentDistance: Float
        var currentForward: SIMD3<Float>
        /// Barrel-roll baseline: the recognizer reports ABSOLUTE roll, the
        /// session consumes the delta from the first report it sees.
        var rollReference: Float?
        /// Patch Clone preview base: the selection-only scratch mesh's
        /// render buffers, transformed on the CPU per pose.
        var previewPositions: [Float] = []
        var previewNormals: [Float] = []
        var previewIndices: [UInt32] = []
        /// Extend Boundary preview base: the chain's world positions.
        var chainPositions: [SIMD3<Float>] = []
        /// Transform Vertices live-mutation state (brush-session style):
        /// the pinned transaction, the live mesh handle it mutates, and
        /// the absolute transform applied so far (camera feeds apply the
        /// delta; commit applies the final correction plus re-snap).
        var transaction: MeshEditTransaction?
        var liveMesh: Mesh?
        var appliedTransform = matrix_identity_float4x4
        var mutated = false
        /// The payload bytes an OWN commit (a Patch Clone paste) just
        /// wrote, so the coordinator's snapshot-change hook can re-pin
        /// instead of cancelling and Patch Clone stays armed for repeat
        /// pastes.
        ///
        /// A payload, NOT a Bool. `editMeshSnapshotWillChange` runs on
        /// SwiftUI's next `updateUIView` pass, not synchronously with the
        /// commit, so a one-bit "expecting my own commit" flag was consumed
        /// by whatever snapshot change arrived first. If an EXTERNAL change
        /// (undo tap, autosave conflict reload, batch command) coalesced
        /// into the same pass, the coordinator saw ONE `payload !=
        /// overlayPayload` transition, the flag ate it as "mine", and the
        /// session stayed armed with `plan.faces` / `plan.pivot` naming
        /// pre-reload topology — a later paste then cloned face ids
        /// resolved against a different document revision. Matching the
        /// exact bytes cannot be fooled that way: an external change never
        /// produces the payload this session just wrote.
        var committedPayload: Data?
    }

    /// True while the session holds live mesh edits a resync would
    /// clobber (Transform Vertices between selection and commit).
    var cameraSessionHoldsLiveMesh: Bool {
        if case .transformVertices = cameraSession?.plan { return true }
        return false
    }

    var cameraToolBanner: CameraToolBanner? {
        guard let session = cameraSession else { return nil }
        switch session.plan {
        case .patchClone(let plan):
            let pasted = plan.pasteCount > 0 ? " · pasted \(plan.pasteCount)" : ""
            return CameraToolBanner(
                tool: .patchClone,
                status: "\(plan.faces.count) faces — orbit to place, tap to paste\(pasted)",
                mode: nil, flipped: plan.flipped, canCommit: true
            )
        case .extendBoundary(let plan):
            let rows = plan.mode == .fan
                ? "fan apex follows the camera"
                : "rows: \(plan.commitOffsets.count)"
            return CameraToolBanner(
                tool: .extendBoundary,
                status: "\(plan.chain.count) boundary vertices — orbit to extrude, \(rows)",
                mode: plan.mode, flipped: nil, canCommit: plan.canCommit
            )
        case .transformVertices(let plan):
            return CameraToolBanner(
                tool: .transformVertices,
                status: "\(plan.vertices.count) vertices locked to screen — orbit to move",
                mode: nil, flipped: nil, canCommit: true
            )
        }
    }

    private func publishCameraSession() {
        onCameraSessionChanged?(cameraToolBanner)
    }

    // MARK: - Stroke routing (selection / tap-commit)

    /// Sampled surface hits of a stroke (bounded stride so long strokes
    /// stay cheap).
    private func strokeSurfaceHits(
        samples points: [SIMD2<Float>], context: Context, limit: Int = 48
    ) -> [SIMD3<Float>] {
        guard !points.isEmpty else { return [] }
        let stride = max(1, points.count / limit)
        var hits: [SIMD3<Float>] = []
        var index = 0
        while index < points.count {
            if let hit = surfacePoint(at: points[index], in: context) {
                hits.append(hit)
            }
            index += stride
        }
        if let last = points.last, let hit = surfacePoint(at: last, in: context) {
            hits.append(hit)
        }
        return hits
    }

    /// A finished Pencil stroke while a camera tool is armed: a TAP on an
    /// armed session commits (paste / extrude / re-snap); anything else
    /// (re)selects.
    func handleCameraToolStroke(_ stroke: ToolStroke, samples: [StrokeSample]) {
        let points = samples.map { point(of: $0) }
        let isTap = CameraToolStrokes.isTap(points: points)
        if cameraSession != nil, isTap {
            commitCameraToolSession()
            return
        }
        // A new selection replaces any armed session (discarding it).
        cancelCameraToolSession()
        // …and the discard may have RELOADED the live EditMesh: cancelling
        // a mutated Transform Vertices session fires `onDiscardLiveEdits`,
        // which builds a FRESH `Mesh` from the pinned payload and rebinds
        // `recognizerEditMesh`. `stroke.context` was pinned at stroke begin
        // — where `resyncFromDocumentIfIdle()` was deliberately skipped
        // because the session was active — so its `editMesh` is now the
        // orphaned handle that still carries the edits we just discarded.
        // Arming the new session off it would transform an invisible mesh
        // (the overlay reads the rebound handle) and commit a payload
        // containing the cancelled session's edits. Re-read the
        // document-derived fields; the camera/ray half of the pinned
        // context stays put so the stroke still resolves against the pose
        // it was drawn under.
        let context = refreshedDocumentContext(stroke.context)
        switch stroke.tool {
        case .patchClone:
            beginPatchCloneSession(context: context, points: points)
        case .extendBoundary:
            beginExtendBoundarySession(context: context, points: points, isHold: isTap)
        case .transformVertices:
            beginTransformVerticesSession(context: context, points: points)
        default:
            break
        }
        publishCameraSession()
    }

    /// `pinned` with its document-derived fields refreshed from the CURRENT
    /// snapshot (live mesh handle, payload bytes, manifest entry,
    /// annotations). Everything camera-shaped is kept exactly as pinned.
    /// Falls back to the pinned context when no provider is installed
    /// (headless tests that drive the sessions directly).
    private func refreshedDocumentContext(_ pinned: Context) -> Context {
        guard let fresh = contextProvider?() else { return pinned }
        var context = pinned
        context.editObject = fresh.editObject
        context.editMesh = fresh.editMesh
        context.editPayload = fresh.editPayload
        context.annotations = fresh.annotations
        context.documentHasEditMesh = fresh.documentHasEditMesh
        return context
    }

    // MARK: - Selection (session begin)

    private func beginPatchCloneSession(context: Context, points: [SIMD2<Float>]) {
        guard
            let mesh = context.editMesh, let payload = context.editPayload,
            let camera = context.camera
        else { return }
        let pickRadius = context.sceneRadius * Self.vertexPickRadiusFraction
        var faces: [UInt32] = []
        var seen = Set<UInt32>()
        for hit in strokeSurfaceHits(samples: points, context: context) {
            guard let pick = mesh.nearestEdge(to: hit, maxDistance: pickRadius)
            else { continue }
            for adjacent in mesh.edgeFaces(of: pick.edge)
            where seen.insert(adjacent.face).inserted {
                faces.append(adjacent.face)
            }
        }
        guard !faces.isEmpty else { return }
        // Preview base: a scratch mesh holding ONLY the selected patch
        // (clone in place, drop everything else), rendered as ghost
        // geometry and transformed on the CPU per camera pose.
        guard let base = patchPreviewBase(faces: faces, payload: payload) else { return }
        var plan = PatchClonePlan(
            faces: faces, pivot: base.pivot, patchNormal: base.normal
        )
        plan.rollAngle = 0
        var session = CameraToolSession(
            tool: .patchClone,
            plan: .patchClone(plan),
            initialView: camera.viewMatrix(),
            initialDistance: camera.distance,
            currentView: camera.viewMatrix(),
            currentDistance: camera.distance,
            currentForward: camera.basis.forward
        )
        session.previewPositions = base.positions
        session.previewNormals = base.normals
        session.previewIndices = base.indices
        cameraSession = session
        refreshCameraSessionPreview()
    }

    /// Builds the selection-only preview geometry on a scratch mesh
    /// deserialized from the document payload (the live mesh is never
    /// touched by a preview).
    private func patchPreviewBase(
        faces: [UInt32], payload: Data
    ) -> (positions: [Float], normals: [Float], indices: [UInt32],
          pivot: SIMD3<Float>, normal: SIMD3<Float>)? {
        do {
            let scratch = try Mesh(payloadData: payload)
            let cloned = try scratch.patchClone(faces: faces, transform: .identity)
            let keep = Set(cloned)
            let doomed = scratch.liveFaceIDs().filter { !keep.contains($0) }
            if !doomed.isEmpty {
                _ = try scratch.deleteFaces(doomed)
            }
            let positions = scratch.positions()
            let normals = scratch.normals()
            let indices = scratch.triangleIndices()
            guard !positions.isEmpty, !indices.isEmpty else { return nil }
            var pivot = SIMD3<Float>.zero
            var normal = SIMD3<Float>.zero
            for base in stride(from: 0, to: positions.count, by: 3) {
                pivot += SIMD3(positions[base], positions[base + 1], positions[base + 2])
                normal += SIMD3(normals[base], normals[base + 1], normals[base + 2])
            }
            pivot /= Float(positions.count / 3)
            let length = simd_length(normal)
            return (
                positions, normals, indices, pivot,
                length > .ulpOfOne ? normal / length : SIMD3(0, 0, 1)
            )
        } catch {
            return nil
        }
    }

    private func beginExtendBoundarySession(
        context: Context, points: [SIMD2<Float>], isHold: Bool
    ) {
        guard let mesh = context.editMesh, let camera = context.camera else { return }
        let pickRadius = context.sceneRadius * Self.vertexPickRadiusFraction
        let hits = strokeSurfaceHits(samples: points, context: context)
        // Seed: the first boundary edge under the stroke.
        var seedChain: Mesh.BoundaryChain?
        for hit in hits {
            guard let pick = mesh.nearestEdge(to: hit, maxDistance: pickRadius)
            else { continue }
            if let chain = mesh.boundaryChain(through: pick.edge) {
                seedChain = chain
                break
            }
        }
        guard let full = seedChain, full.vertices.count >= 2 else { return }
        // Hold on a boundary vertex auto-selects the WHOLE chain (spec:
        // "boundary auto-select on hold"); a stroke along part of the
        // boundary selects the contiguous run it covered.
        var chain = full.vertices
        var closed = full.closed
        if !isHold {
            let marked = full.vertices.map { vertex -> Bool in
                guard let position = mesh.vertexPosition(vertex) else { return false }
                return hits.contains { simd_distance($0, position) <= pickRadius }
            }
            let run = CameraToolStrokes.contiguousRun(marked: marked, closed: full.closed)
            if run.count >= 2, run.count < full.vertices.count {
                chain = run.map { full.vertices[$0] }
                closed = false
            }
        }
        let positions = chain.compactMap { mesh.vertexPosition($0) }
        guard positions.count == chain.count else { return }
        var length: Float = 0
        for index in 1..<positions.count {
            length += simd_distance(positions[index - 1], positions[index])
        }
        let edgeCount = closed ? positions.count : positions.count - 1
        guard edgeCount > 0 else { return }
        let plan = ExtendBoundaryPlan(
            mode: preferredExtendBoundaryMode,
            chain: chain,
            closed: closed,
            step: ExtendBoundaryPlan.step(
                averageEdgeLength: length / Float(edgeCount),
                sceneRadius: context.sceneRadius
            )
        )
        var session = CameraToolSession(
            tool: .extendBoundary,
            plan: .extendBoundary(plan),
            initialView: camera.viewMatrix(),
            initialDistance: camera.distance,
            currentView: camera.viewMatrix(),
            currentDistance: camera.distance,
            currentForward: camera.basis.forward
        )
        session.chainPositions = positions
        cameraSession = session
        refreshCameraSessionPreview()
    }

    private func beginTransformVerticesSession(
        context: Context, points: [SIMD2<Float>]
    ) {
        guard
            let mesh = context.editMesh, let object = context.editObject,
            let payload = context.editPayload, let camera = context.camera
        else { return }
        let pickRadius = context.sceneRadius * Self.vertexPickRadiusFraction * 0.75
        var vertices: [UInt32] = []
        var seen = Set<UInt32>()
        var pivot = SIMD3<Float>.zero
        for hit in strokeSurfaceHits(samples: points, context: context) {
            guard
                let pick = mesh.nearestVertex(to: hit, maxDistance: pickRadius),
                seen.insert(pick.vertex).inserted
            else { continue }
            vertices.append(pick.vertex)
            pivot += pick.position
        }
        guard !vertices.isEmpty else { return }
        pivot /= Float(vertices.count)
        var session = CameraToolSession(
            tool: .transformVertices,
            plan: .transformVertices(TransformVerticesPlan(
                vertices: vertices, pivot: pivot
            )),
            initialView: camera.viewMatrix(),
            initialDistance: camera.distance,
            currentView: camera.viewMatrix(),
            currentDistance: camera.distance,
            currentForward: camera.basis.forward
        )
        session.transaction = MeshEditTransaction(
            object: object, mesh: mesh, currentPayload: payload
        )
        session.liveMesh = mesh
        cameraSession = session
    }

    // MARK: - Camera feed (the manipulator)

    /// A camera pose change while the arbiter's camera→tool gate is open:
    /// updates the armed session (placement preview / live transform).
    func cameraPoseChanged(camera: CameraState) {
        guard var session = cameraSession else { return }
        session.currentView = camera.viewMatrix()
        session.currentDistance = camera.distance
        session.currentForward = camera.basis.forward
        switch session.plan {
        case .patchClone(var plan):
            plan.scale = PlacementMath.pinchScale(
                initialDistance: session.initialDistance,
                currentDistance: session.currentDistance
            )
            session.plan = .patchClone(plan)
            cameraSession = session
            refreshCameraSessionPreview()
        case .extendBoundary(var plan):
            let centroid = session.chainPositions.reduce(SIMD3<Float>.zero, +)
                / Float(max(session.chainPositions.count, 1))
            plan.displacementChanged(PlacementMath.displacement(
                of: centroid,
                initialView: session.initialView,
                currentView: session.currentView
            ))
            let wantsAutoCommit = plan.wantsAutoCommit
            session.plan = .extendBoundary(plan)
            cameraSession = session
            refreshCameraSessionPreview()
            if wantsAutoCommit {
                commitCameraToolSession()
                return
            }
        case .transformVertices(var plan):
            plan.scale = PlacementMath.pinchScale(
                initialDistance: session.initialDistance,
                currentDistance: session.currentDistance
            )
            session.plan = .transformVertices(plan)
            cameraSession = session
            applyTransformSessionDelta()
        }
        publishCameraSession()
    }

    /// Barrel-roll feed (task 3.7a: the first real rotate-placed-element
    /// consumer): rotates the Patch Clone placement / the Transform
    /// Vertices selection about the current view axis. Only hardware that
    /// reports roll ever calls this with non-zero angles (capability-
    /// gated at the recognizer; the delta baseline makes the first report
    /// neutral).
    func barrelRollChanged(_ angle: Float) {
        guard var session = cameraSession else { return }
        let reference = session.rollReference ?? angle
        session.rollReference = reference
        let delta = angle - reference
        switch session.plan {
        case .patchClone(var plan):
            plan.rollAngle = delta
            session.plan = .patchClone(plan)
            cameraSession = session
            refreshCameraSessionPreview()
        case .transformVertices(var plan):
            plan.rollAngle = delta
            session.plan = .transformVertices(plan)
            cameraSession = session
            applyTransformSessionDelta()
        case .extendBoundary:
            // No free orientation: the offset already comes from the
            // camera (see tasks.md 3.7a).
            cameraSession = session
            return
        }
        publishCameraSession()
    }

    /// The absolute placement transform of the current pose for plans
    /// with a pivot (Patch Clone / Transform Vertices).
    private func placementTransform(
        of session: CameraToolSession, pivot: SIMD3<Float>, scale: Float,
        rollAngle: Float, flipped: Bool, flipNormal: SIMD3<Float>
    ) -> simd_float4x4 {
        PlacementMath.placementTransform(
            initialView: session.initialView,
            currentView: session.currentView,
            pivot: pivot,
            scale: scale,
            rollAngle: rollAngle,
            viewAxis: session.currentForward,
            flipped: flipped,
            flipNormal: flipNormal
        )
    }

    /// Applies the delta between the last applied transform and the
    /// current absolute one to the LIVE mesh (Transform Vertices' brush-
    /// style live preview; commit re-snaps, cancel discards).
    private func applyTransformSessionDelta() {
        guard var session = cameraSession,
            case .transformVertices(let plan) = session.plan,
            let mesh = session.liveMesh
        else { return }
        let absolute = placementTransform(
            of: session, pivot: plan.pivot, scale: plan.scale,
            rollAngle: plan.rollAngle, flipped: false, flipNormal: SIMD3(0, 0, 1)
        )
        let delta = absolute * session.appliedTransform.inverse
        do {
            try mesh.transformVertices(plan.vertices, transform: MeshTransform(delta))
            session.appliedTransform = absolute
            session.mutated = true
            cameraSession = session
            onLiveEdit?()
        } catch {
            // Dead ids mid-session can only follow an external change the
            // snapshot hook already cancels on; log and drop the session.
            cancelCameraToolSession()
        }
    }

    // MARK: - Ghost preview

    /// Rebuilds and publishes the session's ghost preview.
    func refreshCameraSessionPreview() {
        guard let session = cameraSession else {
            onSessionPreviewChanged?(nil)
            return
        }
        switch session.plan {
        case .patchClone(let plan):
            let transform = placementTransform(
                of: session, pivot: plan.pivot, scale: plan.scale,
                rollAngle: plan.rollAngle, flipped: plan.flipped,
                flipNormal: plan.patchNormal
            )
            onSessionPreviewChanged?(PlacementPreviewGeometry.transformedGhost(
                positions: session.previewPositions,
                normals: session.previewNormals,
                indices: session.previewIndices,
                transform: MeshTransform(transform)
            ))
        case .extendBoundary(let plan):
            if plan.mode == .fan {
                let centroid = session.chainPositions.reduce(SIMD3<Float>.zero, +)
                    / Float(max(session.chainPositions.count, 1))
                onSessionPreviewChanged?(PlacementPreviewGeometry.fanGhost(
                    chain: session.chainPositions, closed: plan.closed,
                    apex: centroid + plan.displacement
                ))
            } else {
                onSessionPreviewChanged?(PlacementPreviewGeometry.ringsGhost(
                    chain: session.chainPositions, closed: plan.closed,
                    offsets: plan.commitOffsets
                ))
            }
        case .transformVertices:
            onSessionPreviewChanged?(nil)  // the live mesh IS the preview
        }
    }

    // MARK: - Commit / cancel / mode

    /// Commits the armed session: Patch Clone pastes (session stays armed
    /// — repeatable), Extend Boundary extrudes every accumulated row (or
    /// the fan) in ONE journal entry and ends, Transform Vertices re-snaps
    /// the moved vertices, journals once, reports, and ends.
    func commitCameraToolSession() {
        guard cameraSession != nil else { return }
        // Context FIRST, session SECOND. `contextProvider()` runs
        // `resyncFromDocumentIfIdle()`, which — for the plans that do not
        // hold live mesh edits, so resync is not suppressed — can detect an
        // external payload change (conflict reload, autosave-driven bundle
        // update) and call `editMeshSnapshotWillChange()`, dropping the
        // session synchronously. Capturing `session` before that would
        // commit pre-reload element ids against the newly rebound mesh:
        // the wrong faces pasted, or an `invalidArgument` throw, followed
        // by the trailing `guard var kept` silently swallowing the result.
        guard let context = contextProvider?() else { return }
        guard var session = cameraSession else { return }
        // Re-read the LIVE camera: unfed pose changes (animated reframe)
        // must not commit a stale placement — but ONLY through the same
        // arbiter gate the feed itself goes through. Camera motion the
        // gate deliberately withheld from the session (pen down /
        // palm-rejected touch) never moved the ghost, so baking it in here
        // would commit a placement the user never saw.
        if context.cameraFeedsArmedTool, let camera = context.camera {
            session.currentView = camera.viewMatrix()
            session.currentDistance = camera.distance
            session.currentForward = camera.basis.forward
            cameraSession = session
        }
        switch session.plan {
        case .patchClone(var plan):
            guard
                let mesh = context.editMesh, let object = context.editObject,
                let payload = context.editPayload
            else { return }
            plan.scale = PlacementMath.pinchScale(
                initialDistance: session.initialDistance,
                currentDistance: session.currentDistance
            )
            let transform = placementTransform(
                of: session, pivot: plan.pivot, scale: plan.scale,
                rollAngle: plan.rollAngle, flipped: plan.flipped,
                flipNormal: plan.patchNormal
            )
            let transaction = MeshEditTransaction(
                object: object, mesh: mesh, currentPayload: payload
            )
            session.committedPayload = nil
            cameraSession = session
            lastCommit = nil
            journalOrDiscard(verb: "tool.patchClone.paste") {
                try mesh.patchClone(
                    faces: plan.faces, transform: MeshTransform(transform),
                    flipped: plan.flipped, snapping: context.snapper
                )
                onLiveEdit?()
                let command = try transaction.command(verb: "tool.patchClone.paste")
                // Pin the EXACT bytes this paste is about to write BEFORE
                // the command is sent: `send` can drive the coordinator's
                // snapshot rebind synchronously, and the hook has to be
                // able to recognize these bytes as ours by then. A commit
                // that produced nothing leaves it nil, so the next snapshot
                // change is correctly treated as external.
                if let payload = command?.resultingPayload(forObject: object.id),
                    var pending = self.cameraSession {
                    pending.committedPayload = payload
                    self.cameraSession = pending
                }
                return command
            }
            guard var kept = cameraSession else { return }
            if lastCommit != nil {
                plan.pasteCount += 1
            }
            kept.plan = .patchClone(plan)
            cameraSession = kept
            publishCameraSession()
        case .extendBoundary(let plan):
            guard plan.canCommit,
                let mesh = context.editMesh, let object = context.editObject,
                let payload = context.editPayload
            else { return }
            let transaction = MeshEditTransaction(
                object: object, mesh: mesh, currentPayload: payload
            )
            // The session ends with the extrusion (the extruded rim is a
            // new boundary — select again to continue).
            cameraSession = nil
            onSessionPreviewChanged?(nil)
            if plan.mode == .fan {
                journalOrDiscard(verb: "tool.extendBoundary.fan") {
                    _ = try mesh.extendBoundaryFan(
                        chain: plan.chain, closed: plan.closed,
                        apexOffset: plan.displacement,
                        snapping: context.snapper
                    )
                    onLiveEdit?()
                    return try transaction.command(verb: "tool.extendBoundary.fan")
                }
            } else {
                journalOrDiscard(verb: "tool.extendBoundary.grid") {
                    var chain = plan.chain
                    for offset in plan.commitOffsets {
                        let extended = try mesh.extendBoundary(
                            chain: chain, closed: plan.closed, offset: offset,
                            rings: 1, snapping: context.snapper
                        )
                        chain = extended.outerChain
                    }
                    onLiveEdit?()
                    return try transaction.command(verb: "tool.extendBoundary.grid")
                }
            }
            publishCameraSession()
        case .transformVertices(let plan):
            guard let mesh = session.liveMesh, let transaction = session.transaction
            else { return }
            let absolute = placementTransform(
                of: session, pivot: plan.pivot, scale: plan.scale,
                rollAngle: plan.rollAngle, flipped: false, flipNormal: SIMD3(0, 0, 1)
            )
            let delta = absolute * session.appliedTransform.inverse
            cameraSession = nil
            journalOrDiscard(verb: "tool.transformVertices") {
                let report = try mesh.transformVertices(
                    plan.vertices, transform: MeshTransform(delta),
                    reprojecting: context.snapper,
                    resnapEpsilon: context.sceneRadius * 1e-4
                )
                recordResnapReport(report)
                onCameraToolStatus?(String(
                    format: "Transform Vertices: %d of %d re-snapped (max %.4f)",
                    report.resnapped, plan.vertices.count, report.maxDistance
                ))
                onLiveEdit?()
                return try transaction.command(verb: "tool.transformVertices")
            }
            publishCameraSession()
        }
    }

    /// Discards the armed session: ghost cleared, Transform Vertices'
    /// live edits reloaded from the document payload, nothing journaled.
    func cancelCameraToolSession() {
        guard let session = cameraSession else { return }
        cameraSession = nil
        onSessionPreviewChanged?(nil)
        if case .transformVertices = session.plan, session.mutated {
            onDiscardLiveEdits?()
        }
        publishCameraSession()
    }

    /// The coordinator's EditMesh snapshot is about to rebind (document
    /// payload/object changed): an OWN commit (Patch Clone paste) re-pins
    /// and keeps the session armed — repeatable paste; any EXTERNAL
    /// change (undo, conflict reload) invalidates the selection ids, so
    /// the session is discarded. The live mesh is being reloaded by the
    /// caller either way, so no separate discard runs here.
    ///
    /// - Parameter payload: the payload bytes the snapshot is rebinding TO.
    ///   The session is only kept when they are byte-identical to what its
    ///   own last paste wrote — see `Session.committedPayload` for why a
    ///   bare flag could not tell the two apart.
    func editMeshSnapshotWillChange(payload: Data?) {
        guard var session = cameraSession else { return }
        if let expected = session.committedPayload, let payload, payload == expected {
            session.committedPayload = nil
            cameraSession = session
            return
        }
        cameraSession = nil
        onSessionPreviewChanged?(nil)
        publishCameraSession()
    }

    /// Banner controls.
    func setExtendBoundaryMode(_ mode: ExtendBoundaryPlan.Mode) {
        preferredExtendBoundaryMode = mode
        guard var session = cameraSession,
            case .extendBoundary(var plan) = session.plan
        else { return }
        plan.mode = mode
        plan.wantsAutoCommit = false
        session.plan = .extendBoundary(plan)
        cameraSession = session
        refreshCameraSessionPreview()
        publishCameraSession()
    }

    func togglePatchCloneFlip() {
        guard var session = cameraSession,
            case .patchClone(var plan) = session.plan
        else { return }
        plan.flipped.toggle()
        session.plan = .patchClone(plan)
        cameraSession = session
        refreshCameraSessionPreview()
        publishCameraSession()
    }

    // MARK: - Draw Strip (stroke-driven, task 4.2)

    /// Drag from a boundary quad edge: the strip follows the stroke,
    /// stations one source-edge-length apart (preserving the source quad
    /// size), welded onto the edge, snapped to the Target — one journal
    /// entry per stroke.
    func applyDrawStrip(_ stroke: ToolStroke, samples: [StrokeSample]) {
        let context = stroke.context
        guard
            let mesh = context.editMesh,
            let object = context.editObject,
            let payload = context.editPayload,
            let first = samples.first,
            let hitStart = surfacePoint(at: point(of: first), in: context)
        else { return }
        let pickRadius = context.sceneRadius * Self.vertexPickRadiusFraction
        guard
            let pick = mesh.nearestEdge(to: hitStart, maxDistance: pickRadius),
            mesh.edgeFaces(of: pick.edge).count == 1,
            let endpoints = mesh.edgeEndpoints(of: pick.edge),
            let a = mesh.vertexPosition(endpoints.0),
            let b = mesh.vertexPosition(endpoints.1)
        else { return }
        let width = simd_distance(a, b)
        guard width > .ulpOfOne else { return }
        let hits = strokeSurfaceHits(
            samples: samples.map { point(of: $0) }, context: context, limit: 128
        )
        let stations = CameraToolStrokes.resample(
            [(a + b) * 0.5] + hits, step: width
        )
        guard !stations.isEmpty,
            let ray = context.ray(point(of: samples[samples.count / 2]))
        else { return }
        let transaction = MeshEditTransaction(
            object: object, mesh: mesh, currentPayload: payload
        )
        journalOrDiscard(verb: "tool.drawStrip") {
            // Capture what the strip creates so its rail vertices can weld
            // onto existing topology beyond the start-edge weld (task 4.2a):
            // the engine op reports only a face count, and after the Target
            // snap a rail vertex's position no longer says whether it landed
            // on a neighbouring cage vertex. A live-id diff is exact.
            let before = mesh.liveVertexIDs()
            try mesh.drawStrip(
                path: stations, width: width, viewDirection: ray.direction,
                weldingOnto: endpoints, snapping: context.snapper
            )
            // Rail vertices that landed on the cage the strip was drawn toward
            // fold onto it (release merge). Capped to the strip's own scale so
            // a rail never welds across the strip to its opposite rail; the
            // set exclusion keeps it off the strip's own vertices.
            let created = mesh.liveVertexIDs().subtracting(before)
            try mesh.weldNewVerticesOntoExisting(
                created, mergeRadius: min(pickRadius, width * Self.stripWeldWidthFraction)
            )
            onLiveEdit?()
            return try transaction.command(verb: "tool.drawStrip")
        }
    }
}

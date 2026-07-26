import CyberKit
import Foundation
import simd

/// Weave Fill session (openspec add-weave-region-selection, task 3): turns the
/// captured intent into a proposal.
///
/// **Deliberately reuses the Auto-Retopo proposal slot.** A fill produces a
/// `SolverGhost` exactly as a whole-Target solve does, so the amber ghost, the
/// Accept/Discard bar, the region notice (task 13.3), one-entry accept and
/// byte-exact undo all come for free — and the user can only be reviewing one
/// proposal at a time anyway.
///
/// **Deliberately runs ON the main actor**, unlike `beginAutoRetopoAsync`. That is not
/// an oversight:
///
/// - Auto-Retopo crosses the actor boundary by serialising meshes to payload `Data`
///   (engine meshes are not `Sendable`). The payload is OBJ written at default
///   ostream precision — SIX significant digits — and it renumbers every element.
/// - A whole-Target solve does not care: nothing of the input is preserved in the
///   output. A FILL does: the cage is frozen and must come back BITWISE identical,
///   because it is the artist's hand-authored geometry. Round-tripping it would
///   quantise every cage vertex, silently degrading work the user did by hand.
/// - The cost is affordable because a fill solves the CAGE plus a small seed band —
///   a coarse quad mesh — not the multi-million-triangle Target. The Target is only
///   touched through the already-built snapper while growing the seed.
///
/// If a fill ever needs to be async, the fix is a `Sendable` id-preserving transfer,
/// not a payload round-trip.
extension MetalViewport.Coordinator {

    /// Solves the pending fill request and presents it as a ghost. Returns false
    /// (inert, nothing shown) when there is no request, no Target, no EditMesh, or
    /// when the cage offers nothing to grow from.
    @discardableResult
    func beginWeaveFill() -> Bool {
        guard let intent = meshEditor.weaveFillIntent,
            let snapper = currentTargetSnapper(),
            let cage = currentCage()
        else {
            return false
        }

        let seed: WeaveFillDomain.Seed
        var truncated = false
        do {
            // One row first, to learn the run and its step before deciding how far.
            let probe = try WeaveFillDomain.grow(
                cage: cage, snapper: snapper, towards: intent.fillPoint, rows: 1
            )
            let reach = Self.reach(
                of: intent, from: probe.chain, of: cage, step: probe.step
            )
            let rows: Int
            if intent.wantsDefaultExtent {
                // A TAP asks for the default band, so it only makes sense NEAR a free
                // edge. Growing 2 rows toward a distant tap would fill a band beside
                // the cage while the user pointed somewhere else — the "isolated area
                // is refused, not mis-filled" requirement. Paint that far instead.
                // The tap must lie within the band a default fill would cover.
                // Anything beyond it is a request to fill somewhere the band will
                // not reach, which is the "mis-filled" case.
                guard reach <= Float(Self.defaultFillRows) else {
                    throw Failure.tooFarToTap
                }
                rows = Self.defaultFillRows
            } else {
                let wanted = WeaveFillDomain.rows(
                    toCover: intent.extent, from: probe.chain, of: cage, step: probe.step,
                    maximumRows: Self.maximumFillRows
                )
                // A cap that silently truncates reads as "filled everything". Say so.
                truncated = wanted >= Self.maximumFillRows && reach > Float(wanted)
                rows = wanted
            }
            seed = rows == 1
                ? probe
                : try WeaveFillDomain.grow(
                    cage: cage, snapper: snapper, towards: intent.fillPoint, rows: rows,
                    maximumRows: Self.maximumFillRows
                )
        } catch {
            // A refusal is information, not a crash: say why and show nothing.
            autoRetopoGhost = nil
            weaveFillBasePayload = nil
            syncAutoRetopoGhostState()
            inputModel.autoRetopoNotice = Self.fillRefusal(error)
            return false
        }

        var parameters = SolverParameters()
        // Density from the PRESCRIPTION — the cage's own spacing at the seam. This is
        // the spec's "auto-filled regions match manual scale with no dials".
        if let budget = RegionWeaveSolver.prescribedQuadBudget(
            source: seed.mesh, regionFaces: seed.seedFaces
        ) {
            parameters.remesh.targetQuads = budget
        }

        let ghost: SolverGhost?
        do {
            ghost = try weaveSolver.solve(
                source: seed.mesh, region: .faces(seed.seedFaces),
                constraints: WeaveConstraints(
                    guideStrokes: meshEditor.authoredGuides.map { GuideStroke(points: $0) },
                    symmetry: bundleProvider?().manifest.symmetry
                ),
                params: parameters, onProgress: nil, isCancelled: { false }
            )
        } catch {
            autoRetopoGhost = nil
            weaveFillBasePayload = nil
            syncAutoRetopoGhostState()
            inputModel.autoRetopoNotice = "Fill could not be solved"
            return false
        }
        guard let ghost else {
            autoRetopoGhost = nil
            weaveFillBasePayload = nil
            syncAutoRetopoGhostState()
            return false
        }

        autoRetopoGhost = ghost
        // Pin the cage the proposal was derived FROM. A fill ghost contains the cage,
        // so accepting a stale one would resurrect pre-undo geometry — unlike a
        // whole-Target proposal, which merely becomes outdated.
        weaveFillBasePayload = currentCagePayload()
        syncAutoRetopoGhostState()
        inputModel.autoRetopoNotice = [
            truncated ? "filled as far as the row limit allows" : nil,
            Self.notice(for: ghost),
        ].compactMap { $0 }.joined(separator: " · ").nilWhenEmpty
        return true
    }

    /// How far the request reaches beyond the boundary run, in ROWS.
    static func reach(
        of intent: WeaveFillIntent, from chain: [UInt32], of cage: Mesh, step: SIMD3<Float>
    ) -> Float {
        let length = simd_length(step)
        guard length > 1e-9 else { return 0 }
        var sum = SIMD3<Float>.zero
        var count = 0
        for v in chain {
            guard let p = cage.vertexPosition(v) else { continue }
            sum += p
            count += 1
        }
        guard count > 0 else { return 0 }
        let direction = step / length
        let points = intent.extent.isEmpty ? [intent.fillPoint] : intent.extent
        // Measured from the NEAREST boundary vertex, not the run's centroid: a tap
        // beside the END of a long free edge is close to the boundary even though it
        // is far from the middle of it. Using the centroid refused perfectly good taps
        // on any run longer than a few quads.
        var furthest: Float = 0
        for p in points {
            var nearest = Float.greatestFiniteMagnitude
            var along: Float = 0
            for v in chain {
                guard let q = cage.vertexPosition(v) else { continue }
                let distance = simd_length(p - q)
                if distance < nearest {
                    nearest = distance
                    along = simd_dot(p - q, direction)
                }
            }
            furthest = max(furthest, along)
        }
        return max(0, furthest / length)
    }

    /// Shared row cap — one place, so the guard and the derivation cannot disagree.
    static var maximumFillRows: Int { 12 }

    /// Refusals that belong to the session rather than to domain construction.
    enum Failure: Error, Equatable {
        case tooFarToTap
    }

    /// Drops a pending FILL proposal when the EditMesh changed underneath it.
    /// Called from the snapshot-change path; a no-op for a whole-Target proposal,
    /// which does not depend on the cage.
    func discardWeaveFillIfStale(newPayload: Data?) {
        guard let base = weaveFillBasePayload else { return }
        guard base != newPayload else { return }
        autoRetopoGhost = nil
        weaveFillBasePayload = nil
        syncAutoRetopoGhostState()
        // The captured request is stale too: its fill point and extent were resolved
        // against the cage that just changed.
        meshEditor.clearWeaveFill()
    }

    /// The cage to fill from: the LIVE handle when the renderer has bound one (it
    /// carries in-flight edits, so it matches what the user sees), else the document's
    /// EditMesh. Resolving from the document too keeps the session drivable headless,
    /// the way `currentTargetMesh` already is.
    func currentCage() -> Mesh? {
        if let live = recognizerEditMesh { return live }
        guard let bundle = bundleProvider?(),
            let object = bundle.manifest.objects.first(where: { $0.role == .editMesh })
        else { return nil }
        return try? bundle.mesh(for: object)
    }

    /// The payload bytes identifying the cage a proposal was derived from.
    func currentCagePayload() -> Data? {
        if let payload = overlayPayload { return payload }
        guard let bundle = bundleProvider?(),
            let object = bundle.manifest.objects.first(where: { $0.role == .editMesh })
        else { return nil }
        return bundle.payloads[object.payloadFile]
    }

    /// The Target snapper. Prefers the renderer's — building one walks the whole
    /// high-poly Target into a BVH, which is not something to redo per fill.
    func currentTargetSnapper() -> SurfaceSnapper? {
        if let cached = targetSnapper { return cached }
        guard let bundle = bundleProvider?(),
            let object = bundle.manifest.objects.first(where: { $0.role == .target }),
            let mesh = try? bundle.mesh(for: object)
        else { return nil }
        return try? SurfaceSnapper(target: mesh)
    }

    /// Rows a tap grows. Two is one quad band plus one to give the solver room to
    /// place interior topology rather than only a single ring.
    static var defaultFillRows: Int { 2 }

    static func fillRefusal(_ error: Error) -> String {
        if let own = error as? Failure {
            switch own {
            case .tooFarToTap:
                return "Too far from an open cage edge — paint the area to fill it"
            }
        }
        guard let failure = error as? WeaveFillDomain.Failure else {
            return "Fill could not be prepared"
        }
        switch failure {
        case .noOpenBoundary:
            return "No open cage edge to fill from — draw some quads first"
        case .noFillDirection:
            return "Tap or paint on bare surface beside a cage edge"
        case .runTooShort:
            return "That cage edge is too short to fill from"
        case .degenerateStep:
            return "Could not work out which way to fill"
        }
    }
}

extension String {
    /// nil for an empty string, so an absent notice is absent rather than blank.
    var nilWhenEmpty: String? { isEmpty ? nil : self }
}

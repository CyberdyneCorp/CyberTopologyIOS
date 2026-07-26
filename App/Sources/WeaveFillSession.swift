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
        do {
            // Rows: a tap asks for the default band, paint asks for its reach.
            let probe = try WeaveFillDomain.grow(
                cage: cage, snapper: snapper, towards: intent.fillPoint, rows: 1
            )
            let rows = intent.wantsDefaultExtent
                ? Self.defaultFillRows
                : WeaveFillDomain.rows(
                    toCover: intent.extent, from: probe.chain, of: cage, step: probe.step
                )
            seed = rows == 1
                ? probe
                : try WeaveFillDomain.grow(
                    cage: cage, snapper: snapper, towards: intent.fillPoint, rows: rows
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
        inputModel.autoRetopoNotice = Self.notice(for: ghost)
        return true
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

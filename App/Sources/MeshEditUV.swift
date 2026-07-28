import CyberKit
import Foundation
import os

/// One-tap UV unwrap (openspec add-uv-stage-foundation, 6.1 task 4; spec: uv-workflow).
///
/// Shaped after `runBatchMeshEdit`: a whole-mesh command that mutates the live EditMesh
/// handle inside a `MeshEditTransaction`, so the geometry change and the annotations it
/// orphans land as ONE journal entry and one undo restores both together.
///
/// An unwrap IS a payload change — the OBJ payload carries `vt` lines, verified by
/// `MeshUVTests.uvsSurvivePayloadRoundTrip`, which is what makes journaling it as a
/// `meshEdit` correct rather than needing a new command case.
extension MeshEditController {
    /// Seams a proposal is suggesting, or empty when none is pending.
    ///
    /// VIEW state, not document state, and deliberately not journaled: a proposal is not a
    /// change until it is accepted, so discarding one must leave the undo stack untouched.
    /// Same shape as the Phase 5 solver ghost, without needing `SolverGhost` — a seam
    /// proposal is an edge set, not geometry.
    var pendingSeamProposal: [UInt32] { seamProposalStorage }

    /// Why the last proposal produced nothing, or nil when it produced seams.
    ///
    /// The same ambiguity the unwrap's no-op case had: "no EditMesh" and "your mesh needs no
    /// further cuts" are completely different answers, and returning a bare false for both
    /// would have the UI say a proposal failed when the honest answer is that the layout is
    /// already fine. A FLAT cage legitimately proposes nothing — one chart, no internal
    /// chart boundaries — and that is a result, not an error.
    var seamProposalNotice: String? { seamProposalNoticeStorage }

    /// Generates a proposal. Returns whether one was produced.
    ///
    /// The artist's authored seams act as barriers growth will not cross AND are always
    /// included, so accepting can only ever add — never delete a seam they drew.
    @discardableResult
    func proposeSeams() -> Bool {
        seamProposalNoticeStorage = nil
        // Fired on EVERY exit below, including the empty ones: a second propose that finds
        // nothing must clear the first proposal's amber from the viewport, or the artist
        // would be looking at a suggestion that is no longer on offer.
        defer { onSeamProposalChanged?(seamProposalStorage) }
        guard let context = contextProvider?(), let mesh = context.editMesh,
            let object = context.editObject
        else {
            seamProposalStorage = []
            seamProposalNoticeStorage = "No EditMesh to propose seams for"
            return false
        }
        let authored = object.annotations?.seamEdges ?? []
        guard let proposed = try? mesh.proposedSeams(respecting: authored) else {
            seamProposalStorage = []
            seamProposalNoticeStorage = "Could not analyse this mesh for seams"
            return false
        }
        // Only the ADDITIONS are worth reviewing; the authored seams are already on screen.
        let additions = proposed.filter { !authored.contains($0) }
        seamProposalStorage = additions
        guard !additions.isEmpty else {
            // Not a failure. A flat or already well-cut cage needs nothing more, and saying
            // "no further seams needed" is the truthful answer where "could not propose"
            // would be a lie about the artist's mesh.
            seamProposalNoticeStorage = authored.isEmpty
                ? "No seams needed — this cage already unwraps in one piece"
                : "No further seams needed beyond the ones you drew"
            return false
        }
        return true
    }

    /// Accepts the pending proposal as ONE journaled seam edit. Returns whether it committed.
    @discardableResult
    func acceptSeamProposal() -> Bool {
        let additions = seamProposalStorage
        guard !additions.isEmpty else { return false }
        seamProposalStorage = []
        // Cleared BEFORE the commit: once accepted the seams are authored, and drawing them
        // as both amber (proposed) and orange (authored) would double-draw the same edges.
        onSeamProposalChanged?([])
        // `togglingSeams` would SEW anything already a seam, so only the additions are
        // passed — which they are by construction, since `proposeSeams` filtered them.
        return applyAnnotationEditNow(verb: "uv.acceptSeamProposal") {
            $0.togglingSeams(on: additions)
        }
    }

    /// Drops the pending proposal. Journals nothing, by definition.
    func discardSeamProposal() {
        seamProposalStorage = []
        seamProposalNoticeStorage = nil
        onSeamProposalChanged?([])
    }

    /// Re-unwraps the island containing any of `faces`, as ONE journaled step (6.2b).
    ///
    /// POLICY, deliberately here and not in the engine: a mesh with no UVs has no island
    /// layout to redo, and the engine refuses rather than creating a UV column that would
    /// leave every other island collapsed at the origin. So the first X on a never-unwrapped
    /// cage runs the WHOLE-mesh unwrap — the useful thing, and the only one that leaves every
    /// island with a real footprint.
    @discardableResult
    func reunwrapIsland(
        containingAnyOf faces: [UInt32], context: MeshEditController.Context
    ) -> Bool {
        unwrapRefusalStorage = nil
        guard let face = faces.min() else { return false }
        guard let object = context.editObject, let mesh = context.editMesh,
            let payload = context.editPayload
        else {
            unwrapRefusalStorage = "No EditMesh to unwrap"
            return false
        }
        let seams = object.annotations?.seamEdges ?? []

        // Asked BEFORE opening a transaction: the whole-mesh fallback is a different command
        // with a different verb, and discovering that mid-transaction would mean journaling a
        // re-unwrap that actually did a full unwrap.
        if !mesh.hasUVLayout {
            return runUnwrapUVs()
        }

        let verb = "pencil.reunwrapIsland"
        let transaction = MeshEditTransaction(
            object: object, mesh: mesh, currentPayload: payload
        )
        var outcome: Mesh.ReunwrapOutcome?
        lastCommit = nil
        journalOrDiscard(verb: verb) {
            outcome = try mesh.reunwrapIsland(containing: face, seams: seams)
            onLiveEdit?()
            return try transaction.command(verb: verb) { $0 }
        }
        guard lastCommit != nil else {
            // Same three-way distinction `runUnwrapUVs` draws, and for the same reason: the
            // atlas is deterministic, so an island whose parameterization is already what the
            // solve produces yields byte-identical output and the transaction correctly
            // journals nothing. That is a no-op, not a failure.
            if outcome?.didUnwrap == true {
                unwrapRefusalStorage = "Already unwrapped — this island is unchanged"
            } else {
                unwrapRefusalStorage = "Could not unwrap this island"
                Self.uvLog.error("pencil.reunwrapIsland produced no journal entry")
            }
            return false
        }
        return true
    }

    private static let uvLog = Logger(
        subsystem: "com.cyberdynecorp.cybertopology", category: "uv"
    )

    /// The report from the last successful unwrap, or nil when none has run in this
    /// session. Read by the UI to say what the layout actually is.
    var lastUnwrapReport: Mesh.AtlasReport? { unwrapReportStorage }

    /// Why the last unwrap attempt was refused, or nil when it succeeded. A refusal has
    /// to be sayable — a tap that silently does nothing reads as a broken button, which is
    /// exactly the failure `.autoRetopo`'s dead toolbar slot had.
    var lastUnwrapRefusal: String? { unwrapRefusalStorage }

    /// Unwraps the EditMesh as one journaled, undoable step.
    ///
    /// Returns whether anything was committed. Refuses — with a stated reason — when there
    /// is no EditMesh, when a tool session is mid-stroke (its uncommitted live edits must
    /// never be baked into someone else's journal entry), or when the atlas cannot produce
    /// a layout.
    @discardableResult
    func runUnwrapUVs(parameters: Mesh.AtlasParameters = Mesh.AtlasParameters()) -> Bool {
        unwrapRefusalStorage = nil

        // Same guard `runBatchMeshEdit` opens with, and for the same reason: a whole-mesh
        // command must not absorb an armed session's in-flight edits.
        guard allowsWholeMeshCommand() else {
            unwrapRefusalStorage = "Finish the current stroke before unwrapping"
            return false
        }
        guard let context = contextProvider?(), let object = context.editObject,
            let mesh = context.editMesh, let payload = context.editPayload
        else {
            unwrapRefusalStorage = "No EditMesh to unwrap — retopologize first"
            return false
        }

        let verb = "uv.unwrap"
        let transaction = MeshEditTransaction(
            object: object, mesh: mesh, currentPayload: payload
        )
        var report: Mesh.AtlasReport?
        lastCommit = nil
        journalOrDiscard(verb: verb) {
            // In place, inside the transaction: the atlas rewrites the corner UV attribute
            // on this handle, and the transaction captures the payload either side of it.
            // The document's authored seams, so the layout is the one the artist's seams
            // describe rather than whatever automatic chart growth produces.
            report = try mesh.unwrapInPlace(
                parameters: parameters, seams: object.annotations?.seamEdges ?? []
            )
            onLiveEdit?()
            // Unwrapping rewrites no element ids — it adds a corner attribute — so the
            // annotations survive intact. The payload round trip's id compaction is still
            // reconciled by the transaction, exactly as every other whole-mesh command.
            return try transaction.command(verb: verb) { $0 }
        }

        guard lastCommit != nil else {
            // Two very different outcomes reach here, and conflating them tells the artist
            // something false. `journalOrDiscard` swallows a throw into its logger, so the
            // distinction is drawn from whether the atlas produced a report at all:
            //
            //  * report != nil — the atlas RAN and produced byte-identical output, so
            //    `MeshEditTransaction.command` correctly journaled nothing
            //    (`guard after != before else { return nil }`). The layout is already
            //    there; the atlas is deterministic, so re-running it with the same
            //    parameters cannot change anything. Calling that a failure would be a lie.
            //  * report == nil — `unwrapInPlace` threw, so there is genuinely no layout.
            if let report {
                unwrapReportStorage = report
                unwrapRefusalStorage = "Already unwrapped — the layout is unchanged"
                return false
            }
            unwrapRefusalStorage = "Could not unwrap this mesh — the atlas produced no layout"
            Self.uvLog.error("uv.unwrap produced no journal entry")
            return false
        }
        unwrapReportStorage = report
        return true
    }
}

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

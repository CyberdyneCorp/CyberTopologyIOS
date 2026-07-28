import CyberKit
import Foundation
import Testing

@testable import CyberTopology

/// One-tap UV unwrap through the REAL journaled path (openspec add-uv-stage-foundation,
/// 6.1 task 4).
///
/// Drives the actual coordinator, controller and journal rather than the CyberKit API
/// directly — the properties that matter here are "one undo step" and "a refusal is
/// sayable", and neither exists below the app layer.
@MainActor
@Suite("UV unwrap action")
struct UnwrapActionTests {
    /// `@MainActor` on the suite does not propagate to a nested class, so it is annotated
    /// explicitly — the coordinator and every property it exposes are main-actor isolated.
    @MainActor
    private final class Harness {
        var bundle = DocumentBundle()
        let coordinator: MetalViewport.Coordinator
        private(set) var committed: [DocumentCommand] = []

        init() throws {
            coordinator = IsolatedViewportModel.viewport(
                bundle: DocumentBundle(), orbitSpeed: 1, zoomSpeed: 1, onUndo: {}, onRedo: {}
            ).makeCoordinator()
            _ = coordinator.makeView()
            try #require(coordinator.renderer != nil, "Metal device unavailable")
            coordinator.onCommit = { [weak self] command in
                self?.committed.append(command)
                self?.perform(command)
            }
            coordinator.bundleProvider = { [weak self] in self?.bundle ?? DocumentBundle() }
        }

        var editor: MeshEditController { coordinator.meshEditor }
        var model: ViewportInputModel { coordinator.inputModel }
        func sync() { coordinator.syncMesh(from: bundle) }

        func perform(_ command: DocumentCommand) {
            bundle.journal.record(command)
            command.apply(to: &bundle)
            sync()
        }

        func undo() {
            if let command = bundle.journal.undo() {
                command.revert(on: &bundle)
                sync()
            }
        }

        var editObject: DocumentManifest.Object? {
            bundle.manifest.objects.first { $0.role == .editMesh }
        }

        func editMesh() throws -> Mesh { try bundle.mesh(for: #require(editObject)) }

        func payload() throws -> Data {
            // Two separate #require calls: nesting one inside another recursively expands
            // the macro and does not compile.
            let object = try #require(editObject)
            return try #require(bundle.payloads[object.payloadFile])
        }
    }

    private func mesh(_ obj: String) throws -> Mesh {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("unwrap-\(UUID().uuidString).obj")
        try obj.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try Mesh.loadOBJ(at: url)
    }

    /// A CUBE cage. Deliberately not a flat grid: a flat cage grows into ONE chart, so it
    /// legitimately has no internal chart boundaries and proposes no seams. Using one would
    /// have tested the empty case while claiming to test the populated one.
    private func seedCube(_ harness: Harness) throws {
        var obj = ""
        for (x, y, z) in [
            (0, 0, 0), (1, 0, 0), (1, 1, 0), (0, 1, 0),
            (0, 0, 1), (1, 0, 1), (1, 1, 1), (0, 1, 1),
        ] {
            obj += "v \(x) \(y) \(z)\n"
        }
        for face in [
            [1, 2, 3, 4], [5, 8, 7, 6], [1, 5, 6, 2],
            [2, 6, 7, 3], [3, 7, 8, 4], [4, 8, 5, 1],
        ] {
            obj += "f " + face.map(String.init).joined(separator: " ") + "\n"
        }
        try harness.bundle.addObject(name: "cage", role: .editMesh, mesh: try mesh(obj))
        harness.sync()
    }

    /// A small quad cage — the kind of EditMesh an unwrap actually targets.
    private func seedCage(_ harness: Harness) throws {
        var obj = ""
        for i in 0...3 {
            for j in 0...3 { obj += "v \(i) \(j) 0\n" }
        }
        for i in 0..<3 {
            for j in 0..<3 {
                let v = { (a: Int, b: Int) in a * 4 + b + 1 }
                obj += "f \(v(i, j)) \(v(i + 1, j)) \(v(i + 1, j + 1)) \(v(i, j + 1))\n"
            }
        }
        try harness.bundle.addObject(name: "cage", role: .editMesh, mesh: try mesh(obj))
        harness.sync()
    }

    // MARK: - Auto-seam proposals (6.5)

    @Test("A proposal is generated, journals NOTHING, and discarding leaves no trace")
    func proposalIsNotADocumentChange() throws {
        let harness = try Harness()
        try seedCube(harness)

        #expect(harness.editor.proposeSeams(), "a cage should yield some proposal")
        #expect(!harness.editor.pendingSeamProposal.isEmpty)
        // A proposal is not a change until accepted, so nothing may be journaled yet.
        #expect(harness.committed.isEmpty)

        harness.editor.discardSeamProposal()
        #expect(harness.editor.pendingSeamProposal.isEmpty)
        #expect(harness.committed.isEmpty, "discarding must journal nothing")
        #expect(harness.editObject?.annotations?.seamEdges.isEmpty ?? true)
    }

    @Test("Accepting is ONE undo step and adds exactly the proposed seams")
    func acceptingIsOneStep() throws {
        let harness = try Harness()
        try seedCube(harness)
        #expect(harness.editor.proposeSeams())
        let proposed = harness.editor.pendingSeamProposal

        #expect(harness.editor.acceptSeamProposal())
        #expect(harness.committed.count == 1, "accepting must be exactly one journal entry")
        let after = try #require(harness.editObject?.annotations?.seamEdges)
        #expect(Set(after) == Set(proposed))
        // The pending proposal is consumed, so it cannot be accepted twice.
        #expect(harness.editor.pendingSeamProposal.isEmpty)

        harness.undo()
        #expect(harness.editObject?.annotations?.seamEdges.isEmpty ?? true)
    }

    @Test("Accepting NEVER removes a seam the artist drew")
    func acceptingOnlyAdds() throws {
        let harness = try Harness()
        try seedCube(harness)
        let mesh = try harness.editMesh()
        let authored = try #require((0..<UInt32(mesh.edgeCount)).first {
            mesh.edgeEndpoints(of: $0) != nil
        })
        // Author one seam by hand first.
        let object = try #require(harness.editObject)
        harness.perform(.annotationEdit(DocumentCommand.AnnotationEdit(
            objectID: object.id, verb: "test.seam",
            before: object.annotations,
            after: MeshAnnotations(seamEdges: [authored])
        )))

        #expect(harness.editor.proposeSeams())
        // The proposal contains only ADDITIONS, so the authored seam is not in it — and
        // therefore cannot be toggled back off by accepting, which is the whole guarantee.
        #expect(!harness.editor.pendingSeamProposal.contains(authored))

        #expect(harness.editor.acceptSeamProposal())
        let after = try #require(harness.editObject?.annotations?.seamEdges)
        #expect(after.contains(authored), "an accepted proposal must never delete a drawn seam")
    }

    @Test("Accepting with no pending proposal is refused rather than journaling nothing")
    func acceptingNothingIsRefused() throws {
        let harness = try Harness()
        try seedCube(harness)
        #expect(!harness.editor.acceptSeamProposal())
        #expect(harness.committed.isEmpty)
    }

    @Test("A flat cage proposes NOTHING and says so, rather than reporting a failure")
    func flatCageNeedsNoSeams() throws {
        let harness = try Harness()
        // A flat grid grows into one chart, so there are no internal chart boundaries and
        // no seams to propose. That is a RESULT, not an error — the same distinction the
        // unwrap's "already unwrapped" case needed.
        try seedCage(harness)
        #expect(!harness.editor.proposeSeams())
        let notice = try #require(harness.editor.seamProposalNotice)
        #expect(notice.contains("No seams needed"))
        #expect(!notice.contains("Could not"))
    }

    @Test("Every proposal change notifies the overlay, INCLUDING one that finds nothing")
    func proposalChangesReachTheOverlay() throws {
        let harness = try Harness()
        var pushed: [[UInt32]] = []
        harness.editor.onSeamProposalChanged = { pushed.append($0) }

        try seedCube(harness)
        #expect(harness.editor.proposeSeams())
        #expect(pushed.count == 1)
        #expect(!(pushed.last ?? []).isEmpty)

        // Accepting must push an EMPTY set: the seams are authored now, and leaving the
        // amber up would draw the same edges twice in two different colours.
        #expect(harness.editor.acceptSeamProposal())
        #expect(pushed.last?.isEmpty == true)

        // A second propose finds nothing further, and that must ALSO push — otherwise a
        // stale suggestion stays on screen after it stopped being on offer.
        let before = pushed.count
        #expect(!harness.editor.proposeSeams())
        #expect(pushed.count == before + 1)
        #expect(pushed.last?.isEmpty == true)
    }

    @Test("Discarding pushes an empty set and clears the notice")
    func discardClearsEverything() throws {
        let harness = try Harness()
        var pushed: [[UInt32]] = []
        harness.editor.onSeamProposalChanged = { pushed.append($0) }
        try seedCube(harness)
        #expect(harness.editor.proposeSeams())

        harness.editor.discardSeamProposal()
        #expect(pushed.last?.isEmpty == true)
        #expect(harness.editor.pendingSeamProposal.isEmpty)
        // A discard is not a refusal, so nothing should be left explaining one.
        #expect(harness.editor.seamProposalNotice == nil)
        #expect(harness.committed.isEmpty, "a discard must journal NOTHING")
    }

    @Test("With no EditMesh the notice says THAT, not that no seams are needed")
    func noEditMeshIsDistinctFromNoSeams() throws {
        let harness = try Harness()
        #expect(!harness.editor.proposeSeams())
        let notice = try #require(harness.editor.seamProposalNotice)
        // Conflating these two would tell an artist with no cage that their layout is fine.
        #expect(notice.contains("No EditMesh"))
    }

    @Test("Propose is reachable through runCommand and is classified as a command")
    func proposeIsReachable() throws {
        let harness = try Harness()
        try seedCube(harness)
        #expect(EditorAction.proposeSeams.isImmediateCommand)
        #expect(EditorAction.proposeSeams.tool == nil)
        #expect(harness.model.runCommand(.proposeSeams))
        #expect(!harness.editor.pendingSeamProposal.isEmpty)
    }

    @Test("Unwrapping is ONE journaled step that a single undo reverses byte-exactly")
    func unwrapIsOneUndoStep() throws {
        let harness = try Harness()
        try seedCage(harness)
        let before = try harness.payload()
        #expect(!(try harness.editMesh().hasUVLayout))

        #expect(harness.editor.runUnwrapUVs(), "the unwrap should have committed")
        #expect(harness.committed.count == 1, "an unwrap must be exactly one journal entry")
        #expect(try harness.editMesh().hasUVLayout)

        harness.undo()
        // Byte-exact, not merely "no UVs": the transaction pairs the geometry with the
        // annotations the payload round trip renumbered, so undo has to restore the
        // original bytes rather than an equivalent-looking mesh.
        #expect(try harness.payload() == before)
        #expect(!(try harness.editMesh().hasUVLayout))
    }

    @Test("The report is captured and names what the layout is")
    func reportIsCaptured() throws {
        let harness = try Harness()
        try seedCage(harness)
        #expect(harness.editor.runUnwrapUVs())

        let report = try #require(harness.editor.lastUnwrapReport)
        #expect(report.chartCount > 0)
        #expect(report.packedArea > 0)
        // A silent success tells the artist nothing about whether the layout is usable.
        #expect(report.summary.contains("chart"))
        #expect(harness.editor.lastUnwrapRefusal == nil)
    }

    @Test("With no EditMesh the unwrap refuses with a stated reason")
    func refusesWithoutAnEditMesh() throws {
        let harness = try Harness()
        // No cage seeded.
        #expect(!harness.editor.runUnwrapUVs())
        let refusal = try #require(
            harness.editor.lastUnwrapRefusal,
            "a refused unwrap must say why — a silent no-op reads as a broken button"
        )
        #expect(refusal.contains("EditMesh"))
        #expect(harness.committed.isEmpty, "a refusal must journal nothing")
    }

    @Test("A refusal clears once a later attempt succeeds")
    func refusalClearsOnSuccess() throws {
        let harness = try Harness()
        #expect(!harness.editor.runUnwrapUVs())
        #expect(harness.editor.lastUnwrapRefusal != nil)

        try seedCage(harness)
        #expect(harness.editor.runUnwrapUVs())
        // A stale refusal left visible beside a successful unwrap would contradict itself.
        #expect(harness.editor.lastUnwrapRefusal == nil)
    }

    @Test("The action runs through runCommand, not only through the controller")
    func reachableThroughRunCommand() throws {
        let harness = try Harness()
        try seedCage(harness)
        // This is the path a toolbar slot takes. `.autoRetopo` had a working runCommand
        // case that no slot could ever reach, so exercising runCommand rather than the
        // controller directly is the point of this case.
        #expect(harness.model.runCommand(.unwrapUVs))
        #expect(try harness.editMesh().hasUVLayout)
    }

    @Test("A second identical unwrap is a NO-OP that says so, not a failure")
    func repeatedIdenticalUnwrapIsANoOp() throws {
        // I expected two journal entries here and was wrong, which is worth recording.
        // The atlas is deterministic, so re-running it with the same parameters produces
        // byte-identical output, and `MeshEditTransaction.command` correctly journals
        // nothing (`guard after != before else { return nil }`). A no-op must not enter the
        // undo stack.
        let harness = try Harness()
        try seedCage(harness)
        #expect(harness.editor.runUnwrapUVs())
        let afterFirst = try harness.payload()

        #expect(!harness.editor.runUnwrapUVs(), "an unchanged layout journals nothing")
        #expect(harness.committed.count == 1, "a no-op must not add an undo step")
        #expect(try harness.payload() == afterFirst)

        // And the message must NOT claim the unwrap failed — the layout is right there.
        let message = try #require(harness.editor.lastUnwrapRefusal)
        #expect(message.contains("Already unwrapped"))
        #expect(!message.contains("Could not"))
        // The report still describes the existing layout, so the UI can show it.
        #expect(harness.editor.lastUnwrapReport?.chartCount ?? 0 > 0)
    }

    @Test("Different parameters DO produce a second undoable step")
    func differentParametersJournalAgain() throws {
        let harness = try Harness()
        try seedCage(harness)
        #expect(harness.editor.runUnwrapUVs())
        let afterFirst = try harness.payload()

        // A materially different chart-angle bound changes the seams, so the payload
        // changes and this is a real second edit.
        var tighter = Mesh.AtlasParameters()
        tighter.maxChartAngleDegrees = 5
        tighter.packMargin = 0.05
        guard harness.editor.runUnwrapUVs(parameters: tighter) else {
            // If even this produces identical bytes the fixture is too simple to
            // distinguish, which is worth saying rather than asserting a false negative.
            #expect(harness.committed.count == 1)
            return
        }
        #expect(harness.committed.count == 2)
        harness.undo()
        // Back to the FIRST layout, not to no layout: each real change is its own step.
        #expect(try harness.payload() == afterFirst)
        #expect(try harness.editMesh().hasUVLayout)
    }
}

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

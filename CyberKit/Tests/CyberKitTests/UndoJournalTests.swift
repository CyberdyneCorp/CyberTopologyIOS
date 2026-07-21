import CyberKit
import Foundation
import Testing

@Suite("Undo journal")
struct UndoJournalTests {
    private let toUV = DocumentCommand.setStage(from: .retopology, to: .uv)
    private let toBK = DocumentCommand.setStage(from: .uv, to: .baking)

    @Test("record/undo/redo round-trip with state flags")
    func recordUndoRedo() {
        var journal = UndoJournal()
        #expect(!journal.canUndo)
        #expect(!journal.canRedo)

        journal.record(toUV)
        #expect(journal.canUndo)
        #expect(!journal.canRedo)

        #expect(journal.undo() == toUV)
        #expect(!journal.canUndo)
        #expect(journal.canRedo)

        #expect(journal.redo() == toUV)
        #expect(journal.canUndo)
        #expect(!journal.canRedo)
    }

    @Test("undo at root and redo at tip return nil")
    func boundaryConditions() {
        var journal = UndoJournal()
        #expect(journal.undo() == nil)
        #expect(journal.redo() == nil)
        journal.record(toUV)
        #expect(journal.redo() == nil)
    }

    @Test("500 operations undo back to the initial state")
    func deepUndo() {
        var journal = UndoJournal()
        var bundle = DocumentBundle()
        let initialManifest = bundle.manifest

        for index in 0..<500 {
            let command = DocumentCommand.setStage(
                from: index.isMultiple(of: 2) ? .retopology : .uv,
                to: index.isMultiple(of: 2) ? .uv : .retopology
            )
            journal.record(command)
            command.apply(to: &bundle)
        }
        #expect(journal.depth == 500)

        var undone = 0
        while let command = journal.undo() {
            command.revert(on: &bundle)
            undone += 1
        }
        #expect(undone == 500)
        #expect(bundle.manifest == initialManifest)
        #expect(!journal.canUndo)
    }

    @Test("divergent edit after undo preserves the abandoned branch")
    func branchPreservation() {
        var journal = UndoJournal()
        journal.record(toUV)   // branch A
        _ = journal.undo()
        journal.record(toBK)   // branch B from the root

        // Both branches remain reachable at the root; B is the active one.
        let roots = journal.children(of: nil)
        #expect(roots.count == 2)
        #expect(roots.map(\.command).contains(toUV))
        #expect(roots.map(\.command).contains(toBK))

        // Redo follows the most recent branch (B), not the abandoned one.
        _ = journal.undo()
        #expect(journal.redo() == toBK)
    }

    @Test("journal round-trips through Codable with position and branches")
    func codableRoundTrip() throws {
        var journal = UndoJournal()
        journal.record(toUV)
        journal.record(toBK)
        _ = journal.undo()

        let data = try JSONEncoder().encode(journal)
        var decoded = try JSONDecoder().decode(UndoJournal.self, from: data)

        #expect(decoded == journal)
        #expect(decoded.canUndo)
        #expect(decoded.canRedo)
        #expect(decoded.redo() == toBK)
    }

    @Test("addObject command applies and reverts payload plus manifest entry")
    func addObjectCommand() {
        let object = DocumentManifest.Object(
            name: "probe", role: .editMesh, payloadFile: "probe.payload",
            counts: .init(vertices: 8, faces: 6)
        )
        let command = DocumentCommand.addObject(object: object, payload: Data([1, 2, 3]))
        var bundle = DocumentBundle()

        command.apply(to: &bundle)
        #expect(bundle.manifest.objects.count == 1)
        #expect(bundle.payloads["probe.payload"] == Data([1, 2, 3]))

        command.revert(on: &bundle)
        #expect(bundle.manifest.objects.isEmpty)
        #expect(bundle.payloads.isEmpty)
    }

    @Test("bundle persists and restores the journal; corrupt journal degrades")
    func bundleJournalPersistence() throws {
        var bundle = DocumentBundle()
        bundle.journal.record(toUV)
        toUV.apply(to: &bundle)

        let restored = try DocumentBundle(fileWrapper: bundle.fileWrapper())
        #expect(restored.journal == bundle.journal)
        #expect(restored.journal.canUndo)

        // Corrupt journal.json: document loads, history resets, no throw.
        let wrapper = try bundle.fileWrapper()
        let corrupted = FileWrapper(directoryWithFileWrappers: [
            DocumentBundle.manifestFilename: wrapper.fileWrappers![DocumentBundle.manifestFilename]!,
            DocumentBundle.journalFilename: FileWrapper(
                regularFileWithContents: Data("not json".utf8)
            ),
            DocumentBundle.objectsDirectoryName: wrapper.fileWrappers![DocumentBundle.objectsDirectoryName]!,
        ])
        let degraded = try DocumentBundle(fileWrapper: corrupted)
        #expect(degraded.journal == UndoJournal())
    }
}

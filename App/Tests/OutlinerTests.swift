import CyberKit
import Foundation
import Testing

@testable import CyberTopology

/// Scene outliner behaviour (openspec add-scene-outliner, 8.1 tasks 3-5).
///
/// The document model and journal are covered in `OutlinerStateTests`; this covers the two
/// things that only exist at the app layer — the lock GUARANTEE and visibility composition.
@MainActor
@Suite("Scene outliner")
struct OutlinerTests {
    private func object(
        _ name: String, role: DocumentManifest.Object.Role = .editMesh,
        hidden: Bool = false, locked: Bool = false, group: String? = nil,
        counts: DocumentManifest.Object.Counts? = nil
    ) -> DocumentManifest.Object {
        DocumentManifest.Object(
            name: name, role: role, payloadFile: "\(name).obj",
            counts: counts, isHidden: hidden, isLocked: locked, group: group
        )
    }

    /// A document backed by a temporary URL. `TopoDocument()` with no file URL traps —
    /// every existing test passes one, and this is why.
    private func document() -> TopoDocument {
        TopoDocument(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("outliner-\(UUID().uuidString).cybertopo")
        )
    }

    // MARK: - Task 3: the lock guarantee

    private func meshEdit(for object: DocumentManifest.Object) -> DocumentCommand {
        .meshEdit(
            DocumentCommand.MeshEdit(
                objectID: object.id, payloadFile: object.payloadFile,
                verb: "test", before: Data("a".utf8), after: Data("b".utf8),
                beforeCounts: nil, afterCounts: nil,
                beforeRevision: nil, afterRevision: 1
            )
        )
    }

    @Test("A command reports which objects' payloads it would change")
    func payloadMutationIsReported() {
        let subject = object("Edit")
        #expect(meshEdit(for: subject).payloadMutatedObjectIDs == [subject.id])

        // Manifest-only changes report nothing, which is what keeps rename/hide/lock
        // available on a locked object.
        let rename = DocumentCommand.objectStateEdit(.from(subject, name: "New"))
        #expect(rename.payloadMutatedObjectIDs.isEmpty)
    }

    @Test("A compound reports the UNION, so one locked member blocks the batch")
    func compoundReportsUnion() {
        let a = object("A")
        let b = object("B")
        let batch = DocumentCommand.compound(
            verb: "batch", commands: [meshEdit(for: a), meshEdit(for: b)]
        )
        // Half-applying a batch because only one member was locked would leave the
        // document in a state no single undo restores.
        #expect(batch.payloadMutatedObjectIDs == [a.id, b.id])
    }

    @Test("An edit to a locked object is refused and the payload is unchanged")
    func lockedObjectRefusesEdits() throws {
        let document = document()
        let locked = object("Locked", locked: true)
        document.updateBundle { bundle in
            bundle.manifest.objects = [locked]
            bundle.payloads[locked.payloadFile] = Data("original".utf8)
        }

        let accepted = document.perform(meshEdit(for: locked))
        #expect(!accepted, "an edit to a locked object must be refused")
        // The refusal must be sayable: silently dropping a stroke reads as a broken app.
        #expect(document.lastRefusal?.contains("Locked") == true)
        #expect(document.bundle.payloads[locked.payloadFile] == Data("original".utf8))
        #expect(!document.canUndo, "a refused command must not enter the undo stack")
    }

    @Test("Locking does not restrict renaming, hiding or unlocking")
    func lockDoesNotRestrictManifestChanges() throws {
        let document = document()
        let locked = object("Locked", locked: true)
        document.updateBundle { $0.manifest.objects = [locked] }

        #expect(document.perform(.objectStateEdit(.from(locked, name: "Renamed"))))
        #expect(document.bundle.manifest.objects[0].name == "Renamed")

        // Unlocking must be possible, or a lock would be permanent.
        let current = document.bundle.manifest.objects[0]
        #expect(document.perform(.objectStateEdit(.from(current, locked: false))))
        #expect(!document.bundle.manifest.objects[0].isLocked)
    }

    @Test("An unlocked object still accepts edits")
    func unlockedObjectAcceptsEdits() throws {
        let document = document()
        let free = object("Free")
        document.updateBundle { bundle in
            bundle.manifest.objects = [free]
            bundle.payloads[free.payloadFile] = Data("original".utf8)
        }
        // The negative control: without this the refusal test would pass against a
        // `perform` that rejected everything.
        #expect(document.perform(meshEdit(for: free)))
        #expect(document.bundle.payloads[free.payloadFile] == Data("b".utf8))
    }

    // MARK: - Task 4: visibility composition

    @Test("A hidden Target falls through to the next visible object")
    func hiddenTargetRevealsTheEditMesh() {
        var manifest = DocumentManifest()
        let target = object("T", role: .target, hidden: true)
        let edit = object("E")
        manifest.objects = [target, edit]
        // Hiding a reference surface is FOR seeing what is under it, so blanking the
        // viewport would defeat the point.
        let shown = MetalViewport.renderableObject(in: manifest)
        #expect(shown?.id == edit.id)
    }

    @Test("Solo shows only the soloed object and does not rewrite stored visibility")
    func soloIsAViewMode() {
        var manifest = DocumentManifest()
        let target = object("T", role: .target)
        let hidden = object("H", hidden: true)
        let other = object("O")
        manifest.objects = [target, hidden, other]

        var visibility = SceneVisibility.everything
        visibility.toggleSolo(other.id)
        #expect(manifest.visibleObjects(visibility).map(\.id) == [other.id])
        // Soloing must not have touched anybody's isHidden...
        #expect(manifest.objects.first { $0.id == hidden.id }?.isHidden == true)
        visibility.toggleSolo(other.id)
        // ...so clearing solo restores exactly what the artist had: T and O, not H.
        #expect(manifest.visibleObjects(visibility).map(\.id) == [target.id, other.id])
    }

    @Test("Soloing a hidden object shows it")
    func soloBeatsHidden() {
        var manifest = DocumentManifest()
        let hidden = object("H", hidden: true)
        manifest.objects = [hidden]
        // "Show me only this" answered with an empty viewport would be obtuse; clearing
        // solo restores the stored isHidden, so nothing is lost by this reading.
        let visibility = SceneVisibility(soloed: hidden.id)
        #expect(manifest.visibleObjects(visibility).map(\.id) == [hidden.id])
    }

    @Test("Hiding a group hides its members without rewriting them")
    func groupHidingIsAViewMode() {
        var manifest = DocumentManifest()
        let a = object("A", group: "Candidates")
        let b = object("B", group: "Candidates")
        let c = object("C")
        manifest.objects = [a, b, c]

        var visibility = SceneVisibility.everything
        visibility.toggleGroup("Candidates")
        #expect(manifest.visibleObjects(visibility).map(\.id) == [c.id])
        #expect(manifest.objects.allSatisfy { !$0.isHidden }, "members must not be rewritten")
        visibility.toggleGroup("Candidates")
        #expect(manifest.visibleObjects(visibility).count == 3)
    }

    @Test("Group order is first-appearance, not Set order")
    func groupOrderIsStable() {
        var manifest = DocumentManifest()
        manifest.objects = [
            object("A", group: "Zebra"), object("B", group: "Alpha"),
            object("C", group: "Zebra"),
        ]
        // Sorted or Set-derived order would make the outliner's sections shuffle between
        // launches for no reason the artist can see.
        #expect(manifest.groupNames == ["Zebra", "Alpha"])
    }

    @Test("Outliner is an immediate command with a complete gallery entry")
    func actionIsReachable() {
        #expect(EditorAction.outliner.isImmediateCommand)
        let entry = EditorAction.outliner.gallery
        #expect(!entry.title.isEmpty)
        #expect(!entry.notes.isEmpty)
        #expect(EditorAction.outliner.tool == nil)
    }
}

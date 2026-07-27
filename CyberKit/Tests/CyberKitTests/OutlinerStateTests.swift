import CyberKit
import Foundation
import Testing

/// Scene-outliner document state (openspec add-scene-outliner, 8.1 tasks 1-2).
///
/// The model and its journal behaviour are the load-bearing parts — the UI on top is
/// replaceable, the document format is not. Covered here rather than in the app target
/// because none of it needs a viewport.
@Suite("Outliner document state")
struct OutlinerStateTests {
    private func object(
        name: String = "EditMesh", hidden: Bool = false, locked: Bool = false,
        group: String? = nil
    ) -> DocumentManifest.Object {
        DocumentManifest.Object(
            name: name, role: .editMesh, payloadFile: "a.obj",
            isHidden: hidden, isLocked: locked, group: group
        )
    }

    // MARK: - Task 1: the model, and old documents still opening

    @Test("Defaults are the pre-8.1 behaviour: visible, unlocked, ungrouped")
    func defaultsMatchOldBehaviour() {
        let plain = DocumentManifest.Object(name: "T", role: .target, payloadFile: "t.obj")
        #expect(!plain.isHidden)
        #expect(!plain.isLocked)
        #expect(plain.group == nil)
    }

    @Test("A document written WITHOUT the new keys still decodes")
    func preEightPointOneDocumentsDecode() throws {
        // The hazard this guards: `isHidden`/`isLocked` are non-optional Bools, so a
        // SYNTHESIZED Codable would treat them as required and throw keyNotFound on every
        // existing document. DensityField hit exactly this in 5.2b and only a test caught
        // it, which is why the explicit init(from:) exists.
        let legacy = Data(
            #"{"id":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","name":"Old","role":"target","payloadFile":"o.obj"}"#
                .utf8
        )
        let decoded = try JSONDecoder().decode(DocumentManifest.Object.self, from: legacy)
        #expect(decoded.name == "Old")
        #expect(!decoded.isHidden)
        #expect(!decoded.isLocked)
        #expect(decoded.group == nil)
    }

    @Test("The new state round-trips through Codable")
    func roundTrips() throws {
        let original = object(name: "Variant B", hidden: true, locked: true, group: "Candidates")
        let restored = try JSONDecoder().decode(
            DocumentManifest.Object.self, from: try JSONEncoder().encode(original)
        )
        #expect(restored == original)
    }

    // MARK: - Task 2: journaled, exactly one undo step

    @Test("Each state change applies and reverts exactly")
    func applyAndRevertAreExact() {
        var bundle = DocumentBundle()
        let subject = object(name: "Before", hidden: false, locked: false, group: nil)
        bundle.manifest.objects = [subject]
        bundle.payloads["a.obj"] = Data("payload".utf8)

        let edit = DocumentCommand.ObjectStateEdit.from(
            subject, name: "After", hidden: true, locked: true, group: .some("Group A")
        )
        let command = DocumentCommand.objectStateEdit(edit)
        command.apply(to: &bundle)
        var applied = bundle.manifest.objects[0]
        #expect(applied.name == "After")
        #expect(applied.isHidden)
        #expect(applied.isLocked)
        #expect(applied.group == "Group A")

        command.revert(on: &bundle)
        applied = bundle.manifest.objects[0]
        #expect(applied.name == "Before")
        #expect(!applied.isHidden)
        #expect(!applied.isLocked)
        #expect(applied.group == nil)
    }

    @Test("Ungrouping is expressible, and distinct from leaving the group alone")
    func ungroupingIsExpressible() {
        let grouped = object(group: "Candidates")
        // `nil` means "leave alone"; `.some(nil)` means "ungroup". Collapsing the two
        // would make ungrouping impossible to express at all.
        let untouched = DocumentCommand.ObjectStateEdit.from(grouped, hidden: true)
        #expect(untouched.afterGroup == "Candidates")

        let ungrouped = DocumentCommand.ObjectStateEdit.from(grouped, group: .some(nil))
        #expect(ungrouped.afterGroup == nil)
    }

    @Test("A no-op edit is recognisable so it need not enter the undo stack")
    func noOpIsRecognisable() {
        let subject = object(name: "Same", hidden: true, locked: false, group: "G")
        let unchanged = DocumentCommand.ObjectStateEdit.from(subject)
        #expect(unchanged.isNoOp)
        let changed = DocumentCommand.ObjectStateEdit.from(subject, hidden: false)
        #expect(!changed.isNoOp)
    }

    @Test("An outliner edit reports no resulting payload, because it changes none")
    func changesNoPayload() {
        let subject = object()
        let command = DocumentCommand.objectStateEdit(
            .from(subject, hidden: true)
        )
        // The snapshot-rebind hook keys on this: an outliner change must not look like a
        // geometry commit, or a caller would rebind its live mesh handle for nothing.
        #expect(command.resultingPayload(forObject: subject.id) == nil)
    }

    @Test("Hiding an object leaves its per-face visibility untouched")
    func objectHidingDoesNotRewriteFaceState() {
        var bundle = DocumentBundle()
        var subject = object()
        subject.annotations = MeshAnnotations(hiddenFaces: [3, 7])
        bundle.manifest.objects = [subject]

        let hide = DocumentCommand.objectStateEdit(.from(subject, hidden: true))
        hide.apply(to: &bundle)
        // The composition rule: object hiding DOMINATES but must not overwrite face
        // state, so showing the object again restores exactly what the lasso had done.
        #expect(bundle.manifest.objects[0].annotations?.hiddenFaces == [3, 7])
        hide.revert(on: &bundle)
        #expect(bundle.manifest.objects[0].annotations?.hiddenFaces == [3, 7])
        #expect(!bundle.manifest.objects[0].isHidden)
    }
}

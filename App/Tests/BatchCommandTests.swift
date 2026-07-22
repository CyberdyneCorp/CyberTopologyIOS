import CyberKit
import CyberKitTesting
import Foundation
import Testing
import simd

@testable import CyberTopology

/// Task 4.5: Auto Relax and the EditMesh batch commands end to end (spec:
/// retopology-tools / "Auto Relax", "EditMesh batch commands"; scenarios
/// "Auto Relax after quad creation" and "Subdivide and reproject").
///
/// Everything below drives the REAL pipeline — a real coordinator with a
/// real Metal renderer camera, real engine meshes, the real journaled
/// command path — and asserts on the resulting mesh state and journal, with
/// byte-exact undo. No engine mocks.
@MainActor
struct BatchCommandTests {
    /// Coordinator + document-journal harness (mirrors `TopoDocument`:
    /// record + apply, then re-sync the viewport like a SwiftUI pass).
    @MainActor
    private final class Harness {
        var bundle = DocumentBundle()
        let coordinator: MetalViewport.Coordinator
        private(set) var committed: [DocumentCommand] = []
        /// Auto Relax persists as a user preference; the harness gives each
        /// case its OWN defaults suite (inside the test container, thrown
        /// away with it) so flipping the mode here can never leak into
        /// `UserDefaults.standard` and silently change how an unrelated
        /// test's strokes behave.
        init() throws {
            let defaults = try #require(
                UserDefaults(suiteName: "batch-commands-\(UUID().uuidString)")
            )
            coordinator = MetalViewport(
                bundle: DocumentBundle(), orbitSpeed: 1, zoomSpeed: 1,
                inputModel: ViewportInputModel(defaults: defaults),
                onUndo: {}, onRedo: {}
            ).makeCoordinator()
            _ = coordinator.makeView()
            try #require(coordinator.renderer != nil, "Metal device unavailable")
            coordinator.onCommit = { [weak self] command in
                self?.committed.append(command)
                self?.perform(command)
            }
            coordinator.bundleProvider = { [weak self] in
                self?.bundle ?? DocumentBundle()
            }
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

        func redo() {
            if let command = bundle.journal.redo() {
                command.apply(to: &bundle)
                sync()
            }
        }

        var editObject: DocumentManifest.Object? {
            bundle.manifest.objects.first { $0.role == .editMesh }
        }

        func editMesh() throws -> Mesh {
            try bundle.mesh(for: #require(editObject))
        }

        func payload() throws -> Data {
            let file = try #require(editObject).payloadFile
            return try #require(bundle.payloads[file])
        }

        /// Normalized viewport point of a world position under the live
        /// camera.
        func screenPoint(of world: SIMD3<Float>) -> SIMD2<Double> {
            let m = coordinator.renderer!.viewProjectionColumns()
            let cx = m[0] * world.x + m[4] * world.y + m[8] * world.z + m[12]
            let cy = m[1] * world.x + m[5] * world.y + m[9] * world.z + m[13]
            let cw = m[3] * world.x + m[7] * world.y + m[11] * world.z + m[15]
            return SIMD2(
                Double(cx / cw) * 0.5 + 0.5, 1 - (Double(cy / cw) * 0.5 + 0.5)
            )
        }

        /// Journals an annotation state directly (the pin/tag commands are
        /// covered by the 4.3 suite; here they are only a precondition).
        func setAnnotations(_ annotations: MeshAnnotations) throws {
            let object = try #require(editObject)
            perform(.annotationEdit(DocumentCommand.AnnotationEdit(
                objectID: object.id, verb: "test.setAnnotations",
                before: object.annotations, after: annotations
            )))
        }
    }

    private func meshFromOBJ(_ text: String) throws -> Mesh {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("batch-cmd-\(UUID().uuidString).obj")
        try text.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try Mesh.loadOBJ(at: url)
    }

    /// Flat Target at z = 0 spanning the cage.
    private func addPlaneTarget(to harness: Harness) throws {
        try harness.bundle.addObject(
            name: "target", role: .target,
            mesh: try meshFromOBJ("""
            v -5 -5 0
            v 5 -5 0
            v 5 5 0
            v -5 5 0
            f 1 2 3 4
            """)
        )
        harness.sync()
    }

    /// The uneven interior column (x = 2.6 instead of 2) — placed NEXT to
    /// the append site, so the Auto Relax neighbourhood genuinely reaches it.
    private static let unevenVertex = SIMD3<Float>(2.6, 1, 0)
    /// Its unpinned sibling one row up (the pin test's anti-vacuity control).
    private static let unevenSibling = SIMD3<Float>(2.6, 2, 0)

    /// 3x3-quad cage on the Target plane, with the interior column next to
    /// the append site pushed off the even spacing, so a relax pass over
    /// that neighbourhood has real work to do.
    private func addUnevenGrid(to harness: Harness) throws {
        var obj = ""
        for row in 0...3 {
            for col in 0...3 {
                // Column 2 is dragged toward column 3: the gap between
                // columns 1 and 2 is now twice the gap between 2 and 3.
                let x = col == 2 ? 2.6 : Double(col)
                obj += "v \(x) \(row) 0\n"
            }
        }
        for row in 0..<3 {
            for col in 0..<3 {
                let a = row * 4 + col + 1
                obj += "f \(a) \(a + 1) \(a + 5) \(a + 4)\n"
            }
        }
        try harness.bundle.addObject(
            name: "cage", role: .editMesh, mesh: try meshFromOBJ(obj)
        )
        harness.sync()
    }

    private func vertexX(_ mesh: Mesh, near point: SIMD3<Float>) throws -> Float {
        try #require(mesh.nearestVertex(to: point, maxDistance: 0.3)).position.x
    }

    /// Appends one quad off the cage's right edge through the REAL create
    /// path (the grammar's createQuad, unprojected onto the Target).
    private func appendQuad(to harness: Harness) throws {
        harness.editor.applyCreate(
            verb: "test.append",
            screenPoints: [
                SIMD3<Float>(3, 1, 0), SIMD3(4, 1, 0),
                SIMD3(4, 2, 0), SIMD3(3, 2, 0),
            ].map { world in
                let point = harness.screenPoint(of: world)
                return SIMD2(Float(point.x), Float(point.y))
            },
            context: try #require(harness.coordinator.makeEditContext())
        ) { mesh, ring, snapper in
            try mesh.createFace(at: ring, snapping: snapper)
        }
    }

    // MARK: - Auto Relax (spec scenario "Auto Relax after quad creation")

    /// The scenario: with Auto Relax on, appending a quad redistributes the
    /// neighbouring unpinned vertices — and the whole thing is ONE journal
    /// entry, not two (append + relax).
    @Test func autoRelaxRedistributesNeighborsAfterAnAppendInOneJournalEntry() throws {
        let harness = try Harness()
        try addPlaneTarget(to: harness)
        try addUnevenGrid(to: harness)
        harness.model.setAutoRelax(true)
        let payloadBefore = try harness.payload()
        let unevenX = try vertexX(try harness.editMesh(), near: Self.unevenVertex)
        #expect(abs(unevenX - 2.6) < 1e-4)

        // Append a quad on the cage's right edge through the real create
        // path (the grammar's createQuad, unprojected onto the Target).
        try appendQuad(to: harness)

        // ONE undo step for append + redistribution.
        #expect(harness.bundle.journal.depth == 1)
        #expect(harness.committed.count == 1)
        guard case .meshEdit(let edit) = try #require(harness.committed.first) else {
            Issue.record("expected a single meshEdit command")
            return
        }
        #expect(edit.verb == "test.append")

        // The uneven interior column moved back toward even spacing.
        let relaxed = try harness.editMesh()
        let afterX = try vertexX(relaxed, near: Self.unevenVertex)
        #expect(afterX < unevenX - 1e-4)

        // One undo restores the exact pre-append bytes — geometry AND the
        // redistribution together.
        harness.undo()
        #expect(try harness.payload() == payloadBefore)
    }

    @Test func autoRelaxOffLeavesNeighborsExactlyWhereTheyWere() throws {
        let harness = try Harness()
        try addPlaneTarget(to: harness)
        try addUnevenGrid(to: harness)
        #expect(harness.model.autoRelaxEnabled == false)
        let unevenX = try vertexX(try harness.editMesh(), near: Self.unevenVertex)

        try appendQuad(to: harness)

        #expect(harness.bundle.journal.depth == 1)
        #expect(try vertexX(try harness.editMesh(), near: Self.unevenVertex) == unevenX)
    }

    /// The spec's "honoring pins" clause for Auto Relax (task 4.3a left it
    /// explicitly unproven until this task): a PINNED neighbour must not
    /// move even while its unpinned siblings redistribute.
    @Test func autoRelaxNeverMovesAPinnedVertex() throws {
        let harness = try Harness()
        try addPlaneTarget(to: harness)
        try addUnevenGrid(to: harness)
        harness.model.setAutoRelax(true)
        let cage = try harness.editMesh()
        let pinned = try #require(cage.nearestVertex(to: Self.unevenVertex, maxDistance: 0.2))
        let sibling = try #require(cage.nearestVertex(to: Self.unevenSibling, maxDistance: 0.2))
        try harness.setAnnotations(MeshAnnotations(pinnedVertices: [pinned.vertex]))

        try appendQuad(to: harness)

        let relaxed = try harness.editMesh()
        #expect(relaxed.vertexPosition(pinned.vertex) == pinned.position)
        // Anti-vacuity: the unpinned sibling in the same column DID move.
        #expect(relaxed.vertexPosition(sibling.vertex) != sibling.position)
    }

    @Test func autoRelaxBrushCoversThePointsPlusANeighbourRing() throws {
        let brush = try #require(
            MeshEditController.autoRelaxBrush(
                around: [SIMD3(0, 0, 0), SIMD3(2, 0, 0)], sceneRadius: 10
            )
        )
        #expect(brush.center == SIMD3<Float>(1, 0, 0))
        // Half-extent (1) plus the pad (10 * 0.12).
        #expect(abs(brush.radius - 2.2) < 1e-5)
        #expect(MeshEditController.autoRelaxBrush(around: [], sceneRadius: 1) == nil)
    }

    @Test func autoRelaxModePersistsAcrossModels() throws {
        let suite = "auto-relax-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = ViewportInputModel(defaults: defaults)
        #expect(first.autoRelaxEnabled == false)
        first.toggleAutoRelax()
        #expect(first.autoRelaxEnabled)
        // A fresh model (relaunch) restores the persisted mode.
        #expect(ViewportInputModel(defaults: defaults).autoRelaxEnabled)
    }

    // MARK: - Batch commands: journaling and undo round-trips

    @Test func snapAllToTargetJournalsOnceAndUndoesByteExactly() throws {
        let harness = try Harness()
        // Dome Target ABOVE the flat cage, so snap-all has to move things.
        try harness.bundle.addObject(
            name: "target", role: .target,
            mesh: try Mesh.loadOBJ(at: UITestSupport.writeSeedTargetOBJ())
        )
        try addUnevenGrid(to: harness)
        let before = try harness.payload()

        #expect(harness.model.runBatchCommand(.snapAllToTarget))
        #expect(harness.bundle.journal.depth == 1)
        guard case .meshEdit(let edit) = try #require(harness.committed.last) else {
            Issue.record("expected a plain meshEdit (snap-all preserves ids)")
            return
        }
        #expect(edit.verb == "batch.snapAllToTarget")
        harness.undo()
        #expect(try harness.payload() == before)
        harness.redo()
        #expect(try harness.payload() != before)
    }

    @Test func relaxAllJournalsOnceAndUndoesByteExactly() throws {
        let harness = try Harness()
        try addPlaneTarget(to: harness)
        try addUnevenGrid(to: harness)
        let before = try harness.payload()
        let unevenX = try vertexX(try harness.editMesh(), near: Self.unevenVertex)

        #expect(harness.model.runBatchCommand(.relaxAll))
        #expect(harness.bundle.journal.depth == 1)
        #expect(try vertexX(try harness.editMesh(), near: Self.unevenVertex) < unevenX)
        harness.undo()
        #expect(try harness.payload() == before)
    }

    @Test func triangulateJournalsOnceAndUndoesByteExactly() throws {
        let harness = try Harness()
        try addPlaneTarget(to: harness)
        try addUnevenGrid(to: harness)
        let before = try harness.payload()

        #expect(harness.model.runBatchCommand(.triangulate))
        #expect(harness.bundle.journal.depth == 1)
        #expect(try harness.editMesh().faceCount == 18)  // 9 quads -> 18 tris
        harness.undo()
        #expect(try harness.payload() == before)
        #expect(try harness.editMesh().faceCount == 9)
    }

    @Test func subdivideAndReprojectJournalsOnceAndLandsOnTheTarget() throws {
        let harness = try Harness()
        let target = try Mesh.loadOBJ(at: UITestSupport.writeSeedTargetOBJ())
        try harness.bundle.addObject(name: "target", role: .target, mesh: target)
        try harness.bundle.addObject(
            name: "cage", role: .editMesh,
            mesh: try Mesh.loadOBJ(at: UITestSupport.writeSeedDomeGridOBJ())
        )
        harness.sync()
        let before = try harness.payload()
        let coarseFaces = try harness.editMesh().faceCount

        #expect(harness.model.runBatchCommand(.subdivideAndReproject))
        #expect(harness.bundle.journal.depth == 1)
        let fine = try harness.editMesh()
        #expect(fine.faceCount == coarseFaces * 4)

        // Spec scenario "Subdivide and reproject": every vertex of the
        // subdivided cage sits ON the Target surface.
        let snapper = try SurfaceSnapper(target: target)
        for id in 0..<UInt32(fine.vertexCount) {
            let position = try #require(fine.vertexPosition(id))
            let hit = try #require(snapper.snapToSurface(position))
            #expect(simd_distance(hit.point, position) < 1e-3)
        }
        harness.undo()
        #expect(try harness.payload() == before)
    }

    @Test func batchCommandsWithoutAnEditMeshJournalNothing() throws {
        let harness = try Harness()
        try addPlaneTarget(to: harness)
        for command in BatchCommand.allCases {
            #expect(harness.model.runBatchCommand(command) == false)
        }
        #expect(harness.bundle.journal.depth == 0)
    }

    @Test func snapAllWithoutATargetIsRefusedRatherThanJournalingANoOp() throws {
        let harness = try Harness()
        try addUnevenGrid(to: harness)
        #expect(harness.model.runBatchCommand(.snapAllToTarget) == false)
        #expect(harness.model.runBatchCommand(.subdivideAndReproject) == false)
        #expect(harness.bundle.journal.depth == 0)
    }

    // MARK: - Annotation-orphaning regression (the compound entry)

    /// The regression this task exists to prevent: subdivide REBUILDS every
    /// element id, so the document's pins would silently address unrelated
    /// vertices. The geometry edit and the annotation clear must journal as
    /// ONE compound entry, so a single undo restores BOTH.
    @Test func subdivideClearsOrphanedPinsAndOneUndoRestoresThem() throws {
        let harness = try Harness()
        try addPlaneTarget(to: harness)
        try addUnevenGrid(to: harness)
        let cage = try harness.editMesh()
        let pinned = try #require(cage.nearestVertex(to: Self.unevenVertex, maxDistance: 0.2))
        let annotations = MeshAnnotations(
            taggedEdges: [0], tagColorIndices: [2], pinnedVertices: [pinned.vertex]
        )
        try harness.setAnnotations(annotations)
        let payloadBefore = try harness.payload()
        let depthBefore = harness.bundle.journal.depth

        #expect(harness.model.runBatchCommand(.subdivide))

        // ONE journal entry, and it is a compound of the mesh edit plus the
        // annotation clear.
        #expect(harness.bundle.journal.depth == depthBefore + 1)
        guard case .compound(let verb, let commands) = try #require(harness.committed.last)
        else {
            Issue.record("expected a compound command")
            return
        }
        #expect(verb == "batch.subdivide")
        #expect(commands.count == 2)
        guard case .meshEdit = commands[0],
            case .annotationEdit(let annotationEdit) = commands[1]
        else {
            Issue.record("expected [meshEdit, annotationEdit]")
            return
        }
        #expect(annotationEdit.before == annotations)
        #expect(annotationEdit.after == nil)
        #expect(harness.editObject?.annotations == nil)

        // One undo brings back the geometry AND the pins/tags together.
        harness.undo()
        #expect(try harness.payload() == payloadBefore)
        #expect(harness.editObject?.annotations == annotations)
        // Redo re-applies both halves.
        harness.redo()
        #expect(harness.editObject?.annotations == nil)
        #expect(try harness.editMesh().faceCount == 36)
    }

    /// Triangulate mutates in place, so VERTEX ids — and therefore pins —
    /// keep their meaning. Hidden faces do not (each split n-gon gains face
    /// ids the set cannot know about) and neither do LOOP TAGS: the payload
    /// stores no edges, so the reload rebuilds every edge id from the face
    /// stream triangulate just reshuffled (regression for the major finding;
    /// the engine-side proof is `triangulateReshufflesRebuiltEdgeIDs`).
    @Test func triangulateKeepsPinsButClearsTagsAndHiddenFaces() throws {
        let harness = try Harness()
        try addPlaneTarget(to: harness)
        try addUnevenGrid(to: harness)
        let cage = try harness.editMesh()
        let pinned = try #require(cage.nearestVertex(to: Self.unevenVertex, maxDistance: 0.2))
        let annotations = MeshAnnotations(
            taggedEdges: [1], tagColorIndices: [3],
            hiddenFaces: [0], pinnedVertices: [pinned.vertex]
        )
        try harness.setAnnotations(annotations)

        #expect(harness.model.runBatchCommand(.triangulate))
        let after = try #require(harness.editObject?.annotations)
        #expect(after.pinnedVertices == [pinned.vertex])
        #expect(after.taggedEdges.isEmpty)
        #expect(after.tagColorIndices.isEmpty)
        #expect(after.hiddenFaces.isEmpty)
        // Still ONE undo step for geometry + the annotation reset.
        harness.undo()
        #expect(harness.editObject?.annotations == annotations)
    }

    @Test func batchCommandsWithNoAnnotationsJournalAPlainMeshEdit() throws {
        let harness = try Harness()
        try addPlaneTarget(to: harness)
        try addUnevenGrid(to: harness)
        #expect(harness.model.runBatchCommand(.subdivide))
        // Nothing to clear: no needless compound wrapper, no empty
        // annotation blob written into the manifest.
        guard case .meshEdit = try #require(harness.committed.last) else {
            Issue.record("expected a plain meshEdit")
            return
        }
    }

    // MARK: - Annotation clears through the same panel

    @Test func clearPinsAndClearLoopTagsRunFromTheBatchPanel() throws {
        let harness = try Harness()
        try addPlaneTarget(to: harness)
        try addUnevenGrid(to: harness)
        try harness.setAnnotations(
            MeshAnnotations(taggedEdges: [2], tagColorIndices: [1], pinnedVertices: [0, 1])
        )
        #expect(harness.model.runBatchCommand(.clearPins))
        #expect(harness.editObject?.annotations?.pinnedVertices.isEmpty == true)
        #expect(harness.editObject?.annotations?.taggedEdges == [2])
        #expect(harness.model.runBatchCommand(.clearLoopTags))
        #expect(harness.editObject?.annotations == nil)
        // Clearing nothing journals nothing.
        #expect(harness.model.runBatchCommand(.clearPins) == false)
        harness.undo()
        #expect(harness.editObject?.annotations?.taggedEdges == [2])
    }

    // MARK: - Panel + toolbar wiring

    @Test func batchPanelActionPresentsTheSheetAndJournalsNothingItself() throws {
        let harness = try Harness()
        #expect(harness.model.showsBatchCommands == false)
        #expect(harness.model.runCommand(.batchCommands) == false)
        #expect(harness.model.showsBatchCommands)
    }

    @Test func autoRelaxToolbarActionTogglesTheModeWithoutJournaling() throws {
        let harness = try Harness()
        #expect(harness.model.isCommandActive(.toggleAutoRelax) == false)
        #expect(harness.model.runCommand(.toggleAutoRelax) == false)
        #expect(harness.model.isCommandActive(.toggleAutoRelax))
        #expect(harness.editor.autoRelaxEnabled)
        #expect(harness.bundle.journal.depth == 0)
        #expect(harness.model.runCommand(.toggleAutoRelax) == false)
        #expect(harness.editor.autoRelaxEnabled == false)
        // Only the toggle-style command reports an active state.
        #expect(harness.model.isCommandActive(.clearPins) == false)
    }

    @Test func batchCommandMetadataIsCoherent() {
        for command in BatchCommand.allCases {
            #expect(!command.title.isEmpty)
            #expect(!command.symbol.isEmpty)
            #expect(!command.notes.isEmpty)
        }
        #expect(BatchCommand.snapAllToTarget.requiresTarget)
        #expect(BatchCommand.subdivideAndReproject.requiresTarget)
        #expect(BatchCommand.subdivide.requiresTarget == false)
        #expect(BatchCommand.subdivide.annotationPolicy == .rebuilt)
        #expect(BatchCommand.subdivideAndReproject.annotationPolicy == .rebuilt)
        #expect(BatchCommand.triangulate.annotationPolicy == .pinsOnly)
        #expect(BatchCommand.relaxAll.annotationPolicy == .preserved)
        // Both task-4.5 toolbar actions are immediate (tap runs them) and
        // neither arms a tool or selects a verb.
        for action in [EditorAction.toggleAutoRelax, .batchCommands] {
            #expect(action.isImmediateCommand)
            #expect(action.verb == nil)
            #expect(action.tool == nil)
            #expect(!action.gallery.title.isEmpty)
        }
    }

    @Test func probeSubdividesThroughTheRealJournaledPath() throws {
        let harness = try Harness()
        let target = try Mesh.loadOBJ(at: UITestSupport.writeSeedTargetOBJ())
        try harness.bundle.addObject(name: "target", role: .target, mesh: target)
        try harness.bundle.addObject(
            name: "cage", role: .editMesh,
            mesh: try Mesh.loadOBJ(at: UITestSupport.writeSeedDomeGridOBJ())
        )
        harness.sync()
        #expect(harness.editor.probeBatchSubdivideForVisualVerification())
        #expect(harness.bundle.journal.depth == 1)
    }

    @Test func snapAllStatusReportsWhatMoved() {
        #expect(
            MeshEditController.snapAllStatus(.init(resnapped: 0, maxDistance: 0))
                == "Already on the Target"
        )
        #expect(
            MeshEditController.snapAllStatus(.init(resnapped: 3, maxDistance: 0.25))
                .hasPrefix("Snapped 3 vertices")
        )
    }
}

/// The compound journal entry itself (task 4.5): applied in order, reverted
/// in reverse, and a single node in the tree.
@Suite("Compound document command")
struct CompoundCommandTests {
    @Test func compoundAppliesInOrderAndRevertsInReverse() throws {
        var bundle = DocumentBundle()
        let mesh = try Mesh()
        try mesh.createFace(at: [
            SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0),
        ])
        try bundle.addObject(name: "cage", role: .editMesh, mesh: mesh)
        let object = try #require(bundle.manifest.objects.first)
        let annotations = MeshAnnotations(pinnedVertices: [1, 2])
        let payloadBefore = try #require(bundle.payloads[object.payloadFile])

        // Precondition: annotations present.
        DocumentCommand.annotationEdit(.init(
            objectID: object.id, verb: "pins", before: nil, after: annotations
        )).apply(to: &bundle)

        let compound = DocumentCommand.compound(
            verb: "batch.subdivide",
            commands: [
                .meshEdit(DocumentCommand.MeshEdit(
                    objectID: object.id, payloadFile: object.payloadFile,
                    verb: "batch.subdivide", before: payloadBefore,
                    after: payloadBefore + Data([0]),
                    beforeCounts: object.counts, afterCounts: object.counts,
                    beforeRevision: object.revision, afterRevision: 1
                )),
                .annotationEdit(.init(
                    objectID: object.id, verb: "batch.subdivide.annotations",
                    before: annotations, after: nil
                )),
            ]
        )
        var journal = UndoJournal()
        journal.record(compound)
        compound.apply(to: &bundle)
        #expect(journal.depth == 1)
        #expect(bundle.payloads[object.payloadFile] != payloadBefore)
        #expect(bundle.manifest.objects.first?.annotations == nil)

        let undoneCommand = journal.undo()
        let undone = try #require(undoneCommand)
        undone.revert(on: &bundle)
        #expect(bundle.payloads[object.payloadFile] == payloadBefore)
        #expect(bundle.manifest.objects.first?.annotations == annotations)
        #expect(journal.depth == 0)

        let redoneCommand = journal.redo()
        let redone = try #require(redoneCommand)
        redone.apply(to: &bundle)
        #expect(bundle.manifest.objects.first?.annotations == nil)
    }

    @Test func compoundSurvivesJournalPersistence() throws {
        let command = DocumentCommand.compound(
            verb: "batch.triangulate",
            commands: [
                .setStage(from: .retopology, to: .uv),
                .annotationEdit(.init(
                    objectID: UUID(), verb: "a", before: MeshAnnotations(hiddenFaces: [1]),
                    after: nil
                )),
            ]
        )
        let data = try JSONEncoder().encode(command)
        #expect(try JSONDecoder().decode(DocumentCommand.self, from: data) == command)
    }
}


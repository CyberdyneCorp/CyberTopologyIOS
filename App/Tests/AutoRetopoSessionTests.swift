import CyberKit
import Foundation
import Testing

@testable import CyberTopology

/// The Auto-Retopo session (Phase 5, add-weave-solver-pipeline): begin runs the
/// Weave solver over the Target and holds a ghost; accept commits it as the
/// EditMesh in one journal entry; discard drops it. Driven directly (as the
/// camera-tool tests drive `commitCameraToolSession`), so the spec's testable
/// guarantees hold without the Metal ghost rendering or gesture routing.
/// App-hosted, so it runs on the iPad as well as the simulator.
@MainActor
struct AutoRetopoSessionTests {
    @MainActor
    private final class Harness {
        var bundle = DocumentBundle()
        let coordinator: MetalViewport.Coordinator
        private(set) var committed: [DocumentCommand] = []

        init() {
            coordinator = MetalViewport(
                bundle: DocumentBundle(), orbitSpeed: 1, zoomSpeed: 1, onUndo: {}, onRedo: {}
            ).makeCoordinator()
            coordinator.onCommit = { [weak self] command in
                self?.committed.append(command)
                self?.perform(command)
            }
            coordinator.bundleProvider = { [weak self] in self?.bundle ?? DocumentBundle() }
        }

        func perform(_ command: DocumentCommand) {
            bundle.journal.record(command)
            command.apply(to: &bundle)
        }

        func undo() {
            if let command = bundle.journal.undo() { command.revert(on: &bundle) }
        }

        var editObject: DocumentManifest.Object? {
            bundle.manifest.objects.first { $0.role == .editMesh }
        }
        func editMesh() throws -> Mesh { try bundle.mesh(for: #require(editObject)) }

        func addTargetCube() throws {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("autoretopo-\(UUID().uuidString).obj")
            try """
            v -0.5 -0.5 -0.5
            v  0.5 -0.5 -0.5
            v  0.5  0.5 -0.5
            v -0.5  0.5 -0.5
            v -0.5 -0.5  0.5
            v  0.5 -0.5  0.5
            v  0.5  0.5  0.5
            v -0.5  0.5  0.5
            f 1 4 3 2
            f 5 6 7 8
            f 1 2 6 5
            f 2 3 7 6
            f 3 4 8 7
            f 4 1 5 8
            """.write(to: url, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: url) }
            try bundle.addObject(name: "target", role: .target, mesh: try Mesh.loadOBJ(at: url))
        }
    }

    private func params() -> SolverParameters {
        var p = SolverParameters()
        p.remesh.targetQuads = 60
        return p
    }

    @Test("Begin produces a pending ghost and changes nothing")
    func beginProducesGhostNoChange() throws {
        let harness = Harness()
        try harness.addTargetCube()
        #expect(harness.coordinator.beginAutoRetopo(parameters: params()))
        #expect(harness.coordinator.hasAutoRetopoGhost)
        // The solve committed nothing and created no EditMesh — the document is
        // untouched until accept.
        #expect(harness.committed.isEmpty)
        #expect(harness.editObject == nil)
    }

    @Test("Accept journals exactly once, creates the EditMesh, and undo restores")
    func acceptJournalsOnceAndUndoRestores() throws {
        let harness = Harness()
        try harness.addTargetCube()
        _ = harness.coordinator.beginAutoRetopo(parameters: params())

        #expect(harness.coordinator.acceptAutoRetopo())
        #expect(!harness.coordinator.hasAutoRetopoGhost)
        #expect(harness.committed.count == 1, "accept is exactly one journal entry")

        // The accepted ghost is an ordinary EditMesh of quads.
        let edit = try harness.editMesh()
        #expect(try edit.stats().quads > 0)
        #expect(edit.faceCount > 0)

        // One undo restores the pre-accept document (no EditMesh — it was created).
        harness.undo()
        #expect(harness.editObject == nil)
    }

    @Test("Discard drops the ghost with no journal entry")
    func discardChangesNothing() throws {
        let harness = Harness()
        try harness.addTargetCube()
        _ = harness.coordinator.beginAutoRetopo(parameters: params())

        harness.coordinator.discardAutoRetopo()
        #expect(!harness.coordinator.hasAutoRetopoGhost)
        #expect(harness.committed.isEmpty)
        #expect(harness.editObject == nil)
    }

    @Test("Opt-in: without an invocation there is no ghost and no EditMesh")
    func optInProducesNothing() throws {
        let harness = Harness()
        try harness.addTargetCube()
        #expect(!harness.coordinator.hasAutoRetopoGhost)
        #expect(harness.editObject == nil)
    }

    @Test("Begin without a Target is inert")
    func beginWithoutTargetIsInert() throws {
        let harness = Harness()
        #expect(!harness.coordinator.beginAutoRetopo(parameters: params()))
        #expect(!harness.coordinator.hasAutoRetopoGhost)
    }

    @Test("Accept over an existing EditMesh replaces it in one undoable step")
    func acceptReplacesExistingEditMeshInOneStep() throws {
        let harness = Harness()
        try harness.addTargetCube()
        // Seed a prior EditMesh so accept must REPLACE (compound remove+add).
        try harness.bundle.addObject(
            name: "cage", role: .editMesh, mesh: try Mesh.loadOBJ(at: seedQuadURL())
        )
        let priorFaces = try harness.editMesh().faceCount

        _ = harness.coordinator.beginAutoRetopo(parameters: params())
        #expect(harness.coordinator.acceptAutoRetopo())
        #expect(harness.committed.count == 1, "replace is one undoable step")
        // The EditMesh is now the remeshed cage (more than the seed's 1 quad).
        #expect(try harness.editMesh().faceCount != priorFaces)

        // One undo brings the original cage back exactly.
        harness.undo()
        #expect(try harness.editMesh().faceCount == priorFaces)
    }

    private func seedQuadURL() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("autoretopo-seed-\(UUID().uuidString).obj")
        try "v 0 0 0\nv 1 0 0\nv 1 1 0\nv 0 1 0\nf 1 2 3 4\n"
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

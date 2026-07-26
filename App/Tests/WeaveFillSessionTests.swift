import CyberKit
import Foundation
import Testing
import simd

@testable import CyberTopology

/// The Weave Fill session (add-weave-region-selection, task 3): a captured intent
/// becomes a proposal; accepting it is one journal entry; a proposal whose cage
/// changed underneath is dropped rather than accepted.
///
/// Driven directly, like the Auto-Retopo session tests. App-hosted, so it runs on
/// the iPad too.
@MainActor
struct WeaveFillSessionTests {
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
        var editPayload: Data? {
            editObject.flatMap { bundle.payloads[$0.payloadFile] }
        }

        private static func dome(_ x: Float, _ y: Float) -> Float {
            0.5 * max(0, 1.0 - (x * x + y * y) / 2.0)
        }

        private func write(_ obj: String) throws -> Mesh {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("fillsess-\(UUID().uuidString).obj")
            try obj.write(to: url, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: url) }
            return try Mesh.loadOBJ(at: url)
        }

        /// High-poly triangle Target — the surface, never modified.
        func addDomedTarget(n: Int = 20) throws {
            var obj = ""
            for i in 0...n {
                for j in 0...n {
                    let x = 2 * Float(i) / Float(n) - 1, y = 2 * Float(j) / Float(n) - 1
                    obj += "v \(x) \(y) \(Self.dome(x, y))\n"
                }
            }
            let v = { (a: Int, b: Int) in a * (n + 1) + b + 1 }
            for i in 0..<n {
                for j in 0..<n {
                    obj += "f \(v(i, j)) \(v(i + 1, j)) \(v(i + 1, j + 1))\n"
                    obj += "f \(v(i, j)) \(v(i + 1, j + 1)) \(v(i, j + 1))\n"
                }
            }
            try bundle.addObject(name: "target", role: .target, mesh: try write(obj))
        }

        /// A coarse quad cage over the lower band — the hand-authored 10%.
        func addPartialCage() throws {
            var obj = ""
            let cols = 4, rows = 2
            for i in 0...cols {
                for j in 0...rows {
                    let x = -0.8 + 1.6 * Float(i) / Float(cols)
                    let y = -0.8 + 0.6 * Float(j) / Float(rows)
                    obj += "v \(x) \(y) \(Self.dome(x, y))\n"
                }
            }
            let v = { (a: Int, b: Int) in a * (rows + 1) + b + 1 }
            for i in 0..<cols {
                for j in 0..<rows {
                    obj += "f \(v(i, j)) \(v(i + 1, j)) \(v(i + 1, j + 1)) \(v(i, j + 1))\n"
                }
            }
            try bundle.addObject(name: "EditMesh", role: .editMesh, mesh: try write(obj))
        }

        func requestTapFill() {
            coordinator.meshEditor.weaveFillIntent = WeaveFillIntent(
                fillPoint: SIMD3(0, 0.6, Self.dome(0, 0.6)), extent: [], isTap: true
            )
        }
    }

    @Test("A tap fill produces a pending ghost and changes nothing")
    func fillProducesGhostNoChange() throws {
        let harness = Harness()
        try harness.addDomedTarget()
        try harness.addPartialCage()
        let before = try #require(harness.editPayload)
        harness.requestTapFill()

        #expect(harness.coordinator.beginWeaveFill())
        #expect(harness.coordinator.hasAutoRetopoGhost)
        // Nothing committed, document byte-unchanged: the proposal is a ghost.
        #expect(harness.committed.isEmpty)
        #expect(harness.editPayload == before)
    }

    @Test("Accepting a fill is ONE journal entry and adds quads to the cage")
    func acceptIsOneEntry() throws {
        let harness = Harness()
        try harness.addDomedTarget()
        try harness.addPartialCage()
        let cageFaces = try harness.editMesh().faceCount
        harness.requestTapFill()
        #expect(harness.coordinator.beginWeaveFill())

        #expect(harness.coordinator.acceptAutoRetopo())
        #expect(harness.committed.count == 1, "accept is exactly one journal entry")
        #expect(try harness.editMesh().faceCount > cageFaces, "the fill added quads")
        #expect(!harness.coordinator.hasAutoRetopoGhost)
    }

    @Test("One undo restores the pre-accept cage exactly")
    func undoRestoresBytes() throws {
        let harness = Harness()
        try harness.addDomedTarget()
        try harness.addPartialCage()
        let before = try #require(harness.editPayload)
        harness.requestTapFill()
        #expect(harness.coordinator.beginWeaveFill())
        #expect(harness.coordinator.acceptAutoRetopo())
        #expect(harness.editPayload != before)

        harness.undo()
        #expect(harness.editPayload == before, "one undo restores the pre-accept bytes")
    }

    @Test("Discarding a fill journals nothing and leaves no seed rows behind")
    func discardLeavesNothing() throws {
        let harness = Harness()
        try harness.addDomedTarget()
        try harness.addPartialCage()
        let before = try #require(harness.editPayload)
        harness.requestTapFill()
        #expect(harness.coordinator.beginWeaveFill())

        harness.coordinator.discardAutoRetopo()
        #expect(!harness.coordinator.hasAutoRetopoGhost)
        #expect(harness.committed.isEmpty)
        // The seed was grown on a COPY, so there is nothing to clean up.
        #expect(harness.editPayload == before)
    }

    @Test("A proposal whose cage changed underneath is DROPPED, not accepted")
    func stalefillIsDropped() throws {
        let harness = Harness()
        try harness.addDomedTarget()
        try harness.addPartialCage()
        harness.requestTapFill()
        #expect(harness.coordinator.beginWeaveFill())
        #expect(harness.coordinator.hasAutoRetopoGhost)

        // Something else changes the EditMesh — an undo, a redo, a conflict revert.
        // A fill ghost CONTAINS the cage, so accepting it now would put the old cage
        // back. This is the hazard a whole-Target proposal does not have.
        harness.coordinator.discardWeaveFillIfStale(newPayload: Data("different".utf8))

        #expect(!harness.coordinator.hasAutoRetopoGhost, "stale fill proposal must be dropped")
        #expect(harness.coordinator.meshEditor.weaveFillIntent == nil,
                "the request was resolved against the old cage, so it is stale too")
        #expect(harness.committed.isEmpty)
    }

    @Test("An unchanged snapshot keeps the proposal — the check is staleness, not paranoia")
    func unchangedSnapshotKeepsGhost() throws {
        let harness = Harness()
        try harness.addDomedTarget()
        try harness.addPartialCage()
        harness.requestTapFill()
        #expect(harness.coordinator.beginWeaveFill())

        harness.coordinator.discardWeaveFillIfStale(newPayload: harness.editPayload)
        #expect(harness.coordinator.hasAutoRetopoGhost)
    }

    @Test("A cage with no free edge refuses, and says why")
    func closedCageRefuses() throws {
        let harness = Harness()
        try harness.addDomedTarget()
        // A closed tetrahedron has no boundary to grow from.
        try harness.bundle.addObject(
            name: "EditMesh", role: .editMesh,
            mesh: try {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("closed-\(UUID().uuidString).obj")
                try "v 0 0 0\nv 1 0 0\nv 0 1 0\nv 0 0 1\nf 1 3 2\nf 1 2 4\nf 2 3 4\nf 3 1 4\n"
                    .write(to: url, atomically: true, encoding: .utf8)
                defer { try? FileManager.default.removeItem(at: url) }
                return try Mesh.loadOBJ(at: url)
            }()
        )
        harness.requestTapFill()

        #expect(harness.coordinator.beginWeaveFill() == false)
        #expect(!harness.coordinator.hasAutoRetopoGhost)
        let notice = try #require(harness.coordinator.inputModel.autoRetopoNotice)
        #expect(notice.lowercased().contains("no open cage edge"))
        #expect(harness.committed.isEmpty)
    }

    @Test("No request means no proposal — strictly opt-in")
    func noRequestNoProposal() throws {
        let harness = Harness()
        try harness.addDomedTarget()
        try harness.addPartialCage()
        #expect(harness.coordinator.beginWeaveFill() == false)
        #expect(!harness.coordinator.hasAutoRetopoGhost)
    }

    @Test("Refusal messages are distinct and human")
    func refusalMessages() {
        let messages = [
            MetalViewport.Coordinator.fillRefusal(WeaveFillDomain.Failure.noOpenBoundary),
            MetalViewport.Coordinator.fillRefusal(WeaveFillDomain.Failure.noFillDirection),
            MetalViewport.Coordinator.fillRefusal(WeaveFillDomain.Failure.runTooShort),
            MetalViewport.Coordinator.fillRefusal(WeaveFillDomain.Failure.degenerateStep),
        ]
        #expect(Set(messages).count == messages.count, "each refusal needs its own message")
        for message in messages { #expect(!message.isEmpty) }
    }
}

/// Live re-solve (add-weave-region-selection, task 4).
@MainActor
struct WeaveFillResolveTests {
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
                self?.bundle.journal.record(command)
                command.apply(to: &self!.bundle)
            }
            coordinator.bundleProvider = { [weak self] in self?.bundle ?? DocumentBundle() }
            // The hook the shell installs; re-solve on request change.
            coordinator.meshEditor.onWeaveFillIntentChanged = { [weak coordinator] intent in
                guard let coordinator else { return }
                if intent == nil {
                    coordinator.discardAutoRetopo()
                } else {
                    coordinator.beginWeaveFill()
                }
            }
        }

        static func dome(_ x: Float, _ y: Float) -> Float {
            0.5 * max(0, 1.0 - (x * x + y * y) / 2.0)
        }

        private func write(_ obj: String) throws -> Mesh {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("resolve-\(UUID().uuidString).obj")
            try obj.write(to: url, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: url) }
            return try Mesh.loadOBJ(at: url)
        }

        func addDomedTarget(n: Int = 20) throws {
            var obj = ""
            for i in 0...n {
                for j in 0...n {
                    let x = 2 * Float(i) / Float(n) - 1, y = 2 * Float(j) / Float(n) - 1
                    obj += "v \(x) \(y) \(Self.dome(x, y))\n"
                }
            }
            let v = { (a: Int, b: Int) in a * (n + 1) + b + 1 }
            for i in 0..<n {
                for j in 0..<n {
                    obj += "f \(v(i, j)) \(v(i + 1, j)) \(v(i + 1, j + 1))\n"
                    obj += "f \(v(i, j)) \(v(i + 1, j + 1)) \(v(i, j + 1))\n"
                }
            }
            try bundle.addObject(name: "target", role: .target, mesh: try write(obj))
        }

        func addPartialCage() throws {
            var obj = ""
            let cols = 4, rows = 2
            for i in 0...cols {
                for j in 0...rows {
                    let x = -0.8 + 1.6 * Float(i) / Float(cols)
                    let y = -0.8 + 0.6 * Float(j) / Float(rows)
                    obj += "v \(x) \(y) \(Self.dome(x, y))\n"
                }
            }
            let v = { (a: Int, b: Int) in a * (rows + 1) + b + 1 }
            for i in 0..<cols {
                for j in 0..<rows {
                    obj += "f \(v(i, j)) \(v(i + 1, j)) \(v(i + 1, j + 1)) \(v(i, j + 1))\n"
                }
            }
            try bundle.addObject(name: "EditMesh", role: .editMesh, mesh: try write(obj))
        }

        var editPayload: Data? {
            bundle.manifest.objects.first { $0.role == .editMesh }
                .flatMap { bundle.payloads[$0.payloadFile] }
        }

        /// Simulates capture publishing a new request.
        func publish(_ intent: WeaveFillIntent?) {
            coordinator.meshEditor.weaveFillIntent = intent
            coordinator.meshEditor.onWeaveFillIntentChanged?(intent)
        }
    }

    private func tap() -> WeaveFillIntent {
        WeaveFillIntent(
            fillPoint: SIMD3(0, 0.6, Harness.dome(0, 0.6)), extent: [], isTap: true
        )
    }

    @Test("A changed request re-solves and REPLACES the proposal, journaling nothing")
    func changedRequestReplacesProposal() throws {
        let harness = Harness()
        try harness.addDomedTarget()
        try harness.addPartialCage()
        let before = try #require(harness.editPayload)

        harness.publish(tap())
        #expect(harness.coordinator.hasAutoRetopoGhost)
        let first = try #require(harness.coordinator.autoRetopoGhost).mesh.faceCount

        // Paint further out: more rows, so a different proposal.
        var painted = tap()
        painted.isTap = false
        painted.extent = [
            SIMD3(0, 0.1, Harness.dome(0, 0.1)),
            SIMD3(0, 0.9, Harness.dome(0, 0.9)),
        ]
        painted.fillPoint = SIMD3(0, 0.5, Harness.dome(0, 0.5))
        harness.publish(painted)

        #expect(harness.coordinator.hasAutoRetopoGhost, "a re-solve replaces, never clears")
        let second = try #require(harness.coordinator.autoRetopoGhost).mesh.faceCount
        #expect(second != first, "reaching further should propose more geometry")
        // Only ONE proposal is ever pending, and nothing was journaled.
        #expect(harness.committed.isEmpty)
        #expect(harness.editPayload == before)
    }

    @Test("Clearing the request drops the proposal")
    func clearingDropsProposal() throws {
        let harness = Harness()
        try harness.addDomedTarget()
        try harness.addPartialCage()
        harness.publish(tap())
        #expect(harness.coordinator.hasAutoRetopoGhost)

        harness.publish(nil)
        #expect(!harness.coordinator.hasAutoRetopoGhost)
        #expect(harness.committed.isEmpty)
    }

    @Test("Re-solving is idempotent — the same request gives the same proposal")
    func resolveIsDeterministic() throws {
        let harness = Harness()
        try harness.addDomedTarget()
        try harness.addPartialCage()

        harness.publish(tap())
        let first = try #require(harness.coordinator.autoRetopoGhost).mesh.faceCount
        harness.publish(tap())
        let second = try #require(harness.coordinator.autoRetopoGhost).mesh.faceCount
        #expect(first == second)
    }
}

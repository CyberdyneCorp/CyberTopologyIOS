import CyberKit
import CyberKitTesting
import Foundation
import Testing
import simd
@testable import CyberTopology

/// Selecting a quad patch and scoping the batch commands to it (openspec
/// add-patch-selection-scope).
///
/// Asked on device: "can we first select the patch of quads that we want this
/// option to be applied? If no patch is selected then it will be all the patches
/// on EditMesh."
@MainActor
struct PatchSelectionScopeTests {
    private func meshFromOBJ(_ text: String) throws -> Mesh {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("patch-scope-\(UUID().uuidString).obj")
        try text.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try Mesh.loadOBJ(at: url)
    }

    /// A headless context over `mesh`: the patch selection needs no camera and
    /// no Target, only the cage it reads topology from.
    private func context(
        _ mesh: Mesh, annotations: MeshAnnotations? = nil
    ) -> MeshEditController.Context {
        MeshEditController.Context(
            editMesh: mesh, annotations: annotations, sceneRadius: 1, ray: { _ in nil }
        )
    }

    /// A flat `n` x `n` grid at z = 0.
    private func grid(_ n: Int) throws -> Mesh {
        var obj = ""
        for row in 0...n {
            for col in 0...n {
                obj += "v \(col) \(row) 0\n"
            }
        }
        let stride = n + 1
        for row in 0..<n {
            for col in 0..<n {
                let a = row * stride + col + 1
                obj += "f \(a) \(a + 1) \(a + stride + 1) \(a + stride)\n"
            }
        }
        return try meshFromOBJ(obj)
    }

    // MARK: - The gesture

    /// The double-tap belongs to the armed region tool when there is one, and
    /// selects a patch when there is not.
    @Test func theDoubleTapSelectsAPatchWhenNoRegionToolIsArmed() {
        #expect(PencilTapAction.forTool(nil) == .selectPatch)
        #expect(PencilTapAction.forTool(.transformVertices) == .selectPatch)
        // A region tool still owns it: while one is armed the artist is working
        // on the Target, and the patch selection is about the cage.
        #expect(PencilTapAction.forTool(.paintRegion) == .toggleErase)
        #expect(PencilTapAction.forTool(.selectRegionBox) == .toggleSeeThrough)
    }

    /// Tapping adds a patch; tapping a face already selected removes its patch,
    /// so a mistaken tap is undone by repeating it.
    @Test func tappingTwiceAddsThenRemoves() throws {
        let controller = MeshEditController()
        let cage = try grid(4)
        controller.contextProvider = { self.context(cage) }
        let seed = try #require(cage.liveFaceIDs().sorted().first)

        controller.togglePatch(containing: seed)
        #expect(controller.selectedPatch.count == 16, "a flat grid is one patch")

        controller.togglePatch(containing: seed)
        #expect(controller.selectedPatch.isEmpty)
    }

    @Test func theSelectionPublishesItsChanges() throws {
        let controller = MeshEditController()
        let cage = try grid(3)
        controller.contextProvider = { self.context(cage) }
        var published: [Int] = []
        controller.onSelectedPatchChanged = { published.append($0.count) }
        let seed = try #require(cage.liveFaceIDs().sorted().first)

        controller.togglePatch(containing: seed)
        controller.clearSelectedPatch()

        #expect(published == [9, 0])
        // Clearing an empty selection says nothing: the callback drives a redraw.
        controller.clearSelectedPatch()
        #expect(published == [9, 0])
    }

    // MARK: - What a scoped command reaches

    /// The heart of it: a scoped Relax must move the selection and NOTHING else.
    /// Scoping works by pinning the complement, so this is also the test that the
    /// pin set is built from the right vertices.
    @Test func aScopedRelaxHoldsEverythingOutsideStill() throws {
        let controller = MeshEditController()
        // Two grids far apart, so "the other patch" is unambiguous.
        let cage = try meshFromOBJ("""
        v 0 0 0
        v 1 0 0
        v 2 0 0
        v 0 1 0
        v 1.4 1.3 0
        v 2 1 0
        v 0 2 0
        v 1 2 0
        v 2 2 0
        v 10 0 0
        v 11 0 0
        v 10.4 1.3 0
        v 11 1 0
        f 1 2 5 4
        f 2 3 6 5
        f 4 5 8 7
        f 5 6 9 8
        f 10 11 13 12
        """)
        let context = self.context(cage)
        controller.contextProvider = { context }
        // Select the 2x2 block only.
        let block = Set(cage.liveFaceIDs().sorted().prefix(4))
        let seed = try #require(block.sorted().first)
        controller.togglePatch(containing: seed)
        #expect(!controller.selectedPatch.isEmpty)

        let outsideBefore = cage.vertexPosition(11)
        let pinned = controller.holdingEverythingOutside(cage, context)
        try cage.relaxAll(strength: 0.9, iterations: 8, pinned: pinned)

        #expect(
            cage.vertexPosition(11) == outsideBefore,
            "a vertex of the unselected patch must not move"
        )
    }

    /// No selection means the whole cage, which is the behaviour every batch
    /// command had before there was a selection at all.
    @Test func noSelectionPinsOnlyTheArtistsOwnPins() throws {
        let controller = MeshEditController()
        let cage = try grid(3)
        let context = self.context(cage, annotations: MeshAnnotations(pinnedVertices: [0, 1]))
        controller.contextProvider = { context }

        #expect(controller.holdingEverythingOutside(cage, context) == [0, 1])
    }

    /// A scoped triangulate leaves the unselected quads alone. It builds the
    /// triangles before deleting the quads they replace, because deleting
    /// compacts ids and would invalidate the ids being worked from.
    @Test func aScopedTriangulateLeavesTheRestQuad() throws {
        let cage = try grid(3)
        let all = cage.liveFaceIDs().sorted()
        let selected = Set(all.prefix(2))

        try MeshEditController.triangulate(selected, in: cage)

        let quads = try cage.stats().quads
        #expect(quads == 7, "the 7 unselected quads survive: \(quads)")
        #expect(cage.faceCount == 7 + 4, "each selected quad became two triangles")
    }

    /// Clearing pins inside the selection keeps the ones outside it.
    @Test func aScopedClearKeepsWhatIsOutside() throws {
        let annotations = MeshAnnotations(pinnedVertices: [1, 2, 3, 40, 41])
        let cleared = annotations.clearingPins(on: [1, 2, 3])
        #expect(cleared.pinnedVertices == [40, 41])
        // …and the unscoped clear still clears everything.
        #expect(annotations.clearingAllPins().pinnedVertices.isEmpty)
    }

    // MARK: - What refuses to scope

    @Test func subdivideAndHalveStayWholeCageAndSaySo() {
        #expect(!BatchCommand.subdivide.scopesToSelection)
        #expect(!BatchCommand.subdivideAndReproject.scopesToSelection)
        #expect(!BatchCommand.halve.scopesToSelection)
        for command in [BatchCommand.snapAllToTarget, .relaxAll, .triangulate, .clearPins] {
            #expect(command.scopesToSelection, "\(command.rawValue) can scope exactly")
        }
        // The notice names the reason, not just the fact.
        #expect(MeshEditController.wholeCageOnly(.halve).contains("hanging half-loop"))
        #expect(MeshEditController.wholeCageOnly(.subdivide).contains("n-gons"))
    }
}

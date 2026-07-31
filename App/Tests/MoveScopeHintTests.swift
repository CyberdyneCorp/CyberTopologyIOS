import Foundation
import Testing
@testable import CyberTopology

/// What the chip slot says during a drag (openspec add-context-aware-move;
/// spec: pencil-interaction / "The viewport names the scope before the drag
/// commits").
///
/// The scope turns on a distance as small as a third of a cell, so if it were
/// knowable only from the RESULT, a mis-pick would be discovered after the mesh
/// had already changed.
@MainActor
struct MoveScopeHintTests {
    @Test("a live Move drag names its scope, and the name clears when it ends")
    func scopeIsNamedThenCleared() {
        let model = ViewportInputModel()
        #expect(model.dragHint == nil)

        model.moveScopeChanged("Loop")
        #expect(model.dragHint == "Loop")

        model.moveScopeChanged(nil)
        #expect(model.dragHint == nil)
    }

    /// Both statements are true at once on a vertex drag held over a neighbour.
    /// "Merge" wins because it names an OUTCOME; the scope only names what is
    /// being carried.
    @Test("a merge outranks the scope, and the scope returns when it clears")
    func mergeOutranksTheScope() {
        let model = ViewportInputModel()
        model.moveScopeChanged("Vertex")
        #expect(model.dragHint == "Vertex")

        model.snapHighlightChanged(engaged: true)
        #expect(model.dragHint == "Merge")

        model.snapHighlightChanged(engaged: false)
        #expect(model.dragHint == "Vertex", "the scope must come back")
    }

    /// The scope names come from one place, so the hint and the journal verb
    /// can never disagree about what a drag carried.
    @Test("every scope has a name and a journal suffix")
    func scopeNamesAndSuffixes() {
        #expect(MeshEditController.MoveScope.vertex(0).hint == "Vertex")
        #expect(MeshEditController.MoveScope.loop([0, 1, 2], edge: 7, seed: 0).hint == "Loop")
        #expect(MeshEditController.MoveScope.surface(seed: 0).hint == "Surface")

        #expect(MeshEditController.MoveScope.vertex(0).verbSuffix == ".vertex")
        #expect(MeshEditController.MoveScope.loop([0, 1, 2], edge: 7, seed: 0).verbSuffix == ".loop")
        #expect(
            MeshEditController.MoveScope.surface(seed: 0).verbSuffix == "",
            "surface keeps the bare `move` verb so existing history keeps its meaning"
        )

        #expect(MeshEditController.MoveScope.vertex(0).mergesOnRelease)
        #expect(MeshEditController.MoveScope.surface(seed: 0).mergesOnRelease)
        #expect(!MeshEditController.MoveScope.loop([0, 1, 2], edge: 7, seed: 0).mergesOnRelease)
    }
}

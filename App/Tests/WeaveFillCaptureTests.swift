import CyberKit
import CyberKitTesting
import Testing
import simd

@testable import CyberTopology

/// Weave Fill capture (add-weave-region-selection, task 2): resolving a stroke into
/// an unexecuted fill request. Pure intent semantics — the solve is task 3.
@MainActor
@Suite("Weave fill capture")
struct WeaveFillCaptureTests {

    @Test("Every action has a gallery entry, including the new fill actions")
    func galleryCompleteness() {
        for action in EditorAction.allCases {
            #expect(!action.gallery.title.isEmpty, "\(action) has no title")
            #expect(!action.gallery.demoFrames.isEmpty, "\(action) has no demo frames")
            #expect(!action.gallery.notes.isEmpty, "\(action) has no notes")
        }
        // The help must say what the gesture IS, since there is no shape to guess.
        #expect(EditorAction.weaveFill.gallery.gesture.lowercased().contains("tap"))
        #expect(EditorAction.weaveFill.gallery.gesture.lowercased().contains("paint"))
        // …and must record why it is not a lasso, the way the retired entry does.
        #expect(EditorAction.weaveFill.gallery.notes.lowercased().contains("lasso"))
    }

    @Test("Weave Fill arms as a stroke tool, not a camera manipulator")
    func armsAsAStrokeTool() {
        #expect(EditorAction.weaveFill.tool == .weaveFill)
        #expect(RetopoTool.weaveFill.isCameraManipulator == false)
        // The clear is a command, not a tool.
        #expect(EditorAction.clearWeaveFill.tool == nil)
    }

    // MARK: - Intent semantics (pure, no engine)

    @Test("A tap REPLACES the request; it means fill here, not also here")
    func tapReplaces() {
        var intent = WeaveFillIntent(fillPoint: SIMD3(1, 0, 0), extent: [SIMD3(1, 0, 0)],
                                     isTap: false)
        #expect(!intent.wantsDefaultExtent)
        // What handleWeaveFillStroke does for a tap.
        intent = WeaveFillIntent(fillPoint: SIMD3(0, 5, 0), extent: [], isTap: true)
        #expect(intent.isTap)
        #expect(intent.wantsDefaultExtent, "a tap asks for the default band")
        #expect(intent.fillPoint == SIMD3(0, 5, 0))
    }

    @Test("Painting UNIONS into the extent and re-centres the fill direction")
    func paintAccumulates() {
        // Mirrors the accumulation handleWeaveFillStroke performs, which is the
        // property that matters: a second stroke extends the area AND steers which
        // stretch of cage boundary gets grown.
        var intent = WeaveFillIntent(fillPoint: SIMD3(0, 1, 0), extent: [SIMD3(0, 1, 0)],
                                     isTap: false)
        intent.extent.append(contentsOf: [SIMD3(0, 3, 0)])
        intent.fillPoint = MeshEditController.centroid(intent.extent) ?? intent.fillPoint
        #expect(intent.extent.count == 2)
        #expect(intent.fillPoint == SIMD3(0, 2, 0))
        #expect(!intent.wantsDefaultExtent)
    }

    @Test("centroid is nil for nothing and exact for a set")
    func centroidHelper() {
        #expect(MeshEditController.centroid([]) == nil)
        #expect(MeshEditController.centroid([SIMD3(1, 1, 1)]) == SIMD3(1, 1, 1))
        #expect(MeshEditController.centroid([SIMD3(0, 0, 0), SIMD3(2, 4, 6)]) == SIMD3(1, 2, 3))
    }
}

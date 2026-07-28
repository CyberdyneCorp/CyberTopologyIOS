import CyberKit
import Foundation
import Testing
import simd

@testable import CyberTopology

/// UV-only projects and the split-view layout (openspec add-uv-only-projects, 6.1a;
/// spec: document-model / "UV-only document without a Target" + uv-workflow / "Split-view UV
/// layout").
@MainActor
@Suite("UV-only projects and split layout")
struct UVOnlyProjectTests {
    private func writeCage() throws -> URL {
        var obj = ""
        for i in 0...2 {
            for j in 0...2 { obj += "v \(i) \(j) 0\n" }
        }
        for i in 0..<2 {
            for j in 0..<2 {
                let v = { (a: Int, b: Int) in a * 3 + b + 1 }
                obj += "f \(v(i, j)) \(v(i + 1, j)) \(v(i + 1, j + 1)) \(v(i, j + 1))\n"
            }
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("uvonly-\(UUID().uuidString).obj")
        try obj.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func document() throws -> TopoDocument {
        // A fileURL is required: TopoDocument() without one traps.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("uvonly-\(UUID().uuidString).cybertopo")
        return TopoDocument(fileURL: url)
    }

    // MARK: - The project type is DERIVED

    @Test("Importing a low-poly with no Target opens in the UV stage as ONE undo step")
    func uvOnlyImportOpensInUVStage() throws {
        let doc = try document()
        let cage = try writeCage()
        defer { try? FileManager.default.removeItem(at: cage) }
        #expect(doc.bundle.manifest.stage == .retopology)

        try doc.importUVOnlyProject(at: cage)

        #expect(doc.bundle.manifest.stage == .uv)
        #expect(doc.isUVOnlyProject)
        #expect(doc.bundle.manifest.objects.contains { $0.role == .editMesh })
        #expect(!doc.bundle.manifest.objects.contains { $0.role == .target })

        // ONE undo, not two. Two separate commands would leave an undo that removed the mesh
        // while stranding the document in a UV stage with nothing to unwrap.
        #expect(doc.bundle.journal.depth == 1)
        doc.undoLast()
        #expect(doc.bundle.manifest.stage == .retopology)
        #expect(doc.bundle.manifest.objects.isEmpty)
    }

    @Test("A UV-only project is derived from the objects, never stored")
    func projectTypeIsDerived() throws {
        let doc = try document()
        let cage = try writeCage()
        defer { try? FileManager.default.removeItem(at: cage) }

        #expect(!doc.isUVOnlyProject, "an empty document is not a UV-only project")
        try doc.importUVOnlyProject(at: cage)
        #expect(doc.isUVOnlyProject)

        // Adding a Target makes it stop being one — which a stored flag would not survive. This
        // is the same reasoning that keeps UDIM tiles derived from where an island's UVs are.
        try doc.importMesh(at: cage, role: .target)
        #expect(!doc.isUVOnlyProject)
    }

    @Test("Importing into a document ALREADY in the UV stage does not journal a no-op stage step")
    func alreadyInUVStageJournalsOnlyTheImport() throws {
        let doc = try document()
        let cage = try writeCage()
        defer { try? FileManager.default.removeItem(at: cage) }
        doc.perform(.setStage(from: .retopology, to: .uv))
        let depth = doc.bundle.journal.depth

        try doc.importUVOnlyProject(at: cage)
        #expect(doc.bundle.journal.depth == depth + 1)
        // A compound carrying setStage(.uv → .uv) would journal a step that changes nothing when
        // undone, which reads as a broken undo.
        doc.undoLast()
        #expect(doc.bundle.manifest.stage == .uv, "the stage was already UV and must stay")
    }

    @Test("UV features are functional with NO Target: unwrap and export both work")
    func uvFeaturesWorkWithoutATarget() throws {
        let doc = try document()
        let cage = try writeCage()
        defer { try? FileManager.default.removeItem(at: cage) }
        try doc.importUVOnlyProject(at: cage)

        // The 2D panel must describe the EditMesh, not report "no EditMesh" for want of a Target.
        guard case .notUnwrapped(let faceCount) = UVLayoutGeometry.state(inDocument: doc.bundle)
        else {
            Issue.record("expected .notUnwrapped for an imported, un-unwrapped cage")
            return
        }
        #expect(faceCount == 4)

        // And the unwrap itself: performed directly on the document's mesh, since the whole point
        // is that nothing in the UV path requires a Target.
        let object = try #require(doc.bundle.manifest.objects.first { $0.role == .editMesh })
        let mesh = try doc.bundle.mesh(for: object)
        _ = try mesh.unwrapInPlace()
        #expect(mesh.hasUVLayout)
        #expect(try mesh.udimTiles() == [1001])

        // Export must not require a Target either.
        let exported = try doc.exportEditMeshes()
        #expect(!exported.isEmpty)
        for url in exported { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: - Split layout

    private let size = CGSize(width: 1000, height: 800)

    /// Panel-LOCAL coordinates: the gesture lives on the panel, never on a container above the
    /// viewport, so the camera keeps every touch that starts over the 3D view.
    private let panel = CGSize(width: 400, height: 800)

    @Test("Pulling the panel IN maximizes it; pushing it AWAY maximizes the viewport")
    func swipeDirectionChoosesWhichPaneGrows() {
        #expect(
            UVSplitLayout.split.gesture(
                from: CGPoint(x: 380, y: 400), to: CGPoint(x: 100, y: 410), in: panel
            ) == .swipeFromPanelEdge
        )
        #expect(
            UVSplitLayout.split.gesture(
                from: CGPoint(x: 100, y: 400), to: CGPoint(x: 380, y: 410), in: panel
            ) == .swipePanelAway
        )
        #expect(UVSplitLayout.split.applying(.swipeFromPanelEdge) == .maximizedPanel)
        #expect(UVSplitLayout.split.applying(.swipePanelAway) == .maximizedViewport)
    }

    @Test("Every maximized state is REACHABLE and RECOVERABLE, so neither is a dead end")
    func noMaximizedStateIsADeadEnd() {
        // Reachable.
        let toPanel = UVSplitLayout.split.applying(.swipeFromPanelEdge)
        let toViewport = UVSplitLayout.split.applying(.swipePanelAway)
        #expect(toPanel == .maximizedPanel)
        #expect(toViewport == .maximizedViewport)

        // And recoverable. The panel keeps a grab STRIP when the viewport is maximized precisely
        // so its gesture surface survives — a hidden panel would make that state enterable with
        // one swipe and impossible to leave.
        #expect(UVSplitLayout.grabStripWidth > 0)
        #expect(toPanel.applying(.lineDownDivider) == .split)
        #expect(toViewport.applying(.swipeFromPanelEdge) == .maximizedPanel)
        for state in UVSplitLayout.allCases where state != .split {
            #expect(
                UVSplitLayout.Gesture.allPathsBackToSplit.contains { state.applying($0) != state },
                "\(state.rawValue) must have a way out"
            )
        }
    }

    @Test("A divider line restores the split — but ONLY when a pane is maximized")
    func dividerLineOnlyRestores() {
        let start = CGPoint(x: 200, y: 200)
        let end = CGPoint(x: 205, y: 600)

        // In `.split` the screen middle lies over the 3D VIEWPORT, whose finger drags orbit the
        // camera. Claiming the drag there would make an orbit ambiguous, so it is declined — and
        // there is nothing to restore anyway.
        #expect(UVSplitLayout.split.gesture(from: start, to: end, in: panel) == nil)

        // Maximized, the middle is over the 2D panel, which has no camera gesture.
        #expect(
            UVSplitLayout.maximizedPanel.gesture(from: start, to: end, in: panel)
                == .lineDownDivider
        )
        #expect(UVSplitLayout.maximizedPanel.applying(.lineDownDivider) == .split)
    }

    @Test("A gesture that would not change the layout is DECLINED, not swallowed")
    func noOpGesturesAreDeclined() {
        // Already maximized: claiming the swipe would consume a drag some other recognizer could
        // legitimately use.
        #expect(
            UVSplitLayout.maximizedPanel.gesture(
                from: CGPoint(x: 380, y: 400), to: CGPoint(x: 100, y: 400), in: panel
            ) == nil
        )
    }

    @Test("A diagonal smudge resolves to NOTHING rather than to whichever test ran first")
    func diagonalsAreRejected() {
        // Equal travel on both axes: neither gesture dominates, so neither fires.
        #expect(
            UVSplitLayout.classify(
                from: CGPoint(x: 380, y: 100), to: CGPoint(x: 100, y: 380), in: panel
            ) == nil
        )
    }

    @Test("A short drag and a degenerate size fire nothing")
    func shortAndDegenerateDragsAreIgnored() {
        // Under the travel threshold.
        #expect(
            UVSplitLayout.classify(
                from: CGPoint(x: 380, y: 400), to: CGPoint(x: 370, y: 400), in: panel
            ) == nil
        )
        #expect(
            UVSplitLayout.classify(
                from: CGPoint(x: 380, y: 400), to: CGPoint(x: 100, y: 400), in: .zero
            ) == nil
        )
    }

    @Test("A vertical drag on the panel while split is left to the panel's own gestures")
    func verticalDragWhileSplitIsNotClaimed() {
        // The 2D island grammar owns vertical drags on an island. The layout gesture must not
        // swallow them, or dragging an island would resize the pane instead.
        #expect(
            UVSplitLayout.split.gesture(
                from: CGPoint(x: 200, y: 200), to: CGPoint(x: 205, y: 600), in: panel
            ) == nil
        )
    }

    @Test("The split fraction leaves the 3D view the larger share")
    func splitFavoursTheModel() {
        // The model is what an artist looks at while judging a layout; the panel is a reference
        // beside it.
        #expect(UVSplitLayout.split.panelWidthFraction < 0.5)
        #expect(UVSplitLayout.maximizedViewport.panelWidthFraction == 0)
    }
}

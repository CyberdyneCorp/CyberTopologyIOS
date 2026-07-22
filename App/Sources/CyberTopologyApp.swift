import SwiftUI

@main
struct CyberTopologyApp: App {
    init() {
        UITestSupport.resetStateIfRequested(arguments: ProcessInfo.processInfo.arguments)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// UI-test hooks. `-UITestResetState` gives each UI test a clean slate:
/// no recovery journal and no leftover documents. `-UITestOpenDocument`
/// opens (creating if needed) a fixed document at launch, bypassing the
/// system browser chrome, which hides custom bar buttons in an overflow
/// menu on some iPadOS versions and is too fragile to drive from XCUITest.
enum UITestSupport {
    static let resetArgument = "-UITestResetState"
    static let openDocumentArgument = "-UITestOpenDocument"
    /// With `openDocumentArgument`: imports a small EditMesh into the test
    /// document so object-list / export flows are drivable from XCUITest
    /// (the Files picker is system UI and cannot be automated).
    static let seedEditMeshArgument = "-UITestSeedEditMesh"
    /// With `openDocumentArgument`: imports a two-quad strip (middle edge
    /// under the viewport center) as the EditMesh, so the task-3.5 chip UI
    /// test can draw the genuinely AMBIGUOUS stroke of the spec — along
    /// the middle edge: tag loop applied, insert loop as the alternative.
    static let seedEditMeshStripArgument = "-UITestSeedEditMeshStrip"
    /// With `openDocumentArgument`: imports a domed grid as the Target so
    /// verb flows (task 3.3) have a surface to snap onto.
    static let seedTargetArgument = "-UITestSeedTarget"
    /// Shows the "Draw Test Quad" injection button (task 3.3): XCUITest
    /// cannot synthesize a multi-segment single-touch polyline, so the
    /// end-to-end quad-draw UI test replays the committed square fixture
    /// through the real capture → recognizer → verb pipeline.
    static let strokeInjectionArgument = "-UITestStrokeInjection"
    /// Auto-injects the square stroke ~2 s after the editor appears (the
    /// visual-verification screenshot hook — no XCUITest driver needed).
    static let autoDrawQuadArgument = "-UITestAutoDrawQuad"
    /// Same hook for the one-stroke grid gesture (task 3.4).
    static let autoDrawGridArgument = "-UITestAutoDrawGrid"
    /// Same hook for the ambiguous ring-insert stroke (task 3.5: the
    /// interpretation chip with its alternatives in the screenshot).
    static let autoDrawRingArgument = "-UITestAutoDrawRing"
    /// Hover-preview screenshot hooks (task 3.6): after the auto-draw
    /// settles, scan the viewport for a hover point whose preview is the
    /// slide-loop highlight / the ghost-quad hint and lock it (the
    /// simulator cannot synthesize Pencil hover; the probe drives the SAME
    /// controller the hover recognizer feeds).
    static let autoHoverLoopArgument = "-UITestAutoHoverLoop"
    static let autoHoverGhostArgument = "-UITestAutoHoverGhost"
    /// Shows the Pencil Pro quick-verb palette shortly after the editor
    /// appears (task 3.7): the simulator cannot synthesize a squeeze, so
    /// the UI test and the screenshot hook drive the same model entry the
    /// `UIPencilInteraction` delegate calls on hardware.
    static let showQuickVerbPaletteArgument = "-UITestShowQuickVerbPalette"
    /// Begins a real Tweak drag that parks one EditMesh vertex within
    /// merge range of another and leaves the stroke in flight (task 3.7):
    /// the snap-target pre-highlight is visible for the screenshot.
    static let autoSnapDragArgument = "-UITestAutoSnapDrag"
    /// Presents the Action Gallery shortly after the editor appears
    /// (task 3.8 screenshot hook — the same presentation the toolbar's
    /// gallery button drives).
    static let showActionGalleryArgument = "-UITestShowActionGallery"
    /// With `openDocumentArgument`: imports a two-quad strip PRE-SNAPPED
    /// onto the seeded dome Target (task 4.1) — the build tools pick
    /// vertices/edges through Target raycasts, so a flat z=0 strip under
    /// the domed Target would sit outside pick range everywhere but the
    /// dome's rim.
    static let seedEditMeshOnDomeArgument = "-UITestSeedEditMeshOnDome"
    /// Arms a task-4.1 build tool ~2 s after the editor appears and drives
    /// one real probe stroke computed from the live mesh and camera (the
    /// simulator cannot synthesize Pencil drags). Value form:
    /// `-UITestAutoTool buildQuad` (a `RetopoTool` raw value, read through
    /// UserDefaults argument parsing).
    static let autoToolArgument = "UITestAutoTool"

    static var openDocumentRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(openDocumentArgument)
    }

    static var seedEditMeshRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(seedEditMeshArgument)
    }

    static var seedEditMeshStripRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(seedEditMeshStripArgument)
    }

    static var seedTargetRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(seedTargetArgument)
    }

    static var strokeInjectionRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(strokeInjectionArgument)
    }

    static var autoDrawQuadRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(autoDrawQuadArgument)
    }

    static var autoDrawGridRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(autoDrawGridArgument)
    }

    static var autoDrawRingRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(autoDrawRingArgument)
    }

    /// Annotation screenshot hook (task 4.3): pins an edge loop and tags
    /// a DIFFERENT loop in a non-default palette colour, so one screenshot
    /// shows both the yellow pin markers and a coloured tagged loop.
    static let autoAnnotationsArgument = "-UITestAutoAnnotations"

    static var autoAnnotationsRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(autoAnnotationsArgument)
    }

    /// Symmetry screenshot hook (task 4.4): turns X mirroring on through
    /// the real journaled `setSymmetry` command (so the plane rim renders)
    /// and authors ONE quad through the real create path, which the
    /// symmetry replay mirrors inside the same journal entry — one frame
    /// showing the rim, the authored quad and its mirror image.
    static let autoSymmetryArgument = "-UITestAutoSymmetry"

    static var autoSymmetryRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(autoSymmetryArgument)
    }

    /// Batch-panel screenshot hook (task 4.5): presents the batch-commands
    /// sheet a moment after the editor appears (the same presentation the
    /// toolbar's `batchCommands` action drives).
    static let showBatchCommandsArgument = "-UITestShowBatchCommands"

    static var showBatchCommandsRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(showBatchCommandsArgument)
    }

    /// Runs subdivide+reproject on the seeded cage through the real
    /// journaled batch path (task 4.5 screenshot hook: a visibly denser
    /// wireframe still wrapped on the Target).
    static let autoSubdivideArgument = "-UITestAutoSubdivide"

    static var autoSubdivideRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(autoSubdivideArgument)
    }

    /// Turns the Auto Relax MODE on before the other authoring hooks run
    /// (task 4.5), so an injected stroke exercises the real
    /// create → auto-relax → ONE journal entry path.
    static let autoRelaxArgument = "-UITestAutoRelax"

    static var autoRelaxRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(autoRelaxArgument)
    }

    static var autoHoverLoopRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(autoHoverLoopArgument)
    }

    static var autoHoverGhostRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(autoHoverGhostArgument)
    }

    static var showQuickVerbPaletteRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(showQuickVerbPaletteArgument)
    }

    static var autoSnapDragRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(autoSnapDragArgument)
    }

    static var showActionGalleryRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(showActionGalleryArgument)
    }

    /// Seeds a 4x4-quad cage ON the dome Target (task 4.3): unlike the
    /// 1-quad / 2-quad seeds it has several DISJOINT interior edge loops,
    /// which is what the pin-loop and loop-tag hooks need to demonstrate.
    static let seedEditMeshGridArgument = "-UITestSeedEditMeshGrid"

    static var seedEditMeshGridRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(seedEditMeshGridArgument)
    }

    /// 4x4-quad cage draped on the same dome the seed Target uses.
    static func writeSeedDomeGridOBJ() throws -> URL {
        let n = 4
        var obj = ""
        for row in 0...n {
            for col in 0...n {
                let x = Double(col) / Double(n) * 1.2 - 0.6
                let y = Double(row) / Double(n) * 1.2 - 0.6
                let z = 0.45 * (1 - 0.5 * (x * x + y * y))
                obj += "v \(x) \(y) \(z)\n"
            }
        }
        for row in 0..<n {
            for col in 0..<n {
                let a = row * (n + 1) + col + 1
                obj += "f \(a) \(a + 1) \(a + n + 2) \(a + n + 1)\n"
            }
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("seed-dome-grid.obj")
        try obj.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static var seedEditMeshOnDomeRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(seedEditMeshOnDomeArgument)
    }

    /// The build tool requested via `-UITestAutoTool <rawValue>`, if any.
    static var autoToolRequested: RetopoTool? {
        UserDefaults.standard.string(forKey: autoToolArgument)
            .flatMap(RetopoTool.init(rawValue:))
    }

    /// Minimal colored quad used by the seed hook.
    static func writeSeedOBJ() throws -> URL {
        let obj = """
        v 0 0 0 1 0 0
        v 1 0 0 0 1 0
        v 1 1 0 0 0 1
        v 0 1 0 1 1 1
        f 1 2 3 4
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("seed-quad.obj")
        try obj.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Two-quad strip sharing the vertical middle edge (x = 0.5): after
    /// frame-to-fit that edge projects onto the vertical center line —
    /// exactly under the committed ring-insert stroke, making the stroke
    /// ambiguous (along the edge AND crossing it): tag loop best, insert
    /// loop ranked as the one-tap alternative (task 3.5).
    static func writeSeedStripOBJ() throws -> URL {
        let obj = """
        v 0 0 0 1 0 0
        v 0.5 0 0 0 1 0
        v 1 0 0 0 0 1
        v 0 1 0 1 1 0
        v 0.5 1 0 0 1 1
        v 1 1 0 1 0 1
        f 1 2 5 4
        f 2 3 6 5
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("seed-strip.obj")
        try obj.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Two-quad strip PRE-SNAPPED onto the seed dome (task 4.1 tool
    /// hooks): every strip vertex sits ON the Target surface, so the build
    /// tools' Target-raycast picks resolve anywhere on the strip.
    static func writeSeedDomeStripOBJ() throws -> URL {
        var obj = ""
        for y in [-0.25, 0.25] {
            for x in [-0.5, 0.0, 0.5] {
                let z = 0.45 * (1 - 0.5 * (x * x + y * y))
                obj += "v \(x) \(y) \(z)\n"
            }
        }
        obj += "f 1 2 5 4\nf 2 3 6 5\n"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("seed-dome-strip.obj")
        try obj.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Gently domed 10x10-quad grid used by the seed-target hook: a real
    /// curved surface, so snapped EditMesh vertices land visibly OFF the
    /// z=0 plane (verbs must project onto the Target, not just keep z).
    static func writeSeedTargetOBJ() throws -> URL {
        let n = 10
        var obj = ""
        for row in 0...n {
            for col in 0...n {
                let x = Double(col) / Double(n) * 2 - 1
                let y = Double(row) / Double(n) * 2 - 1
                let z = 0.45 * (1 - 0.5 * (x * x + y * y))
                obj += "v \(x) \(y) \(z) 0.55 0.58 0.65\n"
            }
        }
        for row in 0..<n {
            for col in 0..<n {
                let a = row * (n + 1) + col + 1
                let b = a + 1
                let c = a + n + 2
                let d = a + n + 1
                obj += "f \(a) \(b) \(c) \(d)\n"
            }
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("seed-target.obj")
        try obj.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Fixed URL for the auto-opened test document.
    static var testDocumentURL: URL {
        URL.documentsDirectory
            .appendingPathComponent("UITest Document")
            .appendingPathExtension(TopoDocument.fileExtension)
    }

    static func resetStateIfRequested(
        arguments: [String],
        journalURL: URL = RecoveryJournal.defaultStoreURL(),
        documentsDirectory: URL = .documentsDirectory
    ) {
        guard arguments.contains(resetArgument) else { return }
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: journalURL)
        // Toolbar customization persists in UserDefaults (task 3.8);
        // clean-slate launches reset it so every UI test starts from the
        // default layout (the persistence UI test relaunches WITHOUT
        // reset to prove restoration).
        UserDefaults.standard.removeObject(forKey: ToolbarStore.defaultsKey)
        // Auto Relax is a persisted MODE (task 4.5): a clean-slate launch
        // must come up with it off, or an unrelated UI test would author
        // under a relax pass it never asked for.
        UserDefaults.standard.removeObject(forKey: ViewportSettings.autoRelaxKey)
        // Subdivision preview is a persisted DISPLAY level (task 4.6): a
        // clean-slate launch must come up with it off, or an unrelated UI
        // test would screenshot a smoothed surface over its cage. Tests
        // that WANT a preview pass `-subdivisionPreviewLevel <0|1|2>`,
        // which lands in the argument domain and therefore outranks this
        // removal from the app domain.
        UserDefaults.standard.removeObject(forKey: ViewportSettings.subdivisionPreviewKey)
        let contents = (try? fileManager.contentsOfDirectory(
            at: documentsDirectory, includingPropertiesForKeys: nil
        )) ?? []
        for url in contents where url.pathExtension == TopoDocument.fileExtension {
            try? fileManager.removeItem(at: url)
        }
    }
}

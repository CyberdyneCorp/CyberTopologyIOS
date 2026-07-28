import Testing

@testable import CyberTopology

/// Toolbar slot ROUTING — that an action assigned to a slot actually runs.
///
/// This exists because `.autoRetopo` was a dead button for its whole life. It is a command
/// with no `tool`, and it was missing from `isImmediateCommand`, so `ActionToolbarView`
/// routed it to `gestureActionButton` — whose entire body is `onOpenGallery(action)`.
/// Tapping a slot holding Phase 5's headline action opened the help panel and never ran the
/// solve, even though `ViewportInputModel.runCommand` had a working `case .autoRetopo`
/// throughout. It stayed reachable through dedicated affordances in `DocumentEditorView`,
/// which is exactly why nobody noticed.
///
/// So this asserts the ROUTING INVARIANT generally rather than pinning one action: any
/// action `runCommand` can execute must be reachable from a slot. Pinning `.autoRetopo`
/// alone would let the next command-shaped action repeat the bug.
@MainActor
@Suite("Toolbar slot routing")
struct ToolbarRoutingTests {
    /// Every action `ViewportInputModel.runCommand` handles.
    ///
    /// Maintained by hand deliberately: deriving it from `isImmediateCommand` would make
    /// the test tautological, which is how the original bug survived. Adding a `runCommand`
    /// case without adding it here leaves the new action unprotected, so the list is short
    /// and the reason to extend it is obvious.
    private static let runnable: [EditorAction] = [
        .clearPins, .clearLoopTags, .clearFrozen, .toggleLoopInfoPin, .outliner,
        .toggleSymmetry, .applySymmetry, .resymmetrize, .toggleAutoRelax, .batchCommands,
        .autoRetopo, .unwrapUVs,
    ]

    @Test("Every runnable command is reachable from a toolbar slot")
    func runnableCommandsAreReachable() {
        for action in Self.runnable {
            // ActionToolbarView routes: verb -> VerbButton, tool -> ToolButton,
            // isImmediateCommand -> CommandButton (the ONLY thing that calls runCommand),
            // else -> gestureActionButton, which merely opens the gallery.
            #expect(
                action.isImmediateCommand,
                "\(action.rawValue) is runnable but not immediate — its slot would only open help"
            )
            #expect(action.verb == nil, "\(action.rawValue) would route to VerbButton instead")
            #expect(action.tool == nil, "\(action.rawValue) would route to ToolButton instead")
        }
    }

    @Test("Auto-Retopo specifically is reachable, since it was not")
    func autoRetopoIsReachable() {
        // The regression this file was written for. Kept as its own case so a failure names
        // the action rather than pointing at a loop.
        #expect(EditorAction.autoRetopo.isImmediateCommand)
        #expect(EditorAction.autoRetopo.tool == nil)
        #expect(!EditorAction.autoRetopo.gallery.title.isEmpty)
    }

    @Test("An action that arms a tool is NOT also marked immediate")
    func toolsAreNotImmediate() {
        // The opposite failure: a tool marked immediate would render a CommandButton and
        // never arm, so the routing branches have to stay mutually exclusive.
        for action in EditorAction.allCases where action.tool != nil {
            #expect(
                !action.isImmediateCommand,
                "\(action.rawValue) arms a tool AND claims to be immediate"
            )
        }
    }

    @Test("A verb action is neither a tool nor immediate")
    func verbsAreNeitherToolsNorCommands() {
        for action in EditorAction.allCases where action.verb != nil {
            #expect(action.tool == nil, "\(action.rawValue) is both a verb and a tool")
            #expect(!action.isImmediateCommand, "\(action.rawValue) is both a verb and immediate")
        }
    }
}

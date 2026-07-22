import SwiftUI

/// Customizable slot toolbar (task 3.8, spec: pencil-interaction /
/// "Customizable toolbar and Action Gallery"). Replaces the 3.1 minimal
/// verb bar and HOSTS its semantics: verb slots keep the spring-loaded
/// hold-chord behavior (quick tap selects persistently, holding switches
/// for the duration of the hold — spec "Hold-chord spring-loaded
/// modifiers"), gesture-action slots open the Action Gallery focused on
/// that action's help panel (gestures are drawn, not tapped), and empty
/// slots open the gallery for assignment. The slot scheme is documented on
/// `ToolbarConfiguration`.
///
/// Slots are also live drop destinations, so an action dragged out of the
/// gallery (when it is presented non-modally, e.g. a popover on wide
/// layouts) can land here directly; the gallery's own slot strip mirrors
/// this configuration for drag work fully inside the sheet.
///
/// Below the slots: the Action Gallery button. (Authoring is Pencil-only —
/// fingers never author, task 3.9 — so there is no finger draw-mode
/// toggle.)
struct ActionToolbarView: View {
    let model: ViewportInputModel
    let toolbar: ToolbarModel
    /// Opens the Action Gallery, optionally focused on one action.
    let onOpenGallery: (EditorAction?) -> Void

    var body: some View {
        VStack(spacing: 6) {
            ForEach(0..<ToolbarConfiguration.slotCount, id: \.self) { slot in
                slotView(slot)
                    .dropDestination(for: String.self) { items, _ in
                        guard let payload = items.first else { return false }
                        toolbar.handleDrop(payload, onSlot: slot)
                        return true
                    }
            }
            Divider()
                .frame(width: 32)
            galleryButton
        }
        .padding(6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func slotView(_ slot: Int) -> some View {
        switch toolbar.configuration.action(at: slot) {
        case .some(let action):
            if let verb = action.verb {
                VerbButton(verb: verb, model: model)
            } else if let tool = action.tool {
                ToolButton(tool: tool, action: action, model: model)
            } else if action.isImmediateCommand {
                CommandButton(action: action, model: model)
            } else {
                gestureActionButton(action)
            }
        case .none:
            emptySlot(slot)
        }
    }

    /// A gesture-grammar action's slot: a quick reference that opens the
    /// gallery on its help panel (the action itself is performed by
    /// drawing the gesture with the Pencil verb).
    private func gestureActionButton(_ action: EditorAction) -> some View {
        Button {
            onOpenGallery(action)
        } label: {
            Image(systemName: action.gallery.symbol)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 40, height: 40)
                .foregroundStyle(.primary)
        }
        .accessibilityLabel("\(action.gallery.title) help")
        .accessibilityIdentifier("toolbar-action-\(action.rawValue)")
    }

    private func emptySlot(_ slot: Int) -> some View {
        Button {
            onOpenGallery(nil)
        } label: {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    .secondary.opacity(0.35),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                )
                .frame(width: 40, height: 40)
        }
        .accessibilityLabel("Empty toolbar slot")
        .accessibilityIdentifier("toolbar-slot-empty-\(slot)")
    }

    private var galleryButton: some View {
        Button {
            onOpenGallery(nil)
        } label: {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 17, weight: .medium))
                .frame(width: 40, height: 40)
                .foregroundStyle(.secondary)
        }
        .accessibilityLabel("Action Gallery")
        .accessibilityIdentifier("action-gallery-button")
    }
}

/// One verb slot with the 3.1 hold-chord semantics. Press tracking uses a
/// zero-distance drag gesture so the press-down instant spring-loads the
/// verb (a SwiftUI `Button` action only fires on release, too late for
/// hold-chords).
///
/// The pressed flag is `@GestureState`, NOT `@State` + `onEnded`: SwiftUI
/// resets gesture state even when the system CANCELS the gesture (incoming
/// alert, backgrounding, a competing gesture winning), whereas `onEnded`
/// never fires on cancellation. The `onChange(of:)` below therefore always
/// delivers the balancing `verbPressEnded` — a cancelled hold can never
/// leave the arbiter's spring-loaded verb latched.
private struct VerbButton: View {
    let verb: InputArbiter.Verb
    let model: ViewportInputModel

    @GestureState private var isPressed = false

    var body: some View {
        Image(systemName: verb.systemImage)
            .font(.system(size: 17, weight: .medium))
            .frame(width: 40, height: 40)
            .foregroundStyle(model.activeVerb == verb ? Color.accentColor : .primary)
            .background(
                model.activeVerb == verb ? Color.accentColor.opacity(0.25) : .clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .contentShape(Rectangle())
            .gesture(pressGesture)
            .onChange(of: isPressed) { _, pressed in
                if pressed {
                    model.verbPressBegan(verb)
                } else {
                    model.verbPressEnded(verb)
                }
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(verb.rawValue.capitalized)
            .accessibilityIdentifier("verb-\(verb.rawValue)")
            .accessibilityValue(model.activeVerb == verb ? "active" : "inactive")
    }

    private var pressGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($isPressed) { _, state, _ in state = true }
    }
}

/// One retopology-tool slot (task 4.1): tap arms the tool — Pencil strokes
/// then drive it instead of the gesture grammar until a verb is selected.
/// Highlighted only while BOTH the tool is armed and the Pencil verb is
/// active (a spring-loaded verb hold visibly takes over, then restores).
private struct ToolButton: View {
    let tool: RetopoTool
    let action: EditorAction
    let model: ViewportInputModel

    private var isActive: Bool {
        model.activeTool == tool && model.activeVerb == .pencil
    }

    var body: some View {
        Button {
            model.selectTool(tool)
        } label: {
            Image(systemName: action.gallery.symbol)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 40, height: 40)
                .foregroundStyle(isActive ? Color.accentColor : .primary)
                .background(
                    isActive ? Color.accentColor.opacity(0.25) : .clear,
                    in: RoundedRectangle(cornerRadius: 8)
                )
        }
        .accessibilityLabel(action.gallery.title)
        .accessibilityIdentifier("tool-\(action.rawValue)")
        .accessibilityValue(isActive ? "active" : "inactive")
    }
}

/// One immediate-command slot (task 4.3): tap RUNS the command (clear
/// pins / clear loop tags) instead of arming anything. Each run journals
/// exactly one `annotationEdit`, so one undo restores it.
private struct CommandButton: View {
    let action: EditorAction
    let model: ViewportInputModel

    var body: some View {
        // Toggle-style commands (task 4.5's Auto Relax mode) read their
        // on/off state back so the slot shows it; one-shot commands are
        // always "inactive".
        let isActive = model.isCommandActive(action)
        Button {
            model.runCommand(action)
        } label: {
            Image(systemName: action.gallery.symbol)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 40, height: 40)
                .foregroundStyle(isActive ? Color.accentColor : .primary)
                .background(
                    isActive ? Color.accentColor.opacity(0.25) : .clear,
                    in: RoundedRectangle(cornerRadius: 8)
                )
        }
        .accessibilityLabel(action.gallery.title)
        .accessibilityIdentifier("command-\(action.rawValue)")
        .accessibilityValue(isActive ? "active" : "inactive")
    }
}

extension InputArbiter.Verb {
    /// The verb's `EditorAction` (gallery entry, toolbar glyph).
    var editorAction: EditorAction {
        switch self {
        case .pencil: .pencil
        case .relax: .relax
        case .move: .move
        case .tweak: .tweak
        case .erase: .erase
        }
    }

    /// Toolbar/palette glyph, from the shared Action Gallery catalog.
    var systemImage: String { editorAction.gallery.symbol }
}

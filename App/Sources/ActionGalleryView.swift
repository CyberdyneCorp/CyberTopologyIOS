import SwiftUI

/// Action Gallery sheet (task 3.8, spec: pencil-interaction /
/// "Customizable toolbar and Action Gallery"): every action — the five
/// verbs plus the full 3.4 gesture grammar — with a help panel (title,
/// gesture, usage notes, demo-media slot) and the toolbar-slot editor.
///
/// Customization surfaces (slot scheme on `ToolbarConfiguration`):
///   - DRAG an action tile onto a slot in the strip below the help panel:
///     empty slot assigns, occupied slot replaces (an action already
///     placed elsewhere moves).
///   - DRAG a slot's occupant off the strip onto the action-tile area to
///     remove it.
///   - DOUBLE-TAP an action tile to quick-assign (first empty slot; a
///     full toolbar replaces the last slot).
///   - TAP path (also the XCUITest path — it cannot synthesize drags
///     between SwiftUI drop destinations): tap a tile to select it in the
///     help panel, tap a slot to assign the selected action there; the
///     minus button under an occupied slot removes it.
///
/// The live toolbar (`ActionToolbarView`) renders this same configuration
/// and every change persists immediately (`ToolbarStore`, spec scenario
/// "Toolbar persistence").
///
/// Identifiers sit on leaf views only (container-identifier accessibility
/// trap), and the tile grid is deliberately NON-lazy: 21 fixed tiles cost
/// nothing, and every tile exists in the accessibility tree without
/// scrolling, which the UI tests rely on.
struct ActionGalleryView: View {
    let toolbar: ToolbarModel
    @State var selected: EditorAction
    @Environment(\.dismiss) private var dismiss

    /// Tiles per grid row.
    private static let columns = 4

    init(toolbar: ToolbarModel, focus: EditorAction?) {
        self.toolbar = toolbar
        _selected = State(initialValue: focus ?? .pencil)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    helpPanel
                    slotStrip
                    actionTiles
                }
                .padding()
            }
            .navigationTitle("Action Gallery")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("gallery-done")
                }
            }
        }
    }

    // MARK: - Help panel

    private var helpPanel: some View {
        let entry = selected.gallery
        return HStack(alignment: .top, spacing: 14) {
            ActionDemoView(frames: entry.demoFrames)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title)
                    .font(.title3.weight(.semibold))
                    .accessibilityIdentifier("gallery-help-title")
                Text(entry.gesture)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityIdentifier("gallery-help-gesture")
                Text(entry.notes)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("gallery-help-notes")
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Slot strip (the toolbar editor)

    private var slotStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Toolbar slots")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                ForEach(0..<ToolbarConfiguration.slotCount, id: \.self) { slot in
                    slotCell(slot)
                }
                Spacer(minLength: 0)
            }
            Text("Drag an action into a slot, drag it off to remove, or "
                + "double-tap an action to quick-assign. Tap a slot to "
                + "place the selected action.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func slotCell(_ slot: Int) -> some View {
        let action = toolbar.configuration.action(at: slot)
        return VStack(spacing: 4) {
            Button {
                // Tap path: place the selected action here.
                toolbar.assign(selected, to: slot)
            } label: {
                slotLabel(action)
            }
            .accessibilityIdentifier("gallery-slot-\(slot)")
            .accessibilityLabel("Toolbar slot \(slot + 1)")
            .accessibilityValue(action?.rawValue ?? "empty")
            .ifLet(action) { view, action in
                // Drag-off-remove / drag-between-slots source.
                view.draggable(ToolbarDragPayload.slot(slot).string) {
                    Image(systemName: action.gallery.symbol)
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: 44, height: 44)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .dropDestination(for: String.self) { items, _ in
                guard let payload = items.first else { return false }
                toolbar.handleDrop(payload, onSlot: slot)
                return true
            }

            if action != nil {
                Button {
                    toolbar.remove(at: slot)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Remove from slot \(slot + 1)")
                .accessibilityIdentifier("gallery-slot-remove-\(slot)")
            } else {
                // Keep the strip height stable.
                Color.clear.frame(width: 14, height: 14)
            }
        }
    }

    @ViewBuilder
    private func slotLabel(_ action: EditorAction?) -> some View {
        if let action {
            Image(systemName: action.gallery.symbol)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 44, height: 44)
                .foregroundStyle(.primary)
                .background(
                    Color.accentColor.opacity(0.15),
                    in: RoundedRectangle(cornerRadius: 8)
                )
        } else {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    .secondary.opacity(0.35),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                )
                .frame(width: 44, height: 44)
        }
    }

    // MARK: - Action tiles

    private var actionTiles: some View {
        let rows = EditorAction.allCases.chunked(into: Self.columns)
        return VStack(alignment: .leading, spacing: 10) {
            Text("All actions")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 10) {
                    ForEach(row, id: \.self) { action in
                        actionTile(action)
                    }
                }
            }
        }
        // Drag-off-remove: a slot occupant dropped anywhere over the tile
        // area leaves the toolbar.
        .dropDestination(for: String.self) { items, _ in
            guard let payload = items.first else { return false }
            toolbar.handleDrop(payload, onSlot: nil)
            return true
        }
    }

    private func actionTile(_ action: EditorAction) -> some View {
        let entry = action.gallery
        let isSelected = action == selected
        let assignedSlot = toolbar.configuration.slot(of: action)
        return VStack(spacing: 4) {
            Image(systemName: entry.symbol)
                .font(.system(size: 20, weight: .medium))
                .frame(height: 26)
            Text(entry.title)
                .font(.caption2)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(assignedSlot.map { "slot \($0 + 1)" } ?? " ")
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
        }
        .frame(width: 76, height: 66)
        .background(
            isSelected ? Color.accentColor.opacity(0.2) : Color.clear,
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    isSelected ? Color.accentColor : .secondary.opacity(0.25),
                    lineWidth: isSelected ? 1.5 : 1
                )
        )
        .contentShape(Rectangle())
        // Double-tap quick-assign must be attached BEFORE the single-tap
        // selection so both gestures coexist (SwiftUI resolves the pair).
        .onTapGesture(count: 2) {
            selected = action
            toolbar.quickAssign(action)
        }
        .onTapGesture { selected = action }
        .draggable(ToolbarDragPayload.action(action).string) {
            Image(systemName: entry.symbol)
                .font(.system(size: 20, weight: .medium))
                .frame(width: 44, height: 44)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(entry.title)
        .accessibilityValue(isSelected ? "selected" : "unselected")
        .accessibilityIdentifier("gallery-action-\(action.rawValue)")
    }
}

/// The help panel's demo-media slot: a looping SF-symbol frame animation
/// sketching the gesture, honestly labeled as a placeholder — recording
/// real per-action demo videos is tutorial content (task 9.1); see the
/// scope note on `ActionCatalog`. When the recordings land, this view
/// swaps the frame loop for a looping player without changing callers.
struct ActionDemoView: View {
    let frames: [String]
    /// Seconds per frame; injectable so previews/tests can freeze it.
    var frameDuration: TimeInterval = 0.8

    var body: some View {
        VStack(spacing: 4) {
            TimelineView(.periodic(from: .now, by: frameDuration)) { context in
                let tick = Int(
                    context.date.timeIntervalSinceReferenceDate / frameDuration
                )
                Image(systemName: frames[tick % max(frames.count, 1)])
                    .font(.system(size: 34, weight: .light))
                    .frame(width: 84, height: 84)
                    .foregroundStyle(Color.accentColor)
                    .background(
                        .quaternary.opacity(0.6),
                        in: RoundedRectangle(cornerRadius: 10)
                    )
                    .contentTransition(.symbolEffect(.replace))
                    .animation(.easeInOut(duration: 0.25), value: tick)
            }
            Text("Preview — demo video with tutorials")
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
                .accessibilityIdentifier("gallery-demo-placeholder")
        }
    }
}

extension Collection {
    /// Fixed-size rows for the non-lazy tile grid.
    func chunked(into size: Int) -> [[Element]] {
        var rows: [[Element]] = []
        var row: [Element] = []
        for element in self {
            row.append(element)
            if row.count == size {
                rows.append(row)
                row = []
            }
        }
        if !row.isEmpty { rows.append(row) }
        return rows
    }
}

extension View {
    /// Applies `transform` when `value` is non-nil (conditional
    /// `.draggable` — an empty slot must not be a drag source).
    @ViewBuilder
    fileprivate func ifLet<T, Content: View>(
        _ value: T?, transform: (Self, T) -> Content
    ) -> some View {
        if let value {
            transform(self, value)
        } else {
            self
        }
    }
}

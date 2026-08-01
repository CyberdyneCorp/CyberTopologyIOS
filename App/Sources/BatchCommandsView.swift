import SwiftUI

/// The EditMesh batch-commands panel (task 4.5; spec: retopology-tools /
/// "EditMesh batch commands"), presented as a sheet from the toolbar's
/// `batchCommands` action.
///
/// Every row runs one `BatchCommand` through the journaled path and
/// dismisses, so the user sees the result immediately and one undo takes it
/// back — including the annotation clears that ride along with subdivide
/// and triangulate (they journal as a single `DocumentCommand.compound`).
///
/// The Auto Relax MODE toggle lives at the top of the same panel: it is the
/// setting that governs every OTHER edit, so this is where a user looks for
/// it. Identifiers sit on leaf controls (the container-identifier
/// accessibility trap documented on `DocumentEditorView.objectList`).
struct BatchCommandsView: View {
    let model: ViewportInputModel
    /// True when the document has an EditMesh at all — without one every
    /// geometry command is inert, so they disable rather than no-op.
    var hasEditMesh: Bool
    /// True when an active Target exists to project onto.
    var hasTarget: Bool
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle(
                        "Auto Relax",
                        isOn: Binding(
                            get: { model.autoRelaxEnabled },
                            set: { model.setAutoRelax($0) }
                        )
                    )
                    .accessibilityIdentifier("auto-relax-toggle")
                    Text(
                        "Redistributes the topology around each edit as you "
                            + "work. Pins hold. The relax lands in the "
                            + "edit's own undo step."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                } header: {
                    Text("Mode")
                }

                Section {
                    ForEach(BatchCommand.allCases) { command in
                        commandRow(command)
                    }
                } header: {
                    Text(Self.scopeHeader(selectedFaces: model.selectedPatchCount))
                        .accessibilityIdentifier("batch-scope-header")
                }
            }
            .navigationTitle("Batch Commands")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDismiss)
                        .accessibilityIdentifier("batch-commands-done")
                }
            }
        }
    }

    private func commandRow(_ command: BatchCommand) -> some View {
        Button {
            model.runBatchCommand(command)
            onDismiss()
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: command.symbol)
                    .frame(width: 24)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(command.title)
                            .font(.body.weight(.medium))
                        // A command that will ignore the selection says so HERE,
                        // before it runs. Reported from device: a selected patch
                        // and a Subdivide that quietly took the whole cage reads
                        // as a broken selection, not as a documented limit.
                        if ignoresSelection(command) {
                            Text("whole cage")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(command.notes)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .disabled(!isEnabled(command))
        .accessibilityIdentifier("batch-\(command.rawValue)")
    }

    /// What the section header says: the reach every row in it has.
    static func scopeHeader(selectedFaces: Int) -> String {
        selectedFaces > 0
            ? "Run on \(selectedFaces) selected \(selectedFaces == 1 ? "face" : "faces")"
            : "Run on the whole EditMesh"
    }

    /// Whether this command will IGNORE the current selection.
    ///
    /// Subdivide and Halve are the conditional ones: they scope when the selection
    /// is a separate piece — nothing attached, so no loop leaves it and no shared
    /// edge becomes an n-gon — and run whole-cage otherwise. The badge has to follow
    /// the SELECTION, not just the command, or it tells the artist the opposite of
    /// what is about to happen.
    private func ignoresSelection(_ command: BatchCommand) -> Bool {
        guard model.selectedPatchCount > 0 else { return false }
        if !command.scopesToSelection { return !model.selectedPatchIsIsland }
        return false
    }

    private func isEnabled(_ command: BatchCommand) -> Bool {
        guard hasEditMesh else { return false }
        return !command.requiresTarget || hasTarget
    }
}

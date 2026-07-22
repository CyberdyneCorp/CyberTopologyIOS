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
                    Text("Run on the whole EditMesh")
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
                    Text(command.title)
                        .font(.body.weight(.medium))
                    Text(command.notes)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .disabled(!isEnabled(command))
        .accessibilityIdentifier("batch-\(command.rawValue)")
    }

    private func isEnabled(_ command: BatchCommand) -> Bool {
        guard hasEditMesh else { return false }
        return !command.requiresTarget || hasTarget
    }
}

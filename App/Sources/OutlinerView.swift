import CyberKit
import SwiftUI

/// Scene outliner (openspec add-scene-outliner, 8.1; spec: scene-pipeline).
///
/// Lists every object with its role and topology statistics, and offers show / solo / lock
/// per row plus rename and per-group hiding.
///
/// **Statistics are a READOUT, never a computation.** `Object.counts` is captured at import
/// time precisely so the UI never deserialises a payload to show numbers, and an object with
/// no captured counts is shown as unknown rather than as zero — zero is a measurement,
/// absence is not, and rendering absence as zero would tell the artist their mesh is empty.
///
/// **Solo and group hiding are VIEW state**, held in `SceneVisibility` and not journaled.
/// Visibility, lock, group membership and renaming ARE document state and go through
/// `DocumentCommand.objectStateEdit`, so each is one undo step.
struct OutlinerView: View {
    let manifest: DocumentManifest
    @Binding var visibility: SceneVisibility
    /// Journals an object-state change. Returns whether it was accepted, so a refusal
    /// (a locked object) can be surfaced rather than silently dropped.
    let onEdit: (DocumentCommand.ObjectStateEdit) -> Bool
    let onClose: () -> Void

    @State private var renaming: UUID?
    @State private var draftName = ""

    var body: some View {
        NavigationStack {
            List {
                // Ungrouped first, then each group in first-appearance order — a stable
                // order rather than one that depends on Set iteration.
                let ungrouped = manifest.objects.filter { $0.group == nil }
                if !ungrouped.isEmpty {
                    Section("Objects") {
                        ForEach(ungrouped) { row(for: $0) }
                    }
                }
                ForEach(manifest.groupNames, id: \.self) { group in
                    Section {
                        ForEach(manifest.objects.filter { $0.group == group }) { row(for: $0) }
                    } header: {
                        groupHeader(group)
                    }
                }
            }
            .navigationTitle("Outliner")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onClose)
                }
            }
        }
    }

    private func groupHeader(_ group: String) -> some View {
        HStack {
            Text(group)
            Spacer()
            // Hides the group WITHOUT stamping isHidden onto each member, so un-hiding
            // restores each member's own visibility instead of revealing something the
            // artist had hidden individually.
            Button {
                visibility.toggleGroup(group)
            } label: {
                Image(systemName: visibility.hiddenGroups.contains(group) ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(
                visibility.hiddenGroups.contains(group) ? "Show group" : "Hide group"
            )
            .accessibilityIdentifier("outliner-group-toggle-\(group)")
        }
    }

    private func row(for object: DocumentManifest.Object) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if renaming == object.id {
                    TextField("Name", text: $draftName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { commitRename(object) }
                        .accessibilityIdentifier("outliner-rename-field")
                } else {
                    Text(object.name)
                        .font(.body)
                        .accessibilityIdentifier("outliner-name-\(object.name)")
                }
                Text(subtitle(for: object))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("outliner-stats-\(object.name)")
            }
            Spacer()
            toggles(for: object)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            // Rename is available on a LOCKED object too: locking protects payload bytes,
            // not the label.
            renaming = object.id
            draftName = object.name
        }
    }

    /// "Target · 4,798,848 faces" or "EditMesh · counts unknown".
    private func subtitle(for object: DocumentManifest.Object) -> String {
        let role = object.role == .target ? "Target" : "EditMesh"
        guard let counts = object.counts else { return "\(role) · counts unknown" }
        return "\(role) · \(counts.vertices.formatted()) verts · \(counts.faces.formatted()) faces"
    }

    private func toggles(for object: DocumentManifest.Object) -> some View {
        HStack(spacing: 14) {
            Button {
                _ = onEdit(.from(object, hidden: !object.isHidden))
            } label: {
                Image(systemName: object.isHidden ? "eye.slash" : "eye")
            }
            .accessibilityLabel(object.isHidden ? "Show" : "Hide")
            .accessibilityIdentifier("outliner-hide-\(object.name)")

            Button {
                visibility.toggleSolo(object.id)
            } label: {
                Image(systemName: visibility.soloed == object.id ? "1.circle.fill" : "1.circle")
            }
            .accessibilityLabel("Solo")
            .accessibilityIdentifier("outliner-solo-\(object.name)")

            Button {
                _ = onEdit(.from(object, locked: !object.isLocked))
            } label: {
                Image(systemName: object.isLocked ? "lock.fill" : "lock.open")
            }
            .accessibilityLabel(object.isLocked ? "Unlock" : "Lock")
            .accessibilityIdentifier("outliner-lock-\(object.name)")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
    }

    private func commitRename(_ object: DocumentManifest.Object) {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        renaming = nil
        // An empty name would leave an unidentifiable row, so a blank submit is a cancel
        // rather than a rename to "".
        guard !trimmed.isEmpty, trimmed != object.name else { return }
        _ = onEdit(.from(object, name: trimmed))
    }
}

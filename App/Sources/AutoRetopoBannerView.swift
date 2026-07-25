import SwiftUI

/// Accept/Discard controls for a pending Auto-Retopo proposal (Phase 5, spec:
/// weave-solver): visible only while an amber Weave ghost is proposed. Accept
/// commits the ghost as the EditMesh in one undoable step; Discard drops it
/// with no journal entry. Identifiers live on the leaf controls (the
/// container-identifier accessibility trap), so UI tests drive the buttons.
struct AutoRetopoBannerView: View {
    let model: ViewportInputModel

    var body: some View {
        VStack(spacing: 8) {
            Text("Auto-Retopo proposal — accept to replace the EditMesh")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("auto-retopo-status")
            HStack(spacing: 8) {
                Button("Accept") { model.acceptAutoRetopo() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("auto-retopo-accept")
                Button("Discard", role: .cancel) { model.discardAutoRetopo() }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("auto-retopo-discard")
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

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
            // A region proposal reports what it could not make regular. Shown,
            // not hidden: an irregular interface is legal output (the guarantee
            // is exact landing, not regularity — task 5.3a), but the user should
            // see a pole at the seam before welding it into their cage.
            if let notice = model.autoRetopoNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("auto-retopo-notice")
            }
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

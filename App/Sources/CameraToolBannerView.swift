import SwiftUI

/// Session controls for the camera-as-manipulator tools (task 4.2):
/// visible only while a Patch Clone / Extend Boundary / Transform
/// Vertices session is armed. The Pencil tap on the viewport commits the
/// same way; these buttons exist for finger-only use and for UI tests
/// (XCUITest cannot synthesize Pencil taps). Identifiers live on the leaf
/// controls (container-identifier accessibility trap).
struct CameraToolBannerView: View {
    let banner: MeshEditController.CameraToolBanner
    let model: ViewportInputModel

    var body: some View {
        VStack(spacing: 8) {
            Text(banner.status)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("tool-session-status")
            HStack(spacing: 8) {
                if banner.tool == .extendBoundary, let mode = banner.mode {
                    modePicker(active: mode)
                }
                if banner.flipped != nil {
                    Button {
                        model.togglePatchCloneFlip()
                    } label: {
                        Label(
                            "Flip",
                            systemImage: banner.flipped == true
                                ? "arrow.left.and.right.righttriangle.left.righttriangle.right.fill"
                                : "arrow.left.and.right.righttriangle.left.righttriangle.right"
                        )
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("tool-session-flip")
                    .accessibilityValue(banner.flipped == true ? "flipped" : "normal")
                }
                Button(banner.tool == .patchClone ? "Paste" : "Commit") {
                    model.commitCameraToolSession()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!banner.canCommit)
                .accessibilityIdentifier("tool-session-commit")
                Button("Cancel", role: .cancel) {
                    model.cancelCameraToolSession()
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("tool-session-cancel")
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    /// One button per Extend Boundary mode (spec: single / once /
    /// automatic modes + triangle fans).
    private func modePicker(active: ExtendBoundaryPlan.Mode) -> some View {
        HStack(spacing: 4) {
            ForEach(ExtendBoundaryPlan.Mode.allCases, id: \.rawValue) { mode in
                Button(mode.rawValue.capitalized) {
                    model.setExtendBoundaryMode(mode)
                }
                .buttonStyle(.bordered)
                .tint(mode == active ? .accentColor : .secondary)
                .accessibilityIdentifier("tool-mode-\(mode.rawValue)")
                .accessibilityValue(mode == active ? "active" : "inactive")
            }
        }
    }
}

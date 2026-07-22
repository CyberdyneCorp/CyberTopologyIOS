import CyberKit
import SwiftUI

// Loop-tag palette + Loop Info inspector chip (task 4.3; spec:
// retopology-tools / "Loop tags" and the roster's "Loop Info inspection").
//
// Both are read-mostly surfaces over document annotation state: the
// palette picks the colour the NEXT tag is authored in (a preference, not
// document state — nothing journals until a loop is actually tagged), and
// the chip only reports engine measurements.

/// Loop-tag colour palette: the small swatch row the spec's "color-tag
/// edge loops" needs. Indices are document state; the colours are
/// presentation (`LoopTagPalette`).
struct LoopTagPaletteView: View {
    let model: ViewportInputModel

    var body: some View {
        HStack(spacing: 6) {
            ForEach(LoopTagPalette.indices, id: \.self) { index in
                swatch(index)
            }
        }
        .padding(6)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func swatch(_ index: UInt8) -> some View {
        let isActive = model.activeTagColor == index
        return Button {
            model.selectTagColor(index)
        } label: {
            Circle()
                .fill(Color(rgb: LoopTagPalette.color(index)))
                .frame(width: 20, height: 20)
                .overlay(
                    Circle().strokeBorder(
                        isActive ? Color.primary : Color.clear, lineWidth: 2
                    )
                )
        }
        .accessibilityLabel("\(LoopTagPalette.name(index)) loop tag")
        .accessibilityIdentifier("tag-color-\(index)")
        .accessibilityValue(isActive ? "active" : "inactive")
    }
}

/// Loop Info inspector chip (spec roster: "Loop Info inspection
/// (vertex/edge counts, boundary length, snapping state in O(loop)
/// time)"). Appears while the Pencil holds over an interior edge and
/// reports the engine's measurements for that loop.
struct LoopInfoChipView: View {
    let info: LoopInfoChipState.Info

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if let tag = info.tagColor {
                    Circle()
                        .fill(Color(rgb: LoopTagPalette.color(tag)))
                        .frame(width: 10, height: 10)
                }
                Text("Loop")
                    .font(.caption.weight(.semibold))
            }
            Text(info.countsLine)
                .accessibilityIdentifier("loop-info-counts")
            Text(info.lengthLine)
                .accessibilityIdentifier("loop-info-length")
            Text(info.snappingLine)
                .accessibilityIdentifier("loop-info-snapping")
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        // Inert by construction: an inspector must never intercept the
        // next stroke.
        .allowsHitTesting(false)
    }
}

extension Color {
    /// A palette colour as a SwiftUI colour (the palette speaks SIMD3 so
    /// the Metal overlay and the UI share one source of truth).
    init(rgb: SIMD3<Float>) {
        self.init(
            .sRGB, red: Double(rgb.x), green: Double(rgb.y), blue: Double(rgb.z), opacity: 1
        )
    }
}

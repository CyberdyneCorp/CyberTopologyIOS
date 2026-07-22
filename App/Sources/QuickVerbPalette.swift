import SwiftUI
import simd

// Pencil Pro squeeze → radial quick-verb palette (task 3.7, spec:
// pencil-interaction / "Pencil Pro and haptic feedback": "Pencil Pro
// squeeze SHALL open a radial Action Gallery at the pen tip"). This is the
// MINIMAL radial menu over the five verbs; the full customizable Action
// Gallery (demo videos, drag-to-toolbar) is task 3.8 and will replace the
// palette's contents, not its squeeze plumbing.
//
// Split like the arbiter (design D5): `QuickVerbPaletteState` is the pure
// policy (squeeze events + system preference in, palette visibility + verb
// selections out — headless unit tests), the SwiftUI view below renders it,
// and the UIKit squeeze delivery (`UIPencilInteraction`) lives in
// `MetalViewport.Coordinator`. Squeeze delivery itself is hardware-only
// (Pencil Pro; the simulator cannot synthesize it — device test plan 9.6),
// so everything below the delegate callback is driven directly in tests
// and by the UI-test/screenshot launch hook.

/// Pure squeeze → palette state machine.
struct QuickVerbPaletteState: Equatable {
    /// The visible palette: where it centers (normalized viewport
    /// coordinates — the pen tip's hover location at squeeze time, clamped
    /// so the ring stays on screen; viewport center when the pose is
    /// unknown) and the verbs it offers, in ring order.
    struct Palette: Equatable {
        var location: SIMD2<Float>
        var verbs: [InputArbiter.Verb]
    }

    /// What the user's SYSTEM squeeze preference asks of the app (mapped
    /// from `UIPencilInteraction.preferredSqueezeAction` by the UIKit
    /// layer; kept UIKit-free here so policy is headless-testable).
    enum SqueezeAction: Equatable {
        /// Show a contextual palette — this app's quick-verb ring.
        case showPalette
        /// Switch to the eraser — this app's Erase verb.
        case selectEraser
        /// The user disabled squeeze; do nothing.
        case ignore
    }

    enum Effect: Equatable {
        case selectVerb(InputArbiter.Verb)
    }

    static let defaultLocation = SIMD2<Float>(0.5, 0.5)
    /// Clamp margin keeping the ring's buttons inside the viewport.
    static let edgeMargin: Float = 0.14

    private(set) var palette: Palette?

    /// A squeeze completed (`.ended` phase). `showPalette` toggles the
    /// ring at the pen location; `selectEraser` honors the system's
    /// switch-eraser preference directly.
    mutating func squeezeEnded(
        action: SqueezeAction, at location: SIMD2<Float>?
    ) -> [Effect] {
        switch action {
        case .ignore:
            return []
        case .selectEraser:
            palette = nil
            return [.selectVerb(.erase)]
        case .showPalette:
            guard palette == nil else {
                // Second squeeze dismisses (toggle, CozyBlanket-style).
                palette = nil
                return []
            }
            palette = Palette(
                location: Self.clamped(location ?? Self.defaultLocation),
                verbs: InputArbiter.Verb.allCases
            )
            return []
        }
    }

    /// A palette verb was tapped: select it and dismiss.
    mutating func verbChosen(_ verb: InputArbiter.Verb) -> [Effect] {
        guard palette != nil else { return [] }
        palette = nil
        return [.selectVerb(verb)]
    }

    /// A stroke began: the palette must never sit under live authoring
    /// (same rule as the interpretation chip and the hover preview).
    mutating func strokeBegan() {
        palette = nil
    }

    /// Explicit dismissal (center close button).
    mutating func dismissed() {
        palette = nil
    }

    static func clamped(_ point: SIMD2<Float>) -> SIMD2<Float> {
        simd_clamp(
            point,
            SIMD2(edgeMargin, edgeMargin),
            SIMD2(1 - edgeMargin, 1 - edgeMargin)
        )
    }
}

/// Radial quick-verb ring rendered at the squeeze location. Identifiers
/// live on the leaf buttons (container-identifier accessibility trap).
struct QuickVerbPaletteView: View {
    let palette: QuickVerbPaletteState.Palette
    let activeVerb: InputArbiter.Verb
    let onChoose: (InputArbiter.Verb) -> Void
    let onDismiss: () -> Void

    /// Ring radius in points.
    static let ringRadius: CGFloat = 62

    var body: some View {
        ZStack {
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .foregroundStyle(.secondary)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Dismiss quick verbs")
            .accessibilityIdentifier("quick-verb-dismiss")

            ForEach(Array(palette.verbs.enumerated()), id: \.element) { index, verb in
                verbButton(verb, at: index, of: palette.verbs.count)
            }
        }
    }

    private func verbButton(
        _ verb: InputArbiter.Verb, at index: Int, of count: Int
    ) -> some View {
        // First verb at 12 o'clock, clockwise.
        let angle = -Double.pi / 2 + 2 * .pi * Double(index) / Double(max(count, 1))
        let isActive = verb == activeVerb
        return Button {
            onChoose(verb)
        } label: {
            Image(systemName: verb.systemImage)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 44, height: 44)
                .foregroundStyle(isActive ? Color.accentColor : .primary)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(
                    Circle().strokeBorder(
                        isActive ? Color.accentColor : .clear, lineWidth: 1.5
                    )
                )
        }
        .offset(
            x: Self.ringRadius * cos(angle),
            y: Self.ringRadius * sin(angle)
        )
        .accessibilityLabel(verb.rawValue.capitalized)
        .accessibilityIdentifier("quick-verb-\(verb.rawValue)")
        .accessibilityValue(isActive ? "active" : "inactive")
    }
}

import CyberKit
import SwiftUI

/// Pure state machine for the post-stroke interpretation chip (task 3.5;
/// spec: pencil-interaction / "Post-stroke interpretation chip", design D5:
/// every stroke produces an interpretation record that powers the chip).
///
/// After each recognized (or rejected) Pencil stroke the chip transiently
/// states what the recognizer did, with one-tap alternatives when the
/// stroke was ambiguous. The machine owns only the SHOW / REPLACE /
/// DISMISS transitions — applying an alternative (the journaled swap) is
/// `MeshEditController.applyAlternative`, and scheduling the auto-dismiss
/// timer is `ViewportInputModel` (the machine stays pure and headless-
/// testable). `generation` tokens make a stale auto-dismiss harmless: a
/// timer armed for chip N can never hide chip N+1.
struct InterpretationChipState: Equatable {
    /// One tappable alternative: `id` is the interpretation record's
    /// candidate index (what `MeshEditController.applyAlternative` takes).
    struct Alternative: Equatable, Identifiable {
        let id: Int
        let action: StrokeInterpretation.Action
        let label: String
    }

    struct Chip: Equatable {
        let title: String
        /// Confidence of the shown candidate, e.g. "82%".
        let detail: String?
        let alternatives: [Alternative]
        /// Dismiss token: an auto-dismiss armed for an older generation
        /// must not hide a newer chip.
        let generation: Int
    }

    private(set) var chip: Chip?
    private(set) var generation = 0

    // MARK: - Transitions

    /// SHOW (and REPLACE after an alternative swap): a Pencil stroke
    /// resolved. `appliedIndex` is the candidate that actually applied and
    /// journaled (nil = the stroke changed nothing); `alternatives` are the
    /// candidate indices offered as one-tap swaps.
    mutating func strokeResolved(
        interpretation: StrokeInterpretation?, appliedIndex: Int?, alternatives: [Int]
    ) {
        generation += 1
        chip = Chip(
            title: Self.title(for: interpretation, appliedIndex: appliedIndex),
            detail: Self.detail(for: interpretation, appliedIndex: appliedIndex),
            alternatives: alternatives.compactMap { index in
                guard let candidate = interpretation?.candidates[safe: index] else {
                    return nil
                }
                return Alternative(
                    id: index, action: candidate.action,
                    label: Self.label(for: candidate.action)
                )
            },
            generation: generation
        )
    }

    /// DISMISS on the next stroke beginning: the chip must never block (or
    /// linger into) the next stroke.
    mutating func strokeBegan() {
        chip = nil
    }

    /// Unconditional DISMISS (failed swap, external document change).
    mutating func dismiss() {
        chip = nil
    }

    /// Timed DISMISS. Hides the chip only when `generation` still matches
    /// (a newer chip has a newer token); returns whether anything changed.
    @discardableResult
    mutating func autoDismiss(generation: Int) -> Bool {
        guard chip?.generation == generation else { return false }
        chip = nil
        return true
    }

    // MARK: - Copy

    /// Human title for what the recognizer did with the stroke.
    static func title(
        for interpretation: StrokeInterpretation?, appliedIndex: Int?
    ) -> String {
        guard let interpretation, let best = interpretation.best,
            best.action != .none
        else { return "Not recognized" }
        guard let appliedIndex,
            let applied = interpretation.candidates[safe: appliedIndex]
        else {
            // Recognized but nothing changed (e.g. a visibility line that
            // was not decisively vertical, a tap awaiting its double-tap).
            return "\(label(for: best.action)) — no change"
        }
        return label(for: applied.action)
    }

    static func detail(
        for interpretation: StrokeInterpretation?, appliedIndex: Int?
    ) -> String? {
        let candidate = appliedIndex.flatMap { interpretation?.candidates[safe: $0] }
            ?? interpretation?.best
        guard let candidate, candidate.action != .none else { return nil }
        return "\(Int((candidate.confidence * 100).rounded()))%"
    }

    /// User-facing label per grammar action (chip title + alternative
    /// buttons).
    static func label(for action: StrokeInterpretation.Action) -> String {
        switch action {
        case .none: return "No match"
        case .createQuad: return "Quad"
        case .createGrid: return "Quad grid"
        case .insertLoop: return "Insert loop"
        case .tagLoop: return "Tag loop"
        case .dissolveEdge: return "Dissolve"
        case .deleteFaces: return "Delete faces"
        case .mergeVertices: return "Merge"
        case .rotateEdge: return "Rotate edge"
        case .tweakVertex: return "Vertex tap"
        case .hideRegion: return "Hide faces"
        case .toggleVisibility: return "Visibility"
        }
    }
}

extension Array {
    /// nil instead of a trap for out-of-range candidate indices (the chip
    /// consumes indices that crossed an async boundary).
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// The transient chip itself: what the recognizer did, plus one-tap
/// alternative buttons when the stroke was ambiguous. Identifiers live on
/// LEAF views only (container identifiers would swallow the buttons —
/// the accessibility trap noted on `DocumentEditorView.objectList`).
struct InterpretationChipView: View {
    let chip: InterpretationChipState.Chip
    let onAlternative: (Int) -> Void

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                Text(chip.title)
                    .font(.footnote.weight(.semibold))
                    .accessibilityIdentifier("interpretation-chip-title")
                if let detail = chip.detail {
                    Text(detail)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("interpretation-chip-confidence")
                }
            }
            ForEach(chip.alternatives) { alternative in
                Button(alternative.label) {
                    onAlternative(alternative.id)
                }
                .font(.footnote.weight(.medium))
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.mini)
                .accessibilityIdentifier("chip-alternative-\(alternative.action.rawValue)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

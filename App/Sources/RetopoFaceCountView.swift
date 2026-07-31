import SwiftUI

// Auto-Retopo face-count entry (openspec improve-region-paint-ux).
//
// Replaces the system alert with an in-dialog keypad. Three reasons the alert had
// to go: a SwiftUI alert can host a TextField and buttons and nothing else, so
// Half/Double had nowhere to live; the system number pad floats OVER the dialog and
// covered the very message stating what was reachable; and the pad it brings has no
// idea what a face count is.

/// The pure entry model: digits in, a clamped count out. No SwiftUI, so every rule
/// is unit-testable.
struct RetopoFaceCountModel: Equatable {
    /// Fewest quads the solver will accept (`SolverParameters.targetingQuads`
    /// floors at 4, so asking for less is asking for nothing).
    static let minimum = 4

    /// Most quads this solve can use: four per source triangle for a painted
    /// region, or the engine's own ceiling for a whole Target.
    let ceiling: Int
    private(set) var count: Int

    init(count: Int, ceiling: Int) {
        self.ceiling = max(Self.minimum, ceiling)
        self.count = min(max(count, 0), self.ceiling)
    }

    /// Appends a digit, IGNORING it when the result would exceed the ceiling.
    ///
    /// Ignored rather than accepted-then-clamped: a field that silently rewrites
    /// what you typed is worse than one that stops taking input, because the second
    /// is visible the moment it happens and the ceiling is on screen beside it.
    mutating func append(digit: Int) {
        guard (0...9).contains(digit) else { return }
        let candidate = count * 10 + digit
        guard candidate <= ceiling else { return }
        count = candidate
    }

    mutating func backspace() {
        count /= 10
    }

    mutating func clear() {
        count = 0
    }

    /// Half the count, never below the solver's floor.
    mutating func halve() {
        count = max(Self.minimum, count / 2)
    }

    /// Twice the count, never above the ceiling.
    mutating func double() {
        count = min(ceiling, max(Self.minimum, count * 2))
    }

    /// Whether Retopologize may run: below the floor there is nothing to ask for.
    var isRunnable: Bool { count >= Self.minimum }

    /// What the field shows. Empty at zero so the placeholder can explain itself,
    /// rather than showing a "0" the artist has to delete.
    var display: String { count == 0 ? "" : count.formatted() }
}

/// Face-count entry with its own keypad and Half/Double.
struct RetopoFaceCountView: View {
    @State private var model: RetopoFaceCountModel
    /// What is available for this solve, stated above the field.
    let availability: String
    let onRun: (Int) -> Void
    let onCancel: () -> Void

    init(
        initial: Int, ceiling: Int, availability: String,
        onRun: @escaping (Int) -> Void, onCancel: @escaping () -> Void
    ) {
        _model = State(initialValue: RetopoFaceCountModel(count: initial, ceiling: ceiling))
        self.availability = availability
        self.onRun = onRun
        self.onCancel = onCancel
    }

    private let keys: [[String]] = [
        ["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["C", "0", "⌫"],
    ]

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                Text("Auto-Retopo Face Count")
                    .font(.headline)
                Text(availability)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // The value, big enough to read at arm's length with a pen in hand.
            Text(model.display.isEmpty ? "—" : model.display)
                .font(.system(size: 40, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityIdentifier("auto-retopo-custom-value")

            HStack(spacing: 12) {
                Button("Half") { model.halve() }
                    .accessibilityIdentifier("auto-retopo-half-button")
                Button("Double") { model.double() }
                    .accessibilityIdentifier("auto-retopo-double-button")
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity)

            VStack(spacing: 8) {
                ForEach(keys, id: \.first) { row in
                    HStack(spacing: 8) {
                        ForEach(row, id: \.self) { key in
                            Button {
                                press(key)
                            } label: {
                                Text(key)
                                    .font(.title2)
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("auto-retopo-key-\(key)")
                        }
                    }
                }
            }

            HStack(spacing: 12) {
                Button("Cancel", role: .cancel) { onCancel() }
                    .accessibilityIdentifier("auto-retopo-custom-cancel")
                Button("Retopologize") { onRun(model.count) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.isRunnable)
                    .accessibilityIdentifier("auto-retopo-custom-run")
            }
            .frame(maxWidth: .infinity)
        }
        .padding(20)
        .frame(maxWidth: 340)
    }

    private func press(_ key: String) {
        switch key {
        case "C": model.clear()
        case "⌫": model.backspace()
        default:
            if let digit = Int(key) { model.append(digit: digit) }
        }
    }
}

import CyberKit
import SwiftUI
import simd

/// Symmetry controls in the viewport settings popover (task 4.4; spec:
/// retopology-tools / "Multi-axis and radial symmetry" — "any combination
/// of X/Y/Z axes with configurable origin, and radial symmetry with
/// configurable count").
///
/// Pure presentation over a value: it never touches the document. Every
/// edit goes out through `onChange`, and the owner journals it as one
/// `DocumentCommand.setSymmetry` — symmetry is document state, so it
/// belongs in the undo history like the stage switch, not in `AppStorage`
/// beside the camera speeds.
///
/// The origin editor deliberately exposes ONLY the component that matters
/// for each enabled axis: the mirror plane of X is fully described by the
/// origin's x, so a per-axis slider over the model's extent is the whole
/// of "configurable origin" without a three-field vector editor nobody can
/// drive with a Pencil.
struct SymmetrySettingsView: View {
    let settings: SymmetrySettings
    /// Scene bounding sphere — the origin sliders span it, so the plane
    /// can be placed anywhere through the model.
    let sceneCenter: SIMD3<Float>
    let sceneRadius: Float
    let onChange: (SymmetrySettings) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Symmetry")
                .font(.headline)
            Toggle("Mirror while drawing", isOn: enabledBinding)
                .accessibilityIdentifier("symmetry-toggle")
            axisToggles
            if !settings.mirrorAxes.isEmpty {
                originSliders
                Picker("Authored half", selection: workingSideBinding) {
                    Text("Positive").tag(true)
                    Text("Negative").tag(false)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("symmetry-working-side")
            }
            radialControls
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("symmetry-summary")
        }
    }

    // MARK: - Sections

    private var axisToggles: some View {
        HStack(spacing: 12) {
            ForEach(SymmetrySettings.Axis.allCases, id: \.self) { axis in
                Toggle(axis.rawValue.uppercased(), isOn: mirrorBinding(axis))
                    .toggleStyle(.button)
                    .accessibilityIdentifier("symmetry-axis-\(axis.rawValue)")
            }
        }
    }

    @ViewBuilder
    private var originSliders: some View {
        ForEach(settings.mirrorAxes, id: \.self) { axis in
            LabeledContent("\(axis.rawValue.uppercased()) plane at") {
                Slider(value: originBinding(axis), in: originRange(axis))
                    .frame(width: 160)
                    .accessibilityIdentifier("symmetry-origin-\(axis.rawValue)")
            }
        }
        Button("Centre on Model") {
            var next = settings
            next.origin = sceneCenter
            onChange(next)
        }
        .accessibilityIdentifier("symmetry-centre-origin")
    }

    private var radialControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Stepper(
                "Radial sectors: \(settings.radialCount)",
                value: radialCountBinding,
                in: SymmetrySettings.radialCountRange
            )
            .accessibilityIdentifier("symmetry-radial-count")
            if settings.radialCount > 1 {
                Picker("Radial axis", selection: radialAxisBinding) {
                    ForEach(SymmetrySettings.Axis.allCases, id: \.self) { axis in
                        Text(axis.rawValue.uppercased()).tag(axis)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("symmetry-radial-axis")
            }
        }
    }

    /// One-line description of what the next stroke will do — the honest
    /// readout of `replicas.count`, so the UI can never claim symmetry the
    /// authoring path would not actually apply.
    var summary: String {
        guard settings.isActive else { return "Off — strokes author one copy" }
        let copies = settings.replicas.count + 1
        var parts: [String] = []
        if !settings.mirrorAxes.isEmpty {
            parts.append("mirror \(settings.mirrorAxes.map { $0.rawValue.uppercased() }.joined(separator: "+"))")
        }
        if settings.radialCount > 1 {
            parts.append("\(settings.radialCount)x radial about \(settings.radialAxis.rawValue.uppercased())")
        }
        return "\(parts.joined(separator: ", ")) — each stroke authors \(copies) copies"
    }

    // MARK: - Bindings

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { settings.isEnabled },
            set: { value in
                var next = settings
                next.isEnabled = value
                onChange(next)
            }
        )
    }

    private var workingSideBinding: Binding<Bool> {
        Binding(
            get: { settings.workingSidePositive },
            set: { value in
                var next = settings
                next.workingSidePositive = value
                onChange(next)
            }
        )
    }

    private func mirrorBinding(_ axis: SymmetrySettings.Axis) -> Binding<Bool> {
        Binding(
            get: { settings.mirrorAxes.contains(axis) },
            set: { onChange(settings.settingMirror(axis, enabled: $0)) }
        )
    }

    private var radialCountBinding: Binding<Int> {
        Binding(
            get: { settings.radialCount },
            set: { onChange(settings.settingRadialCount($0)) }
        )
    }

    private var radialAxisBinding: Binding<SymmetrySettings.Axis> {
        Binding(
            get: { settings.radialAxis },
            set: { value in
                var next = settings
                next.radialAxis = value
                onChange(next)
            }
        )
    }

    private func originBinding(_ axis: SymmetrySettings.Axis) -> Binding<Double> {
        Binding(
            get: { Double(component(settings.origin, axis)) },
            set: { value in
                var next = settings
                setComponent(&next.origin, axis, Float(value))
                onChange(next)
            }
        )
    }

    private func originRange(_ axis: SymmetrySettings.Axis) -> ClosedRange<Double> {
        let center = Double(component(sceneCenter, axis))
        let radius = Double(max(sceneRadius, SceneBounds.minimumRadius))
        return (center - radius)...(center + radius)
    }

    private func component(_ vector: SIMD3<Float>, _ axis: SymmetrySettings.Axis) -> Float {
        switch axis {
        case .x: return vector.x
        case .y: return vector.y
        case .z: return vector.z
        }
    }

    private func setComponent(
        _ vector: inout SIMD3<Float>, _ axis: SymmetrySettings.Axis, _ value: Float
    ) {
        switch axis {
        case .x: vector.x = value
        case .y: vector.y = value
        case .z: vector.z = value
        }
    }
}

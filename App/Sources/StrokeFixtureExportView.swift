#if DEBUG
    import CyberKit
    import CyberKitTesting
    import SwiftUI
    import UIKit

    /// DEBUG-build stroke recorder (change: simplify-gesture-grammar, task
    /// 1.1): saves the last completed stroke as a `StrokeFixture` under
    /// Documents, from where it can be pulled off the device and committed
    /// to the corpus.
    ///
    /// Presented from the viewport settings popover. DEBUG-only for the same
    /// reason as the recognizer HUD: it is a development instrument, and the
    /// intent picker offers actions (the reduced three-gesture set) that the
    /// shipping grammar does not yet agree with.
    struct StrokeFixtureExportView: View {
        /// The stroke to export, resolved when the sheet is presented so it
        /// cannot change under the user while they are naming it.
        let stroke: ViewportStrokeCapture.CapturedStroke?
        /// What the recognizer made of it — recorded alongside, since it is
        /// the before-picture the re-tune is measured against.
        let recognizedAs: String?
        /// Name of the Target the stroke was drawn on.
        let targetName: String

        @Environment(\.dismiss) private var dismiss

        @State private var name = "quad_adjacent_pencil"
        @State private var intent = StrokeFixtureExport.Intent.createQuad
        @State private var notes = ""
        @State private var exported: URL?
        @State private var failure: String?

        var body: some View {
            NavigationStack {
                Form {
                    if let stroke {
                        details(for: stroke)
                    } else {
                        Text("Draw a stroke first — nothing has been captured yet.")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("stroke-export-empty")
                    }
                }
                .navigationTitle("Record stroke")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
        }

        @ViewBuilder
        private func details(
            for stroke: ViewportStrokeCapture.CapturedStroke
        ) -> some View {
            Section("Stroke") {
                LabeledContent("Samples", value: "\(stroke.samples.count)")
                LabeledContent("Input", value: stroke.source.rawValue)
                if let recognizedAs {
                    LabeledContent("Recognized as", value: recognizedAs)
                }
            }
            Section("Fixture") {
                TextField("Name", text: $name)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("stroke-export-name")
                Picker("Intended", selection: $intent) {
                    ForEach(StrokeFixtureExport.Intent.allCases) { intent in
                        Text(intent.label).tag(intent)
                    }
                }
                .accessibilityIdentifier("stroke-export-intent")
                TextField("What you meant (optional)", text: $notes, axis: .vertical)
                    .lineLimit(2...4)
                    .accessibilityIdentifier("stroke-export-notes")
                Text("Saved as \(StrokeFixtureExport.fileName(for: name))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("Save to Files") { export(stroke) }
                    .accessibilityIdentifier("stroke-export-save")
                if let exported {
                    // The share sheet is the fast path to a Mac; the file is
                    // already on disk either way, so a failed/cancelled
                    // share loses nothing.
                    ShareLink(item: exported) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("stroke-export-share")
                    Text("Saved to Files ▸ CyberTopology ▸ \(StrokeFixtureExport.directoryName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("stroke-export-confirmation")
                }
                if let failure {
                    Text(failure)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("stroke-export-failure")
                }
            }
        }

        private func export(_ stroke: ViewportStrokeCapture.CapturedStroke) {
            let fixture = StrokeFixture(
                name: name,
                samples: stroke.samples,
                expectedOutcome: intent.rawValue,
                provenance: StrokeFixtureExport.provenance(
                    device: UIDevice.current.model,
                    target: targetName,
                    intent: intent,
                    notes: notes,
                    recognizedAs: recognizedAs
                )
            )
            do {
                exported = try StrokeFixtureExport.write(
                    fixture, inDocuments: StrokeFixtureExport.documentsDirectory()
                )
                failure = nil
            } catch {
                exported = nil
                failure = "Could not save: \(error.localizedDescription)"
            }
        }
    }
#endif

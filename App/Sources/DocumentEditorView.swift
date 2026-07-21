import CyberKit
import SwiftUI

/// Editor shell for an open document: name, stage picker, placeholder
/// viewport (the Metal viewport lands in phase 2), save-version and close
/// actions, and autosave-on-backgrounding.
struct DocumentEditorView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var document: TopoDocument
    let journal: RecoveryJournal
    let onClose: @MainActor () -> Void

    @State private var showingSaveVersion = false
    @State private var versionName = ""

    /// Version of the linked CyberRemesherAndUV engine, via the CyberKit
    /// facade (regression canary for the engine bridge).
    let engineVersionText = "Engine \(CyberEngine.version())"

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                stagePicker
                viewportPlaceholder
            }
            .padding()
            .navigationTitle(document.documentName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", action: onClose)
                        .accessibilityIdentifier("close-document")
                }
                ToolbarItem(placement: .principal) {
                    Text(document.documentName)
                        .font(.headline)
                        .accessibilityIdentifier("document-name")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Save Version") {
                        versionName = ""
                        showingSaveVersion = true
                    }
                    .accessibilityIdentifier("save-version")
                }
            }
        }
        .alert("Save New Version", isPresented: $showingSaveVersion) {
            TextField("Version name", text: $versionName)
            Button("Save") { saveVersion() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Creates a named copy alongside the original document.")
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { autosaveNow() }
        }
    }

    /// Stage state placeholder: the only editable document state until the
    /// viewport lands. Editing it exercises the real change → autosave →
    /// journal pipeline.
    private var stagePicker: some View {
        Picker("Stage", selection: stageBinding) {
            Text("RT").tag(DocumentManifest.Stage.retopology)
            Text("UV").tag(DocumentManifest.Stage.uv)
            Text("BK").tag(DocumentManifest.Stage.baking)
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("stage-picker")
    }

    private var viewportPlaceholder: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(.quaternary)
            // Identifier on the shape only: applying it after .overlay wraps
            // shape + overlay into one accessibility element and hides the
            // overlay's children from UI tests.
            .accessibilityIdentifier("viewport-placeholder")
            .overlay {
                VStack(spacing: 8) {
                    Image(systemName: "square.grid.3x3.topleft.filled")
                        .font(.system(size: 44))
                        .foregroundStyle(.tint)
                    Text("Viewport — phase 2")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text(engineVersionText)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("engine-version")
                }
            }
    }

    private var stageBinding: Binding<DocumentManifest.Stage> {
        Binding(
            get: { document.bundle.manifest.stage },
            set: { stage in
                document.updateBundle { $0.manifest.stage = stage }
                journal.handle(.documentEdited)
            }
        )
    }

    private func saveVersion() {
        let name = versionName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            try document.saveNewVersion(named: name)
        } catch {
            assertionFailure("save new version failed: \(error)")
        }
    }

    /// Forces an autosave when the app is backgrounded (spec: document-model /
    /// "Autosave and session recovery").
    private func autosaveNow() {
        let document = document
        let journal = journal
        Task { @MainActor in
            if await document.autosave() {
                journal.handle(.documentSaved)
            }
        }
    }
}

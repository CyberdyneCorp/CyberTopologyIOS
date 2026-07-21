import CyberKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let wavefrontOBJ = UTType(filenameExtension: "obj", conformingTo: .data)!
}

/// Editor shell for an open document: name, stage picker, object list,
/// OBJ import/export, undo/redo (buttons + multi-finger taps), placeholder
/// viewport (the Metal viewport lands in phase 2), save-version and close
/// actions, and autosave-on-backgrounding.
struct DocumentEditorView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var document: TopoDocument
    let journal: RecoveryJournal
    let onClose: @MainActor () -> Void

    @State private var showingSaveVersion = false
    @State private var versionName = ""
    @State private var importRole: DocumentManifest.Object.Role?
    @State private var statusMessage: String?

    /// Version of the linked CyberRemesherAndUV engine, via the CyberKit
    /// facade (regression canary for the engine bridge).
    let engineVersionText = "Engine \(CyberEngine.version())"

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                stagePicker
                objectList
                viewportPlaceholder
                if let statusMessage {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("status-message")
                }
            }
            .padding()
            .navigationTitle(document.documentName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
        }
        .alert("Save New Version", isPresented: $showingSaveVersion) {
            TextField("Version name", text: $versionName)
            Button("Save") { saveVersion() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Creates a named copy alongside the original document.")
        }
        .fileImporter(
            isPresented: Binding(
                get: { importRole != nil },
                set: { if !$0 { importRole = nil } }
            ),
            allowedContentTypes: [.wavefrontOBJ]
        ) { result in
            if let role = importRole {
                importRole = nil
                handleImport(result, role: role)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { autosaveNow() }
        }
    }

    // MARK: - Components

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Done", action: onClose)
                .accessibilityIdentifier("close-document")
        }
        ToolbarItem(placement: .principal) {
            Text(document.documentName)
                .font(.headline)
                .accessibilityIdentifier("document-name")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                document.undoLast()
                journal.handle(.documentEdited)
            } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .disabled(!document.canUndo)
            .accessibilityIdentifier("undo")

            Button {
                document.redoLast()
                journal.handle(.documentEdited)
            } label: {
                Label("Redo", systemImage: "arrow.uturn.forward")
            }
            .disabled(!document.canRedo)
            .accessibilityIdentifier("redo")

            Menu {
                Button("Import Target…") { importRole = .target }
                    .accessibilityIdentifier("import-target")
                Button("Import EditMesh…") { importRole = .editMesh }
                    .accessibilityIdentifier("import-editmesh")
                Button("Export EditMeshes") { exportNow() }
                    .accessibilityIdentifier("export-editmeshes")
                    .disabled(!document.bundle.manifest.objects.contains { $0.role == .editMesh })
            } label: {
                Label("Import/Export", systemImage: "square.and.arrow.down.on.square")
            }
            .accessibilityIdentifier("io-menu")

            Button("Save Version") {
                versionName = ""
                showingSaveVersion = true
            }
            .accessibilityIdentifier("save-version")
        }
    }

    /// Stage switching goes through the journaled command path (task 1.4).
    private var stagePicker: some View {
        Picker("Stage", selection: stageBinding) {
            Text("RT").tag(DocumentManifest.Stage.retopology)
            Text("UV").tag(DocumentManifest.Stage.uv)
            Text("BK").tag(DocumentManifest.Stage.baking)
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("stage-picker")
    }

    /// Imported objects with live vertex/face counts (pre-outliner: the full
    /// outliner is task 8.1).
    @ViewBuilder
    private var objectList: some View {
        let objects = document.bundle.manifest.objects
        if !objects.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(objects) { object in
                    HStack(spacing: 8) {
                        Image(systemName: object.role == .target ? "mountain.2" : "square.grid.3x3")
                            .foregroundStyle(object.role == .target ? .secondary : Color.accentColor)
                        Text(object.name)
                            .font(.subheadline.weight(.medium))
                        if let counts = object.counts {
                            Text("\(counts.vertices) v · \(counts.faces) f")
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(object.role == .target ? "Target" : "EditMesh")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("object-row-\(object.name)")
                }
            }
            // No container identifier: it would combine the rows into one
            // accessibility element and hide their identifiers (same trap
            // as viewport-placeholder).
            .padding(12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        }
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
            .overlay {
                UndoGestureView(
                    onUndo: {
                        document.undoLast()
                        journal.handle(.documentEdited)
                    },
                    onRedo: {
                        document.redoLast()
                        journal.handle(.documentEdited)
                    }
                )
            }
    }

    private var stageBinding: Binding<DocumentManifest.Stage> {
        Binding(
            get: { document.bundle.manifest.stage },
            set: { stage in
                document.perform(.setStage(from: document.bundle.manifest.stage, to: stage))
                journal.handle(.documentEdited)
            }
        )
    }

    // MARK: - Actions

    /// Internal (not private) so unit tests can drive the import result
    /// path directly — the Files picker itself is system UI.
    func handleImport(_ result: Result<URL, Error>, role: DocumentManifest.Object.Role) {
        do {
            let url = try result.get()
            try document.importOBJ(at: url, role: role)
            journal.handle(.documentEdited)
            statusMessage = nil
        } catch {
            statusMessage = "Import failed: \(error.localizedDescription)"
        }
    }

    func exportNow() {
        do {
            let written = try document.exportEditMeshes()
            statusMessage = "Exported \(written.count) file(s) to Export/\(document.documentName)"
        } catch {
            statusMessage = "Export failed: \(error.localizedDescription)"
        }
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

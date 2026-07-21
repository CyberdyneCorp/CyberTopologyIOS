import CyberKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let wavefrontOBJ = UTType(filenameExtension: "obj", conformingTo: .data)!
}

/// Editor shell for an open document: name, stage picker, object list,
/// Metal viewport (camera gestures + multi-finger tap undo/redo), OBJ
/// import/export, undo/redo buttons, save-version and close actions, and
/// autosave-on-backgrounding.
struct DocumentEditorView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var document: TopoDocument
    let journal: RecoveryJournal
    let onClose: @MainActor () -> Void

    @State private var showingSaveVersion = false
    @State private var showingViewportSettings = false
    @State private var versionName = ""
    @State private var importRole: DocumentManifest.Object.Role?
    @State private var statusMessage: String?

    /// Persisted camera sensitivity (spec: viewport-rendering / "Robust
    /// camera system" — orbit/zoom speed SHALL be user-adjustable).
    @AppStorage(ViewportSettings.orbitSpeedKey)
    private var orbitSpeed = ViewportSettings.defaultSpeed
    @AppStorage(ViewportSettings.zoomSpeedKey)
    private var zoomSpeed = ViewportSettings.defaultSpeed

    /// EditMesh overlay display options (spec: viewport-rendering /
    /// "Animated EditMesh overlay pipeline" + "X-ray and occlusion
    /// control"): configurable wireframe opacity, occlusion depth
    /// threshold, and true x-ray mode.
    @AppStorage(ViewportSettings.overlayOpacityKey)
    private var overlayOpacity = ViewportSettings.defaultOverlayOpacity
    @AppStorage(ViewportSettings.xrayKey)
    private var xrayEnabled = false
    @AppStorage(ViewportSettings.occlusionBiasKey)
    private var occlusionBias = ViewportSettings.defaultOcclusionBias

    /// DEBUG-only ghost preview (task 2.4 demo path): renders the EditMesh
    /// as ghost geometry until the Weave solver (phase 5) exists. The
    /// toggle only appears in DEBUG builds of the settings popover.
    @AppStorage(ViewportSettings.ghostDebugKey)
    private var ghostDebugEnabled = false

    /// Viewport resolution scale (task 2.5, spec: viewport-rendering /
    /// "Performance controls"): 50/75/100% of native drawable resolution;
    /// MetalFX upscaling engages automatically where supported.
    @AppStorage(ViewportSettings.resolutionScaleKey)
    private var resolutionScale = ViewportSettings.defaultResolutionScale

    /// Version of the linked CyberRemesherAndUV engine, via the CyberKit
    /// facade (regression canary for the engine bridge).
    let engineVersionText = "Engine \(CyberEngine.version())"

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                stagePicker
                objectList
                viewport
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

            Button {
                showingViewportSettings = true
            } label: {
                Label("Viewport Settings", systemImage: "gearshape")
            }
            .accessibilityIdentifier("viewport-settings")
            .popover(isPresented: $showingViewportSettings) {
                ViewportSettingsView(
                    orbitSpeed: $orbitSpeed,
                    zoomSpeed: $zoomSpeed,
                    overlayOpacity: $overlayOpacity,
                    xrayEnabled: $xrayEnabled,
                    occlusionBias: $occlusionBias,
                    ghostDebugEnabled: $ghostDebugEnabled,
                    resolutionScale: $resolutionScale
                )
            }
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

    /// Metal viewport. The undo/redo tap overlay lives INSIDE MetalViewport's
    /// UIKit hierarchy (not as a SwiftUI .overlay) so camera drags/pinches
    /// and the multi-finger taps share one hit-tested view tree — a SwiftUI
    /// overlay sibling would shield the MTKView from all camera gestures.
    private var viewport: some View {
        MetalViewport(
            bundle: document.bundle,
            orbitSpeed: orbitSpeed,
            zoomSpeed: zoomSpeed,
            overlayOpacity: overlayOpacity,
            xrayEnabled: xrayEnabled,
            occlusionBias: occlusionBias,
            ghostDebugEnabled: ghostDebugEnabled,
            resolutionScale: resolutionScale,
            onUndo: {
                document.undoLast()
                journal.handle(.documentEdited)
            },
            onRedo: {
                document.redoLast()
                journal.handle(.documentEdited)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(alignment: .bottomTrailing) {
            // Corner HUD; identifier on the leaf Text and hit-testing off so
            // the label neither hides the viewport from XCUITest nor eats
            // camera gestures.
            Text(engineVersionText)
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
                .accessibilityIdentifier("engine-version")
                .allowsHitTesting(false)
                .padding(10)
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

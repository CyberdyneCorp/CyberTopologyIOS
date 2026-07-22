import CyberKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let wavefrontOBJ = UTType(filenameExtension: "obj", conformingTo: .data)!
    /// Autodesk FBX (task 3.10): resolved by extension — the system type
    /// (`com.autodesk.fbx`) is used when a declaring app is installed,
    /// otherwise a dynamic type; either satisfies the Files picker filter.
    static let fbx = UTType(filenameExtension: "fbx", conformingTo: .data)!
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

    /// Left-handed mirror stub (task 3.1): mirrors the verb toolbar to the
    /// trailing edge; full toolbar repositioning is task 3.8.
    @AppStorage(ViewportSettings.leftHandedToolbarKey)
    private var leftHandedToolbar = false

    /// Snap haptics on/off (task 3.7, spec: pencil-interaction / "Pencil
    /// Pro and haptic feedback" — haptics SHALL be user-disableable).
    @AppStorage(ViewportSettings.snapHapticsKey)
    private var snapHapticsEnabled = true

    /// DEBUG-only recognizer HUD (task 3.2): last stroke polyline +
    /// interpretation record over the viewport, toggled from the settings
    /// popover. The key exists in all builds; the HUD itself is DEBUG-only.
    @AppStorage(ViewportSettings.strokeDebugHUDKey)
    private var strokeDebugHUD = false

    /// Subdivision preview level (task 4.6, spec: retopology-tools /
    /// "Subdivision preview"): 0 / 1 / 2 levels of reprojected subdivision
    /// rendered non-destructively while editing continues on the base cage.
    /// A persisted DISPLAY preference — the document never sees it.
    @AppStorage(ViewportSettings.subdivisionPreviewKey)
    private var subdivisionPreviewLevel = ViewportSettings.defaultSubdivisionPreviewLevel

    /// Input arbitration (task 3.1, design D5): one arbiter shared by the
    /// verb toolbar (spring-loaded hold-chords) and the
    /// viewport's touch handling.
    @State private var inputModel = ViewportInputModel()

    /// Customizable toolbar (task 3.8): slot configuration, persisted via
    /// `ToolbarStore` on every change and restored on launch (spec
    /// scenario "Toolbar persistence").
    @State private var toolbarModel = ToolbarModel()
    /// Non-nil presents the Action Gallery, optionally focused on one
    /// action (a gesture-action slot tap). Item-based so the sheet content
    /// is always built WITH its focus — a bool + separate focus state can
    /// present the first sheet before the focus write lands.
    @State private var galleryPresentation: GalleryPresentation?

    struct GalleryPresentation: Identifiable {
        let id = UUID()
        let focus: EditorAction?
    }

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
            allowedContentTypes: [.wavefrontOBJ, .fbx]
        ) { result in
            if let role = importRole {
                importRole = nil
                handleImport(result, role: role)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { autosaveNow() }
        }
        .sheet(item: $galleryPresentation) { presentation in
            // Action Gallery (task 3.8): every action with its help panel
            // plus the toolbar-slot editor; the toolbar overlay renders
            // the same live configuration.
            ActionGalleryView(toolbar: toolbarModel, focus: presentation.focus)
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
                    resolutionScale: $resolutionScale,
                    leftHandedToolbar: $leftHandedToolbar,
                    snapHapticsEnabled: $snapHapticsEnabled,
                    strokeDebugHUD: $strokeDebugHUD,
                    subdivisionPreviewLevel: $subdivisionPreviewLevel,
                    hasTarget: document.bundle.manifest.objects.contains {
                        $0.role == .target
                    },
                    // Symmetry (task 4.4) is DOCUMENT state: it reads out
                    // of the manifest and every edit goes through the
                    // journaled command path, exactly like the stage
                    // picker above.
                    symmetry: document.bundle.manifest.effectiveSymmetry,
                    sceneCenter: inputModel.sceneCenter,
                    sceneRadius: inputModel.sceneRadius,
                    onSymmetryChange: setSymmetry
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
            // Journal integrity: strokes that drain before the next SwiftUI
            // update pass re-sync against the LIVE document, not the
            // per-pass snapshot above.
            currentBundle: { document.bundle },
            orbitSpeed: orbitSpeed,
            zoomSpeed: zoomSpeed,
            inputModel: inputModel,
            overlayOpacity: overlayOpacity,
            xrayEnabled: xrayEnabled,
            occlusionBias: occlusionBias,
            ghostDebugEnabled: ghostDebugEnabled,
            resolutionScale: resolutionScale,
            subdivisionPreviewLevel: subdivisionPreviewLevel,
            snapHapticsEnabled: snapHapticsEnabled,
            onUndo: {
                document.undoLast()
                journal.handle(.documentEdited)
            },
            onRedo: {
                document.redoLast()
                journal.handle(.documentEdited)
            },
            onCommit: { command in
                // Verb layer (task 3.3): every mesh mutation is journaled.
                document.perform(command)
                journal.handle(.documentEdited)
            },
            onReplaceCommit: { replacement, expected in
                // Interpretation-chip alternative (task 3.5): atomically
                // swaps the last journaled command — exactly one entry
                // stands for the stroke afterwards, no extra undo step.
                let swapped = document.performReplacingLast(
                    with: replacement, expecting: expected
                )
                if swapped { journal.handle(.documentEdited) }
                return swapped
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(alignment: .bottom) {
            // UI-test stroke injection (task 3.3): XCUITest cannot draw a
            // multi-segment single-touch polyline, so the end-to-end quad
            // test replays the committed square fixture through the real
            // capture → recognizer → verb pipeline via this button. Only
            // present when launched with the injection argument.
            if UITestSupport.strokeInjectionRequested {
                HStack {
                    Button("Draw Test Quad") {
                        inputModel.injectSquareStroke()
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("inject-square-stroke")
                    Button("Draw Test Grid") {
                        inputModel.injectGridStroke()
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("inject-grid-stroke")
                    Button("Draw Test Loop") {
                        inputModel.injectRingStroke()
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("inject-ring-stroke")
                }
                .padding(.bottom, 8)
            }
        }
        .overlay {
            // Pencil Pro quick-verb palette (task 3.7): radial five-verb
            // ring at the squeeze location (normalized viewport coords).
            // Only the ring's buttons hit-test — the rest of the viewport
            // stays live. Identifiers sit on the leaf buttons
            // (container-identifier accessibility trap).
            if let palette = inputModel.quickVerbPalette {
                GeometryReader { geometry in
                    QuickVerbPaletteView(
                        palette: palette,
                        activeVerb: inputModel.activeVerb,
                        onChoose: { inputModel.chooseQuickVerb($0) },
                        onDismiss: { inputModel.dismissQuickVerbPalette() }
                    )
                    .position(
                        x: geometry.size.width * CGFloat(palette.location.x),
                        y: geometry.size.height * CGFloat(palette.location.y)
                    )
                }
            }
        }
        .overlay(alignment: .top) {
            // Camera-as-manipulator session banner (task 4.2): commit /
            // cancel / mode / flip controls plus the status line while a
            // Patch Clone / Extend Boundary / Transform Vertices session
            // is armed; the transient status keeps the Transform Vertices
            // re-snap report visible after the session ends.
            VStack(spacing: 6) {
                if let banner = inputModel.cameraToolBanner {
                    CameraToolBannerView(banner: banner, model: inputModel)
                } else if let status = inputModel.cameraToolStatus {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                        .accessibilityIdentifier("tool-session-status")
                        .allowsHitTesting(false)
                }
            }
            .padding(.top, 8)
        }
        .overlay(alignment: .bottom) {
            // Post-stroke interpretation chip (task 3.5): transient, shows
            // what the recognizer did with one-tap alternatives when the
            // stroke was ambiguous. Sits above the injection buttons and
            // never covers the viewport center, so it cannot block the
            // next stroke (it also dismisses the moment one begins).
            if let chip = inputModel.interpretationChip {
                InterpretationChipView(chip: chip) { index in
                    inputModel.chooseAlternative(index)
                }
                .padding(.bottom, 52)
            }
        }
        .sheet(isPresented: Binding(
            get: { inputModel.showsBatchCommands },
            set: { inputModel.showsBatchCommands = $0 }
        )) {
            // EditMesh batch commands + the Auto Relax mode toggle
            // (task 4.5). Every row journals one undoable entry; the
            // toggle is a persisted preference.
            BatchCommandsView(
                model: inputModel,
                hasEditMesh: document.bundle.manifest.objects.contains {
                    $0.role == .editMesh
                },
                hasTarget: document.bundle.manifest.objects.contains {
                    $0.role == .target
                },
                onDismiss: { inputModel.showsBatchCommands = false }
            )
        }
        .overlay(alignment: .topTrailing) {
            // Loop-tag palette + Loop Info inspector (task 4.3). The
            // palette picks the colour the next tag is authored in; the
            // chip appears while the Pencil holds over an interior edge.
            VStack(alignment: .trailing, spacing: 8) {
                LoopTagPaletteView(model: inputModel)
                if let info = inputModel.loopInfo {
                    LoopInfoChipView(info: info)
                }
            }
            .padding(.top, 8)
            .padding(.trailing, 8)
        }
        .task {
            // Screenshot hook: draws the quad and/or the one-stroke grid
            // automatically shortly after the editor appears (drives the
            // same injection path).
            let quad = UITestSupport.autoDrawQuadRequested
            let grid = UITestSupport.autoDrawGridRequested
            let ring = UITestSupport.autoDrawRingRequested
            let hoverLoop = UITestSupport.autoHoverLoopRequested
            let hoverGhost = UITestSupport.autoHoverGhostRequested
            let palette = UITestSupport.showQuickVerbPaletteRequested
            let snapDrag = UITestSupport.autoSnapDragRequested
            let gallery = UITestSupport.showActionGalleryRequested
            let tool = UITestSupport.autoToolRequested
            let annotations = UITestSupport.autoAnnotationsRequested
            let symmetry = UITestSupport.autoSymmetryRequested
            let batchPanel = UITestSupport.showBatchCommandsRequested
            let subdivide = UITestSupport.autoSubdivideRequested
            let autoRelax = UITestSupport.autoRelaxRequested
            guard
                quad || grid || ring || hoverLoop || hoverGhost || palette
                    || snapDrag || gallery || annotations || symmetry
                    || batchPanel || subdivide || autoRelax || tool != nil
            else { return }
            // Auto Relax mode hook (task 4.5): turn the MODE on BEFORE any
            // authoring hook runs, so the injected stroke exercises the
            // real create → auto-relax → single-journal-entry path.
            if autoRelax { inputModel.setAutoRelax(true) }
            try? await Task.sleep(for: .seconds(2))
            if quad { inputModel.injectSquareStroke() }
            if grid { inputModel.injectGridStroke() }
            if ring { inputModel.injectRingStroke() }
            // Hover-preview screenshot hooks (task 3.6): after the drawn
            // geometry settles, lock a hover point previewing the slide
            // loop / the ghost-quad hint (the simulator has no Pencil
            // hover hardware; this drives the same controller the hover
            // recognizer feeds).
            if hoverLoop || hoverGhost {
                try? await Task.sleep(for: .seconds(1))
                inputModel.hoverPreview?.probeForVisualVerification(
                    hoverLoop ? .loopHighlight : .ghostQuad
                )
            }
            // Pencil Pro hooks (task 3.7): the simulator can synthesize
            // neither a squeeze nor a Pencil drag, so these drive the same
            // entries the hardware paths use — the squeeze delegate's
            // model call, and the capture-level stroke events.
            if palette {
                inputModel.pencilSqueezed(action: .showPalette, atNormalized: nil)
            }
            if snapDrag {
                try? await Task.sleep(for: .seconds(1))
                inputModel.meshEditor?.probeSnapHighlightForVisualVerification()
            }
            // Action Gallery screenshot hook (task 3.8): the same
            // presentation the toolbar's gallery button drives.
            if gallery {
                galleryPresentation = GalleryPresentation(focus: nil)
            }
            // Build-tool screenshot/UI-test hook (task 4.1): arm the tool
            // through the model (toolbar highlight in sync) and drive one
            // real probe stroke computed from the live mesh and camera.
            if let tool {
                try? await Task.sleep(for: .seconds(1))
                inputModel.selectTool(tool)
                inputModel.meshEditor?.probeToolStrokeForVisualVerification(tool)
            }
            // Annotation screenshot hook (task 4.3): a pinned loop AND a
            // differently-coloured tagged loop in one frame, both through
            // the real journaled command path.
            if annotations {
                try? await Task.sleep(for: .seconds(1))
                inputModel.selectTagColor(1)
                inputModel.meshEditor?.probeAnnotationsForVisualVerification()
            }
            // Symmetry screenshot hook (task 4.4): enable X mirroring
            // about the model centre through the journaled command path
            // (which is what makes the plane rim appear), then author one
            // quad — the create path mirrors it inside the same entry.
            if symmetry {
                try? await Task.sleep(for: .seconds(1))
                setSymmetry(
                    SymmetrySettings(
                        mirrorAxes: [.x], origin: inputModel.sceneCenter, isEnabled: true
                    )
                )
                try? await Task.sleep(for: .seconds(1))
                inputModel.meshEditor?.probeSymmetryForVisualVerification()
            }
            // Batch-command hooks (task 4.5): subdivide the seeded cage
            // through the REAL journaled batch path (denser wireframe in
            // the screenshot), then present the panel over it.
            if subdivide {
                try? await Task.sleep(for: .seconds(1))
                inputModel.meshEditor?.probeBatchSubdivideForVisualVerification()
            }
            if batchPanel {
                try? await Task.sleep(for: .seconds(1))
                inputModel.showsBatchCommands = true
            }
        }
        .overlay {
            // Recognizer debug HUD (task 3.2, DEBUG builds): last stroke
            // polyline + interpretation record; hit-testing disabled inside
            // the view so viewport touches are untouched.
            #if DEBUG
                if strokeDebugHUD {
                    StrokeDebugHUD(
                        polyline: inputModel.lastStrokePolyline,
                        interpretation: inputModel.lastInterpretation
                    )
                }
            #endif
        }
        .overlay(alignment: leftHandedToolbar ? .topTrailing : .topLeading) {
            // Customizable slot toolbar (task 3.8): hosts the 3.1 verb
            // hold-chords, gesture-action references, and the Action
            // Gallery entry point. Mirrored by the left-handed option;
            // identifiers live on the leaf buttons (container-identifier
            // accessibility trap).
            ActionToolbarView(model: inputModel, toolbar: toolbarModel) { focus in
                galleryPresentation = GalleryPresentation(focus: focus)
            }
            .padding(10)
        }
        .overlay(alignment: .bottomLeading) {
            // Debug stroke HUD: raw capture→consumer diagnostic for every
            // verb (the task-3.5 interpretation chip is the user-facing
            // surface for Pencil strokes). Hit-testing off so it never
            // eats viewport touches.
            if let summary = inputModel.lastStrokeSummary {
                Text(summary)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                    .accessibilityIdentifier("stroke-hud")
                    .allowsHitTesting(false)
                    .padding(10)
            }
        }
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

    /// Journals a symmetry-settings change (task 4.4). Symmetry is
    /// document state and changes what the next authoring stroke does, so
    /// it goes through the same command path as the stage switch — setting
    /// what is already set journals nothing.
    /// Internal (not private) so unit tests can drive it without the
    /// popover.
    func setSymmetry(_ settings: SymmetrySettings) {
        let current = document.bundle.manifest.symmetry
        guard settings != (current ?? SymmetrySettings()) else { return }
        document.perform(.setSymmetry(from: current, to: settings))
        journal.handle(.documentEdited)
    }

    /// Internal (not private) so unit tests can drive the import result
    /// path directly — the Files picker itself is system UI.
    func handleImport(_ result: Result<URL, Error>, role: DocumentManifest.Object.Role) {
        do {
            let url = try result.get()
            try document.importMesh(at: url, role: role)
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
        // nonisolated(unsafe): MainActor-to-MainActor capture of the
        // non-Sendable document/journal (see RootView.close for the full
        // rationale; Xcode 26.6+ rejects the plain capture).
        nonisolated(unsafe) let document = document
        nonisolated(unsafe) let journal = journal
        Task { @MainActor in
            if await document.autosave() {
                journal.handle(.documentSaved)
            }
        }
    }
}

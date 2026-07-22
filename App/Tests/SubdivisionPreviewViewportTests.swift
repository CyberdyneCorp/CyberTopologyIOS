import CyberKit
import CyberKitTesting
import Foundation
import Metal
import Testing
import simd

@testable import CyberTopology

/// Task 4.6: the non-destructive subdivision preview in the viewport (spec:
/// retopology-tools / "Subdivision preview", scenario "Editing under
/// preview").
///
/// Everything below drives the REAL pipeline — a real coordinator with a real
/// Metal renderer, real engine meshes, the real journaled command path and
/// real offscreen frames. No engine mocks.
///
/// **HONEST SCOPE:** the preview is REPROJECTED-LINEAR (see
/// `CyberKit/Sources/CyberKit/SubdivisionPreview.swift`); genuinely smooth
/// (Catmull-Clark) subdivision is task 4.6a and is not asserted here.
@MainActor
struct SubdivisionPreviewViewportTests {
    // MARK: - Harness

    /// Coordinator + document-journal harness (mirrors `TopoDocument`:
    /// record + apply, then re-sync the viewport like a SwiftUI pass).
    @MainActor
    private final class Harness {
        var bundle = DocumentBundle()
        let coordinator: MetalViewport.Coordinator
        private(set) var committed: [DocumentCommand] = []

        init() throws {
            coordinator = MetalViewport(
                bundle: DocumentBundle(), orbitSpeed: 1, zoomSpeed: 1,
                onUndo: {}, onRedo: {}
            ).makeCoordinator()
            _ = coordinator.makeView()
            try #require(coordinator.renderer != nil, "Metal device unavailable")
            coordinator.onCommit = { [weak self] command in
                self?.committed.append(command)
                self?.perform(command)
            }
            coordinator.bundleProvider = { [weak self] in
                self?.bundle ?? DocumentBundle()
            }
        }

        var renderer: ViewportRenderer { coordinator.renderer! }
        var editor: MeshEditController { coordinator.meshEditor }

        func sync() { coordinator.syncMesh(from: bundle) }

        func setLevel(_ level: SubdivisionPreviewLevel) {
            coordinator.setSubdivisionPreviewLevel(level)
        }

        func perform(_ command: DocumentCommand) {
            bundle.journal.record(command)
            command.apply(to: &bundle)
            sync()
        }

        func undo() {
            if let command = bundle.journal.undo() {
                command.revert(on: &bundle)
                sync()
            }
        }

        var editObject: DocumentManifest.Object? {
            bundle.manifest.objects.first { $0.role == .editMesh }
        }

        /// The document's STORED bytes for the EditMesh — what the preview
        /// must never touch.
        func storedPayload() throws -> Data {
            let file = try #require(editObject).payloadFile
            return try #require(bundle.payloads[file])
        }

        func storedMesh() throws -> Mesh {
            try bundle.mesh(for: #require(editObject))
        }
    }

    private func meshFromOBJ(_ text: String) throws -> Mesh {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("subdiv-preview-vp-\(UUID().uuidString).obj")
        try text.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try Mesh.loadOBJ(at: url)
    }

    /// Domed Target: the preview's smoothing comes entirely from
    /// reprojecting onto it, so a flat Target would make it invisible.
    private func addDomeTarget(to harness: Harness) throws {
        let n = 12
        var obj = ""
        for row in 0...n {
            for col in 0...n {
                let x = Double(col) / Double(n) * 4 - 2
                let y = Double(row) / Double(n) * 4 - 2
                let z = 0.9 - 0.18 * (x * x + y * y)
                obj += "v \(x) \(y) \(z)\n"
            }
        }
        for row in 0..<n {
            for col in 0..<n {
                let a = row * (n + 1) + col + 1
                obj += "f \(a) \(a + 1) \(a + n + 2) \(a + n + 1)\n"
            }
        }
        try harness.bundle.addObject(name: "target", role: .target, mesh: try meshFromOBJ(obj))
        harness.sync()
    }

    /// Flat 4x4-quad cage on z = 0 under the dome — 16 faces, so a level-2
    /// preview is exactly 256.
    private func addFlatCage(to harness: Harness, side: Int = 4) throws {
        var obj = ""
        for row in 0...side {
            for col in 0...side {
                let x = Double(col) / Double(side) * 1.6 - 0.8
                let y = Double(row) / Double(side) * 1.6 - 0.8
                obj += "v \(x) \(y) 0\n"
            }
        }
        for row in 0..<side {
            for col in 0..<side {
                let a = row * (side + 1) + col + 1
                obj += "f \(a) \(a + 1) \(a + side + 2) \(a + side + 1)\n"
            }
        }
        try harness.bundle.addObject(
            name: "cage", role: .editMesh, mesh: try meshFromOBJ(obj)
        )
        harness.sync()
    }

    private func livePositions(_ mesh: Mesh) -> [SIMD3<Float>] {
        (0..<UInt32(mesh.vertexCount)).compactMap { mesh.vertexPosition($0) }
    }

    // MARK: - Spec scenario: "Editing under preview"

    /// THE mapped scenario. With preview level 2 active, an edit of the base
    /// cage updates the preview live WHILE the STORED mesh remains the base
    /// cage: same face count, no extra object, no preview bytes anywhere in
    /// the document, and exactly ONE journal entry for the edit.
    @Test("Editing under preview: the stored mesh stays the base cage")
    func editingUnderPreviewLeavesTheStoredCageUntouched() throws {
        let harness = try Harness()
        try addDomeTarget(to: harness)
        try addFlatCage(to: harness)
        harness.setLevel(.two)

        let baseFaces = try harness.storedMesh().faceCount
        #expect(baseFaces == 16)
        let previewBefore = try #require(harness.coordinator.subdivisionPreviewMesh)
        #expect(previewBefore.faceCount == baseFaces * 16)
        let previewPositionsBefore = livePositions(previewBefore)
        let objectCountBefore = harness.bundle.manifest.objects.count
        let payloadCountBefore = harness.bundle.payloads.count

        // A real journaled edit of the base cage: move an interior vertex.
        // (The spec's phrasing is "slides an edge loop"; any base-cage
        // mutation exercises the identical live-preview path, and this one
        // is deterministic without synthesizing Pencil input.)
        let live = try #require(harness.coordinator.recognizerEditMesh)
        let moved = try #require(
            (0..<UInt32(live.vertexCount)).first { id in
                guard let p = live.vertexPosition(id) else { return false }
                return abs(p.x) < 1e-4 && abs(p.y) < 1e-4
            }
        )
        let transaction = MeshEditTransaction(
            object: try #require(harness.editObject), mesh: live,
            currentPayload: try harness.storedPayload()
        )
        try live.tweakVertex(moved, to: SIMD3(0, 0, 0.55))
        // The live-edit refresh the viewport coordinator runs once per
        // rendered frame (this cage is far under the throttle budget).
        harness.coordinator.rebuildSubdivisionPreview(duringStroke: true)
        let command = try #require(try transaction.command(verb: "tweak"))
        harness.perform(command)

        // The edit landed in the document as exactly ONE journal entry…
        #expect(harness.bundle.journal.canUndo)
        // …as the BASE CAGE, not the preview: same topology size, one
        // EditMesh object, one payload per object — nothing derived was
        // ever written.
        let storedAfter = try harness.storedMesh()
        #expect(storedAfter.faceCount == baseFaces)
        #expect(storedAfter.vertexCount == live.vertexCount)
        #expect(harness.bundle.manifest.objects.count == objectCountBefore)
        #expect(harness.bundle.payloads.count == payloadCountBefore)
        #expect(
            harness.bundle.manifest.objects.filter { $0.role == .editMesh }.count == 1
        )

        // …while the PREVIEW followed the edit live.
        let previewAfter = try #require(harness.coordinator.subdivisionPreviewMesh)
        #expect(previewAfter.faceCount == baseFaces * 16)
        #expect(livePositions(previewAfter) != previewPositionsBefore)
        #expect(harness.coordinator.subdivisionPreviewRebuildCount > 1)

        // And the preview is genuinely not in the document: the stored
        // bytes still deserialize to the 16-face cage after undo, too.
        harness.undo()
        #expect(try harness.storedMesh().faceCount == baseFaces)
    }

    /// The preview never mutates the live handle the recognizer and every
    /// verb share — asserted on the ACTUAL coordinator handle, byte-exact.
    @Test("The live edit handle is byte-identical across preview rebuilds")
    func previewDerivationNeverTouchesTheLiveHandle() throws {
        let harness = try Harness()
        try addDomeTarget(to: harness)
        try addFlatCage(to: harness)

        let live = try #require(harness.coordinator.recognizerEditMesh)
        let before = try live.payloadData()
        harness.setLevel(.one)
        harness.setLevel(.two)
        harness.coordinator.rebuildSubdivisionPreview(duringStroke: false)
        #expect(try live.payloadData() == before)
        #expect(try harness.storedPayload() == before)
    }

    /// Reprojection is what smooths: under the dome the preview must lift
    /// off the flat cage — with an anti-vacuity control proving the same
    /// preview stays flat when the document has no Target.
    @Test("The preview is reprojected onto the Target (with a no-Target control)")
    func previewReprojectsOntoTheTarget() throws {
        let withTarget = try Harness()
        try addDomeTarget(to: withTarget)
        try addFlatCage(to: withTarget)
        withTarget.setLevel(.two)
        let lifted = livePositions(try #require(withTarget.coordinator.subdivisionPreviewMesh))
        #expect(lifted.contains { $0.z > 0.3 })

        let withoutTarget = try Harness()
        try addFlatCage(to: withoutTarget)
        withoutTarget.setLevel(.two)
        let flat = livePositions(
            try #require(withoutTarget.coordinator.subdivisionPreviewMesh)
        )
        #expect(flat.count == lifted.count)
        #expect(flat.allSatisfy { abs($0.z) < 1e-5 })
    }

    // MARK: - Level control

    @Test("Level 0 clears the preview; levels 1 and 2 size it correctly")
    func levelDrivesThePreview() throws {
        let harness = try Harness()
        try addDomeTarget(to: harness)
        try addFlatCage(to: harness)

        #expect(harness.coordinator.subdivisionPreviewMesh == nil)
        #expect(harness.renderer.hasSubdivisionPreview == false)

        harness.setLevel(.one)
        #expect(try #require(harness.coordinator.subdivisionPreviewMesh).faceCount == 64)
        #expect(harness.renderer.hasSubdivisionPreview)

        harness.setLevel(.two)
        #expect(try #require(harness.coordinator.subdivisionPreviewMesh).faceCount == 256)

        harness.setLevel(.off)
        #expect(harness.coordinator.subdivisionPreviewMesh == nil)
        #expect(harness.renderer.hasSubdivisionPreview == false)
    }

    /// Re-applying the SAME level costs nothing: the SwiftUI update pass
    /// runs on every unrelated state change and must not re-derive.
    @Test("Re-applying the same level does not re-derive")
    func sameLevelIsIdempotent() throws {
        let harness = try Harness()
        try addFlatCage(to: harness)
        harness.setLevel(.one)
        let rebuilds = harness.coordinator.subdivisionPreviewRebuildCount
        harness.setLevel(.one)
        harness.setLevel(.one)
        #expect(harness.coordinator.subdivisionPreviewRebuildCount == rebuilds)
    }

    /// Removing the EditMesh clears the preview rather than leaving a
    /// surface floating over an empty document.
    @Test("Losing the EditMesh clears the preview")
    func losingTheCageClearsThePreview() throws {
        let harness = try Harness()
        try addFlatCage(to: harness)
        harness.setLevel(.two)
        #expect(harness.renderer.hasSubdivisionPreview)

        harness.bundle = DocumentBundle()
        harness.sync()
        #expect(harness.coordinator.subdivisionPreviewMesh == nil)
        #expect(harness.renderer.hasSubdivisionPreview == false)
    }

    // MARK: - Throttle policy

    /// The documented policy, observed on the real coordinator: a cage whose
    /// level-2 preview is over the live budget does NOT re-derive mid-stroke
    /// (the previous preview stays on screen), but the stroke-end path
    /// rebuilds unconditionally.
    @Test("Mid-stroke rebuilds are cost-gated; stroke-end rebuilds are not")
    func throttleSkipsExpensiveMidStrokeRebuilds() throws {
        let harness = try Harness()
        // 40x40 = 1 600 quads → a level-2 preview is 25 600 faces, over the
        // 20 000-face live budget.
        try addFlatCage(to: harness, side: 40)
        #expect(SubdivisionPreviewPolicy.previewFaceCount(baseFaces: 1_600, level: .two)
            > SubdivisionPreviewPolicy.liveFaceBudget)
        harness.setLevel(.two)
        let afterInitial = harness.coordinator.subdivisionPreviewRebuildCount
        #expect(afterInitial > 0)
        #expect(harness.renderer.hasSubdivisionPreview)

        harness.coordinator.rebuildSubdivisionPreview(duringStroke: true)
        #expect(harness.coordinator.subdivisionPreviewRebuildCount == afterInitial)
        // Skipped, NOT cleared: the user keeps seeing the last preview.
        #expect(harness.renderer.hasSubdivisionPreview)

        harness.coordinator.rebuildSubdivisionPreview(duringStroke: false)
        #expect(harness.coordinator.subdivisionPreviewRebuildCount == afterInitial + 1)
    }

    /// REGRESSION: the derivation is a filesystem round trip and can throw
    /// transiently. The failure path used to wipe the preview and return, so
    /// the smoothed surface VANISHED mid-drag — the opposite of the "skipped,
    /// NOT cleared" contract above. A mid-stroke failure must leave the last
    /// preview on screen; a stroke-end failure still clears, because there is
    /// no later rebuild to correct a stale surface.
    @Test("A failed mid-stroke derivation skips; a failed stroke-end one clears")
    func failedMidStrokeDerivationDoesNotClearThePreview() throws {
        let harness = try Harness()
        try addFlatCage(to: harness)
        harness.setLevel(.two)
        let derived = try #require(harness.coordinator.subdivisionPreviewMesh)
        let baseline = harness.coordinator.subdivisionPreviewRebuildCount
        #expect(harness.renderer.hasSubdivisionPreview)

        struct DerivationFailure: Error {}
        harness.coordinator.subdivisionPreviewDeriver = { _, _, _ in throw DerivationFailure() }

        harness.coordinator.rebuildSubdivisionPreview(duringStroke: true)
        #expect(harness.renderer.hasSubdivisionPreview)
        #expect(harness.coordinator.subdivisionPreviewMesh === derived)
        #expect(harness.coordinator.subdivisionPreviewRebuildCount == baseline)

        // Stroke end: nothing will correct a stale surface later, so the
        // preview does come down rather than lying about the committed cage.
        harness.coordinator.rebuildSubdivisionPreview(duringStroke: false)
        #expect(harness.coordinator.subdivisionPreviewMesh == nil)
        #expect(harness.renderer.hasSubdivisionPreview == false)

        // Recovery: once the derivation works again the preview comes back.
        harness.coordinator.subdivisionPreviewDeriver = nil
        harness.coordinator.rebuildSubdivisionPreview(duringStroke: false)
        #expect(harness.renderer.hasSubdivisionPreview)
    }

    /// Below the budget, mid-stroke rebuilds DO run — the interactive-latency
    /// requirement for the cages this stage actually works on.
    @Test("Small cages rebuild live during a stroke")
    func smallCagesRebuildDuringAStroke() throws {
        let harness = try Harness()
        try addFlatCage(to: harness)
        harness.setLevel(.two)
        let before = harness.coordinator.subdivisionPreviewRebuildCount
        harness.coordinator.rebuildSubdivisionPreview(duringStroke: true)
        #expect(harness.coordinator.subdivisionPreviewRebuildCount == before + 1)
    }

    /// REGRESSION: `refreshLiveEditGeometry` runs once per RENDERED FRAME,
    /// and each rebuild is an OBJ write/read round trip plus a BVH
    /// reprojection on the main actor. Under the old policy a small cage
    /// paid that on every frame of a 120 Hz display. The rate guard bounds
    /// consecutive mid-stroke rebuilds; the stroke-end path still bypasses
    /// it so what the user is left with is exact.
    @Test("Consecutive mid-stroke frames do not each re-derive the preview")
    func midStrokeRebuildsAreRateLimited() throws {
        let harness = try Harness()
        try addFlatCage(to: harness)
        harness.setLevel(.two)
        let before = harness.coordinator.subdivisionPreviewRebuildCount

        // First mid-stroke frame derives...
        harness.coordinator.rebuildSubdivisionPreview(duringStroke: true)
        #expect(harness.coordinator.subdivisionPreviewRebuildCount == before + 1)
        // ...and the next frames of the same stroke do not.
        for _ in 0..<10 {
            harness.coordinator.rebuildSubdivisionPreview(duringStroke: true)
        }
        #expect(
            harness.coordinator.subdivisionPreviewRebuildCount == before + 1,
            "10 more frames must not each pay the derivation"
        )
        // Skipped, never cleared: the last preview stays on screen.
        #expect(harness.renderer.hasSubdivisionPreview)

        // Stroke end bypasses the rate guard entirely.
        harness.coordinator.rebuildSubdivisionPreview(duringStroke: false)
        #expect(harness.coordinator.subdivisionPreviewRebuildCount == before + 2)
        // ...and it re-arms the guard, so the next stroke is responsive.
        harness.coordinator.rebuildSubdivisionPreview(duringStroke: true)
        #expect(harness.coordinator.subdivisionPreviewRebuildCount == before + 3)
    }

    // MARK: - Rendering

    private static let quadPositions: [Float] = [
        0, 0, 0, /**/ 1, 0, 0, /**/ 1, 1, 0, /**/ 0, 1, 0,
    ]
    private static let quadNormals: [Float] = [
        0, 0, 1, /**/ 0, 0, 1, /**/ 0, 0, 1, /**/ 0, 0, 1,
    ]
    private static let quadTriangles: [UInt32] = [0, 1, 2, 0, 2, 3]
    private static let quadEdges: [UInt32] = [0, 1, 1, 2, 2, 3, 3, 0]

    private func makeRenderer() throws -> ViewportRenderer {
        try #require(ViewportRenderer(), "Metal device unavailable")
    }

    private func frameCameraOnQuad(_ renderer: ViewportRenderer) throws {
        renderer.setViewportSize(CGSize(width: 128, height: 128))
        let bounds = try #require(SceneBounds(positions: Self.quadPositions))
        renderer.camera = CameraState.framing(bounds, aspect: 1)
    }

    private func differingPixels(_ a: [UInt8], _ b: [UInt8]) -> Int {
        var count = 0
        for base in stride(from: 0, to: min(a.count, b.count), by: 4)
        where a[base..<base + 4] != b[base..<base + 4] {
            count += 1
        }
        return count
    }

    /// Offscreen frames must be measurably different with the preview on
    /// versus off, and turning it back off must restore the original frame
    /// exactly (nothing about the preview leaks into other passes).
    @Test("Offscreen frames distinguish preview on from preview off")
    func offscreenRenderDistinguishesPreviewOnAndOff() throws {
        let renderer = try makeRenderer()
        try frameCameraOnQuad(renderer)
        renderer.loadOverlayGeometry(
            positions: Self.quadPositions, edges: Self.quadEdges, at: 0
        )
        // Well past the overlay creation sweep so the wire is fully drawn.
        let time = 1_000.0
        let wireOnly = try #require(renderer.renderOffscreen(width: 128, height: 128, at: time))

        renderer.loadSubdivisionPreviewGeometry(
            positions: Self.quadPositions, normals: Self.quadNormals,
            indices: Self.quadTriangles
        )
        #expect(renderer.hasSubdivisionPreview)
        let withPreview = try #require(
            renderer.renderOffscreen(width: 128, height: 128, at: time)
        )
        // The preview fills the quad's interior, which the wireframe alone
        // leaves at the clear color.
        #expect(differingPixels(wireOnly, withPreview) > 400)

        renderer.clearSubdivisionPreview()
        let cleared = try #require(renderer.renderOffscreen(width: 128, height: 128, at: time))
        #expect(differingPixels(wireOnly, cleared) == 0)
    }

    /// The base-cage wireframe draws OVER the preview surface — that
    /// stacking IS the retopology workflow. Asserted by pixel classification:
    /// with the preview loaded, cyan wire pixels (blue clearly above red)
    /// still survive on top of the neutral grey-blue fill.
    @Test("The base wireframe stays visible over the preview surface")
    func wireframeDrawsOverThePreview() throws {
        let renderer = try makeRenderer()
        try frameCameraOnQuad(renderer)
        renderer.loadOverlayGeometry(
            positions: Self.quadPositions, edges: Self.quadEdges, at: 0
        )
        renderer.loadSubdivisionPreviewGeometry(
            positions: Self.quadPositions, normals: Self.quadNormals,
            indices: Self.quadTriangles
        )
        let frame = try #require(
            renderer.renderOffscreen(width: 128, height: 128, at: 1_000)
        )
        // Wire cyan is strongly blue-dominant; the preview surface style is
        // near-neutral (0.62, 0.68, 0.78) and cannot produce this margin.
        var wirePixels = 0
        for base in stride(from: 0, to: frame.count, by: 4) {
            let blue = Int(frame[base]), red = Int(frame[base + 2])
            if blue > red + 60 { wirePixels += 1 }
        }
        #expect(wirePixels > 40)
    }

    /// The preview surface is static by design: it must not pin the display
    /// link the way a pulsing proposal ghost does.
    @Test("A shown preview does not force continuous redraws")
    func previewDoesNotAnimate() throws {
        let renderer = try makeRenderer()
        renderer.loadSubdivisionPreviewGeometry(
            positions: Self.quadPositions, normals: Self.quadNormals,
            indices: Self.quadTriangles
        )
        #expect(renderer.hasSubdivisionPreview)
        #expect(renderer.isAnimating(at: 1_000) == false)
        let style = GhostStyle.subdivisionPreview
        #expect(style.pulsedAlpha(at: 0) == style.baseAlpha)
        #expect(style.pulsedAlpha(at: 12.345) == style.baseAlpha)
    }

    /// The normal lift that keeps the reprojected preview from z-fighting
    /// with the Target it was projected onto: scale-free and strictly
    /// positive, but far smaller than the hover hint's (the preview must
    /// still read as hugging the surface, not floating over it).
    @Test("The preview is lifted off the Target it was reprojected onto")
    func previewIsLiftedOffTheTarget() throws {
        #expect(GhostStyle.subdivisionPreview.normalOffset == 0)
        let lifted = GhostStyle.subdivisionPreview(sceneRadius: 2)
        #expect(lifted.normalOffset > 0)
        #expect(lifted.normalOffset < GhostStyle.hoverHint(sceneRadius: 2).normalOffset)
        // Scale-free: twice the scene, twice the lift.
        #expect(
            abs(GhostStyle.subdivisionPreview(sceneRadius: 4).normalOffset
                - 2 * lifted.normalOffset) < 1e-6
        )
        // A degenerate scene radius must not collapse the lift to zero.
        #expect(GhostStyle.subdivisionPreview(sceneRadius: 0).normalOffset > 0)

        // And the renderer actually applies it on a real load.
        let renderer = try makeRenderer()
        renderer.loadGeometry(
            positions: Self.quadPositions, normals: Self.quadNormals,
            colors: nil, indices: Self.quadTriangles
        )
        renderer.loadSubdivisionPreviewGeometry(
            positions: Self.quadPositions, normals: Self.quadNormals,
            indices: Self.quadTriangles
        )
        #expect(renderer.subdivisionPreviewStyle.normalOffset == 0)
        renderer.loadSubdivisionPreview(mesh: try Mesh.loadOBJ(
            at: UITestSupport.writeSeedOBJ()
        ))
        #expect(renderer.subdivisionPreviewStyle.normalOffset > 0)
    }

    /// No per-frame allocation regression: once the preview is uploaded,
    /// rendering frames binds pooled buffers only.
    @Test("Rendering a preview allocates nothing per frame")
    func previewRenderingAllocatesNothingPerFrame() throws {
        let renderer = try makeRenderer()
        try frameCameraOnQuad(renderer)
        renderer.loadSubdivisionPreviewGeometry(
            positions: Self.quadPositions, normals: Self.quadNormals,
            indices: Self.quadTriangles
        )
        let pool = renderer.subdivisionPreviewPath.bufferPool
        let allocations = pool.allocationCount
        for step in 0..<5 {
            _ = renderer.renderOffscreen(width: 64, height: 64, at: 100 + Double(step))
        }
        #expect(pool.allocationCount == allocations)

        // Re-uploading a same-sized preview (what every live edit does) is
        // free too: the pool reuses its streams.
        for _ in 0..<3 {
            renderer.loadSubdivisionPreviewGeometry(
                positions: Self.quadPositions, normals: Self.quadNormals,
                indices: Self.quadTriangles
            )
        }
        #expect(pool.allocationCount == allocations)
    }

    // MARK: - Settings surface

    @Test("Settings expose the three levels and reset to off")
    func settingsSurface() {
        #expect(ViewportSettings.subdivisionPreviewLevels == [0, 1, 2])
        #expect(ViewportSettings.defaultSubdivisionPreviewLevel == 0)
        #expect(
            SubdivisionPreviewLevel(clamping: ViewportSettings.defaultSubdivisionPreviewLevel)
                == .off
        )
    }
}

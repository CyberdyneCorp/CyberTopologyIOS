import CyberKit
import Foundation
import simd

// Symmetry: live mirroring, apply-symmetry and re-symmetrize (task 4.4;
// spec: retopology-tools / "Multi-axis and radial symmetry").
//
// Live symmetric AUTHORING is not implemented here — it lives in
// `MeshEditController.applyCreate`, which replays the authored engine
// operation once per `SymmetrySettings.replica` INSIDE the stroke's single
// `MeshEditTransaction`. That is the whole point: the journal holds one
// command whose engine-side effect is already symmetric, so one undo
// removes every side together and redo brings them all back. Nothing is
// duplicated app-side after the fact.
//
// This file holds the two BAKE commands (each one journaled `meshEdit`)
// and the world-space rim geometry that makes the active symmetry planes
// visible in the viewport.

/// Scene-relative tolerances for the symmetry operations. Free-standing
/// (not on the `@MainActor` controller) so the pure `SymmetrySettings`
/// helpers below can read them from any isolation.
enum SymmetryTolerances {
    /// Weld tolerance for symmetry planes, as a fraction of the scene
    /// radius — scale-free, so the same setting behaves identically on a
    /// centimetre prop and a metre-scale character.
    static let weldFraction: Float = 0.002
    /// Re-symmetrize match radius, as a fraction of the scene radius. A
    /// vertex whose mirror image lands further away than this has no
    /// counterpart and is left alone.
    static let matchFraction: Float = 0.05
}

extension MeshEditController {
    /// Apply-symmetry: BAKES the mirror into real geometry across every
    /// enabled axis, as ONE journaled command (spec: "Apply-symmetry SHALL
    /// bake the mirror"). Returns whether anything journaled — baking a
    /// mesh that is already whole adds no faces and stays out of the undo
    /// stack.
    @discardableResult
    func applySymmetryNow() -> Bool {
        withSymmetryTarget(verb: "symmetry.apply") { mesh, settings, snapper in
            try mesh.applySymmetry(settings, snapping: snapper)
        }
    }

    /// Status line shown when a bake is refused for want of usable
    /// symmetry state.
    static let symmetryDisabledStatus =
        "Symmetry is off — enable it (and a mirror axis) to bake"
    static let noMirrorAxisStatus =
        "No mirror axis enabled — radial-only symmetry has no plane to bake (task 4.4a)"

    /// The mirror axis a bake would use, or nil when the current symmetry
    /// state cannot drive one.
    ///
    /// `SymmetrySettings` deliberately RETAINS `mirrorAxes` while disabled
    /// (so toggling back restores the user's setup), so "has an axis" is
    /// NOT the same question as "symmetry is on" — both must hold, and a
    /// radial-only document (empty `mirrorAxes`) has no plane at all. The
    /// old `mirrorAxes.first ?? .x` fallback silently mirrored about an
    /// axis the user never enabled.
    var bakeableMirrorAxis: SymmetrySettings.Axis? {
        let settings = contextProvider?()?.effectiveSymmetry ?? SymmetrySettings()
        guard settings.isEnabled else { return nil }
        return settings.mirrorAxes.first
    }

    /// Re-symmetrize about one axis: mirrors the working half onto the
    /// other, preserving topology correspondence where it exists (spec
    /// scenario "Re-symmetrize"). ONE journaled command; the engine report
    /// is surfaced on the transient status line.
    ///
    /// The axis is RESOLVED from the document's symmetry state, never
    /// defaulted: with symmetry off, or with a radial-only setup, there is
    /// no axis the user enabled and the command is refused.
    @discardableResult
    func resymmetrizeNow() -> Bool {
        guard let axis = bakeableMirrorAxis else {
            onCameraToolStatus?(
                (contextProvider?()?.effectiveSymmetry.isEnabled ?? false)
                    ? Self.noMirrorAxisStatus : Self.symmetryDisabledStatus
            )
            return false
        }
        return resymmetrizeNow(about: axis)
    }

    @discardableResult
    func resymmetrizeNow(about axis: SymmetrySettings.Axis) -> Bool {
        var report: ResymmetrizeReport?
        let journaled = withSymmetryTarget(verb: "symmetry.resymmetrize") {
            mesh, settings, _ in
            report = try mesh.resymmetrize(
                settings, axis: axis,
                matchTolerance: settings.matchTolerance(sceneRadius: self.symmetrySceneRadius)
            )
        }
        if let report {
            onCameraToolStatus?(Self.resymmetrizeStatus(report, axis: axis))
        }
        return journaled
    }

    /// Human-readable summary of a re-symmetrize pass. Unmatched vertices
    /// are called out explicitly: they are the geometry that exists on one
    /// side only and was deliberately NOT destroyed.
    static func resymmetrizeStatus(
        _ report: ResymmetrizeReport, axis: SymmetrySettings.Axis
    ) -> String {
        let name = axis.rawValue.uppercased()
        guard !report.isNoOp || report.unmatched > 0 else {
            return "Already symmetric about \(name)"
        }
        var parts = ["Re-symmetrized \(report.matched) vertices about \(name)"]
        if report.snappedToPlane > 0 {
            parts.append("\(report.snappedToPlane) welded to the plane")
        }
        if report.unmatched > 0 {
            parts.append("\(report.unmatched) left (no counterpart)")
        }
        return parts.joined(separator: ", ")
    }

    /// Journals a symmetry-settings change (task 4.4: symmetry is
    /// DOCUMENT state). Journaled like the stage switch, because it
    /// changes what the next authoring stroke does: replaying history
    /// without it would replay strokes under the wrong symmetry. Returns
    /// whether anything journaled — setting the state it already has is a
    /// no-op and stays out of the undo stack.
    @discardableResult
    func setSymmetry(_ settings: SymmetrySettings) -> Bool {
        guard let context = contextProvider?() else { return false }
        guard settings != context.effectiveSymmetry else { return false }
        send(.setSymmetry(from: context.symmetry, to: settings))
        return true
    }

    /// Toolbar toggle: flips symmetry on/off, keeping the configured axes
    /// and origin so toggling back restores the user's setup. Enabling a
    /// never-configured document turns X mirroring on, which is what
    /// "symmetry" means to a user who has not opened the settings yet.
    @discardableResult
    func toggleSymmetry() -> Bool {
        guard let context = contextProvider?() else { return false }
        var settings = context.effectiveSymmetry
        settings.isEnabled.toggle()
        if settings.isEnabled, settings.mirrorAxes.isEmpty, settings.radialCount == 1 {
            settings = settings.settingMirror(.x, enabled: true)
        }
        return setSymmetry(settings)
    }

    /// Scene radius of the current context (1 when there is no context —
    /// keeps the tolerance math finite in headless unit tests).
    private var symmetrySceneRadius: Float {
        max(contextProvider?()?.sceneRadius ?? 1, 1e-6)
    }

    /// Shared epilogue for the bake commands: resolves the live EditMesh,
    /// runs `body` inside one `MeshEditTransaction`, and journals exactly
    /// one `meshEdit`. Returns whether a command reached the journal (a
    /// no-op bake serializes identically and journals nothing).
    private func withSymmetryTarget(
        verb: String,
        _ body: @escaping (Mesh, SymmetrySettings, SurfaceSnapper?) throws -> Void
    ) -> Bool {
        // Same invariant as the batch commands: a bake takes the LIVE mesh
        // handle, so an armed session's uncommitted edits must not ride
        // along into this command's journal entry.
        guard allowsWholeMeshCommand() else { return false }
        guard let context = contextProvider?(), let object = context.editObject,
            let mesh = context.editMesh, let payload = context.editPayload
        else { return false }
        // ENABLEMENT (the toolbar slots have none: `isImmediateCommand`
        // actions fire whatever the document state is). A bake is
        // destructive and irreversible-looking to the user, so it runs
        // ONLY under symmetry the user actually has switched on — the
        // retained-axes design means `mirrorAxes` alone proves nothing.
        guard context.effectiveSymmetry.isEnabled else {
            onCameraToolStatus?(Self.symmetryDisabledStatus)
            return false
        }
        guard !context.effectiveSymmetry.mirrorAxes.isEmpty else {
            onCameraToolStatus?(Self.noMirrorAxisStatus)
            return false
        }
        let settings = context.effectiveSymmetry.weldScaled(sceneRadius: context.sceneRadius)
        let transaction = MeshEditTransaction(
            object: object, mesh: mesh, currentPayload: payload
        )
        lastCommit = nil
        journalOrDiscard(verb: verb) {
            try body(mesh, settings, context.snapper)
            onLiveEdit?()
            return try transaction.command(verb: verb)
        }
        return lastCommit != nil
    }

    // MARK: - Visual-verification probe (task 4.4 screenshot hook)

    /// Enables X mirroring about the scene centre and authors ONE quad
    /// through the real create path, so the screenshot shows the plane rim
    /// with the authored quad and its mirror image. Returns whether the
    /// mirrored create journaled.
    @discardableResult
    func probeSymmetryForVisualVerification() -> Bool {
        guard let context = contextProvider?(), context.snapper != nil else { return false }
        // Author over a small screen-space square offset to one side of
        // the viewport centre, so the authored quad and its mirror land
        // apart rather than on top of each other.
        let corners: [SIMD2<Float>] = [
            SIMD2(0.62, 0.42), SIMD2(0.74, 0.42), SIMD2(0.74, 0.56), SIMD2(0.62, 0.56),
        ]
        lastCommit = nil
        applyCreate(verb: "probe.symmetryQuad", screenPoints: corners, context: context) {
            mesh, ring, snapper in
            try mesh.createFace(at: ring, snapping: snapper)
        }
        return lastCommit != nil
    }
}

extension SymmetrySettings {
    /// This state with the weld tolerance scaled to the scene, so
    /// center-line welding behaves the same at any model scale.
    func weldScaled(sceneRadius: Float) -> SymmetrySettings {
        var copy = self
        copy.weldTolerance = max(sceneRadius, 1e-6) * SymmetryTolerances.weldFraction
        return copy
    }

    /// Re-symmetrize match radius for a scene of this size.
    func matchTolerance(sceneRadius: Float) -> Float {
        max(sceneRadius, 1e-6) * SymmetryTolerances.matchFraction
    }
}

/// World-space rim geometry for the active symmetry planes (task 4.4: "a
/// visible symmetry-plane rim in the viewport").
///
/// Pure — takes settings plus the scene's bounding sphere and returns
/// line-list segments, so the whole builder is unit-testable headless and
/// the renderer only uploads what it is handed. Each enabled mirror axis
/// contributes a square outline on its plane plus a cross through the
/// symmetry origin, which reads as a plane at any camera angle (a bare
/// outline disappears edge-on).
enum SymmetryRimGeometry {
    /// Rim colour — deliberately distinct from the loop-tag palette and
    /// the yellow pin markers.
    static let color = SIMD3<Float>(0.30, 0.78, 1.0)
    /// Rim half-extent as a multiple of the scene radius: slightly larger
    /// than the model so the plane visibly cuts through it.
    static let extentFactor: Float = 1.15

    /// Line-list groups for every enabled mirror plane, in axis order.
    /// Empty when symmetry is off or no mirror axis is enabled (a purely
    /// radial setup has no plane to draw).
    static func rims(
        for settings: SymmetrySettings, center: SIMD3<Float>, radius: Float
    ) -> [AnnotationRenderState.TagGroup] {
        guard settings.isEnabled else { return [] }
        let extent = max(radius, SceneBounds.minimumRadius) * extentFactor
        return settings.mirrorAxes.map { axis in
            AnnotationRenderState.TagGroup(
                color: color,
                segments: segments(axis: axis, settings: settings, center: center, extent: extent)
            )
        }
    }

    /// One plane's outline + cross, as x,y,z triples in line-list order.
    private static func segments(
        axis: SymmetrySettings.Axis, settings: SymmetrySettings,
        center: SIMD3<Float>, extent: Float
    ) -> [Float] {
        let (u, v) = basis(for: axis)
        // Anchored at the symmetry ORIGIN along the plane normal (that is
        // where the plane is) but centred on the SCENE in-plane, so the
        // rim frames the model rather than drifting off with the origin.
        let normal: SIMD3<Float> = axis.normal
        let offset: Float = dot(center - settings.origin, normal)
        let anchor: SIMD3<Float> = center - normal * offset
        let du: SIMD3<Float> = u * extent
        let dv: SIMD3<Float> = v * extent
        let corners: [SIMD3<Float>] = [
            anchor - du - dv, anchor + du - dv, anchor + du + dv, anchor - du + dv,
        ]
        var floats: [Float] = []
        for index in corners.indices {
            append(corners[index], to: &floats)
            append(corners[(index + 1) % corners.count], to: &floats)
        }
        append(anchor - du, to: &floats)
        append(anchor + du, to: &floats)
        append(anchor - dv, to: &floats)
        append(anchor + dv, to: &floats)
        return floats
    }

    /// Two unit in-plane directions for the plane whose normal is `axis`.
    private static func basis(
        for axis: SymmetrySettings.Axis
    ) -> (SIMD3<Float>, SIMD3<Float>) {
        switch axis {
        case .x: return (SIMD3(0, 1, 0), SIMD3(0, 0, 1))
        case .y: return (SIMD3(1, 0, 0), SIMD3(0, 0, 1))
        case .z: return (SIMD3(1, 0, 0), SIMD3(0, 1, 0))
        }
    }

    private static func append(_ point: SIMD3<Float>, to floats: inout [Float]) {
        floats.append(contentsOf: [point.x, point.y, point.z])
    }
}

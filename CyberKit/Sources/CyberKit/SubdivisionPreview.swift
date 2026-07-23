import Foundation

// Non-destructive subdivision preview (task 4.6; spec: retopology-tools /
// "Subdivision preview", scenario "Editing under preview").
//
// **SMOOTH (Catmull-Clark), with optional reprojection (task 4.6a).** The
// engine now has a genuine Catmull-Clark smooth operator (`Mesh::
// smoothSubdivide` behind `cyber_retopo_subdivide_smooth`, engine patch
// 0031): the original vertices and edge points move to their
// limit-approaching positions (interior mask, boundary crease rule), so the
// cage smooths on its own — a Target-less preview genuinely rounds the form
// instead of merely densifying it.
//
// With a Target the smoothed result is then projected onto it
// (smooth-then-conform): Catmull-Clark rounds the cage toward its limit
// surface and the reprojection pins that surface onto the scan, which is the
// shape a retopologist is checking ("does my cage follow the form?"). Either
// way the preview is a real smooth surface, no longer a reprojected-linear
// stand-in.
//
// NON-DESTRUCTIVENESS is structural, not a convention: `subdivisionPreview`
// derives its result from a COPY of the base mesh (a document-payload round
// trip — the same lossless serialization the journal uses), so the engine
// handle the app edits is never handed to a mutating op. The preview mesh is
// derived RENDER DATA only: it is never journaled, never persisted into the
// document bundle and never exported.

/// Subdivision preview level (spec: "1–2 level"). Raw value is the number
/// of subdivision passes, so `.off` is genuinely zero work.
public enum SubdivisionPreviewLevel: Int, CaseIterable, Codable, Sendable {
    case off = 0
    case one = 1
    case two = 2

    /// Nearest valid level for a persisted/raw integer (out-of-range values
    /// clamp rather than silently disabling the preview).
    public init(clamping raw: Int) {
        self = SubdivisionPreviewLevel(rawValue: min(max(raw, 0), 2)) ?? .off
    }

    /// Face-count multiplier one preview at this level applies to the base
    /// cage: linear subdivision splits every n-gon into n quads, so a
    /// quad-dominant cage quadruples per level.
    public var faceMultiplier: Int { 1 << (2 * rawValue) }

    /// Short label for the viewport control and the status line.
    public var label: String {
        switch self {
        case .off: return "Off"
        case .one: return "1"
        case .two: return "2"
        }
    }

    /// Whether a preview at this level actually SMOOTHS the cage. Catmull-Clark
    /// smooths on its own now (engine patch 0031), so this is true for any
    /// non-off level regardless of a Target; a Target only additionally
    /// conforms the smoothed surface onto the scan. `hasTarget` is retained for
    /// source compatibility with callers deciding messaging.
    public func smoothingIsAvailable(hasTarget: Bool) -> Bool {
        self != .off
    }
}

/// When a live (mid-edit) preview rebuild is affordable.
///
/// **THROTTLE POLICY (one place, tested).** Two independent mechanisms, in
/// order:
///
///  1. *Frame coalescing* (owned by the app's viewport coordinator): preview
///     derivation rides the SAME once-per-rendered-frame refresh hook the
///     wireframe upload uses (`ViewportRenderer.pendingGeometryRefresh`), so
///     no matter how many coalesced Pencil samples arrive — up to 240 Hz on
///     ProMotion — the preview is derived at most once per frame.
///
///  2a. *Derivation-cost guard* (here): the preview is built on a DETACHED
///     COPY, and the engine capi exposes no `cyber_mesh_clone` — so the copy
///     is an OBJ write/read round trip through the filesystem
///     (`Mesh.detachedCopy`), whose cost scales with the BASE cage, not with
///     the preview. That cost is real and it is paid on the main actor, so
///     it gets its own budget: `liveBaseFaceBudget`. Without it a small
///     preview face count (well under `liveFaceBudget`) would wave through
///     a cage whose per-frame disk round trip is the dominant expense —
///     which is precisely the case the face budget alone used to miss.
///
///  2b. *Rate guard* (here): even inside both budgets, a rebuild must not
///     run on every rendered frame of a ProMotion display. Callers stamp
///     `minimumLiveRebuildInterval` between mid-stroke rebuilds
///     (`shouldRebuildNow(since:now:)`), so the preview tracks the drag at a
///     bounded rate rather than at the display's refresh rate.
///
///  3. *Face-count guard* (here): a level-2 preview of a big cage is a 16x mesh
///     rebuild plus a 16x BVH projection, which cannot finish inside a frame.
///     While a stroke is IN FLIGHT, a rebuild is skipped whenever the
///     projected preview face count exceeds `liveFaceBudget`; the previously
///     derived preview stays on screen (stale for the duration of the drag)
///     instead of dropping the frame rate. The moment the stroke ENDS —
///     commit or cancel, both of which re-enter the normal document-sync
///     path — the preview is rebuilt unconditionally, so what the user is
///     left looking at is always exact.
///
/// Below the budget every live edit rebuilds the preview, which is the
/// interactive-latency requirement for the cages this stage actually works
/// on (the spec's scenario slides an edge loop on a retopology cage).
public enum SubdivisionPreviewPolicy: Sendable {
    /// Maximum preview face count still rebuilt DURING a stroke. Sized so a
    /// level-2 preview of a ~1 200-quad cage (a realistic dense retopology
    /// cage) still updates live, while pathological inputs degrade to
    /// rebuild-on-commit instead of to dropped frames.
    public static let liveFaceBudget = 20_000

    /// Maximum BASE cage face count whose detached-copy round trip is still
    /// affordable inside a frame. The copy writes and re-parses an OBJ for
    /// the whole base cage on every rebuild, so this budget — not the
    /// preview face count — is what bounds the dominant per-rebuild cost.
    public static let liveBaseFaceBudget = 2_000

    /// Minimum wall-clock gap between two MID-STROKE rebuilds. Chosen so a
    /// live preview updates at ~20 Hz: fast enough to read as tracking the
    /// drag, slow enough that a 120 Hz display never pays the derivation
    /// cost six times per visible change.
    public static let minimumLiveRebuildInterval: TimeInterval = 0.05

    /// Whether enough time has passed since the last mid-stroke rebuild.
    /// `last` nil = nothing derived yet during this stroke, so rebuild.
    public static func shouldRebuildNow(since last: Date?, now: Date = Date()) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= minimumLiveRebuildInterval
    }

    /// Faces the preview will have: the base face count times the level's
    /// multiplier (exact for the quad-dominant cages this stage produces,
    /// an underestimate for n-gons — which is fine, the guard is a budget).
    public static func previewFaceCount(baseFaces: Int, level: SubdivisionPreviewLevel) -> Int {
        baseFaces * level.faceMultiplier
    }

    /// Whether a rebuild should run right now.
    ///
    /// - Parameters:
    ///   - baseFaces: face count of the base cage.
    ///   - level: requested preview level.
    ///   - duringStroke: true while a brush/authoring session is in flight.
    public static func allowsRebuild(
        baseFaces: Int, level: SubdivisionPreviewLevel, duringStroke: Bool
    ) -> Bool {
        guard level != .off, baseFaces > 0 else { return false }
        guard duringStroke else { return true }
        // BOTH budgets: the preview's own size, and the base cage whose
        // detached-copy round trip is paid on every single rebuild.
        guard baseFaces <= liveBaseFaceBudget else { return false }
        return previewFaceCount(baseFaces: baseFaces, level: level) <= liveFaceBudget
    }
}

extension Mesh {
    /// Derives the non-destructive subdivision preview of this cage.
    ///
    /// `self` is **never mutated**: the preview is built on a `detachedCopy`,
    /// so the engine op (which
    /// rebuilds the mesh and reassigns every element id) can only ever touch
    /// the throwaway handle. The returned mesh is derived render data — the
    /// caller must not journal, persist or export it.
    ///
    /// Reprojection runs after EVERY level, not once at the end: projecting
    /// the intermediate result means the next level's midpoints are computed
    /// from points already on the surface, which is what keeps a level-2
    /// preview from cutting corners across curvature.
    ///
    /// Returns nil at `.off` and for an empty cage (nothing to preview).
    public func subdivisionPreview(
        level: SubdivisionPreviewLevel,
        reprojectingOnto snapper: SurfaceSnapper? = nil
    ) throws -> Mesh? {
        guard level != .off, faceCount > 0 else { return nil }
        let preview = try detachedCopy()
        for _ in 0..<level.rawValue {
            try preview.smoothSubdivide(reprojectingOnto: snapper)
        }
        return preview
    }
}

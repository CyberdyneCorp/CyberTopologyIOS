import CyberKit
import CyberKitTesting
import Foundation
import simd

/// Weave Fill capture (openspec add-weave-region-selection, task 2).
///
/// Fills bare Target with quads that meet the existing cage's open boundary exactly.
/// Two ways in, both resolved here into the same intent:
///
/// - **TAP** on bare Target → propose the next patch outward from the nearest free
///   cage edge, at a default extent. No selection step.
/// - **PAINT** across bare Target → say how far to fill; successive strokes extend
///   the area rather than replacing it.
///
/// Neither classifies the stroke's SHAPE. `simplify-gesture-grammar` removed the
/// lasso from the Pencil grammar because on device a closed quad stroke with a slight
/// overshoot classified as `lasso` → `hideRegion`; an armed tool has nothing to
/// misread. Tap versus paint is `CameraToolStrokes.isTap`, the same test the camera
/// tools already use.
///
/// Capture journals NOTHING. The intent is an unexecuted request; the document only
/// changes if the user accepts the proposal it produces (task 3).

/// An unexecuted fill request. Not document state, not persisted.
struct WeaveFillIntent: Equatable {
    /// Where the user asked to fill — chooses which stretch of cage boundary to
    /// grow from, so it is required (`WeaveFillDomain` refuses without one).
    var fillPoint: SIMD3<Float>
    /// Target-surface points the user painted. Empty for a tap.
    var extent: [SIMD3<Float>]
    /// True when the request came from a tap rather than a paint stroke.
    var isTap: Bool

    /// A tap asks for the default band; paint asks for whatever it covered.
    var wantsDefaultExtent: Bool { extent.isEmpty }
}

extension MeshEditController {

    /// A finished Weave Fill stroke. A tap (re)starts a request at the tapped point;
    /// anything else unions its Target hits into the painted extent.
    func handleWeaveFillStroke(_ stroke: ToolStroke, samples: [StrokeSample]) {
        let points = samples.map { point(of: $0) }
        guard !points.isEmpty else { return }
        let context = stroke.context
        let hits = strokeSurfaceHits(samples: points, context: context)
        // A stroke that missed the Target asks for nothing — it is not an error and
        // must not clear a request the user already made.
        guard !hits.isEmpty else { return }

        if CameraToolStrokes.isTap(points: points) {
            // A tap REPLACES the request: it means "fill here", not "also here".
            weaveFillIntent = WeaveFillIntent(fillPoint: hits[0], extent: [], isTap: true)
        } else {
            var intent = weaveFillIntent ?? WeaveFillIntent(
                fillPoint: hits[0], extent: [], isTap: false
            )
            intent.isTap = false
            intent.extent.append(contentsOf: hits)
            // The fill direction is the centre of everything painted so far, so a
            // second stroke steers the run as well as extending the reach.
            intent.fillPoint = Self.centroid(intent.extent) ?? hits[0]
            weaveFillIntent = intent
        }
        onWeaveFillIntentChanged?(weaveFillIntent)
    }

    /// Drops the pending request. Journals nothing — there was never a document change.
    func clearWeaveFill() {
        guard weaveFillIntent != nil else { return }
        weaveFillIntent = nil
        onWeaveFillIntentChanged?(nil)
    }

    static func centroid(_ points: [SIMD3<Float>]) -> SIMD3<Float>? {
        guard !points.isEmpty else { return nil }
        return points.reduce(SIMD3<Float>.zero, +) / Float(points.count)
    }
}

import CyberKit
import Foundation
import simd

// Camera-as-manipulator tool sessions (task 4.2; spec: retopology-tools /
// "Core RT action roster" — Patch Clone, Extend Boundary, Transform
// Vertices; Draw Strip is the stroke-driven sibling in the same roster).
//
// This file is the PURE half (design D5 precedent: `InputArbiter`,
// `HoverPreviewState`): placement math, per-tool session plans, stroke
// resampling and selection helpers, and the ghost preview geometry — no
// UIKit, no engine handles, every rule headless-testable. The controller
// glue (engine queries, journaled commits, camera feed) lives in
// `MeshEditCameraTools.swift`.

/// Placement math shared by the camera-driven sessions. The core rule is
/// SCREEN LOCK: geometry armed to the camera keeps its screen position
/// while the camera moves, i.e. it moves over the model by
/// `p' = V_now⁻¹ · V₀ · p` (rigid — the shared projection cancels).
/// Pinch zoom additionally scales about the pivot (distance ratio) and
/// Pencil Pro barrel roll rotates about the current view axis.
enum PlacementMath {
    /// The rigid world transform keeping geometry screen-locked between
    /// two camera poses (view matrices).
    static func screenLockTransform(
        fromView initial: simd_float4x4, toView current: simd_float4x4
    ) -> simd_float4x4 {
        current.inverse * initial
    }

    /// Pinch-scale factor from the camera distance ratio, clamped so a
    /// runaway zoom cannot collapse or explode the placement.
    static func pinchScale(initialDistance: Float, currentDistance: Float) -> Float {
        guard initialDistance > 0, currentDistance > 0 else { return 1 }
        return simd_clamp(initialDistance / currentDistance, 0.2, 5)
    }

    static func translationMatrix(_ t: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4(t.x, t.y, t.z, 1)
        return m
    }

    static func rotationMatrix(axis: SIMD3<Float>, angle: Float) -> simd_float4x4 {
        let length = simd_length(axis)
        guard length > .ulpOfOne, angle != 0 else { return matrix_identity_float4x4 }
        return simd_float4x4(simd_quatf(angle: angle, axis: axis / length))
    }

    static func scaleMatrix(_ s: Float) -> simd_float4x4 {
        simd_float4x4(diagonal: SIMD4(s, s, s, 1))
    }

    /// Reflection across the plane through the origin with normal `n`
    /// (the Patch Clone flip; pair with reversed winding).
    static func reflectionMatrix(normal: SIMD3<Float>) -> simd_float4x4 {
        let length = simd_length(normal)
        guard length > .ulpOfOne else { return matrix_identity_float4x4 }
        let n = normal / length
        var m = matrix_identity_float4x4
        m.columns.0 = SIMD4(1 - 2 * n.x * n.x, -2 * n.y * n.x, -2 * n.z * n.x, 0)
        m.columns.1 = SIMD4(-2 * n.x * n.y, 1 - 2 * n.y * n.y, -2 * n.z * n.y, 0)
        m.columns.2 = SIMD4(-2 * n.x * n.z, -2 * n.y * n.z, 1 - 2 * n.z * n.z, 0)
        return m
    }

    /// The full placement transform: optional flip (reflection about the
    /// selection pivot along `flipNormal`), the screen-lock rigid part,
    /// then barrel-roll rotation and pinch scale about the TRANSFORMED
    /// pivot along the current view axis.
    static func placementTransform(
        initialView: simd_float4x4, currentView: simd_float4x4,
        pivot: SIMD3<Float>, scale: Float, rollAngle: Float,
        viewAxis: SIMD3<Float>, flipped: Bool, flipNormal: SIMD3<Float>
    ) -> simd_float4x4 {
        var m = screenLockTransform(fromView: initialView, toView: currentView)
        if flipped {
            let flip = translationMatrix(pivot)
                * reflectionMatrix(normal: flipNormal)
                * translationMatrix(-pivot)
            m = m * flip
        }
        let p4 = m * SIMD4(pivot.x, pivot.y, pivot.z, 1)
        let movedPivot = SIMD3(p4.x, p4.y, p4.z)
        let local = rotationMatrix(axis: viewAxis, angle: rollAngle) * scaleMatrix(scale)
        return translationMatrix(movedPivot) * local * translationMatrix(-movedPivot) * m
    }

    /// Where the screen-lock transform puts `point` (the Extend Boundary
    /// offset source: the chain centroid's displacement).
    static func displacement(
        of point: SIMD3<Float>, initialView: simd_float4x4, currentView: simd_float4x4
    ) -> SIMD3<Float> {
        let m = screenLockTransform(fromView: initialView, toView: currentView)
        let p = m * SIMD4(point.x, point.y, point.z, 1)
        return SIMD3(p.x, p.y, p.z) - point
    }
}

// MARK: - Per-tool session plans (pure state)

/// Patch Clone: faces selected with one stroke, repositioned by the
/// camera, pasted repeatedly (spec scenario "Patch Clone round-trip").
struct PatchClonePlan: Equatable {
    var faces: [UInt32]
    /// Selection centroid (transform pivot).
    var pivot: SIMD3<Float>
    /// Average selection normal (the flip mirror plane's normal).
    var patchNormal: SIMD3<Float>
    /// Flip option: mirrors the patch (cloned with reversed winding).
    var flipped = false
    var scale: Float = 1
    /// Barrel-roll rotation about the view axis (radians).
    var rollAngle: Float = 0
    var pasteCount = 0
}

/// Extend Boundary: an ordered boundary chain extruded by camera-driven
/// quad strips (spec scenario "Extend Boundary automatic mode").
struct ExtendBoundaryPlan: Equatable {
    /// The spec's modes: `single` extrudes ONE camera-adjusted row per
    /// commit, `once` auto-commits as soon as one full row accumulated,
    /// `automatic` keeps stepping rows while the camera moves (all rows
    /// journal as ONE entry at commit), `fan` closes the chain onto one
    /// camera-placed apex with triangles (the roster's triangle fans).
    enum Mode: String, CaseIterable, Equatable {
        case single
        case once
        case automatic
        case fan
    }

    var mode: Mode = .single
    var chain: [UInt32]
    var closed: Bool
    /// One quad-row step: the chain's average edge length.
    var step: Float
    /// Rows already stepped off (once/automatic), in commit order.
    var steppedOffsets: [SIMD3<Float>] = []
    /// Continuous camera displacement of the chain centroid.
    var displacement: SIMD3<Float> = .zero
    /// `once` consumed its row: the session should commit now.
    var wantsAutoCommit = false

    /// Camera feed: updates the continuous displacement and, in
    /// once/automatic modes, steps off full rows as they accumulate
    /// (each row consumes `step` length of the remaining displacement).
    mutating func displacementChanged(_ total: SIMD3<Float>) {
        displacement = total
        // `once` steps exactly one row, ever — even if further feeds
        // arrive before the auto-commit lands.
        guard mode == .automatic || (mode == .once && !wantsAutoCommit),
            step > 0
        else { return }
        var consumed = steppedOffsets.reduce(SIMD3<Float>.zero, +)
        while true {
            let remainder = displacement - consumed
            guard simd_length(remainder) >= step else { break }
            let row = simd_normalize(remainder) * step
            steppedOffsets.append(row)
            consumed += row
            if mode == .once {
                wantsAutoCommit = true
                break
            }
        }
    }

    /// The quad-row offsets a commit right now would extrude, in order.
    /// nil rows = nothing to commit (fan commits an apex instead).
    var commitOffsets: [SIMD3<Float>] {
        switch mode {
        case .single:
            return simd_length(displacement) > max(step * 0.05, .ulpOfOne)
                ? [displacement] : []
        case .once, .automatic:
            return steppedOffsets
        case .fan:
            return []
        }
    }

    var canCommit: Bool {
        mode == .fan ? simd_length(displacement) > 0 : !commitOffsets.isEmpty
    }
}

/// Transform Vertices: vertices selected with a stroke lock to screen
/// space; the camera moves them over the model, commit re-snaps and
/// reports how many moved.
struct TransformVerticesPlan: Equatable {
    var vertices: [UInt32]
    var pivot: SIMD3<Float>
    var scale: Float = 1
    var rollAngle: Float = 0
}

// MARK: - Selection + stroke helpers (pure)

enum CameraToolStrokes {
    /// Normalized-viewport extent below which a stroke is a TAP/HOLD
    /// (commit gesture / boundary auto-select hold).
    static let tapExtent: Float = 0.02

    /// Whether the sample points stay within the tap extent of the first.
    static func isTap(points: [SIMD2<Float>]) -> Bool {
        guard let first = points.first else { return false }
        return points.allSatisfy { simd_distance($0, first) <= tapExtent }
    }

    /// Arc-length resampling of a world polyline: stations every `step`
    /// along the path, first station one `step` in (the Draw Strip quad
    /// grid: one station per source-quad-size length). Empty when the
    /// path is shorter than one step.
    static func resample(_ points: [SIMD3<Float>], step: Float) -> [SIMD3<Float>] {
        guard step > 0, points.count >= 2 else { return [] }
        var stations: [SIMD3<Float>] = []
        var nextDistance = step
        var traveled: Float = 0
        for index in 1..<points.count {
            var segmentStart = points[index - 1]
            var segmentLength = simd_distance(segmentStart, points[index])
            while traveled + segmentLength >= nextDistance, segmentLength > 0 {
                let t = (nextDistance - traveled) / segmentLength
                let station = segmentStart + (points[index] - segmentStart) * t
                stations.append(station)
                // Continue within the same segment from the new station.
                traveled = nextDistance
                nextDistance += step
                segmentLength = simd_distance(station, points[index])
                segmentStart = station
            }
            traveled += segmentLength
        }
        return stations
    }

    /// The longest contiguous run of marked chain indices (wrapping on
    /// closed chains), in chain order — the Extend Boundary sub-chain a
    /// stroke along part of the boundary selects. Empty when nothing is
    /// marked; the full index range when everything is.
    static func contiguousRun(marked: [Bool], closed: Bool) -> [Int] {
        let count = marked.count
        guard count > 0 else { return [] }
        if marked.allSatisfy({ $0 }) { return Array(0..<count) }
        var bestStart = 0
        var bestLength = 0
        var start: Int?
        // Scan twice around for closed chains so wrap runs count once.
        let laps = closed ? 2 * count : count
        for i in 0..<laps {
            if marked[i % count] {
                if start == nil { start = i }
                let length = min(i - (start ?? i) + 1, count)
                if length > bestLength {
                    bestLength = length
                    bestStart = (start ?? i) % count
                }
            } else {
                start = nil
            }
        }
        guard bestLength > 0 else { return [] }
        return (0..<bestLength).map { (bestStart + $0) % count }
    }
}

// MARK: - Ghost preview geometry (pure)

/// Session previews render as ghost geometry through the hover ghost
/// channel (`GhostRenderPath`, task 2.4/3.6): translucent pulsing fill,
/// never a committed mutation.
enum PlacementPreviewGeometry {
    /// The selected patch transformed by the placement matrix: base
    /// positions/normals from the selection-time scratch mesh, moved on
    /// the CPU per camera pose (positions by the affine, normals by its
    /// linear part).
    static func transformedGhost(
        positions: [Float], normals: [Float], indices: [UInt32],
        transform: MeshTransform
    ) -> HoverRenderState.GhostQuad? {
        guard !positions.isEmpty, positions.count == normals.count,
            positions.count.isMultiple(of: 3), !indices.isEmpty
        else { return nil }
        var movedPositions = [Float]()
        var movedNormals = [Float]()
        movedPositions.reserveCapacity(positions.count)
        movedNormals.reserveCapacity(normals.count)
        for base in stride(from: 0, to: positions.count, by: 3) {
            let p = transform.apply(
                SIMD3(positions[base], positions[base + 1], positions[base + 2])
            )
            movedPositions.append(contentsOf: [p.x, p.y, p.z])
            var n = transform.applyDirection(
                SIMD3(normals[base], normals[base + 1], normals[base + 2])
            )
            let length = simd_length(n)
            n = length > .ulpOfOne ? n / length : SIMD3(0, 0, 1)
            movedNormals.append(contentsOf: [n.x, n.y, n.z])
        }
        return HoverRenderState.GhostQuad(
            positions: movedPositions, normals: movedNormals, indices: indices
        )
    }

    /// Quad-strip rows extruded off the chain by successive offsets (the
    /// Extend Boundary grid preview): row r's vertices sit at
    /// chain + offsets[0] + … + offsets[r].
    static func ringsGhost(
        chain: [SIMD3<Float>], closed: Bool, offsets: [SIMD3<Float>]
    ) -> HoverRenderState.GhostQuad? {
        guard chain.count >= 2, !offsets.isEmpty else { return nil }
        let columns = chain.count
        var positions: [Float] = []
        var normals: [Float] = []
        var indices: [UInt32] = []
        var accumulated = SIMD3<Float>.zero
        var rows: [[SIMD3<Float>]] = [chain]
        for offset in offsets {
            accumulated += offset
            rows.append(chain.map { $0 + accumulated })
        }
        for row in rows {
            for (index, point) in row.enumerated() {
                positions.append(contentsOf: [point.x, point.y, point.z])
                let next = row[(index + 1) % row.count]
                let previous = row[(index + row.count - 1) % row.count]
                var normal = simd_cross(next - previous, offsets[0])
                let length = simd_length(normal)
                normal = length > .ulpOfOne ? normal / length : SIMD3(0, 0, 1)
                normals.append(contentsOf: [normal.x, normal.y, normal.z])
            }
        }
        let quadCount = closed && columns >= 3 ? columns : columns - 1
        for row in 0..<(rows.count - 1) {
            let rowBase = UInt32(row * columns)
            let nextBase = UInt32((row + 1) * columns)
            for i in 0..<quadCount {
                let a = rowBase + UInt32(i)
                let b = rowBase + UInt32((i + 1) % columns)
                let c = nextBase + UInt32((i + 1) % columns)
                let d = nextBase + UInt32(i)
                indices.append(contentsOf: [a, b, c, a, c, d])
            }
        }
        return HoverRenderState.GhostQuad(
            positions: positions, normals: normals, indices: indices
        )
    }

    /// Triangle fan from the chain to a single apex (the Extend Boundary
    /// fan preview).
    static func fanGhost(
        chain: [SIMD3<Float>], closed: Bool, apex: SIMD3<Float>
    ) -> HoverRenderState.GhostQuad? {
        guard chain.count >= 2 else { return nil }
        var positions: [Float] = []
        var normals: [Float] = []
        var indices: [UInt32] = []
        let centroid = chain.reduce(SIMD3<Float>.zero, +) / Float(chain.count)
        var normal = apex - centroid
        let length = simd_length(normal)
        normal = length > .ulpOfOne ? normal / length : SIMD3(0, 0, 1)
        for point in chain + [apex] {
            positions.append(contentsOf: [point.x, point.y, point.z])
            normals.append(contentsOf: [normal.x, normal.y, normal.z])
        }
        let apexIndex = UInt32(chain.count)
        let edgeCount = closed && chain.count >= 3 ? chain.count : chain.count - 1
        for i in 0..<edgeCount {
            indices.append(contentsOf: [
                UInt32(i), UInt32((i + 1) % chain.count), apexIndex,
            ])
        }
        return HoverRenderState.GhostQuad(
            positions: positions, normals: normals, indices: indices
        )
    }
}

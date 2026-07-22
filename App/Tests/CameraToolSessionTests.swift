import CyberKit
import Foundation
import Testing
import simd
@testable import CyberTopology

/// Task 4.2, pure half (design D5 precedent): the camera-as-manipulator
/// placement math, the per-tool session plans, the stroke/selection
/// helpers, and the ghost preview geometry — all headless, no engine, no
/// UIKit.
struct PlacementMathTests {
    /// Screen lock is exact by construction: V_now · M = V_0, so a
    /// transformed point projects to the SAME normalized screen point
    /// under the new camera as the original did under the old one.
    @Test func screenLockKeepsScreenPositionAcrossAnOrbit() throws {
        var before = CameraState(focus: SIMD3(0.2, -0.1, 0.4), distance: 3)
        before.azimuth = 0.5
        before.elevation = 0.2
        var after = before
        after.orbit(byPoints: SIMD2(140, -60), speed: 1)
        after.pan(byPoints: SIMD2(30, 20), viewportHeight: 800)

        let m = PlacementMath.screenLockTransform(
            fromView: before.viewMatrix(), toView: after.viewMatrix()
        )
        let bounds = SceneBounds.unit
        let point = SIMD3<Float>(0.3, 0.1, -0.2)
        let moved4 = m * SIMD4(point.x, point.y, point.z, 1)
        let moved = SIMD3(moved4.x, moved4.y, moved4.z)

        func columns(_ camera: CameraState) -> [Float] {
            let mvp = camera.projectionMatrix(aspect: 1.5, bounds: bounds)
                * camera.viewMatrix()
            var out: [Float] = []
            for column in [mvp.columns.0, mvp.columns.1, mvp.columns.2, mvp.columns.3] {
                out.append(contentsOf: [column.x, column.y, column.z, column.w])
            }
            return out
        }
        let screenBefore = try #require(ScreenRay.normalizedPoint(
            of: point, viewProjectionColumns: columns(before)
        ))
        let screenAfter = try #require(ScreenRay.normalizedPoint(
            of: moved, viewProjectionColumns: columns(after)
        ))
        #expect(simd_distance(screenBefore, screenAfter) < 1e-4)
        // And the camera did actually move the point in world space.
        #expect(simd_distance(point, moved) > 0.1)
    }

    @Test func identicalPosesYieldTheIdentity() {
        let camera = CameraState(focus: .zero, distance: 2)
        let m = PlacementMath.screenLockTransform(
            fromView: camera.viewMatrix(), toView: camera.viewMatrix()
        )
        let p = m * SIMD4<Float>(1, 2, 3, 1)
        #expect(simd_distance(SIMD3(p.x, p.y, p.z), SIMD3(1, 2, 3)) < 1e-5)
    }

    @Test func pinchScaleIsTheClampedDistanceRatio() {
        #expect(PlacementMath.pinchScale(initialDistance: 2, currentDistance: 1) == 2)
        #expect(PlacementMath.pinchScale(initialDistance: 1, currentDistance: 2) == 0.5)
        #expect(PlacementMath.pinchScale(initialDistance: 100, currentDistance: 1) == 5)
        #expect(PlacementMath.pinchScale(initialDistance: 1, currentDistance: 100) == 0.2)
        #expect(PlacementMath.pinchScale(initialDistance: 0, currentDistance: 1) == 1)
    }

    @Test func rollRotatesAboutTheViewAxisThroughThePivot() {
        let camera = CameraState(focus: .zero, distance: 2, azimuth: 0, elevation: 0)
        let view = camera.viewMatrix()
        let pivot = SIMD3<Float>(1, 0, 0)
        let m = PlacementMath.placementTransform(
            initialView: view, currentView: view,
            pivot: pivot, scale: 1, rollAngle: .pi / 2,
            viewAxis: camera.basis.forward, flipped: false, flipNormal: SIMD3(0, 0, 1)
        )
        // The pivot is a fixed point.
        let movedPivot = m * SIMD4(pivot.x, pivot.y, pivot.z, 1)
        #expect(simd_distance(SIMD3(movedPivot.x, movedPivot.y, movedPivot.z), pivot) < 1e-5)
        // A point one unit +x of the pivot rotates 90° about the view
        // axis (camera at azimuth/elevation 0 looks along -z: axis -z).
        let p = m * SIMD4<Float>(2, 0, 0, 1)
        let rotated = SIMD3(p.x, p.y, p.z) - pivot
        #expect(abs(simd_length(rotated) - 1) < 1e-5)
        #expect(abs(rotated.x) < 1e-5)
        #expect(abs(abs(rotated.y) - 1) < 1e-5)
    }

    @Test func scaleGrowsAboutThePivot() {
        let camera = CameraState(focus: .zero, distance: 2)
        let view = camera.viewMatrix()
        let pivot = SIMD3<Float>(0, 1, 0)
        let m = PlacementMath.placementTransform(
            initialView: view, currentView: view,
            pivot: pivot, scale: 2, rollAngle: 0,
            viewAxis: camera.basis.forward, flipped: false, flipNormal: SIMD3(0, 0, 1)
        )
        let p = m * SIMD4<Float>(1, 1, 0, 1)
        #expect(simd_distance(SIMD3(p.x, p.y, p.z), SIMD3(2, 1, 0)) < 1e-5)
    }

    @Test func flipReflectsAcrossThePivotPlane() {
        let camera = CameraState(focus: .zero, distance: 2)
        let view = camera.viewMatrix()
        let pivot = SIMD3<Float>(0, 0, 1)
        let m = PlacementMath.placementTransform(
            initialView: view, currentView: view,
            pivot: pivot, scale: 1, rollAngle: 0,
            viewAxis: camera.basis.forward, flipped: true, flipNormal: SIMD3(0, 0, 1)
        )
        // A point 0.5 above the plane lands 0.5 below it; in-plane
        // coordinates are untouched.
        let p = m * SIMD4<Float>(0.3, -0.2, 1.5, 1)
        #expect(simd_distance(SIMD3(p.x, p.y, p.z), SIMD3(0.3, -0.2, 0.5)) < 1e-5)
    }

    @Test func displacementTracksTheScreenLockedPoint() {
        let before = CameraState(focus: .zero, distance: 3)
        var after = before
        after.orbit(byPoints: SIMD2(200, 0), speed: 1)
        let d = PlacementMath.displacement(
            of: SIMD3(0.5, 0, 0),
            initialView: before.viewMatrix(), currentView: after.viewMatrix()
        )
        #expect(simd_length(d) > 0.1)
        // Identity when nothing moved.
        let zero = PlacementMath.displacement(
            of: SIMD3(0.5, 0, 0),
            initialView: before.viewMatrix(), currentView: before.viewMatrix()
        )
        #expect(simd_length(zero) < 1e-5)
    }
}

// MARK: - Extend Boundary plan (modes state machine)

struct ExtendBoundaryPlanTests {
    private func plan(mode: ExtendBoundaryPlan.Mode) -> ExtendBoundaryPlan {
        ExtendBoundaryPlan(mode: mode, chain: [0, 1, 2], closed: false, step: 1)
    }

    @Test func singleModeCommitsTheLiveDisplacementRow() {
        var p = plan(mode: .single)
        #expect(!p.canCommit)
        p.displacementChanged(SIMD3(0, -0.4, 0))
        #expect(p.commitOffsets == [SIMD3(0, -0.4, 0)])
        #expect(p.canCommit)
        #expect(p.steppedOffsets.isEmpty)
        #expect(!p.wantsAutoCommit)
        // The row follows the camera continuously.
        p.displacementChanged(SIMD3(0, -2.5, 0))
        #expect(p.commitOffsets == [SIMD3(0, -2.5, 0)])
    }

    @Test func automaticModeStepsQuadSizedRowsWhileTheCameraMoves() {
        var p = plan(mode: .automatic)
        p.displacementChanged(SIMD3(0.6, 0, 0))
        #expect(p.steppedOffsets.isEmpty)  // less than one step
        p.displacementChanged(SIMD3(2.5, 0, 0))
        #expect(p.steppedOffsets.count == 2)  // 2.5 accumulated, step 1
        for row in p.steppedOffsets {
            #expect(abs(simd_length(row) - 1) < 1e-5)
        }
        #expect(!p.wantsAutoCommit)
        // Rows follow the CURRENT remainder direction, not the first.
        p.displacementChanged(SIMD3(2.5, 1.2, 0))
        #expect(p.steppedOffsets.count == 3)
        let third = p.steppedOffsets[2]
        #expect(third.y > 0.5)
        #expect(p.commitOffsets == p.steppedOffsets)
    }

    @Test func onceModeStepsExactlyOneRowThenWantsAutoCommit() {
        var p = plan(mode: .once)
        p.displacementChanged(SIMD3(0, 0, 0.4))
        #expect(!p.wantsAutoCommit)
        p.displacementChanged(SIMD3(0, 0, 3))
        #expect(p.steppedOffsets.count == 1)
        #expect(p.wantsAutoCommit)
        // Never steps a second row.
        p.displacementChanged(SIMD3(0, 0, 9))
        #expect(p.steppedOffsets.count == 1)
    }

    @Test func fanModeCommitsOnAnyDisplacement() {
        var p = plan(mode: .fan)
        #expect(!p.canCommit)
        p.displacementChanged(SIMD3(0, 0, 0.2))
        #expect(p.canCommit)
        #expect(p.commitOffsets.isEmpty)  // the fan commits an apex, not rows
    }
}

// MARK: - Stroke helpers

struct CameraToolStrokesTests {
    @Test func tapDetectionUsesTheScreenExtent() {
        let center = SIMD2<Float>(0.5, 0.5)
        #expect(CameraToolStrokes.isTap(points: [center, center + SIMD2(0.01, 0)]))
        #expect(!CameraToolStrokes.isTap(points: [center, center + SIMD2(0.1, 0)]))
        #expect(!CameraToolStrokes.isTap(points: []))
    }

    @Test func resampleSpacesStationsByArcLength() {
        let path: [SIMD3<Float>] = [
            SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(2, 0, 0), SIMD3(3.2, 0, 0),
        ]
        let stations = CameraToolStrokes.resample(path, step: 1)
        #expect(stations.count == 3)
        #expect(simd_distance(stations[0], SIMD3(1, 0, 0)) < 1e-5)
        #expect(simd_distance(stations[1], SIMD3(2, 0, 0)) < 1e-5)
        #expect(simd_distance(stations[2], SIMD3(3, 0, 0)) < 1e-5)
        // Shorter than one step: nothing.
        #expect(CameraToolStrokes.resample(
            [SIMD3(0, 0, 0), SIMD3(0.4, 0, 0)], step: 1
        ).isEmpty)
        #expect(CameraToolStrokes.resample([], step: 1).isEmpty)
        #expect(CameraToolStrokes.resample(path, step: 0).isEmpty)
    }

    @Test func resampleFollowsCorners() {
        // An L: 1 along +x then 1 along +y, stations every 0.5.
        let path: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0)]
        let stations = CameraToolStrokes.resample(path, step: 0.5)
        #expect(stations.count == 4)
        #expect(simd_distance(stations[1], SIMD3(1, 0, 0)) < 1e-5)
        #expect(simd_distance(stations[3], SIMD3(1, 1, 0)) < 1e-5)
    }

    @Test func contiguousRunFindsTheLongestMarkedStretch() {
        #expect(CameraToolStrokes.contiguousRun(
            marked: [false, true, true, true, false], closed: false
        ) == [1, 2, 3])
        // Wrapping run on a closed chain.
        #expect(CameraToolStrokes.contiguousRun(
            marked: [true, false, false, true, true], closed: true
        ) == [3, 4, 0])
        // The same marks unwrapped split into two runs; the longer wins.
        #expect(CameraToolStrokes.contiguousRun(
            marked: [true, false, false, true, true], closed: false
        ) == [3, 4])
        #expect(CameraToolStrokes.contiguousRun(
            marked: [true, true, true], closed: true
        ) == [0, 1, 2])
        #expect(CameraToolStrokes.contiguousRun(
            marked: [false, false], closed: false
        ).isEmpty)
        #expect(CameraToolStrokes.contiguousRun(marked: [], closed: true).isEmpty)
    }
}

// MARK: - Ghost preview geometry

struct PlacementPreviewGeometryTests {
    @Test func transformedGhostMovesPositionsAndRotatesNormals() throws {
        let rotate = MeshTransform(PlacementMath.rotationMatrix(
            axis: SIMD3(0, 0, 1), angle: .pi / 2
        ))
        let ghost = try #require(PlacementPreviewGeometry.transformedGhost(
            positions: [1, 0, 0, 0, 1, 0, 0, 0, 1],
            normals: [1, 0, 0, 0, 0, 1, 0, 0, 1],
            indices: [0, 1, 2],
            transform: rotate
        ))
        #expect(ghost.indices == [0, 1, 2])
        // (1,0,0) -> (0,1,0)
        #expect(abs(ghost.positions[0]) < 1e-5)
        #expect(abs(ghost.positions[1] - 1) < 1e-5)
        // Normal (1,0,0) -> (0,1,0), still unit.
        #expect(abs(ghost.normals[0]) < 1e-5)
        #expect(abs(ghost.normals[1] - 1) < 1e-5)
        // Degenerate inputs are nil.
        #expect(PlacementPreviewGeometry.transformedGhost(
            positions: [], normals: [], indices: [], transform: .identity
        ) == nil)
        #expect(PlacementPreviewGeometry.transformedGhost(
            positions: [1, 0, 0], normals: [], indices: [0], transform: .identity
        ) == nil)
    }

    @Test func ringsGhostBuildsOneQuadPerColumnPerRow() throws {
        let chain: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(2, 0, 0)]
        let open = try #require(PlacementPreviewGeometry.ringsGhost(
            chain: chain, closed: false, offsets: [SIMD3(0, -1, 0), SIMD3(0, -1, 0)]
        ))
        // 3 rows of 3 vertices; 2 quads per row pair, 2 row pairs.
        #expect(open.positions.count == 9 * 3)
        #expect(open.indices.count == 2 * 2 * 6)
        // Second ring accumulated both offsets.
        let lastY = open.positions[8 * 3 + 1]
        #expect(abs(lastY + 2) < 1e-5)

        let closed = try #require(PlacementPreviewGeometry.ringsGhost(
            chain: chain, closed: true, offsets: [SIMD3(0, -1, 0)]
        ))
        #expect(closed.indices.count == 3 * 6)  // wrap quad included
        #expect(PlacementPreviewGeometry.ringsGhost(
            chain: chain, closed: false, offsets: []
        ) == nil)
    }

    @Test func fanGhostConnectsChainEdgesToTheApex() throws {
        let chain: [SIMD3<Float>] = [
            SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0),
        ]
        let open = try #require(PlacementPreviewGeometry.fanGhost(
            chain: chain, closed: false, apex: SIMD3(0.5, 0.5, 1)
        ))
        #expect(open.indices.count == 3 * 3)  // 3 chain edges
        let closed = try #require(PlacementPreviewGeometry.fanGhost(
            chain: chain, closed: true, apex: SIMD3(0.5, 0.5, 1)
        ))
        #expect(closed.indices.count == 4 * 3)  // wrap edge included
        #expect(PlacementPreviewGeometry.fanGhost(
            chain: [SIMD3(0, 0, 0)], closed: false, apex: .zero
        ) == nil)
    }
}

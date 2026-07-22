import CyberKit
import Foundation
import Testing
import simd

/// Task 3.2 engine patch 0004 (spatial queries, prereq for 3.3 continuous
/// Target snapping): the `SurfaceSnapper` facade and the EditMesh
/// element-query extensions exercise the real engine BVH/pick paths.
@Suite("Surface snapper and element queries")
struct SurfaceSnapperTests {
    private func cubeMesh() throws -> Mesh {
        let url = try #require(Bundle.module.url(
            forResource: "cube", withExtension: "obj", subdirectory: "Fixtures"
        ))
        return try Mesh.loadOBJ(at: url)
    }

    // MARK: - SurfaceSnapper

    @Test("snap-to-surface projects an outside point onto the cube face")
    func snapToSurfaceHitsNearestFace() throws {
        let snapper = try SurfaceSnapper(target: cubeMesh())
        let hit = try #require(snapper.snapToSurface(SIMD3(0, 0, 2)))
        // Closest point from (0,0,2) is the +z face center (0,0,0.5).
        #expect(abs(hit.point.x) < 1e-5)
        #expect(abs(hit.point.y) < 1e-5)
        #expect(abs(hit.point.z - 0.5) < 1e-5)
    }

    @Test("snap-to-vertex finds the corner inside the radius and misses outside it")
    func snapToVertexRespectsRadius() throws {
        let snapper = try SurfaceSnapper(target: cubeMesh())
        let near = SIMD3<Float>(0.45, 0.45, 0.45)
        let hit = try #require(snapper.snapToVertex(near, radius: 0.2))
        #expect(hit.point == SIMD3(0.5, 0.5, 0.5))
        #expect(snapper.snapToVertex(near, radius: 0.01) == nil)
    }

    @Test("raycast hits the front face and reports distance; misses report nil")
    func raycastHitsAndMisses() throws {
        let snapper = try SurfaceSnapper(target: cubeMesh())
        let hit = try #require(snapper.raycast(
            origin: SIMD3(0, 0, 2), direction: SIMD3(0, 0, -1)
        ))
        #expect(abs(hit.point.z - 0.5) < 1e-5)
        #expect(abs(hit.distance - 1.5) < 1e-5)
        #expect(snapper.raycast(origin: SIMD3(0, 0, 2), direction: SIMD3(0, 0, 1)) == nil)
        #expect(snapper.raycast(origin: SIMD3(0, 0, 2), direction: SIMD3(0, 0, 0)) == nil)
    }

    @Test("snapper creation fails on an empty mesh")
    func emptyMeshIsRejected() throws {
        let empty = try Mesh()
        #expect(throws: CyberKitError.self) {
            _ = try SurfaceSnapper(target: empty)
        }
    }

    // MARK: - EditMesh element queries

    @Test("nearest vertex pick honors the distance limit and reports the position")
    func nearestVertexPick() throws {
        let mesh = try cubeMesh()
        let pick = try #require(mesh.nearestVertex(
            to: SIMD3(0.4, 0.4, 0.4), maxDistance: 0.5
        ))
        #expect(pick.position == SIMD3(0.5, 0.5, 0.5))
        #expect(mesh.vertexPosition(pick.vertex) == SIMD3(0.5, 0.5, 0.5))
        #expect(mesh.nearestVertex(to: SIMD3(5, 5, 5), maxDistance: 0.5) == nil)
    }

    @Test("nearest vertex excluding skips the dragged vertex (merge-snap query)")
    func nearestVertexExcludingSkipsTheDraggedVertex() throws {
        let mesh = try cubeMesh()
        // The corner itself always wins the unfiltered query…
        let corner = try #require(mesh.nearestVertex(
            to: SIMD3(0.5, 0.5, 0.5), maxDistance: 0.1
        ))
        #expect(corner.position == SIMD3(0.5, 0.5, 0.5))
        // …excluding it returns the nearest OTHER vertex (a cube neighbor
        // one unit away), exactly what merge-snap detection needs while
        // that corner is being dragged (task 3.7, spec "Snap feedback").
        let other = try #require(mesh.nearestVertex(
            to: SIMD3(0.5, 0.5, 0.5), maxDistance: 1.5, excluding: corner.vertex
        ))
        #expect(other.vertex != corner.vertex)
        #expect(abs(simd_distance(other.position, corner.position) - 1) < 1e-5)
        // Radius still binds with the exclusion active.
        #expect(mesh.nearestVertex(
            to: SIMD3(0.5, 0.5, 0.5), maxDistance: 0.1, excluding: corner.vertex
        ) == nil)
        // Excluding a dead id filters nothing.
        let unfiltered = try #require(mesh.nearestVertex(
            to: SIMD3(0.4, 0.4, 0.4), maxDistance: 0.5, excluding: 9999
        ))
        #expect(unfiltered.vertex == corner.vertex)
    }

    @Test("nearest edge pick returns the closest point on the edge segment")
    func nearestEdgePick() throws {
        let mesh = try cubeMesh()
        // Query near the middle of some cube edge: closest edge point must
        // lie on the cube's wireframe (two coordinates at ±0.5).
        let pick = try #require(mesh.nearestEdge(
            to: SIMD3(0, 0.6, 0.6), maxDistance: 0.5
        ))
        #expect(abs(pick.point.y - 0.5) < 1e-5)
        #expect(abs(pick.point.z - 0.5) < 1e-5)
        let endpoints = try #require(mesh.edgeEndpoints(of: pick.edge))
        #expect(endpoints.0 != endpoints.1)
        // A closed cube has no boundary edges.
        #expect(mesh.isBoundaryEdge(pick.edge) == false)
        #expect(mesh.nearestEdge(to: SIMD3(9, 9, 9), maxDistance: 0.1) == nil)
    }

    @Test("dead element ids are reported as nil, not garbage")
    func deadIdsReturnNil() throws {
        let mesh = try cubeMesh()
        #expect(mesh.edgeEndpoints(of: 9999) == nil)
        #expect(mesh.isBoundaryEdge(9999) == nil)
        #expect(mesh.vertexPosition(9999) == nil)
    }
}

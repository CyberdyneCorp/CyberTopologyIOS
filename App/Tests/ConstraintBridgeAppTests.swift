import CyberKit
import Foundation
import Testing
import simd

@testable import CyberTopology

/// The app half of the constraint bridge (openspec add-weave-constraint-authoring,
/// tasks 1.3 and 1.2): narrowing the EditMesh's authored annotations to the faces
/// actually being solved, and grouping tagged edges for the solver.
///
/// The CyberKit half proves the solver HONOURS pins; this proves the app SUPPLIES the
/// right ones. Both halves are needed — a correct solver fed the wrong constraint set
/// is still wrong, and that mismatch is invisible in a solved mesh.
@MainActor
@Suite("Constraint bridge narrows annotations to the region")
struct ConstraintBridgeAppTests {
    private func grid66() throws -> Mesh {
        var obj = ""
        for i in 0...6 {
            for j in 0...6 { obj += "v \(i) \(j) 0\n" }
        }
        for i in 0..<6 {
            for j in 0..<6 {
                let v = { (a: Int, b: Int) in a * 7 + b + 1 }
                obj += "f \(v(i, j)) \(v(i + 1, j)) \(v(i + 1, j + 1)) \(v(i, j + 1))\n"
            }
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-app-\(UUID().uuidString).obj")
        try obj.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try Mesh.loadOBJ(at: url)
    }

    /// The centre 4x4 block of the grid.
    private var centreBlock: [UInt32] {
        var faces: [UInt32] = []
        for i in 1...4 {
            for j in 1...4 { faces.append(UInt32(i * 6 + j)) }
        }
        return faces
    }

    private func vertex(_ i: Int, _ j: Int) -> UInt32 { UInt32(i * 7 + j) }

    @Test("Nil or empty annotations supply nothing")
    func emptySuppliesNothing() throws {
        let mesh = try grid66()
        let none = MetalViewport.Coordinator.regionAnnotations(
            nil, mesh: mesh, regionFaces: centreBlock
        )
        #expect(none.pinnedVertices.isEmpty)
        #expect(none.taggedLoops.isEmpty)

        let empty = MetalViewport.Coordinator.regionAnnotations(
            MeshAnnotations(), mesh: mesh, regionFaces: centreBlock
        )
        #expect(empty.pinnedVertices.isEmpty)
        #expect(empty.taggedLoops.isEmpty)
    }

    @Test("A pin inside the region is supplied; one outside it is dropped")
    func pinsNarrowToRegion() throws {
        let mesh = try grid66()
        let inside = vertex(3, 3)
        let outside = vertex(0, 0)
        let supplied = MetalViewport.Coordinator.regionAnnotations(
            MeshAnnotations(pinnedVertices: [inside, outside]),
            mesh: mesh, regionFaces: centreBlock
        )
        #expect(supplied.pinnedVertices.contains(inside))
        #expect(
            !supplied.pinnedVertices.contains(outside),
            "a pin outside the region constrains geometry the solve never touches"
        )
    }

    @Test("Tagged edges are grouped by colour, in ascending colour order")
    func tagsGroupByColour() throws {
        let mesh = try grid66()
        // Two interior edges of the centre block, tagged in different colours.
        let regionVertices = Set(centreBlock.flatMap { mesh.faceVertices($0) })
        var interior: [UInt32] = []
        for edge in 0..<UInt32(mesh.edgeCount) {
            guard let ends = mesh.edgeEndpoints(of: edge),
                regionVertices.contains(ends.0), regionVertices.contains(ends.1)
            else { continue }
            interior.append(edge)
            if interior.count == 2 { break }
        }
        try #require(interior.count == 2)

        let annotations = MeshAnnotations(
            taggedEdges: interior, tagColorIndices: [3, 1]
        )
        let supplied = MetalViewport.Coordinator.regionAnnotations(
            annotations, mesh: mesh, regionFaces: centreBlock
        )
        #expect(supplied.taggedLoops.count == 2, "one group per colour")
        #expect(
            supplied.taggedLoops.map(\.colorIndex) == [1, 3],
            "ascending colour order, so the constraint set is deterministic"
        )
    }

    @Test("A tagged edge outside the region is dropped")
    func tagsNarrowToRegion() throws {
        let mesh = try grid66()
        let regionVertices = Set(centreBlock.flatMap { mesh.faceVertices($0) })
        // An edge with NEITHER endpoint in the region.
        var outside: UInt32?
        for edge in 0..<UInt32(mesh.edgeCount) {
            guard let ends = mesh.edgeEndpoints(of: edge),
                !regionVertices.contains(ends.0), !regionVertices.contains(ends.1)
            else { continue }
            outside = edge
            break
        }
        let far = try #require(outside)
        let supplied = MetalViewport.Coordinator.regionAnnotations(
            MeshAnnotations(taggedEdges: [far], tagColorIndices: [0]),
            mesh: mesh, regionFaces: centreBlock
        )
        #expect(supplied.taggedLoops.isEmpty)
    }

    @Test("A frozen face inside the region is supplied; one outside it is dropped")
    func frozenFacesNarrowToRegion() throws {
        let mesh = try grid66()
        let inside = centreBlock[0]
        let outside: UInt32 = 0  // corner face, outside the centre block
        try #require(!centreBlock.contains(outside))
        let supplied = MetalViewport.Coordinator.regionAnnotations(
            MeshAnnotations(frozenFaces: [inside, outside]),
            mesh: mesh, regionFaces: centreBlock
        )
        #expect(supplied.frozenFaces == [inside])
    }

    @Test("A frozen face is drawn as a closed outline, and a stale one draws nothing")
    func frozenFacesRender() throws {
        let mesh = try grid66()
        let face = centreBlock[0]
        let ring = mesh.faceVertices(face)
        try #require(ring.count == 4)

        let state = AnnotationRenderState.build(
            annotations: MeshAnnotations(frozenFaces: [face]),
            edgeEndpoints: { mesh.edgeEndpoints(of: $0) },
            vertexPosition: { mesh.vertexPosition($0) },
            faceVertices: { mesh.faceVertices($0) }
        )
        // A closed quad perimeter: 4 segments, 2 endpoints each, 3 floats each.
        #expect(state.frozenOutlines.count == 1)
        #expect(state.frozenOutlines[0].segments.count == 4 * 2 * 3)
        #expect(state.frozenOutlines[0].color == AnnotationRenderState.frozenColor)
        // A frozen-only state must not read as empty, or the pass never uploads.
        #expect(!state.isEmpty)

        let stale = AnnotationRenderState.build(
            annotations: MeshAnnotations(frozenFaces: [999_999]),
            edgeEndpoints: { mesh.edgeEndpoints(of: $0) },
            vertexPosition: { mesh.vertexPosition($0) },
            faceVertices: { mesh.faceVertices($0) }
        )
        #expect(stale.frozenOutlines.isEmpty, "a stale id renders as nothing, never a crash")
    }

    @Test("An empty region supplies nothing rather than everything")
    func emptyRegionSuppliesNothing() throws {
        let mesh = try grid66()
        // The inverted-guard bug this guards: an empty region set could easily be read
        // as "no filter", supplying every annotation on the mesh.
        let supplied = MetalViewport.Coordinator.regionAnnotations(
            MeshAnnotations(pinnedVertices: [vertex(3, 3)]), mesh: mesh, regionFaces: []
        )
        #expect(supplied.pinnedVertices.isEmpty)
        #expect(supplied.frozenFaces.isEmpty)
    }
}

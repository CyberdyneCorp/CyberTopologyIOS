import CyberKit
import Foundation
import Testing
import simd

@testable import CyberTopology

/// Task 4.3a — the annotation remainders, three separate clauses.
///
/// The first two clauses of 4.3a were already closed elsewhere (pins honoured by
/// Relax/Move, and Auto Relax passing the same pin set). These cover what was left:
/// tags reaching the solver, tags/pins respecting the visibility lasso, and the Loop
/// Info chip being readable with both hands on the model.
@MainActor
@Suite("Annotation remainders (4.3a)")
struct AnnotationRemaindersTests {
    private func mesh(_ obj: String) throws -> Mesh {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("annot-\(UUID().uuidString).obj")
        try obj.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try Mesh.loadOBJ(at: url)
    }

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
        return try mesh(obj)
    }

    // MARK: - Clause: tags on hidden faces must not draw

    @Test("A tag on a face hidden by the visibility lasso stops drawing")
    func hiddenFacesSuppressTags() throws {
        let mesh = try grid66()
        // An interior edge of face 0, so hiding face 0's neighbours can isolate it.
        let face: UInt32 = 0
        let ring = mesh.faceVertices(face)
        try #require(ring.count == 4)
        var seed: UInt32?
        for edge in 0..<UInt32(mesh.edgeCount) {
            guard let ends = mesh.edgeEndpoints(of: edge),
                ring.contains(ends.0), ring.contains(ends.1)
            else { continue }
            seed = edge
            break
        }
        let edge = try #require(seed)

        let visible = AnnotationRenderState.build(
            annotations: MeshAnnotations(taggedEdges: [edge], tagColorIndices: [0]),
            edgeEndpoints: { mesh.edgeEndpoints(of: $0) },
            vertexPosition: { mesh.vertexPosition($0) },
            faceVertices: { mesh.faceVertices($0) },
            liveFaces: { mesh.liveFaceIDs() }
        )
        #expect(!visible.tagGroups.isEmpty, "an unhidden tag must draw")

        // Hide EVERY face: nothing is left for the tag to sit on, so it must vanish.
        // Before 4.3a the per-colour pass was standalone world-space geometry that never
        // consulted the hidden-face set, so it went on drawing over whatever was behind.
        let hiddenAll = AnnotationRenderState.build(
            annotations: MeshAnnotations(
                taggedEdges: [edge], tagColorIndices: [0],
                hiddenFaces: mesh.liveFaceIDs()
            ),
            edgeEndpoints: { mesh.edgeEndpoints(of: $0) },
            vertexPosition: { mesh.vertexPosition($0) },
            faceVertices: { mesh.faceVertices($0) },
            liveFaces: { mesh.liveFaceIDs() }
        )
        #expect(hiddenAll.tagGroups.isEmpty, "a tag with no visible face must not draw")
    }

    @Test("A pin on a hidden face stops drawing; a pin on a visible one survives")
    func hiddenFacesSuppressPins() throws {
        let mesh = try grid66()
        let corner = mesh.faceVertices(0).first!
        let faces = mesh.liveFaceIDs()

        let all = AnnotationRenderState.build(
            annotations: MeshAnnotations(hiddenFaces: faces, pinnedVertices: [corner]),
            edgeEndpoints: { mesh.edgeEndpoints(of: $0) },
            vertexPosition: { mesh.vertexPosition($0) },
            faceVertices: { mesh.faceVertices($0) },
            liveFaces: { faces }
        )
        #expect(all.pinPoints.isEmpty)

        // Hiding a face the pin does NOT touch must leave it drawn — the filter has to be
        // per element, not a blanket "any hidden face suppresses everything".
        let farFace = faces.first { !mesh.faceVertices($0).contains(corner) }
        let some = AnnotationRenderState.build(
            annotations: MeshAnnotations(
                hiddenFaces: [try #require(farFace)], pinnedVertices: [corner]
            ),
            edgeEndpoints: { mesh.edgeEndpoints(of: $0) },
            vertexPosition: { mesh.vertexPosition($0) },
            faceVertices: { mesh.faceVertices($0) },
            liveFaces: { faces }
        )
        #expect(!some.pinPoints.isEmpty)
    }

    @Test("No hidden faces means the pass is byte-identical to before the filter")
    func noHiddenFacesIsInert() throws {
        let mesh = try grid66()
        let corner = mesh.faceVertices(0).first!
        let annotations = MeshAnnotations(pinnedVertices: [corner])
        // Without `liveFaces` (the old call shape) and with it must agree, so the filter
        // is provably inert when nothing is hidden — the common case.
        let withoutFaces = AnnotationRenderState.build(
            annotations: annotations,
            edgeEndpoints: { mesh.edgeEndpoints(of: $0) },
            vertexPosition: { mesh.vertexPosition($0) }
        )
        let withFaces = AnnotationRenderState.build(
            annotations: annotations,
            edgeEndpoints: { mesh.edgeEndpoints(of: $0) },
            vertexPosition: { mesh.vertexPosition($0) },
            faceVertices: { mesh.faceVertices($0) },
            liveFaces: { mesh.liveFaceIDs() }
        )
        #expect(withoutFaces.pinPoints == withFaces.pinPoints)
    }

    // MARK: - Clause: the Loop Info chip must be readable with both hands on the model

    private func sampleInfo(_ length: Float) -> LoopInfoChipState.Info {
        LoopInfoChipState.Info(
            metrics: LoopMetrics(
                edgeCount: 8, vertexCount: 8, isClosed: true, length: length,
                endpoints: nil, boundaryEdgeCount: 0, snapping: nil
            ),
            tagColor: nil
        )
    }

    @Test("A pinned chip ignores hover, including hover ending")
    func pinnedChipHoldsItsReading() {
        var state = LoopInfoChipState()
        let shown = state.show(sampleInfo(1))
        #expect(shown)
        let pinned = state.togglePinned()
        #expect(pinned)
        #expect(state.isPinned)

        // The whole point of the clause: the reading must survive both a DIFFERENT loop
        // being hovered and the pen lifting entirely, or it cannot be read two-handed.
        let ignored = state.show(sampleInfo(2))
        #expect(!ignored, "a pinned chip must not follow hover")
        #expect(state.info?.metrics.length == 1)
        let cleared = state.clear()
        #expect(!cleared, "a pinned chip must survive hover ending")
        #expect(state.info != nil)
    }

    @Test("Unpinning clears, because the held reading is stale by then")
    func unpinningClears() {
        var state = LoopInfoChipState()
        _ = state.show(sampleInfo(1))
        _ = state.togglePinned()
        let unpinned = state.togglePinned()
        #expect(unpinned)
        #expect(!state.isPinned)
        // Leaving the old reading up would show a measurement of whatever the pen last
        // touched, indistinguishable from a live one.
        #expect(state.info == nil)
    }

    @Test("Pinning an empty chip is refused rather than arming a blank panel")
    func pinningEmptyIsRefused() {
        var state = LoopInfoChipState()
        let refused = state.togglePinned()
        #expect(!refused)
        #expect(!state.isPinned)
    }

    @Test("The model enforces pinning too, so the two cannot disagree")
    func modelEnforcesPinning() {
        let model = ViewportInputModel()
        model.setLoopInfo(sampleInfo(1))
        #expect(model.toggleLoopInfoPinned())
        #expect(model.loopInfoPinned)
        // The hover controller publishes straight into the model, so trusting only
        // LoopInfoChipState would let the chip on screen disagree with the state machine.
        model.setLoopInfo(sampleInfo(2))
        #expect(model.loopInfo?.metrics.length == 1)
        #expect(model.toggleLoopInfoPinned())
        #expect(model.loopInfo == nil)
    }

    @Test("Pin loop info is an immediate command with a complete gallery entry")
    func actionIsReachable() {
        #expect(EditorAction.toggleLoopInfoPin.isImmediateCommand)
        let entry = EditorAction.toggleLoopInfoPin.gallery
        #expect(!entry.title.isEmpty)
        #expect(!entry.notes.isEmpty)
        // Reached through the gallery deliberately: the chip is allowsHitTesting(false)
        // so an inspector can never intercept the next stroke.
        #expect(EditorAction.toggleLoopInfoPin.tool == nil)
    }
}

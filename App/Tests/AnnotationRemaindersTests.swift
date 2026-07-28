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

    // MARK: - UV seams in the overlay (6.2)

    @Test("A seam draws in its own colour, distinct from tags and frozen outlines")
    func seamsDrawDistinctly() throws {
        let mesh = try grid66()
        let edge = try #require((0..<UInt32(mesh.edgeCount)).first {
            mesh.edgeEndpoints(of: $0) != nil
        })
        let state = AnnotationRenderState.build(
            annotations: MeshAnnotations(seamEdges: [edge]),
            edgeEndpoints: { mesh.edgeEndpoints(of: $0) },
            vertexPosition: { mesh.vertexPosition($0) },
            faceVertices: { mesh.faceVertices($0) },
            liveFaces: { mesh.liveFaceIDs() }
        )
        #expect(state.seamSegments.count == 1)
        #expect(state.seamSegments[0].color == AnnotationRenderState.seamColor)
        // A seam is a CUT and a tag is a FLOW hint; sharing a palette entry would make two
        // different meanings indistinguishable on screen.
        #expect(state.seamSegments[0].color != LoopTagPalette.color(0))
        #expect(state.seamSegments[0].color != AnnotationRenderState.frozenColor)
        #expect(!state.isEmpty)
    }

    @Test("A seam on a hidden face stops drawing, like tags and pins")
    func hiddenFacesSuppressSeams() throws {
        let mesh = try grid66()
        let edge = try #require((0..<UInt32(mesh.edgeCount)).first {
            mesh.edgeEndpoints(of: $0) != nil
        })
        let hidden = AnnotationRenderState.build(
            annotations: MeshAnnotations(
                hiddenFaces: mesh.liveFaceIDs(), seamEdges: [edge]
            ),
            edgeEndpoints: { mesh.edgeEndpoints(of: $0) },
            vertexPosition: { mesh.vertexPosition($0) },
            faceVertices: { mesh.faceVertices($0) },
            liveFaces: { mesh.liveFaceIDs() }
        )
        // The same defect 4.3a fixed for tags: standalone world-space geometry that never
        // consulted the hidden-face set kept drawing over whatever was behind it.
        #expect(hidden.seamSegments.isEmpty)
    }

    @Test("A proposed seam draws distinctly, and never over an authored one")
    func proposalsDrawDistinctly() throws {
        let mesh = try grid66()
        let edges = Array((0..<UInt32(mesh.edgeCount)).filter {
            mesh.edgeEndpoints(of: $0) != nil
        }.prefix(2))
        try #require(edges.count == 2)

        let state = AnnotationRenderState.build(
            annotations: MeshAnnotations(seamEdges: [edges[0]]),
            edgeEndpoints: { mesh.edgeEndpoints(of: $0) },
            vertexPosition: { mesh.vertexPosition($0) },
            faceVertices: { mesh.faceVertices($0) },
            liveFaces: { mesh.liveFaceIDs() },
            proposedSeams: edges  // includes the authored one
        )
        #expect(state.seamSegments.count == 1)
        #expect(state.proposedSeamSegments.count == 1)
        // Amber for proposed, orange for authored: an artist must be able to tell what they
        // drew from what is merely suggested, or they cannot review the proposal.
        #expect(
            state.proposedSeamSegments[0].color == AnnotationRenderState.proposedSeamColor
        )
        #expect(state.proposedSeamSegments[0].color != AnnotationRenderState.seamColor)
        // Only ONE segment proposed: the already-authored edge is excluded, because drawing
        // a proposal over the artist's own cut would imply their cut is a suggestion.
        #expect(state.proposedSeamSegments[0].segments.count == 6)
    }

    @Test("Seam flip and clear seams are reachable and correctly classified")
    func seamActionsAreReachable() {
        // A TOOL, not an immediate command: it is stroke-driven, so it must arm rather than
        // render a CommandButton that fires once.
        #expect(EditorAction.seamFlip.tool == .seamFlip)
        #expect(!EditorAction.seamFlip.isImmediateCommand)
        #expect(!EditorAction.seamFlip.gallery.notes.isEmpty)

        // The clear IS an immediate command, so its slot must route to CommandButton.
        #expect(EditorAction.clearSeams.isImmediateCommand)
        #expect(EditorAction.clearSeams.tool == nil)
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

    @Test("A proposal draws even when the document has NO annotations at all")
    func bareProposalStillDraws() throws {
        // The first thing an artist does on a fresh cage may be to ask where to cut, so the
        // proposal has to survive an empty annotation set. The overlay build used to be
        // gated behind `if let annotations`, which dropped the amber entirely in this case.
        let mesh = try grid66()
        let edges = Array((0..<UInt32(mesh.edgeCount)).filter {
            mesh.edgeEndpoints(of: $0) != nil
        }.prefix(2))
        let state = AnnotationRenderState.build(
            annotations: MeshAnnotations(),
            edgeEndpoints: { mesh.edgeEndpoints(of: $0) },
            vertexPosition: { mesh.vertexPosition($0) },
            faceVertices: { mesh.faceVertices($0) },
            liveFaces: { mesh.liveFaceIDs() },
            proposedSeams: edges
        )
        #expect(!state.proposedSeamSegments.isEmpty)
        #expect(!state.isEmpty)
    }
}

import CyberKit
import Foundation
import SwiftUI
import Testing
import simd

@testable import CyberTopology

/// UV layout geometry and the 2D panel's pure parts (openspec add-uv-stage-foundation,
/// 6.1 task 3.2).
///
/// All of this is deliberately testable without a GPU or a rendered view — the reason the
/// 2D view is a `Canvas` over pre-built paths rather than a Metal render path.
@MainActor
@Suite("UV layout geometry")
struct UVLayoutTests {
    private func mesh(_ obj: String) throws -> Mesh {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("uvlayout-\(UUID().uuidString).obj")
        try obj.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try Mesh.loadOBJ(at: url)
    }

    /// A 3x3 quad cage.
    private func cage() throws -> Mesh {
        var obj = ""
        for i in 0...3 {
            for j in 0...3 { obj += "v \(i) \(j) 0\n" }
        }
        for i in 0..<3 {
            for j in 0..<3 {
                let v = { (a: Int, b: Int) in a * 4 + b + 1 }
                obj += "f \(v(i, j)) \(v(i + 1, j)) \(v(i + 1, j + 1)) \(v(i, j + 1))\n"
            }
        }
        return try mesh(obj)
    }

    // MARK: - State

    @Test("A never-unwrapped mesh reports notUnwrapped WITH its face count")
    func notUnwrappedCarriesFaceCount() throws {
        let subject = try cage()
        guard case .notUnwrapped(let faceCount) = UVLayoutGeometry.state(of: subject) else {
            Issue.record("expected .notUnwrapped")
            return
        }
        // The count is carried so the empty state can say what WOULD be unwrapped, rather
        // than only that nothing is there.
        #expect(faceCount == 9)
    }

    @Test("An unwrapped cage reconstructs one ring per face, quads as FOUR corners")
    func ringsAreAuthoredPolygons() throws {
        let (unwrapped, _) = try cage().unwrapped()
        guard case .laidOut(let layout) = UVLayoutGeometry.state(of: unwrapped) else {
            Issue.record("expected .laidOut")
            return
        }
        #expect(layout.ringCount == 9)
        // Four, not six: a fan diagonal is an artifact of triangulation and drawing it
        // would contradict the 3D wireframe, which is careful to show authored edges only.
        #expect(layout.rings.allSatisfy { $0.count == 4 })
        #expect(layout.cornerCount == 36)
    }

    @Test("A packed layout reports no overflow")
    func packedLayoutHasNoOverflow() throws {
        let (unwrapped, _) = try cage().unwrapped()
        guard case .laidOut(let layout) = UVLayoutGeometry.state(of: unwrapped) else {
            Issue.record("expected .laidOut")
            return
        }
        // The atlas packs into the unit square, so anything outside it is a real defect —
        // reported rather than clamped, since clamping would hide it.
        #expect(layout.overflowCorners == 0)
    }

    @Test("A document with no EditMesh reports noEditMesh")
    func noEditMeshState() throws {
        var bundle = DocumentBundle()
        try bundle.addObject(name: "target", role: .target, mesh: try cage())
        // A Target is not an EditMesh: UVs are laid out on the clean cage, and the panel
        // must not silently describe the Target instead.
        #expect(UVLayoutGeometry.state(inDocument: bundle) == .noEditMesh)
    }

    @Test("The document reader uses the EDIT MESH even when a Target is present")
    func documentReaderPicksTheEditMesh() throws {
        var bundle = DocumentBundle()
        try bundle.addObject(name: "target", role: .target, mesh: try cage())
        let (unwrapped, _) = try cage().unwrapped()
        try bundle.addObject(name: "cage", role: .editMesh, mesh: unwrapped)

        // MetalViewport.renderableObject would return the TARGET here. The panel must
        // agree with what Unwrap writes, or it would draw one object while the button
        // edited another — and the empty state would still say "no layout" after success.
        guard case .laidOut = UVLayoutGeometry.state(inDocument: bundle) else {
            Issue.record("expected the unwrapped EditMesh, not the Target")
            return
        }
    }

    // MARK: - Path mapping

    @Test("The drawing square is centred and never stretched")
    func squareIsCentredAndSquare() {
        let wide = UVLayoutPanelView.squareRect(in: CGSize(width: 300, height: 100))
        #expect(wide.width == wide.height)
        #expect(wide.width == 100)
        #expect(wide.minX == 100, "should be centred horizontally")

        let tall = UVLayoutPanelView.squareRect(in: CGSize(width: 100, height: 300))
        #expect(tall.height == 100)
        #expect(tall.minY == 100)
        // A stretched square would misrepresent distortion, which is the thing this view
        // exists to let someone judge.
    }

    @Test("A degenerate size yields an empty rect rather than a negative one")
    func degenerateSizeIsSafe() {
        let rect = UVLayoutPanelView.squareRect(in: CGSize(width: 0, height: -10))
        #expect(rect.width == 0)
        #expect(rect.height == 0)
    }

    @Test("v is FLIPPED, because UV origin is bottom-left and views are top-left")
    func vIsFlipped() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        // A single edge from UV (0,0) to (0,1): in view space that must run from the
        // BOTTOM of the rect to the top, not the reverse. Getting this wrong renders every
        // layout upside down against every other UV tool.
        let path = UVLayoutPanelView.path(
            for: [[SIMD2(0, 0), SIMD2(0, 1)]], in: rect
        )
        let box = path.boundingRect
        #expect(box.minY == 0)
        #expect(box.maxY == 100)

        let low = UVLayoutPanelView.path(for: [[SIMD2(0, 0), SIMD2(1, 0)]], in: rect)
        // v = 0 maps to the BOTTOM edge (y = height).
        #expect(low.boundingRect.minY == 100)
    }

    @Test("Each ring becomes a closed subpath scaled into the square")
    func ringsMapIntoTheSquare() {
        let rect = CGRect(x: 10, y: 20, width: 200, height: 200)
        let ring: [SIMD2<Float>] = [
            SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1),
        ]
        let box = UVLayoutPanelView.path(for: [ring], in: rect).boundingRect
        #expect(box.minX == 10)
        #expect(box.maxX == 210)
        #expect(box.minY == 20)
        #expect(box.maxY == 220)
    }

    // MARK: - Heatmap colour mapping (6.4)

    @Test("A flipped face is RED in either mode, because it is a defect not a magnitude")
    func flippedIsRed() {
        let flipped = Mesh.FaceDistortion(angle: 0.01, area: 1, flipped: true)
        // Low angle error would otherwise shade it "good", hiding a face that will bake
        // inverted detail.
        for mode in UVLayoutGeometry.HeatmapMode.allCases {
            #expect(
                UVLayoutPanelView.color(
                    for: flipped, mode: mode, textureSize: 1024, reference: 1
                ) == Color.red.opacity(0.55)
            )
        }
    }

    @Test("Angle mode shades a distorted face differently from a clean one")
    func angleModeDiscriminates() {
        let clean = Mesh.FaceDistortion(angle: 0, area: 1, flipped: false)
        let bad = Mesh.FaceDistortion(angle: 0.9, area: 1, flipped: false)
        let cleanColor = UVLayoutPanelView.color(
            for: clean, mode: .angle, textureSize: 1024, reference: 1
        )
        let badColor = UVLayoutPanelView.color(
            for: bad, mode: .angle, textureSize: 1024, reference: 1
        )
        // The whole point of a heatmap: if these matched, the view would say a stretched
        // face and a perfect one are the same.
        #expect(cleanColor != badColor)
    }

    @Test("Density mode needs a reference and yields nothing without one")
    func densityNeedsAReference() {
        let face = Mesh.FaceDistortion(angle: 0, area: 1, flipped: false)
        // No reference means no meaningful relative scale, so it shades nothing rather
        // than inventing an absolute target density nobody specified.
        #expect(
            UVLayoutPanelView.color(
                for: face, mode: .texelDensity, textureSize: 1024, reference: 0
            ) == Color.clear
        )
    }

    @Test("Density mode reads UNDER-sampled faces as hot")
    func underSampledIsHot() {
        let sparse = Mesh.FaceDistortion(angle: 0, area: 0.1, flipped: false)
        let dense = Mesh.FaceDistortion(angle: 0, area: 10, flipped: false)
        let reference = Mesh.FaceDistortion(angle: 0, area: 1, flipped: false)
            .texelDensity(textureSize: 512)
        // A face receiving FEWER texels than its neighbours is the problem worth seeing,
        // so low density must not read as "fine".
        #expect(
            UVLayoutPanelView.color(
                for: sparse, mode: .texelDensity, textureSize: 512, reference: reference
            ) != UVLayoutPanelView.color(
                for: dense, mode: .texelDensity, textureSize: 512, reference: reference
            )
        )
    }

    @Test("The density reference is a MEDIAN, so one outlier cannot wash out the scale")
    func referenceIsMedian() throws {
        let (unwrapped, _) = try cage().unwrapped()
        guard case .laidOut(var layout) = UVLayoutGeometry.state(of: unwrapped) else {
            Issue.record("expected .laidOut")
            return
        }
        let honest = layout.referenceDensity(textureSize: 1024)
        #expect(honest > 0)

        // Add one enormous outlier. A MEAN would move sharply; a median barely notices,
        // which is why it is the median — a single vast chart must not flatten every other
        // face to the same colour.
        layout.distortion.append(
            Mesh.FaceDistortion(angle: 0, area: 100_000, flipped: false)
        )
        let withOutlier = layout.referenceDensity(textureSize: 1024)
        #expect(abs(withOutlier - honest) < honest * 0.5)
    }

    @Test("Distortion is paired with rings only when the counts agree")
    func mismatchedDistortionIsDropped() throws {
        let (unwrapped, _) = try cage().unwrapped()
        guard case .laidOut(let layout) = UVLayoutGeometry.state(of: unwrapped) else {
            Issue.record("expected .laidOut")
            return
        }
        // The guard exists because colouring face N with face M's measurement is visually
        // plausible and completely wrong — the same failure the corner-stream check
        // prevents for the rings themselves.
        #expect(layout.distortion.count == layout.rings.count)
    }

    @Test("A ring with fewer than two corners is skipped rather than crashing")
    func degenerateRingsAreSkipped() {
        let path = UVLayoutPanelView.path(
            for: [[SIMD2(0.5, 0.5)], []], in: CGRect(x: 0, y: 0, width: 10, height: 10)
        )
        #expect(path.isEmpty)
    }
}

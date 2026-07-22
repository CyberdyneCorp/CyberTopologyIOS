import CyberKit
import Foundation
import Testing
import simd

/// Task 4.4: symmetry through the REAL engine (spec: retopology-tools /
/// "Multi-axis and radial symmetry" — mirror on any combination of X/Y/Z
/// with configurable origin, center-line snapping, apply-symmetry, and the
/// "Re-symmetrize" scenario), plus the pure replication math the app's
/// live symmetric authoring replays operations under.
///
/// No mocks: every geometry assertion drives the capi added by engine
/// patch 0021 (`cyber_retopo_snap_symmetry_plane`,
/// `cyber_retopo_apply_symmetry`, `cyber_retopo_resymmetrize`) against a
/// real engine mesh.
@Suite("Symmetry: mirror, apply, re-symmetrize")
struct SymmetryOpsTests {
    // MARK: - Fixtures

    private func mesh(fromOBJ text: String) throws -> Mesh {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("symmetry-\(UUID().uuidString).obj")
        try text.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try Mesh.loadOBJ(at: url)
    }

    /// One unit quad sitting entirely on the POSITIVE side of `axis`,
    /// spanning 1...2 on that axis and 0...1 on the other two.
    private func quadOnPositiveSide(of axis: SymmetrySettings.Axis) throws -> Mesh {
        let corners: [SIMD3<Float>] = {
            switch axis {
            case .x:
                return [SIMD3(1, 0, 0), SIMD3(2, 0, 0), SIMD3(2, 1, 0), SIMD3(1, 1, 0)]
            case .y:
                return [SIMD3(0, 1, 0), SIMD3(1, 1, 0), SIMD3(1, 2, 0), SIMD3(0, 2, 0)]
            case .z:
                return [SIMD3(0, 0, 1), SIMD3(1, 0, 1), SIMD3(1, 1, 2), SIMD3(0, 1, 2)]
            }
        }()
        var obj = corners.map { "v \($0.x) \($0.y) \($0.z)\n" }.joined()
        obj += "f 1 2 3 4\n"
        return try mesh(fromOBJ: obj)
    }

    private func livePositions(_ mesh: Mesh) -> [SIMD3<Float>] {
        (0..<UInt32(mesh.vertexCount * 4)).compactMap { mesh.vertexPosition($0) }
    }

    private func component(_ p: SIMD3<Float>, _ axis: SymmetrySettings.Axis) -> Float {
        switch axis {
        case .x: return p.x
        case .y: return p.y
        case .z: return p.z
        }
    }

    // MARK: - Per-axis mirroring through the real engine

    @Test(
        "Apply-symmetry mirrors onto the other half of every axis",
        arguments: [SymmetrySettings.Axis.x, .y, .z]
    )
    func applySymmetryMirrorsPerAxis(axis: SymmetrySettings.Axis) throws {
        let mesh = try quadOnPositiveSide(of: axis)
        #expect(mesh.faceCount == 1)
        let settings = SymmetrySettings(
            mirrorAxes: [axis], origin: .zero, weldTolerance: 1e-4, isEnabled: true
        )

        let added = try mesh.applySymmetry(settings, axis: axis)

        #expect(added == 1, "one working-side face mirrors to exactly one twin")
        #expect(mesh.faceCount == 2)
        let coordinates = livePositions(mesh).map { component($0, axis) }
        #expect(coordinates.contains { $0 > 0 }, "the authored half survives")
        #expect(coordinates.contains { $0 < 0 }, "the mirrored half exists")
        // The mirror is exact: every positive coordinate has a negative twin.
        for value in coordinates where value > 0 {
            #expect(
                coordinates.contains { abs($0 + value) < 1e-5 },
                "\(value) on \(axis) has no mirror image"
            )
        }
    }

    @Test("A configurable origin moves the mirror plane with it")
    func applySymmetryHonoursTheOrigin() throws {
        let mesh = try quadOnPositiveSide(of: .x)  // spans x in 1...2
        // Plane at x = 3: the quad is now on the NEGATIVE side, so the
        // positive-working-half bake mirrors nothing...
        let farSide = SymmetrySettings(
            mirrorAxes: [.x], origin: SIMD3(3, 0, 0), weldTolerance: 1e-4, isEnabled: true
        )
        #expect(try mesh.applySymmetry(farSide, axis: .x) == 0)
        #expect(mesh.faceCount == 1)

        // ...and flipping which half is authored mirrors it to x in 4...5.
        var nearSide = farSide
        nearSide.workingSidePositive = false
        #expect(try mesh.applySymmetry(nearSide, axis: .x) == 1)
        let xs = livePositions(mesh).map(\.x)
        #expect(xs.contains { abs($0 - 4) < 1e-5 })
        #expect(xs.contains { abs($0 - 5) < 1e-5 })
    }

    @Test("Multi-axis apply-symmetry fills all four quadrants")
    func applySymmetryAcrossTwoAxes() throws {
        // One quad in the +x/+y quadrant.
        let mesh = try self.mesh(fromOBJ: """
        v 1 1 0
        v 2 1 0
        v 2 2 0
        v 1 2 0
        f 1 2 3 4
        """)
        let settings = SymmetrySettings(
            mirrorAxes: [.x, .y], origin: .zero, weldTolerance: 1e-4, isEnabled: true
        )

        #expect(try mesh.applySymmetry(settings) == 3, "X then Y bakes 1 + 2 twins")
        #expect(mesh.faceCount == 4)
        let signs = Set(livePositions(mesh).map { (($0.x > 0), ($0.y > 0)) }.map { "\($0)\($1)" })
        #expect(signs.count == 4, "all four quadrants are occupied")
    }

    // MARK: - Center-line snapping tolerance

    @Test("Vertices within the weld tolerance snap exactly onto the plane")
    func centerLineVerticesSnapToThePlane() throws {
        // x = 0.004 is inside a 0.01 tolerance; x = 0.05 is outside it.
        let mesh = try self.mesh(fromOBJ: """
        v 0.004 0 0
        v 1 0 0
        v 1 1 0
        v 0.05 1 0
        f 1 2 3 4
        """)
        let settings = SymmetrySettings(
            mirrorAxes: [.x], origin: .zero, weldTolerance: 0.01, isEnabled: true
        )

        let snapped = try mesh.snapToSymmetryPlane(settings, axis: .x)

        #expect(snapped == 1, "exactly the in-tolerance vertex welds")
        let xs = livePositions(mesh).map(\.x).sorted()
        #expect(xs.first == 0, "the near vertex sits EXACTLY on the plane")
        #expect(xs.contains { abs($0 - 0.05) < 1e-6 }, "the far vertex is untouched")
    }

    /// REGRESSION: `snapToSymmetryPlane` only calls `setPosition` —
    /// "topology is untouched" — so a mirrored AUTHORING stroke leaves two
    /// coincident, unshared vertices per seam corner. `weldSeamVertices`
    /// is the pass that collapses them, which is what makes the center
    /// line an interior edge instead of a crack.
    @Test("Seam duplicates left by mirrored authoring weld into one vertex")
    func seamVerticesWeldIntoOneSharedVertex() throws {
        // Two quads meeting at x == 0, each with its OWN pair of on-plane
        // vertices: exactly what two independent `createFace` calls (the
        // authored copy and its mirror) produce.
        let mesh = try self.mesh(fromOBJ: """
        v 0 0 0
        v 1 0 0
        v 1 1 0
        v 0 1 0
        v 0 0 0
        v -1 0 0
        v -1 1 0
        v 0 1 0
        f 1 2 3 4
        f 5 6 7 8
        """)
        let settings = SymmetrySettings(
            mirrorAxes: [.x], origin: .zero, weldTolerance: 0.01, isEnabled: true
        )
        #expect(mesh.vertexCount == 8)
        let seamMid = SIMD3<Float>(0, 0.5, 0)
        let crack = try #require(mesh.nearestEdge(to: seamMid, maxDistance: 0.01))
        #expect(mesh.isBoundaryEdge(crack.edge) == true, "unwelded: the seam is a crack")

        let welded = try mesh.weldSeamVertices(settings, near: [
            SIMD3(0, 0, 0), SIMD3(0, 1, 0),
        ])

        #expect(welded == 2, "one merge per seam corner")
        #expect(mesh.vertexCount == 6, "the duplicate pair collapsed")
        #expect(mesh.faceCount == 2, "no face was destroyed")
        let seam = try #require(mesh.nearestEdge(to: seamMid, maxDistance: 0.01))
        #expect(mesh.isBoundaryEdge(seam.edge) == false, "the halves now share the seam")
    }

    /// The pass never touches geometry away from the plane.
    @Test("Seam welding leaves off-plane geometry alone")
    func seamWeldingIgnoresOffPlaneGeometry() throws {
        let mesh = try quadOnPositiveSide(of: .x)
        let settings = SymmetrySettings(
            mirrorAxes: [.x], origin: .zero, weldTolerance: 0.01, isEnabled: true
        )
        let before = mesh.vertexCount
        let welded = try mesh.weldSeamVertices(settings, near: livePositions(mesh))
        #expect(welded == 0)
        #expect(mesh.vertexCount == before)
    }

    @Test("An on-plane vertex is shared by both halves, never duplicated")
    func onPlaneVerticesWeldRatherThanDuplicate() throws {
        let mesh = try self.mesh(fromOBJ: """
        v 0 0 0
        v 1 0 0
        v 1 1 0
        v 0 1 0
        f 1 2 3 4
        """)
        let settings = SymmetrySettings(
            mirrorAxes: [.x], origin: .zero, weldTolerance: 1e-4, isEnabled: true
        )

        #expect(try mesh.applySymmetry(settings, axis: .x) == 1)
        // 4 original + 2 mirrored (the two x = 0 vertices are shared).
        #expect(mesh.vertexCount == 6)
    }

    // MARK: - Re-symmetrize (spec scenario "Re-symmetrize")

    /// A symmetric strip about x = 0: two quads, mirrored vertex pairs.
    private func symmetricStrip() throws -> Mesh {
        try mesh(fromOBJ: """
        v -1 0 0
        v 0 0 0
        v 1 0 0
        v -1 1 0
        v 0 1 0
        v 1 1 0
        f 1 2 5 4
        f 2 3 6 5
        """)
    }

    @Test("Re-symmetrize mirrors the drifted half back, preserving topology")
    func resymmetrizeRestoresDriftedGeometry() throws {
        let mesh = try symmetricStrip()
        let faces = mesh.faceCount
        let vertices = mesh.vertexCount
        // Drift the NEGATIVE half away from symmetry.
        let drifting = try #require(
            (0..<UInt32(vertices * 4)).first { mesh.vertexPosition($0)?.x == -1 }
        )
        try mesh.tweakVertex(drifting, to: SIMD3(-1.4, 0.3, 0.2))
        let settings = SymmetrySettings(
            mirrorAxes: [.x], origin: .zero, weldTolerance: 1e-4,
            workingSidePositive: true, isEnabled: true
        )

        let report = try mesh.resymmetrize(settings, axis: .x, matchTolerance: 0.9)

        #expect(mesh.faceCount == faces, "no faces added or removed")
        #expect(mesh.vertexCount == vertices, "no vertices added or removed")
        #expect(report.matched == 2, "both negative-half vertices matched")
        #expect(report.unmatched == 0)
        #expect(report.maxCorrection > 0.4, "the drift was actually corrected")
        // Every negative vertex is now the exact mirror of a positive one.
        let all = livePositions(mesh)
        for p in all where p.x < 0 {
            #expect(
                all.contains { abs($0.x + p.x) < 1e-5 && abs($0.y - p.y) < 1e-5 },
                "\(p) has no mirror counterpart after re-symmetrize"
            )
        }
    }

    @Test("Re-symmetrize leaves one-sided geometry alone and reports it")
    func resymmetrizeReportsUnmatchedGeometry() throws {
        // A quad on the negative half with NO counterpart on the positive
        // half — the spec's "where it exists" clause.
        let mesh = try self.mesh(fromOBJ: """
        v -2 0 0
        v -1 0 0
        v -1 1 0
        v -2 1 0
        f 1 2 3 4
        """)
        let before = livePositions(mesh).sorted { $0.x < $1.x }
        let settings = SymmetrySettings(
            mirrorAxes: [.x], origin: .zero, weldTolerance: 1e-4, isEnabled: true
        )

        let report = try mesh.resymmetrize(settings, axis: .x, matchTolerance: 0.5)

        #expect(report.matched == 0)
        #expect(report.unmatched == 4, "every one-sided vertex is reported")
        #expect(report.maxCorrection == 0)
        #expect(
            livePositions(mesh).sorted { $0.x < $1.x } == before,
            "one-sided geometry is preserved, not destroyed"
        )
    }

    @Test("Re-symmetrizing an already-symmetric mesh is a no-op")
    func resymmetrizeIsIdempotent() throws {
        let mesh = try symmetricStrip()
        let settings = SymmetrySettings(
            mirrorAxes: [.x], origin: .zero, weldTolerance: 1e-4, isEnabled: true
        )
        let report = try mesh.resymmetrize(settings, axis: .x, matchTolerance: 0.5)
        #expect(report.isNoOp)
        #expect(report.matched == 2, "matched vertices were already in place")
    }

    // MARK: - Replication math (what live symmetric authoring replays under)

    @Test("Symmetry off produces no replicas")
    func inactiveSettingsProduceNoReplicas() {
        #expect(SymmetrySettings(mirrorAxes: [.x]).replicas.isEmpty, "disabled")
        #expect(
            SymmetrySettings(isEnabled: true).replicas.isEmpty,
            "enabled but with no axis and no radial sectors"
        )
        #expect(SymmetrySettings(mirrorAxes: [.x], isEnabled: true).isActive)
    }

    @Test("Replica counts are 2^axes * radialCount - 1")
    func replicaCounts() {
        let base = SymmetrySettings(isEnabled: true)
        #expect(base.settingMirror(.x, enabled: true).replicas.count == 1)
        #expect(
            base.settingMirror(.x, enabled: true).settingMirror(.y, enabled: true)
                .replicas.count == 3
        )
        #expect(base.settingRadialCount(8).replicas.count == 7)
        #expect(
            base.settingMirror(.x, enabled: true).settingRadialCount(8).replicas.count == 15
        )
    }

    @Test("Radial count is clamped into range")
    func radialCountClamping() {
        #expect(SymmetrySettings(radialCount: 0).radialCount == 1)
        #expect(SymmetrySettings(radialCount: 9_999).radialCount == 32)
    }

    @Test("Mirror axes are stored sorted and deduplicated")
    func mirrorAxesAreNormalized() {
        let settings = SymmetrySettings(mirrorAxes: [.z, .x, .x])
        #expect(settings.mirrorAxes == [.x, .z])
    }

    @Test("A single reflection reverses ring winding; two do not")
    func reflectionsReverseWinding() {
        let ring: [SIMD3<Float>] = [
            SIMD3(1, 0, 0), SIMD3(2, 0, 0), SIMD3(2, 1, 0), SIMD3(1, 1, 0),
        ]
        let single = SymmetrySettings(mirrorAxes: [.x], isEnabled: true).replicas
        #expect(single.count == 1)
        #expect(single[0].reversesWinding)
        #expect(single[0].apply(ring: ring).map(\.x) == [-1, -2, -2, -1])

        let double = SymmetrySettings(mirrorAxes: [.x, .y], isEnabled: true).replicas
        #expect(double.filter(\.reversesWinding).count == 2, "the two single-axis mirrors")
        #expect(double.filter { !$0.reversesWinding }.count == 1, "the X+Y composition")
    }

    @Test("Eight-fold radial symmetry places copies on the full turn")
    func radialReplicasSpanTheTurn() {
        let settings = SymmetrySettings(radialAxis: .z, isEnabled: true).settingRadialCount(8)
        let point = SIMD3<Float>(1, 0, 0)
        let angles = settings.replicas.map { replica -> Float in
            let p = replica.apply(point)
            #expect(abs(length(p) - 1) < 1e-5, "a rotation preserves the radius")
            #expect(!replica.reversesWinding, "rotations do not flip winding")
            return atan2(p.y, p.x)
        }
        #expect(angles.count == 7)
        // Every 45-degree step except 0 is present.
        for step in 1..<8 {
            let expected = 2 * Float.pi * Float(step) / 8
            #expect(
                angles.contains { abs(sin($0 - expected)) < 1e-4 },
                "no copy at step \(step)"
            )
        }
    }

    @Test("A reflecting replica reverses each grid row, keeping the lattice")
    func gridLayoutReversesRows() {
        // 1x1 lattice of quads = 2x2 points, cols = 1.
        let lattice: [SIMD3<Float>] = [
            SIMD3(1, 0, 0), SIMD3(2, 0, 0),
            SIMD3(1, 1, 0), SIMD3(2, 1, 0),
        ]
        let replica = SymmetrySettings(mirrorAxes: [.x], isEnabled: true).replicas[0]
        let mirrored = replica.apply(points: lattice, layout: .grid(cols: 1))
        #expect(mirrored.map(\.x) == [-2, -1, -2, -1], "each row is reversed in place")
        #expect(mirrored.map(\.y) == [0, 0, 1, 1], "rows stay rows")
        // A path carries no winding, so its order survives untouched.
        #expect(replica.apply(points: lattice, layout: .path).map(\.x) == [-1, -2, -1, -2])
    }

    @Test("The symmetry origin re-anchors both mirrors and rotations")
    func replicasHonourTheOrigin() {
        let settings = SymmetrySettings(
            mirrorAxes: [.x], origin: SIMD3(5, 0, 0), isEnabled: true
        )
        let mirrored = settings.replicas[0].apply(SIMD3(6, 1, 0))
        #expect(abs(mirrored.x - 4) < 1e-5, "mirrored about x = 5, not x = 0")
        #expect(mirrored.y == 1)
    }

    // MARK: - Document persistence

    @Test("Symmetry settings round-trip through the document bundle")
    func symmetryPersistsInTheDocument() throws {
        var bundle = DocumentBundle()
        let settings = SymmetrySettings(
            mirrorAxes: [.x, .z], origin: SIMD3(0.5, 0, -2), radialCount: 6,
            radialAxis: .z, weldTolerance: 0.01, workingSidePositive: false, isEnabled: true
        )
        bundle.manifest.symmetry = settings

        let reloaded = try DocumentBundle(fileWrapper: try bundle.fileWrapper())

        #expect(reloaded.manifest.symmetry == settings)
    }

    @Test("Pre-4.4 documents read back as symmetry off")
    func documentsWithoutSymmetryDefaultToOff() throws {
        let bundle = try DocumentBundle(fileWrapper: try DocumentBundle().fileWrapper())
        #expect(bundle.manifest.symmetry == nil)
        #expect(bundle.manifest.effectiveSymmetry.isActive == false)
    }

    @Test("Equal settings encode to identical bytes")
    func encodingIsDeterministic() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let a = SymmetrySettings(mirrorAxes: [.z, .x], radialCount: 4, isEnabled: true)
        let b = SymmetrySettings(mirrorAxes: [.x, .z, .x], radialCount: 4, isEnabled: true)
        let encodedA = try encoder.encode(a)
        let encodedB = try encoder.encode(b)
        #expect(encodedA == encodedB)
    }

    @Test("A hand-edited manifest cannot inject an out-of-range sector count")
    func decodingClampsHostileValues() throws {
        let json = Data(
            #"{"mirrorAxes":["z","x"],"radialCount":9999,"isEnabled":true}"#.utf8
        )
        let decoded = try JSONDecoder().decode(SymmetrySettings.self, from: json)
        #expect(decoded.radialCount == 32)
        #expect(decoded.mirrorAxes == [.x, .z])
    }

    // MARK: - Journal

    @Test("setSymmetry applies and reverts the manifest exactly")
    func setSymmetryCommandRoundTrips() {
        var bundle = DocumentBundle()
        let settings = SymmetrySettings(mirrorAxes: [.y], isEnabled: true)
        let command = DocumentCommand.setSymmetry(from: nil, to: settings)

        command.apply(to: &bundle)
        #expect(bundle.manifest.symmetry == settings)

        command.revert(on: &bundle)
        #expect(bundle.manifest.symmetry == nil, "undo restores 'never set'")
    }
}

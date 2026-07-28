import Foundation
import Testing
import simd

@testable import CyberKit

/// Multiple UV sets and their document sidecar (openspec add-uv-sets, 6.7a).
@Suite("UV sets")
struct MeshUVSetsTests {
    private func cube() throws -> Mesh {
        var obj = ""
        for (x, y, z) in [
            (0, 0, 0), (1, 0, 0), (1, 1, 0), (0, 1, 0),
            (0, 0, 1), (1, 0, 1), (1, 1, 1), (0, 1, 1),
        ] {
            obj += "v \(x) \(y) \(z)\n"
        }
        for face in [
            [1, 2, 3, 4], [5, 8, 7, 6], [1, 5, 6, 2],
            [2, 6, 7, 3], [3, 7, 8, 4], [4, 8, 5, 1],
        ] {
            obj += "f " + face.map(String.init).joined(separator: " ") + "\n"
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("uvsets-\(UUID().uuidString).obj")
        try obj.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try Mesh.loadOBJ(at: url)
    }

    private func unwrappedCube() throws -> Mesh {
        let mesh = try cube()
        _ = try mesh.unwrapInPlace()
        return mesh
    }

    @Test("A fresh mesh has one set, and creating one COPIES the active layout")
    func createCopiesTheActiveSet() throws {
        let mesh = try unwrappedCube()
        #expect(mesh.uvSetNames() == ["default"])
        #expect(mesh.activeUVSetName() == "default")

        try mesh.createUVSet(named: "lightmap")
        #expect(mesh.uvSetNames() == ["default", "lightmap"])
        // Still active: creating a set does not switch to it.
        #expect(mesh.activeUVSetName() == "default")
    }

    @Test("Creating a set needs a layout to copy, and rejects bad names")
    func createValidation() throws {
        // An empty set would read downstream as a real layout collapsed at the origin.
        #expect(throws: (any Error).self) { try cube().createUVSet(named: "lightmap") }

        let mesh = try unwrappedCube()
        #expect(throws: (any Error).self) { try mesh.createUVSet(named: "default") }
        #expect(throws: (any Error).self) { try mesh.createUVSet(named: "") }
        // ':' is the internal separator for a stored set.
        #expect(throws: (any Error).self) { try mesh.createUVSet(named: "a:b") }
    }

    @Test("Activating swaps the layouts and every other UV operation keeps working on the active one")
    func activateSwapsLayouts() throws {
        let mesh = try unwrappedCube()
        try mesh.createUVSet(named: "lightmap")

        // Make the two differ so the swap is observable.
        try mesh.transformIsland(containing: 0, translate: SIMD2(0.05, 0))
        let defaultSet = try #require(mesh.uvCoordinates())

        try mesh.activateUVSet(named: "lightmap")
        #expect(mesh.activeUVSetName() == "lightmap")
        let lightmapSet = try #require(mesh.uvCoordinates())
        #expect(lightmapSet != defaultSet)

        // The whole point of keeping the active set under the plain UV attribute: existing
        // operations work on it with no knowledge that sets exist.
        #expect(try mesh.udimTiles() == [1001])
        try mesh.packIslands()

        try mesh.activateUVSet(named: "default")
        #expect(try #require(mesh.uvCoordinates()) == defaultSet)
    }

    @Test("The ACTIVE set can never be deleted")
    func activeSetCannotBeDeleted() throws {
        let mesh = try unwrappedCube()
        try mesh.createUVSet(named: "lightmap")
        // Deleting it would leave the mesh with no active layout at all.
        #expect(throws: (any Error).self) { try mesh.deleteUVSet(named: "default") }
        #expect(mesh.hasUVLayout)

        try mesh.deleteUVSet(named: "lightmap")
        #expect(mesh.uvSetNames() == ["default"])
    }

    @Test("Renaming the active set moves no layout but does change its name")
    func renameActiveSet() throws {
        let mesh = try unwrappedCube()
        let before = try #require(mesh.uvCoordinates())
        try mesh.renameUVSet(from: "default", to: "main")
        #expect(mesh.activeUVSetName() == "main")
        #expect(mesh.uvSetNames() == ["main"])
        #expect(try #require(mesh.uvCoordinates()) == before)
    }

    // MARK: - Sidecar

    @Test("Sets survive a full document SAVE and LOAD, which the OBJ payload alone cannot do")
    func setsSurviveADocumentRoundTrip() throws {
        var bundle = DocumentBundle()
        let mesh = try unwrappedCube()
        try mesh.createUVSet(named: "lightmap")
        try mesh.activateUVSet(named: "lightmap")
        try mesh.transformIsland(containing: 0, translate: SIMD2(0.1, 0.02))
        try bundle.addObject(name: "cage", role: .editMesh, mesh: mesh)

        // The sidecar has to be written explicitly — this is what a UV-set command journals.
        let object = try #require(bundle.manifest.objects.first)
        bundle.payloads[object.uvSetsFile] = try #require(try mesh.uvSetsSidecarData())

        // Through a real FileWrapper round trip, so this exercises the actual save path rather
        // than an in-memory copy. The bundle reads every file in the objects directory and
        // tolerates extras, which is why no schema change was needed.
        let reloaded = try DocumentBundle(fileWrapper: try bundle.fileWrapper())
        let restored = try reloaded.mesh(for: try #require(reloaded.manifest.objects.first))

        #expect(restored.uvSetNames() == ["default", "lightmap"])
        #expect(restored.activeUVSetName() == "lightmap")
        // The ACTIVE layout comes from the PAYLOAD, which carries it as `vt`. The sidecar stores
        // the active set's NAME but not its data — one source of truth per layout.
        //
        // Compared with a TOLERANCE, not bitwise: the payload is OBJ, so the active layout goes
        // through decimal text and loses a little precision. That is the documented round-trip
        // behaviour `MeshUVTests.uvsSurvivePayloadRoundTrip` already pins at the same 1e-4.
        let restoredUVs = try #require(restored.uvCoordinates())
        let expectedUVs = try #require(mesh.uvCoordinates())
        #expect(restoredUVs.count == expectedUVs.count)
        for (got, want) in zip(restoredUVs, expectedUVs) {
            #expect(abs(got.x - want.x) < 1e-4)
            #expect(abs(got.y - want.y) < 1e-4)
        }
    }

    @Test("A STALE sidecar cannot resurrect an old layout over a newer edit")
    func staleSidecarCannotOverwriteNewerEdits() throws {
        // The regression: the first version stored the active set's data in the sidecar too, so
        // restoring it overwrote the live layout — discarding every UV edit made since the sidecar
        // was written. Because a mesh edit round-trips through the OBJ payload by design, that loss
        // happened on the very next edit after any set existed.
        let mesh = try unwrappedCube()
        try mesh.createUVSet(named: "lightmap")
        let stale = try #require(try mesh.uvSetsSidecarData())

        try mesh.transformIsland(containing: 0, translate: SIMD2(0.11, 0))
        let edited = try #require(mesh.uvCoordinates())

        try mesh.restoreUVSets(from: stale)
        #expect(try #require(mesh.uvCoordinates()) == edited)
        // And the inactive set is still there, which is what the sidecar is FOR.
        #expect(mesh.uvSetNames() == ["default", "lightmap"])
    }

    @Test("A sidecar for different topology is REFUSED and the payload's own layout is kept")
    func wrongTopologySidecarIsIgnored() throws {
        let cube = try unwrappedCube()
        try cube.createUVSet(named: "lightmap")
        let cubeSidecar = try #require(try cube.uvSetsSidecarData())

        // A quad has a different corner count. Applying a cube's sets to it would shear every
        // island — plausible-looking and wrong.
        var bundle = DocumentBundle()
        let quad = try cube_quad()
        _ = try quad.unwrapInPlace()
        try bundle.addObject(name: "quad", role: .editMesh, mesh: quad)
        let object = try #require(bundle.manifest.objects.first)
        bundle.payloads[object.uvSetsFile] = cubeSidecar

        // The document must still OPEN: losing extra UV sets is recoverable, refusing to open the
        // document over them would not be.
        let restored = try bundle.mesh(for: object)
        #expect(restored.hasUVLayout)
        #expect(restored.uvSetNames() == ["default"], "the bad sidecar contributed nothing")
    }

    private func cube_quad() throws -> Mesh {
        let obj = "v 0 0 0\nv 1 0 0\nv 1 1 0\nv 0 1 0\nf 1 2 3 4\n"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("uvsets-q-\(UUID().uuidString).obj")
        try obj.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try Mesh.loadOBJ(at: url)
    }

    @Test("A corrupt sidecar is refused and leaves the layout untouched")
    func corruptSidecarIsRefused() throws {
        let mesh = try unwrappedCube()
        let before = try #require(mesh.uvCoordinates())
        #expect(throws: (any Error).self) {
            try mesh.restoreUVSets(from: Data([0xDE, 0xAD, 0xBE, 0xEF]))
        }
        #expect(try #require(mesh.uvCoordinates()) == before)

        // Empty data is a no-op, not an error: "this object has no sidecar" is the common case.
        try mesh.restoreUVSets(from: Data())
        #expect(try #require(mesh.uvCoordinates()) == before)
    }

    @Test("The sidecar filename is DERIVED from the object id, not stored")
    func sidecarFilenameIsDerived() throws {
        var bundle = DocumentBundle()
        try bundle.addObject(name: "cage", role: .editMesh, mesh: try unwrappedCube())
        let object = try #require(bundle.manifest.objects.first)
        // A stored filename would be a second source of truth that could disagree with the object
        // it belongs to — the same reasoning that keeps a UDIM tile derived.
        #expect(object.uvSetsFile == "\(object.id.uuidString).uvsets")
        #expect(object.uvSetsFile != object.payloadFile)
    }
}

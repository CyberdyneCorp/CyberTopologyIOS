import CryptoKit
import CyberKitTesting
import Foundation
import simd
import Testing
@testable import CyberKit

private extension Data {
    var sha256Hex: String {
        SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined()
    }
}

/// End-to-end OBJ import over a REAL mesh (spec: scene-pipeline / "Import
/// formats"; spec: quality-assurance / "Golden-file harness").
///
/// The pre-existing OBJ coverage all runs on `cube.obj` (8 vertices) and
/// `grid32.obj` (32 faces) — hand-written, axis-aligned, perfectly regular,
/// and small enough that a loader could get them right by accident. This
/// suite runs the same path on the Stanford bunny: 2503 vertices, 4968
/// triangles, irregular valence, scientific-notation coordinates and a
/// bounding box nowhere near the unit cube.
///
/// It walks the whole import chain rather than just the loader —
/// file → engine load → `importCommand` → journaled `addObject` → payload
/// serialization → re-read from the bundle → render buffers — because that
/// is the chain `TopoDocument.importMesh` drives, and a break anywhere in
/// it shows up to the user identically: "the model doesn't appear".
@Suite("OBJ import integration (Stanford bunny)")
struct OBJImportIntegrationTests {
    private let bunny = MeshFixtureCorpus.stanfordBunny

    private func bunnyURL() throws -> URL {
        try MeshFixtureCorpus.stanfordBunnyURL()
    }

    // MARK: - Provenance

    /// The corpus is only trustworthy if the committed bytes are the ones
    /// PROVENANCE.md describes. Swapping the file without updating the
    /// table fails here rather than silently changing every count below.
    @Test("Committed fixture matches its pinned hash")
    func fixtureMatchesPinnedHash() throws {
        let data = try Data(contentsOf: bunnyURL())
        #expect(data.sha256Hex == bunny.sha256)
    }

    // MARK: - Load

    /// The engine reports exactly what the file declares. Not "more than
    /// zero" — the file says 2503/4968, so a loader that silently drops
    /// degenerate faces or welds coincident vertices has to say so.
    @Test("Engine loads every vertex and face the file declares")
    func loadsFullMesh() throws {
        let mesh = try Mesh.loadOBJ(at: bunnyURL())
        #expect(mesh.vertexCount == bunny.vertexCount)
        #expect(mesh.faceCount == bunny.faceCount)
    }

    /// Geometry actually arrived: positions are finite, correctly sized,
    /// and span a real bounding box. A loader returning the right COUNTS
    /// with zeroed coordinates would pass the test above and render an
    /// invisible model — which is exactly the reported symptom.
    @Test("Loaded positions are finite and span a non-degenerate box")
    func positionsAreRealGeometry() throws {
        let mesh = try Mesh.loadOBJ(at: bunnyURL())
        let positions = mesh.positions()
        #expect(positions.count == bunny.vertexCount * 3)
        // Computed outside #expect: the macro decomposes the call and can
        // no longer prove the rethrows overload is non-throwing.
        let allFinite = positions.allSatisfy { $0.isFinite }
        #expect(allFinite)

        var minimum = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maximum = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for index in stride(from: 0, to: positions.count, by: 3) {
            let point = SIMD3(positions[index], positions[index + 1], positions[index + 2])
            minimum = simd_min(minimum, point)
            maximum = simd_max(maximum, point)
        }
        let extent = maximum - minimum
        #expect(extent.x > 0 && extent.y > 0 && extent.z > 0)
        // The bunny is ~0.15 units tall in this file; assert the order of
        // magnitude so a unit-scaling regression is visible.
        #expect(extent.max() > 0.1 && extent.max() < 1.0)
    }

    /// This OBJ carries no `vn` and no vertex colours. The loader must
    /// report that honestly — a synthesized has-colors of `true` would
    /// send the renderer down the coloured path with garbage.
    @Test("A file with no vn and no colours reports none")
    func reportsAbsentAttributesHonestly() throws {
        let mesh = try Mesh.loadOBJ(at: bunnyURL())
        #expect(!mesh.hasColors)
        #expect(mesh.colors() == nil)
    }

    // MARK: - Import command → bundle

    /// The chain `DocumentEditorView` → `TopoDocument.importMesh` runs:
    /// the command is journaled, applied, and the object is queryable with
    /// counts matching the file.
    @Test("Import command adds an object whose manifest counts match the file")
    func importCommandProducesMatchingObject() throws {
        let bundle = DocumentBundle()
        let command = try bundle.importCommand(
            for: bunnyURL(), name: "bunny", role: .target
        )

        guard case .addObject(let object, let payload) = command else {
            Issue.record("expected .addObject, got \(command)")
            return
        }
        #expect(object.name == "bunny")
        #expect(object.role == .target)
        // `counts` is optional (absent in pre-1.5 documents); a fresh
        // import must populate it, so require rather than optional-chain.
        let counts = try #require(object.counts)
        #expect(counts.vertices == bunny.vertexCount)
        #expect(counts.faces == bunny.faceCount)
        #expect(!payload.isEmpty)
    }

    /// The payload actually round-trips: applying the command and reading
    /// the mesh back out of the bundle yields the same geometry. This is
    /// the step where a mesh can be imported "successfully" and still
    /// never reach the viewport.
    @Test("Applied import round-trips through the bundle payload")
    func payloadRoundTripsThroughBundle() throws {
        let bundle = DocumentBundle()
        let command = try bundle.importCommand(
            for: bunnyURL(), name: "bunny", role: .target
        )
        var applied = bundle
        command.apply(to: &applied)

        let object = try #require(applied.manifest.objects.first)
        let reloaded = try applied.mesh(for: object)
        #expect(reloaded.vertexCount == bunny.vertexCount)
        #expect(reloaded.faceCount == bunny.faceCount)

        // Positions survive serialization. OBJ writes ~6 significant
        // digits, so compare with a tolerance scaled to the model, not
        // bit-exactly — the payload is text, and claiming byte-equality
        // here would be a false guarantee.
        let original = try Mesh.loadOBJ(at: bunnyURL()).positions()
        let survived = reloaded.positions()
        #expect(survived.count == original.count)
        let worst = zip(original, survived).map { abs($0 - $1) }.max() ?? 0
        #expect(worst < 1e-4)
    }

    // MARK: - Render data

    /// The viewport draws from these buffers; if they are empty or
    /// mis-sized the model is imported but invisible.
    @Test("Render buffers are derivable and correctly sized")
    func renderBuffersAreUsable() throws {
        let mesh = try Mesh.loadOBJ(at: bunnyURL())

        // Every face is already a triangle in this file, so triangulation
        // must be exactly 3 indices per face — no fan-splitting.
        let indices = mesh.triangleIndices()
        #expect(indices.count == bunny.faceCount * 3)
        let indicesInRange = indices.allSatisfy { $0 < UInt32(bunny.vertexCount) }
        #expect(indicesInRange)

        // The file has no `vn`; normals must be synthesized per vertex and
        // be unit length, or lighting collapses to black.
        let normals = mesh.normals()
        #expect(normals.count == bunny.vertexCount * 3)
        for index in stride(from: 0, to: normals.count, by: 3) {
            let normal = SIMD3(normals[index], normals[index + 1], normals[index + 2])
            #expect(abs(simd_length(normal) - 1.0) < 1e-3)
        }
    }

    /// Deterministic across loads — the golden-file harness and the render
    /// cache both depend on it (design D2).
    @Test("Repeated loads produce identical index buffers")
    func loadIsDeterministic() throws {
        let first = try Mesh.loadOBJ(at: bunnyURL()).triangleIndices()
        let second = try Mesh.loadOBJ(at: bunnyURL()).triangleIndices()
        #expect(first == second)
    }

    // MARK: - Failure modes

    /// Import must reject an unknown extension with a readable message
    /// rather than failing silently — the app surfaces this string.
    @Test("Unsupported extension throws a descriptive error")
    func unsupportedExtensionThrows() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let stray = directory.appendingPathComponent("bunny.ply")
        try Data(contentsOf: bunnyURL()).write(to: stray)

        let bundle = DocumentBundle()
        #expect(throws: CyberKitError.self) {
            _ = try bundle.importCommand(for: stray, name: "bunny", role: .target)
        }
    }

    /// A truncated file must throw, not produce a partial mesh the user
    /// then edits and saves.
    @Test("A truncated OBJ throws rather than importing partial geometry")
    func truncatedFileThrows() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let text = try String(contentsOf: bunnyURL(), encoding: .utf8)
        let half = text.prefix(text.count / 2)
        // Cut mid-line so the tail is a malformed face record.
        let truncated = directory.appendingPathComponent("truncated.obj")
        try (half + "f 1 2").write(to: truncated, atomically: true, encoding: .utf8)

        let bundle = DocumentBundle()
        #expect(throws: (any Error).self) {
            _ = try bundle.importCommand(for: truncated, name: "truncated", role: .target)
        }
    }
}

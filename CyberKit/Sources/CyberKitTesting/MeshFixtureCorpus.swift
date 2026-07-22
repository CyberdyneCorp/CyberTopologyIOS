import Foundation

/// Committed mesh-file fixtures for import/round-trip regression tests
/// (spec: quality-assurance / "Golden-file harness"; spec: scene-pipeline /
/// "Import formats").
///
/// These live in `CyberKitTesting` rather than in `CyberKitTests/Fixtures`
/// for one reason: the app test target has no resource bundle of its own,
/// and the import path under test spans both layers — `TopoDocument`
/// (app) calls `DocumentBundle.importCommand` (CyberKit). Shipping the
/// fixture through the test-support library is what lets a single mesh
/// serve both suites, exactly as `StrokeGestureCorpus` already does for
/// gestures.
///
/// Provenance (source URL, retrieval date, hash) is pinned in
/// `Fixtures/PROVENANCE.md` and asserted by the suite, so the corpus
/// cannot silently drift.
public enum MeshFixtureCorpus {
    /// Metadata for a committed mesh fixture. The counts are the file's
    /// own, read off the source data — not whatever the engine happens to
    /// report today, which is the point: if the loader starts dropping or
    /// inventing geometry, the comparison fails.
    public struct Fixture: Sendable {
        public let name: String
        public let fileExtension: String
        /// Vertex count as written in the file.
        public let vertexCount: Int
        /// Face count as written in the file.
        public let faceCount: Int
        /// SHA-256 of the committed bytes, pinned in PROVENANCE.md.
        public let sha256: String

        public var filename: String { "\(name).\(fileExtension)" }
    }

    /// The Stanford bunny: 2503 vertices, 4968 triangles, no normals, no
    /// vertex colours, coordinates in scientific notation, bounding box
    /// roughly 0.15 units and centred away from the origin.
    ///
    /// Deliberately unlike the hand-written `cube.obj` / `grid32.obj`
    /// fixtures, which are tiny and perfectly regular.
    public static let stanfordBunny = Fixture(
        name: "bunny",
        fileExtension: "obj",
        vertexCount: 2503,
        faceCount: 4968,
        sha256: "e4bfe098950c61c42190fefe8f23ad7b469da8d5d488c8f8e28a0e0b00c4c88c"
    )

    /// Every committed mesh fixture, for corpus-wide provenance checks.
    public static let all: [Fixture] = [stanfordBunny]

    /// On-disk URL of a committed fixture inside this library's resource
    /// bundle. Throws rather than force-unwrapping so a missing resource
    /// fails as a readable test error instead of a crash.
    public static func url(for fixture: Fixture) throws -> URL {
        guard let url = Bundle.module.url(
            forResource: fixture.name,
            withExtension: fixture.fileExtension,
            subdirectory: "Fixtures"
        ) else {
            throw MeshFixtureError.missingResource(fixture.filename)
        }
        return url
    }

    /// Convenience for the common case.
    public static func stanfordBunnyURL() throws -> URL {
        try url(for: stanfordBunny)
    }
}

public enum MeshFixtureError: Error, CustomStringConvertible {
    case missingResource(String)

    public var description: String {
        switch self {
        case .missingResource(let name):
            return "mesh fixture '\(name)' is not in the CyberKitTesting "
                + "resource bundle; check Package.swift resources"
        }
    }
}

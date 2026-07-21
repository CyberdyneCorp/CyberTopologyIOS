import Foundation

/// Golden-file regression harness (task 1.1b, spec: quality-assurance /
/// "Determinism and golden-file regression tests").
///
/// Goldens are versioned with the code (committed next to the tests that
/// use them). Setting `REGEN_GOLDENS=1` in the test environment rewrites
/// the golden instead of comparing, for intentional output changes —
/// regeneration must never happen in CI.
///
/// Tests locate goldens via `#filePath`-relative URLs, which works on the
/// simulator (tests read the host file system). The phase-9 device test
/// plan bundles goldens as resources instead and passes bundle URLs — the
/// API only ever sees URLs, so nothing here changes.
public enum GoldenFile {
    public enum Failure: Error, Equatable {
        /// Golden file absent and regeneration not requested.
        case missingGolden(path: String)
        /// Byte-level mismatch: first differing offset and total sizes.
        case dataMismatch(path: String, firstDifference: Int, actualSize: Int, goldenSize: Int)
        /// Float-array mismatch: index of the first out-of-tolerance value.
        case valueMismatch(path: String, index: Int, actual: Float, golden: Float, tolerance: Float)
        /// Float-array length mismatch.
        case countMismatch(path: String, actualCount: Int, goldenCount: Int)
    }

    public static var regenerationRequested: Bool {
        ProcessInfo.processInfo.environment["REGEN_GOLDENS"] == "1"
    }

    /// Bit-exact comparison of raw bytes against the golden at `url`.
    /// In regeneration mode, writes `actual` as the new golden instead.
    /// `regenerate` defaults to the environment flag; tests of the harness
    /// itself pass it explicitly to stay env-independent.
    public static func compare(
        _ actual: Data, golden url: URL, regenerate: Bool = GoldenFile.regenerationRequested
    ) throws {
        if regenerate {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try actual.write(to: url, options: .atomic)
            return
        }
        guard let golden = try? Data(contentsOf: url) else {
            throw Failure.missingGolden(path: url.path)
        }
        if actual == golden { return }
        let firstDifference = zip(actual, golden).enumerated()
            .first { $1.0 != $1.1 }?.offset ?? min(actual.count, golden.count)
        throw Failure.dataMismatch(
            path: url.path, firstDifference: firstDifference,
            actualSize: actual.count, goldenSize: golden.count
        )
    }

    /// Compares a float array against the golden at `url`.
    /// `tolerance` 0 = bit-exact; nonzero allows per-element absolute drift
    /// (for GPU paths whose reductions are not bit-stable — committed
    /// geometry must always use 0).
    public static func compare(
        _ actual: [Float], golden url: URL, tolerance: Float = 0,
        regenerate: Bool = GoldenFile.regenerationRequested
    ) throws {
        if regenerate {
            try compare(encode(actual), golden: url, regenerate: true)  // write path
            return
        }
        guard let goldenData = try? Data(contentsOf: url) else {
            throw Failure.missingGolden(path: url.path)
        }
        let golden = decode(goldenData)
        guard golden.count == actual.count else {
            throw Failure.countMismatch(
                path: url.path, actualCount: actual.count, goldenCount: golden.count
            )
        }
        for (index, pair) in zip(actual, golden).enumerated()
        where abs(pair.0 - pair.1) > tolerance {
            throw Failure.valueMismatch(
                path: url.path, index: index, actual: pair.0, golden: pair.1,
                tolerance: tolerance
            )
        }
    }

    // Float arrays are stored little-endian binary, 4 bytes per value:
    // stable across runs, byte-diffable, no JSON float-formatting drift.
    static func encode(_ values: [Float]) -> Data {
        var data = Data(capacity: values.count * 4)
        for value in values {
            withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func decode(_ data: Data) -> [Float] {
        stride(from: 0, to: data.count - 3, by: 4).map { offset in
            let bits = data.subdata(in: offset..<offset + 4)
                .withUnsafeBytes { $0.load(as: UInt32.self) }
            return Float(bitPattern: UInt32(littleEndian: bits))
        }
    }
}

import CyberRemesherC
import Foundation

/// Typed interpretation record from the engine's two-stage gesture
/// recognizer (design D5; spec: pencil-interaction / "Contextual gesture
/// grammar"): the stage-1 geometric shape class, the stage-2 under-stroke
/// mesh context, and ranked candidate actions (best first) with confidences
/// and the concrete mesh elements each candidate would touch.
///
/// Interpretation never mutates the mesh — applying a candidate is the tool
/// layer's job (tasks 3.3/3.4), and every mutation goes through the
/// journaled `DocumentCommand` path.
public struct StrokeInterpretation: Equatable, Sendable {
    /// Stage-1 shape classes (mirrors `CyberStrokeShape`).
    public enum Shape: String, Equatable, Sendable, CaseIterable {
        case unknown
        case holdPoint
        case line
        case closedLoop
        case circle
        case scribble
        case cross
        case lasso
        case grid
    }

    /// What the resolver found under the stroke (mirrors
    /// `CyberStrokeContext`).
    public enum Context: String, Equatable, Sendable, CaseIterable {
        case emptySurface
        case face
        case edge
        case boundaryEdge
        case vertex
    }

    /// Candidate actions of the gesture grammar (mirrors
    /// `CyberStrokeAction`).
    public enum Action: String, Equatable, Sendable, CaseIterable {
        case none
        case createQuad
        case createTriangle
        case insertLoop
        case tagLoop
        case dissolveEdge
        case deleteFaces
        case mergeVertices
        case rotateEdge
        case tweakVertex
        case hideRegion
        case toggleVisibility
        case createGrid
    }

    /// A referenced mesh element. `id` is the engine's stable element id
    /// (NOT a compacted render-buffer index).
    public struct Element: Equatable, Sendable {
        public enum Kind: String, Equatable, Sendable {
            case vertex
            case edge
            case face
        }

        public let kind: Kind
        public let id: UInt32

        public init(kind: Kind, id: UInt32) {
            self.kind = kind
            self.id = id
        }
    }

    /// One ranked interpretation candidate.
    public struct Candidate: Equatable, Sendable {
        public let action: Action
        public let confidence: Float
        public let elements: [Element]

        public init(action: Action, confidence: Float, elements: [Element]) {
            self.action = action
            self.confidence = confidence
            self.elements = elements
        }
    }

    /// Quad-cell dimensions of a grid stroke's estimated lattice (task 3.4).
    public struct GridSize: Equatable, Sendable {
        public let rows: Int
        public let cols: Int

        public init(rows: Int, cols: Int) {
            self.rows = rows
            self.cols = cols
        }
    }

    public let shape: Shape
    public let shapeConfidence: Float
    public let context: Context
    /// Ranked best-first; index 0 is the chosen interpretation, the rest
    /// are the one-tap alternatives (task 3.5 chip).
    public let candidates: [Candidate]
    /// For CLOSED strokes: 4 engine-estimated corner points in normalized
    /// viewport coordinates (0...1, origin top-left), ordered as a simple
    /// ring — what the tool layer unprojects onto the Target when applying
    /// a `createQuad` candidate (task 3.3). For GRID strokes: the estimated
    /// quad lattice, row-major `(rows+1) x (cols+1)` points (task 3.4).
    /// Empty for other open shapes.
    public let quadCorners: [SIMD2<Float>]
    /// Lattice dimensions when `shape == .grid`; nil otherwise.
    public let gridSize: GridSize?

    public init(
        shape: Shape, shapeConfidence: Float, context: Context, candidates: [Candidate],
        quadCorners: [SIMD2<Float>] = [], gridSize: GridSize? = nil
    ) {
        self.shape = shape
        self.shapeConfidence = shapeConfidence
        self.context = context
        self.candidates = candidates
        self.quadCorners = quadCorners
        self.gridSize = gridSize
    }

    /// The chosen interpretation.
    public var best: Candidate? { candidates.first }

    /// Deterministic one-line encoding, stable across runs: drives the
    /// golden-file regression corpus and the debug HUD. Confidences are
    /// fixed to two decimals so float formatting can never drift a golden.
    public var summary: String {
        let head = String(
            format: "shape=%@ conf=%.2f context=%@", shape.rawValue, shapeConfidence,
            context.rawValue
        )
        let ranked = candidates.map { candidate in
            let elements = candidate.elements
                .map { "\($0.kind.rawValue):\($0.id)" }
                .joined(separator: ",")
            let suffix = elements.isEmpty ? "" : "[\(elements)]"
            return String(
                format: "%@:%.2f%@", candidate.action.rawValue, candidate.confidence, suffix
            )
        }
        return ([head] + ranked).joined(separator: "; ")
    }
}

/// Facade over `cyber_stroke_interpret`: feeds a completed stroke through
/// the ENGINE recognizer (both stages run in C++ so they are headless-
/// testable and portable, design D1/D5) and decodes the record.
public enum StrokeInterpreter {
    /// One stroke sample: normalized viewport coordinates (0...1 each axis,
    /// origin top-left) and seconds since the stroke began.
    public struct Sample: Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var time: Double

        public init(x: Double, y: Double, time: Double) {
            self.x = x
            self.y = y
            self.time = time
        }
    }

    /// Interprets one completed stroke.
    ///
    /// - Parameters:
    ///   - samples: the stroke polyline in recorded order (at least one).
    ///   - editMesh: mesh for stage-2 context resolution; `nil` runs stage 1
    ///     only (every context rule sees an empty scene).
    ///   - viewProjection: column-major 4x4 world→clip matrix (16 floats,
    ///     `simd_float4x4` memory order); required when `editMesh` is given.
    ///   - aspect: viewport width/height so circles and angles are measured
    ///     undistorted (values <= 0 mean square).
    public static func interpret(
        samples: [Sample], editMesh: Mesh? = nil, viewProjection: [Float]? = nil,
        aspect: Float = 1
    ) throws -> StrokeInterpretation {
        guard !samples.isEmpty else {
            throw CyberKitError(code: .invalidArgument, message: "empty stroke")
        }
        if editMesh != nil {
            guard let viewProjection, viewProjection.count == 16 else {
                throw CyberKitError(
                    code: .invalidArgument,
                    message: "viewProjection (16 floats) is required with editMesh"
                )
            }
        }

        var xyt: [Float] = []
        xyt.reserveCapacity(samples.count * 3)
        for sample in samples {
            xyt.append(Float(sample.x))
            xyt.append(Float(sample.y))
            xyt.append(Float(sample.time))
        }

        var raw: OpaquePointer?
        try xyt.withUnsafeBufferPointer { buffer in
            if let editMesh, let viewProjection {
                try viewProjection.withUnsafeBufferPointer { matrix in
                    try check(cyber_stroke_interpret(
                        editMesh.handle, matrix.baseAddress, buffer.baseAddress,
                        samples.count, aspect, &raw
                    ))
                }
            } else {
                try check(cyber_stroke_interpret(
                    nil, nil, buffer.baseAddress, samples.count, aspect, &raw
                ))
            }
        }
        guard let raw else { throw CyberKitError(status: CYBER_ERR_RUNTIME) }
        defer { cyber_stroke_interpretation_free(raw) }
        return decode(raw)
    }

    // MARK: - Record decoding

    private static func decode(_ raw: OpaquePointer) -> StrokeInterpretation {
        let count = cyber_stroke_interpretation_candidate_count(raw)
        let candidates = (0..<count).map { index in
            StrokeInterpretation.Candidate(
                action: action(cyber_stroke_interpretation_action(raw, index)),
                confidence: cyber_stroke_interpretation_confidence(raw, index),
                elements: elements(raw, candidate: index)
            )
        }
        return StrokeInterpretation(
            shape: shape(cyber_stroke_interpretation_shape(raw)),
            shapeConfidence: cyber_stroke_interpretation_shape_confidence(raw),
            context: context(cyber_stroke_interpretation_context(raw)),
            candidates: candidates,
            quadCorners: corners(raw),
            gridSize: gridSize(raw)
        )
    }

    private static func gridSize(_ raw: OpaquePointer) -> StrokeInterpretation.GridSize? {
        var rows = 0, cols = 0
        guard cyber_stroke_interpretation_grid_size(raw, &rows, &cols) == 1 else { return nil }
        return StrokeInterpretation.GridSize(rows: rows, cols: cols)
    }

    private static func corners(_ raw: OpaquePointer) -> [SIMD2<Float>] {
        let count = cyber_stroke_interpretation_corner_count(raw)
        return (0..<count).compactMap { index in
            var xy: [Float] = [0, 0]
            guard cyber_stroke_interpretation_corner(raw, index, &xy) == 1 else { return nil }
            return SIMD2(xy[0], xy[1])
        }
    }

    private static func elements(
        _ raw: OpaquePointer, candidate: Int
    ) -> [StrokeInterpretation.Element] {
        let count = cyber_stroke_interpretation_element_count(raw, candidate)
        return (0..<count).compactMap { index in
            var kind = CYBER_ELEMENT_VERTEX
            var id: UInt32 = 0
            guard cyber_stroke_interpretation_element(raw, candidate, index, &kind, &id) == 1
            else { return nil }
            return StrokeInterpretation.Element(kind: elementKind(kind), id: id)
        }
    }

    private static func shape(_ raw: CyberStrokeShape) -> StrokeInterpretation.Shape {
        switch raw {
        case CYBER_SHAPE_HOLD_POINT: return .holdPoint
        case CYBER_SHAPE_LINE: return .line
        case CYBER_SHAPE_CLOSED_LOOP: return .closedLoop
        case CYBER_SHAPE_CIRCLE: return .circle
        case CYBER_SHAPE_SCRIBBLE: return .scribble
        case CYBER_SHAPE_CROSS: return .cross
        case CYBER_SHAPE_LASSO: return .lasso
        case CYBER_SHAPE_GRID: return .grid
        default: return .unknown
        }
    }

    private static func context(_ raw: CyberStrokeContext) -> StrokeInterpretation.Context {
        switch raw {
        case CYBER_CONTEXT_FACE: return .face
        case CYBER_CONTEXT_EDGE: return .edge
        case CYBER_CONTEXT_BOUNDARY_EDGE: return .boundaryEdge
        case CYBER_CONTEXT_VERTEX: return .vertex
        default: return .emptySurface
        }
    }

    private static func action(_ raw: CyberStrokeAction) -> StrokeInterpretation.Action {
        switch raw {
        case CYBER_ACTION_CREATE_QUAD: return .createQuad
        case CYBER_ACTION_CREATE_TRIANGLE: return .createTriangle
        case CYBER_ACTION_INSERT_LOOP: return .insertLoop
        case CYBER_ACTION_TAG_LOOP: return .tagLoop
        case CYBER_ACTION_DISSOLVE_EDGE: return .dissolveEdge
        case CYBER_ACTION_DELETE_FACES: return .deleteFaces
        case CYBER_ACTION_MERGE_VERTICES: return .mergeVertices
        case CYBER_ACTION_ROTATE_EDGE: return .rotateEdge
        case CYBER_ACTION_TWEAK_VERTEX: return .tweakVertex
        case CYBER_ACTION_HIDE_REGION: return .hideRegion
        case CYBER_ACTION_TOGGLE_VISIBILITY: return .toggleVisibility
        case CYBER_ACTION_CREATE_GRID: return .createGrid
        default: return .none
        }
    }

    private static func elementKind(
        _ raw: CyberElementKind
    ) -> StrokeInterpretation.Element.Kind {
        switch raw {
        case CYBER_ELEMENT_EDGE: return .edge
        case CYBER_ELEMENT_FACE: return .face
        default: return .vertex
        }
    }
}

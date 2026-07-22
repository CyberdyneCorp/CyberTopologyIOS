import Foundation

// Action Gallery catalog (task 3.8, spec: pencil-interaction /
// "Customizable toolbar and Action Gallery"): per-action help-panel
// content — title, gesture, usage notes, and the demo-media slot.
//
// HONEST DEMO SCOPE: the spec asks for "a looping demo video" per action.
// Recording real per-action screen captures is tutorial content (task 9.1
// "Interactive tutorial covering every action" is where the material gets
// produced); shipping fabricated stand-ins as if they were recordings
// would be worse than none. Until then the demo slot plays a LOOPING
// SF-symbol frame animation sketching the gesture, and the panel labels it
// as a placeholder. `demoFrames` is the media slot: when 9.1 lands, the
// entry grows a video resource name and `ActionDemoView` swaps the frame
// loop for the player without touching callers.

extension EditorAction {
    /// Help-panel content for one action.
    struct GalleryEntry {
        /// Display name (also the chip/help title vocabulary).
        let title: String
        /// SF Symbol shown in toolbar slots and gallery tiles.
        let symbol: String
        /// How the action is performed (one line under the title).
        let gesture: String
        /// Usage notes for the help panel.
        let notes: String
        /// Looping demo frames (SF symbols) — the demo-media placeholder;
        /// see the honest-scope note above.
        let demoFrames: [String]
    }

    var gallery: GalleryEntry {
        switch self {
        case .pencil:
            GalleryEntry(
                title: "Pencil",
                symbol: "pencil",
                gesture: "Verb — tap to select, hold to spring-load",
                notes: "The authoring verb: draw quads, grids, loops and "
                    + "every other gesture directly on the Target surface. "
                    + "New geometry snaps continuously onto the Target.",
                demoFrames: ["pencil", "pencil.line", "square.dashed", "square"]
            )
        case .relax:
            GalleryEntry(
                title: "Relax",
                symbol: "wind",
                gesture: "Verb — scrub over vertices to smooth",
                notes: "Evens out vertex spacing under the brush while "
                    + "keeping everything on the Target surface. Corners "
                    + "pin automatically; hold the button for a one-off "
                    + "relax without leaving your current verb.",
                demoFrames: ["circle.grid.3x3", "wind", "circle.grid.3x3.fill"]
            )
        case .move:
            GalleryEntry(
                title: "Move",
                symbol: "arrow.up.and.down.and.arrow.left.and.right",
                gesture: "Verb — drag a vertex; falloff follows the surface",
                notes: "Drags vertices with geodesic falloff: influence "
                    + "travels along the connected surface, never jumping "
                    + "across gaps to disconnected parts. Dropping onto a "
                    + "nearby vertex snaps the position onto it.",
                demoFrames: [
                    "arrow.up.and.down.and.arrow.left.and.right",
                    "dot.circle.and.hand.point.up.left.fill",
                    "arrow.up.and.down.and.arrow.left.and.right",
                ]
            )
        case .tweak:
            GalleryEntry(
                title: "Tweak",
                symbol: "point.topleft.down.to.point.bottomright.curvepath",
                gesture: "Verb — drag a single vertex",
                notes: "Precision single-vertex drags with no falloff. "
                    + "Ending a drag within merge range of another vertex "
                    + "welds the two (the target highlights first, with a "
                    + "haptic tick where supported).",
                demoFrames: [
                    "point.topleft.down.to.point.bottomright.curvepath",
                    "arrow.triangle.merge",
                    "circle.fill",
                ]
            )
        case .erase:
            GalleryEntry(
                title: "Erase",
                symbol: "eraser",
                gesture: "Verb — scrub over elements to delete",
                notes: "Removes the faces under the brush in one journaled "
                    + "stroke. Pencil Pro's squeeze preference can switch "
                    + "here directly when set to eraser.",
                demoFrames: ["eraser", "eraser.line.dashed", "square.slash"]
            )
        case .quadDraw:
            GalleryEntry(
                title: "Draw quad",
                symbol: "square.on.square.dashed",
                gesture: "Pencil verb — outline four corners on the surface",
                notes: "A roughly square stroke over empty Target surface "
                    + "creates one quad snapped onto the surface. Drawn "
                    + "against an existing patch it extends the topology.",
                demoFrames: ["square.dashed", "square.dotted", "square"]
            )
        case .gridStroke:
            GalleryEntry(
                title: "Grid stroke",
                symbol: "square.grid.3x3",
                gesture: "Pencil verb — serpentine stroke over the surface",
                notes: "One back-and-forth lattice stroke drops a whole "
                    + "welded block of quads in a single journal entry — "
                    + "the fastest way to cover open surface.",
                demoFrames: [
                    "scribble", "square.grid.3x2", "square.grid.3x3.fill",
                ]
            )
        case .loopInsert:
            GalleryEntry(
                title: "Insert loop",
                symbol: "rectangle.split.3x1",
                gesture: "Pencil verb — line ACROSS a quad ring",
                notes: "A stroke across a ring of quads splits every quad "
                    + "in the ring, inserting a full edge loop. If the "
                    + "recognizer reads a tag instead, the post-stroke chip "
                    + "offers the swap.",
                demoFrames: [
                    "rectangle.portrait", "rectangle.split.2x1",
                    "rectangle.split.3x1",
                ]
            )
        case .loopTag:
            GalleryEntry(
                title: "Tag loop",
                symbol: "point.forward.to.point.capsulepath",
                gesture: "Pencil verb — line ALONG an edge loop",
                notes: "Marks the whole loop (shown highlighted) for the "
                    + "Weave solver to respect as a flow constraint. "
                    + "Tagging is an annotation — the mesh itself is "
                    + "untouched.",
                demoFrames: [
                    "point.forward.to.point.capsulepath",
                    "capsule", "capsule.fill",
                ]
            )
        case .scribbleDissolve:
            GalleryEntry(
                title: "Dissolve edge",
                symbol: "scribble",
                gesture: "Pencil verb — scribble over an edge",
                notes: "A quick zig-zag over an edge dissolves it, merging "
                    + "the faces on both sides into one.",
                demoFrames: ["scribble", "scribble.variable", "square"]
            )
        case .crossDelete:
            GalleryEntry(
                title: "Delete region",
                symbol: "xmark.square",
                gesture: "Pencil verb — draw an X over faces",
                notes: "Two crossing strokes delete the faces under the X. "
                    + "In later stages the same gesture clears seams (UV) "
                    + "or cage regions (baking).",
                demoFrames: ["xmark", "xmark.square", "square.slash"]
            )
        case .mergeLine:
            GalleryEntry(
                title: "Merge vertices",
                symbol: "arrow.triangle.merge",
                gesture: "Pencil verb — line from vertex to vertex",
                notes: "A stroke connecting two vertices welds them into "
                    + "one, closing small gaps without a drag.",
                demoFrames: [
                    "circle.grid.2x1", "arrow.triangle.merge", "circle.fill",
                ]
            )
        case .edgeRotate:
            GalleryEntry(
                title: "Rotate edge",
                symbol: "arrow.trianglehead.2.clockwise.rotate.90",
                gesture: "Pencil verb — small circle over an edge",
                notes: "Circling an interior edge rotates it: a triangle "
                    + "pair flips its diagonal, a quad pair turns its "
                    + "shared edge to redirect the topology flow.",
                demoFrames: [
                    "arrow.trianglehead.2.clockwise.rotate.90",
                    "square.split.diagonal.2x2", "square.split.diagonal",
                ]
            )
        case .doubleTapTweak:
            GalleryEntry(
                title: "Double-tap tweak",
                symbol: "hand.tap",
                gesture: "Pencil verb — double-tap a vertex",
                notes: "Double-tapping a vertex switches to the Tweak verb "
                    + "right there, ready to drag. Double-tapping an edge "
                    + "will slide its loop once the loop-slide op lands "
                    + "(task 3.4a).",
                demoFrames: ["hand.tap", "hand.tap.fill", "dot.circle"]
            )
        case .visibilityLasso:
            GalleryEntry(
                title: "Hide region",
                symbol: "lasso",
                gesture: "Pencil verb — lasso starting in empty space",
                notes: "A lasso that STARTS over empty space hides the "
                    + "enclosed EditMesh faces so you can work on the "
                    + "geometry behind them. Hidden faces stay in the "
                    + "document and journal.",
                demoFrames: ["lasso", "circle.dashed", "eye.slash"]
            )
        case .visibilityLines:
            GalleryEntry(
                title: "Show hidden",
                symbol: "eye",
                gesture: "Pencil verb — two vertical lines in empty space",
                notes: "Two quick vertical lines over empty space invert "
                    + "the hidden set; drawn again they show everything — "
                    + "the escape hatch after a lasso-hide.",
                demoFrames: ["eye.slash", "line.diagonal", "eye"]
            )
        }
    }
}

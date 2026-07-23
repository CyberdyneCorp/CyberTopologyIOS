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
                notes: "The authoring verb: draw the curated Pencil grammar — "
                    + "quads, triangles, loop cuts and delete-X — directly on "
                    + "the Target surface. New geometry snaps continuously "
                    + "onto the Target.",
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
                gesture: "Retired gesture — a dedicated grid tool is planned",
                notes: "Dropping a whole welded block of quads in one stroke "
                    + "left the curated Pencil grammar (simplify-gesture-"
                    + "grammar): a serpentine stroke was too easily confused "
                    + "with a quad or a scribble. The capability returns as an "
                    + "armed tool; until then, build quads individually.",
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
                    + "in the ring, inserting a full edge loop. A line is now "
                    + "always read as a loop insert (the curated grammar "
                    + "dropped line-along tagging).",
                demoFrames: [
                    "rectangle.portrait", "rectangle.split.2x1",
                    "rectangle.split.3x1",
                ]
            )
        case .loopTag:
            GalleryEntry(
                title: "Tag loop",
                symbol: "point.forward.to.point.capsulepath",
                gesture: "Retired gesture — a loop-tag tool is planned",
                notes: "Marking a loop for the Weave solver left the curated "
                    + "Pencil grammar (simplify-gesture-grammar): a line ALONG "
                    + "a loop and a line ACROSS one (Insert loop) were too easily "
                    + "confused. The capability returns as an armed tool; Clear "
                    + "loop tags still removes existing tags.",
                demoFrames: [
                    "point.forward.to.point.capsulepath",
                    "capsule", "capsule.fill",
                ]
            )
        case .scribbleDissolve:
            GalleryEntry(
                title: "Dissolve edge",
                symbol: "scribble",
                gesture: "Retired gesture — use the Merge pair tool",
                notes: "Dissolving an edge left the curated Pencil grammar "
                    + "(simplify-gesture-grammar), where a scribble now only "
                    + "ever means Delete. The capability lives on in the Merge "
                    + "pair tool: stroke across the shared edge of two "
                    + "triangles to merge them into one quad.",
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
                gesture: "Retired gesture — use the Merge pair tool",
                notes: "Welding two vertices with a line left the curated "
                    + "Pencil grammar (simplify-gesture-grammar), where a line "
                    + "now only ever means Insert loop. The capability lives on "
                    + "in the Merge pair tool: stroke from one vertex to another "
                    + "to collapse the pair at its midpoint.",
                demoFrames: [
                    "circle.grid.2x1", "arrow.triangle.merge", "circle.fill",
                ]
            )
        case .edgeRotate:
            GalleryEntry(
                title: "Rotate edge",
                symbol: "arrow.trianglehead.2.clockwise.rotate.90",
                gesture: "Retired gesture — an edge-rotate tool is planned",
                notes: "Rotating an interior edge (a triangle pair flips its "
                    + "diagonal, a quad pair turns its shared edge) left the "
                    + "curated Pencil grammar (simplify-gesture-grammar): a "
                    + "small circle clashed with the quad outline. The "
                    + "capability returns as an armed tool.",
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
                gesture: "Retired gesture — a hide/show tool is planned",
                notes: "Hiding the faces inside a lasso (to reach geometry "
                    + "behind them) left the curated Pencil grammar (simplify-"
                    + "gesture-grammar): a lasso was too easily read as a quad "
                    + "or a delete. The capability returns as an armed tool; "
                    + "hidden faces always stayed in the document and journal.",
                demoFrames: ["lasso", "circle.dashed", "eye.slash"]
            )
        case .visibilityLines:
            GalleryEntry(
                title: "Show hidden",
                symbol: "eye",
                gesture: "Retired gesture — a hide/show tool is planned",
                notes: "Inverting the hidden set with two vertical lines left "
                    + "the curated Pencil grammar (simplify-gesture-grammar), "
                    + "where a line now only ever means Insert loop. The "
                    + "capability returns as an armed tool alongside Hide "
                    + "region.",
                demoFrames: ["eye.slash", "line.diagonal", "eye"]
            )
        case .buildQuad:
            GalleryEntry(
                title: "Build quad",
                symbol: "plus.rectangle.on.rectangle",
                gesture: "Tool — drag from an edge or corner of the mesh",
                notes: "Grows topology one step per drag: from a quad's "
                    + "boundary edge a triangle tents out, from a "
                    + "triangle's boundary edge the triangle becomes a "
                    + "quad, and from a corner vertex a whole new quad "
                    + "spans the drag. New vertices weld onto nearby "
                    + "existing ones on release.",
                demoFrames: [
                    "square", "square.on.square.dashed",
                    "plus.rectangle.on.rectangle", "rectangle.split.2x1",
                ]
            )
        case .buildTriangle:
            GalleryEntry(
                title: "Build triangle",
                symbol: "triangle",
                gesture: "Tool — drag from an edge or corner of the mesh",
                notes: "The triangle counterpart of Build quad: any "
                    + "boundary edge tents out one triangle; a corner "
                    + "vertex spawns two triangles spanning the drag. New "
                    + "vertices weld onto nearby existing ones on release.",
                demoFrames: ["triangle", "triangle.fill", "square.split.diagonal"]
            )
        case .mergePair:
            GalleryEntry(
                title: "Merge pair",
                symbol: "arrow.triangle.merge",
                gesture: "Tool — line between two vertices or across two triangles",
                notes: "A stroke from vertex to vertex collapses the pair "
                    + "at its midpoint; a stroke across the shared edge of "
                    + "two triangles dissolves it, merging them into one "
                    + "quad.",
                demoFrames: [
                    "circle.grid.2x1", "arrow.triangle.merge", "circle.fill",
                ]
            )
        case .pathDistribute:
            GalleryEntry(
                title: "Path distribute",
                symbol: "point.3.connected.trianglepath.dotted",
                gesture: "Tool — stroke from one vertex to another",
                notes: "Finds the closest edge path between the vertices "
                    + "under the stroke's endpoints and spaces its "
                    + "vertices evenly along it, re-snapped to the "
                    + "Target. Endpoints stay fixed.",
                demoFrames: [
                    "point.3.filled.connected.trianglepath.dotted",
                    "point.3.connected.trianglepath.dotted",
                    "ellipsis",
                ]
            )
        case .surfaceCut:
            GalleryEntry(
                title: "Surface cut",
                symbol: "scissors",
                gesture: "Tool — draw a straight knife line across faces",
                notes: "Cuts new edges where the knife line crosses "
                    + "existing faces; any n-gons the cut leaves behind "
                    + "are triangulated automatically. New cut vertices "
                    + "snap onto the Target.",
                demoFrames: ["scissors", "square.split.diagonal", "scissors"]
            )
        case .patchClone:
            GalleryEntry(
                title: "Patch clone",
                symbol: "square.on.square",
                gesture: "Tool — stroke over faces, orbit, tap to paste",
                notes: "Select a patch of faces with one stroke, then move "
                    + "the CAMERA: the ghost patch stays locked to the "
                    + "screen and travels over the model. Tap to paste it "
                    + "projected onto the Target — repeatable for further "
                    + "pastes; flip mirrors the patch; barrel roll "
                    + "rotates it (Pencil Pro).",
                demoFrames: [
                    "square.dashed", "square.on.square.dashed",
                    "square.on.square", "square.fill.on.square",
                ]
            )
        case .extendBoundary:
            GalleryEntry(
                title: "Extend boundary",
                symbol: "rectangle.expand.vertical",
                gesture: "Tool — stroke or hold on a boundary, then orbit",
                notes: "Select boundary vertices with a stroke (hold on "
                    + "one to auto-select the whole boundary), then orbit "
                    + "the camera to extrude quad strips: single row, one "
                    + "automatic row, continuous automatic steps, or a "
                    + "triangle fan. Tap or use Extrude to commit — the "
                    + "whole extrusion journals as one entry.",
                demoFrames: [
                    "rectangle", "rectangle.expand.vertical",
                    "square.grid.3x2", "square.grid.3x3",
                ]
            )
        case .drawStrip:
            GalleryEntry(
                title: "Draw strip",
                symbol: "point.topleft.filled.down.to.point.bottomright.curvepath",
                gesture: "Tool — drag from a boundary quad edge",
                notes: "Drag out of a boundary edge and a quad strip "
                    + "follows the stroke, preserving the source quad "
                    + "size and welding onto the edge you started from. "
                    + "New vertices snap onto the Target.",
                demoFrames: [
                    "point.topleft.down.to.point.bottomright.curvepath",
                    "rectangle.split.3x1", "rectangle.split.3x1.fill",
                ]
            )
        case .transformVertices:
            GalleryEntry(
                title: "Transform vertices",
                symbol: "move.3d",
                gesture: "Tool — stroke over vertices, then move the camera",
                notes: "Vertices under the stroke lock to the screen: "
                    + "orbit moves them over the model, pinch scales, "
                    + "barrel roll rotates (Pencil Pro). Tap to commit — "
                    + "the vertices re-snap onto the Target and the "
                    + "session reports how many moved.",
                demoFrames: [
                    "circle.grid.2x2", "move.3d", "arrow.up.and.down.and.arrow.left.and.right",
                    "circle.grid.2x2.fill",
                ]
            )
        case .pinFlip:
            GalleryEntry(
                title: "Pin flip",
                symbol: "pin",
                gesture: "Tool — tap a vertex, sweep a run, or hold on a loop",
                notes: "Pinned vertices are immune to Relax, Move and Auto "
                    + "Relax — pin the silhouette you have already placed "
                    + "and smooth everything around it. Tap flips one "
                    + "vertex, a sweep flips every vertex you cross, and "
                    + "HOLDING on an interior edge flips its whole edge "
                    + "loop. Flipping again unpins.",
                demoFrames: ["pin", "pin.fill", "pin.circle.fill", "pin.slash"]
            )
        case .clearPins:
            GalleryEntry(
                title: "Clear pins",
                symbol: "pin.slash",
                gesture: "Command — tap to run",
                notes: "Removes every pin on the EditMesh in one step, so "
                    + "the next Relax is free to move the whole cage. One "
                    + "undo brings the pins back.",
                demoFrames: ["pin.fill", "pin.slash", "pin.slash.fill"]
            )
        case .clearLoopTags:
            GalleryEntry(
                title: "Clear loop tags",
                symbol: "tag.slash",
                gesture: "Command — tap to run",
                notes: "Removes every loop tag on the EditMesh in one "
                    + "step. To clear a single loop instead, draw along it "
                    + "again in the same colour. One undo restores them "
                    + "all.",
                demoFrames: ["tag.fill", "tag.slash", "tag.slash.fill"]
            )
        case .toggleSymmetry:
            GalleryEntry(
                title: "Symmetry",
                symbol: "square.righthalf.filled",
                gesture: "Command — tap to turn mirroring on or off",
                notes: "With symmetry on, every quad and grid you draw is "
                    + "authored on all enabled sides at once, and vertices "
                    + "on a symmetry plane weld onto it. Because the "
                    + "mirroring happens inside the SAME journal entry as "
                    + "the stroke, one undo removes every side together. "
                    + "Choose the axes, the plane position and the radial "
                    + "sector count in Viewport Settings.",
                demoFrames: [
                    "square.righthalf.filled", "square.lefthalf.filled",
                    "square.split.2x1", "square.split.2x1.fill",
                ]
            )
        case .applySymmetry:
            GalleryEntry(
                title: "Apply symmetry",
                symbol: "square.on.square.dashed",
                gesture: "Command — tap to run",
                notes: "Bakes the mirror into real geometry: every face on "
                    + "the authored half gains a real mirrored twin, welded "
                    + "along the symmetry plane so the seam stays "
                    + "manifold. Runs once per enabled mirror axis. Radial "
                    + "symmetry is NOT baked — its sector seams need "
                    + "welding the engine does not do yet.",
                demoFrames: [
                    "square.righthalf.filled", "square.on.square.dashed",
                    "square.split.2x1.fill", "square.fill",
                ]
            )
        case .resymmetrize:
            GalleryEntry(
                title: "Re-symmetrize",
                symbol: "arrow.trianglehead.2.clockwise.rotate.90",
                gesture: "Command — tap to run",
                notes: "Mirrors the authored half onto the other half of a "
                    + "mesh that has drifted asymmetric, moving vertices "
                    + "only — no faces are added or removed, so pins, tags "
                    + "and topology survive. Vertices with no counterpart "
                    + "on the authored half are left exactly where they "
                    + "are, and the status line reports how many.",
                demoFrames: [
                    "square.lefthalf.filled", "arrow.left.and.right",
                    "square.righthalf.filled", "square.split.2x1.fill",
                ]
            )
        case .toggleAutoRelax:
            GalleryEntry(
                title: "Auto Relax",
                symbol: "wand.and.sparkles",
                gesture: "Command — tap to turn the mode on or off",
                notes: "With Auto Relax on, every edit also redistributes "
                    + "the topology around what you just touched, so quads "
                    + "stay evenly spaced as you append along a strip. "
                    + "Pinned vertices never move. The relax happens INSIDE "
                    + "the edit's own journal entry, so one undo takes back "
                    + "the edit and its redistribution together. The mode "
                    + "is remembered between sessions.",
                demoFrames: [
                    "square.grid.3x3", "wand.and.sparkles",
                    "square.grid.3x3.fill", "wind",
                ]
            )
        case .batchCommands:
            GalleryEntry(
                title: "Batch commands",
                symbol: "list.bullet.rectangle",
                gesture: "Command — tap to open the panel",
                notes: "Whole-mesh operations: snap all to Target, relax "
                    + "all, subdivide, subdivide + reproject, triangulate, "
                    + "clear loop tags and clear pins. Each runs as one "
                    + "undoable step. Subdividing rebuilds every element "
                    + "id, so it clears pins and tags in the SAME step — "
                    + "one undo brings the cage and its annotations back "
                    + "together.",
                demoFrames: [
                    "list.bullet.rectangle", "square.grid.2x2",
                    "square.grid.3x3", "list.bullet.rectangle.fill",
                ]
            )
        }
    }
}

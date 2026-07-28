# Interactive UV packing and manual packing aids (6.6)

## Why

The layout an atlas produces is a starting point. An artist repacks after re-unwrapping an
island, after changing a seam, after deciding two shells should share space. So packing has to
be fast enough to sit inside an edit loop, and it has to be steerable by hand.

## The Metal-compute requirement does not survive measurement

The requirement says the system "SHALL pack UV islands via Metal-compute accelerated
packing", with the exit criterion "all islands SHALL be packed without overlaps within the
target region at interactive speed" for 200 islands.

The mechanism was presumed, not measured. So I measured the existing CPU packer first, and the
finding is that the bottleneck was never throughput — it was one inner loop:

```
for (col = 0; col + span <= kCols; ++col)     // 512 columns
    for (k = 0; k < span; ++k)                //  ~50 columns per island
        y = max(y, heights[col + k]);
```

That per-column maximum over a sliding window is O(kCols × span) per island, and the skyline
packer runs it for eight candidate strip widths. Measured cost: **9.64 ms to pack 200 islands,
and 4.64 ms for only 50** — a cost almost independent of island count, which is the signature
of per-box work rather than a scaling problem.

Replacing that scan with a sliding-window maximum brings 200 islands to **1.45 ms**, a 6.7x
improvement, with **byte-identical packed output** (the whole engine suite passes unchanged,
and the tie-break is deliberately preserved). Shelf packing was never the problem: 200 islands
in 0.014 ms.

| islands | before | after | speedup |
|---|---|---|---|
| 50 | 4.637 ms | 0.703 ms | 6.6x |
| 200 | 9.643 ms | 1.450 ms | 6.7x |
| 500 | 15.179 ms | 3.824 ms | 4.0x |
| 2000 | 33.655 ms | 15.601 ms | 2.2x |
| 10000 | 95.234 ms | 64.925 ms | 1.5x |

**So no Metal packer is being written, and the requirement is rewritten to say what it
actually wants.** A GPU packer would add a compute pipeline, a buffer round trip and a
device-only test path to beat 1.45 ms on a workload of 200 boxes — and shelf packing, which is
what an interactive repack should use anyway, is already three orders of magnitude inside
budget. Rewriting the requirement is the honest move: silently skipping it would leave a spec
the implementation contradicts, and building it would be work justified by nothing measured.

### The asymptotically better algorithm was not automatically the faster one

Worth recording because it cost two iterations. The first sliding-window version used
`std::deque` and made the **large** case 2x WORSE — 10,000 islands went 95 ms to 196 ms — even
though it removed a factor of `span`. At high island counts the strip is wide, so `span` falls
to one or two columns and the naive re-scan is already cheap, while deque's chunked allocation
and pointer indirection are not. A contiguous vector-backed queue was still 1.1x worse there.

The shipped version picks between the two by `span`, with a **measured** threshold. That is
why the table above improves at every size instead of trading the small case for the large one.

## Manual aids

- **Pack to a region.** Packing into a sub-rectangle rather than the whole unit square, which
  is what "within the target region" in the exit criterion actually asks for.
- **Overlap distribution.** `distributeIslandsUv` already exists; it needs exposing and a
  gesture.
- **Flip arrows and a one-gesture flip.** A mirrored shell bakes inverted detail. 6.4 already
  detects flipped faces per island and NAMES them; this adds the fix — `mirrorIslandUv` exists.

## Out of scope

- **Island grouping** as persisted document state. It needs a group model on the manifest with
  its own persistence and undo, which is a document-model change of the same shape as 6.7's UV
  sets. Deferred to 6.7 so both land against one manifest revision rather than two.

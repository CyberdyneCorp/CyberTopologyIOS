# Tasks: add-island-scoped-halve

- [x] 1.1 `Mesh.isSelfContainedIsland(_:)` — judged by VERTICES, so a corner touch does not
      pass as an island and get torn apart by the splice.
- [x] 1.2 `Mesh.halveDensity(limitedTo:)` — carve the island onto a COPY, halve it there as
      an ordinary cage, splice it back. Everything that can throw happens before the real
      cage is touched.
- [x] 1.3 The command scopes when the selection is an island and falls back otherwise, with
      wording that says which happened.
- [x] 1.4 The panel badge follows the SELECTION, not just the command.
- [x] 2.1 One island of a two-patch cage halves; the other does not move; still quad-only.
- [x] 2.2 An attached selection is refused by the primitive and falls back in the command.
- [x] 2.3 A corner touch is not an island.
- [x] 2.4 An island keeps the ordinary rules (odd spans still refuse, cage untouched).
- [x] 2.5 Selecting the whole cage matches the unscoped halve exactly.
- [x] 2.6 END TO END: the reported case through `runBatchCommand`, one journal entry.
- [x] 3.1 Run the mirrored suites on the iPad.
- [ ] 3.2 On device: select one patch of a two-patch cage and halve it.

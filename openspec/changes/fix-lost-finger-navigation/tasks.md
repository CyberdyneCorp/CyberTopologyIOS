# Tasks: fix-lost-finger-navigation

## 1. Recovery

- [x] 1.1 `InputArbiter.forget(_:)` — drops named touches, cancelling any authoring stroke and
      clearing the pen pointer.
- [x] 1.2 `InputArbiter.allTouchesFinished()` — the sequence-end backstop.
- [x] 1.3 Weak `UITouch` handles in the controller, swept by `phase` on every touch event and in
      `shouldReceive`.
- [x] 1.4 A BEGINNING touch retires any stale mapping for the same recycled object.
- [x] 1.5 `TouchObserverRecognizer.reset()` forwards the sequence-end reconciliation.

## 2. Observability

- [x] 2.1 `recoveredLeakedTouches` counter + an os_log notice, since the trigger is unreproduced.

## 3. Adjacent gap

- [x] 3.1 The twist recognizer joins the set reset when the pen takes priority — it was missed
      when two-finger roll was added.

## 4. Tests

- [x] 4.1 Two unreleased fingers refuse every further camera touch (the stuck state).
- [x] 4.2 `forget` on one of them restores admission.
- [x] 4.3 A leaked pen touch stops refusing fingers once forgotten.
- [x] 4.4 Reconciliation cancels an authoring stroke.
- [x] 4.5 Reconciling a clean arbiter is a no-op, and forgetting an unknown id is harmless.

## 5. Device verification

- [x] 5.1 Run the mirrored suites on the iPad (Auto-Lock off).
- [ ] 5.2 Use the app until navigation is lost again (if it recurs): confirm it now recovers on
      the next touch, and check the log for the release notice to confirm this was the cause.

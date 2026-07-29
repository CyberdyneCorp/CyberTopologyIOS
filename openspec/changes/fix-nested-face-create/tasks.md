# Tasks: fix-nested-face-create

## 1. Recognizer
- [x] 1.1 Detect a closed stroke contained in ONE face, touching no edge or vertex.
- [x] 1.2 Withhold `CreateQuad`/`CreateTriangle` on the ClosedLoop path.
- [x] 1.3 Withhold `CreateQuad` on the Circle path.
- [x] 1.4 Do NOT gate on `facesEnclosed` — a small interior loop contains the enclosing face's
      centroid, which made the first version reject the case it exists to catch.
- [x] 1.5 Patch-stack entry (0022).

## 2. Tests
- [x] 2.1 A nested closed loop creates nothing.
- [x] 2.2 A nested triangle creates nothing.
- [x] 2.3 A nested circle creates nothing (the path from the report).
- [x] 2.4 REGRESSION GUARD: a loop over empty surface still creates.
- [x] 2.5 REGRESSION GUARD: a loop reaching an existing edge still creates.

## 3. On-device coverage — a gap found while trying to verify this
- [x] 3.1 The first device attempt failed to BUILD, not to run: `CyberKitTests` is tool-hosted and
      cannot be tested on a device destination at all.
- [x] 3.2 `ContextAwareCreateFaceTests` was not in the mirrored set, so the stroke interpreter's
      stage 2 — which runs in C++ ON DEVICE — had never been exercised there. Mirrored into the
      app-hosted target: it qualifies exactly as the existing 15 do (public API, inline OBJ
      fixtures, no `#filePath` goldens, no `Bundle.module`), which its own doc comment already
      claimed.
- [x] 3.3 Its siblings CANNOT be shared and are recorded as such: `StrokeInterpreterTests` and
      `DeviceStrokeCorpusTests` both load `Bundle.module` corpora, which exist only for the SwiftPM
      target.

## 4. Close out
- [x] 4.1 validate; engine, simulator, device.
- [x] 4.2 Engine 358/358, simulator 1536/0, device 1073/0 (13/13 for this suite, on device for the
      first time).

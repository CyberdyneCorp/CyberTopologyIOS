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

## 3. Close out
- [ ] 3.1 validate; engine, simulator, device. Device run BLOCKED: the iPad is locked
      (`passcodeRequired: true`), which fakes bootstrap failures — needs unlocking with Auto-Lock off.
- [x] 3.2 Engine 358/358, simulator 1536/0.

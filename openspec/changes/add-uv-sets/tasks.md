# Tasks: add-uv-sets (6.7a)

## 1. Engine
- [x] 1.1 Active set under `uv`, inactive sets as `uv:<name>`, so the UV module is untouched.
- [x] 1.2 Create (as a copy), activate (swap), delete, rename.
- [x] 1.3 `AttributeSet.names()`, sorted, so set enumeration is deterministic.
- [x] 1.4 Sidecar serialization: active NAME plus the INACTIVE sets' data only.
- [x] 1.5 Reject a sidecar written for a different corner count, or truncated/corrupt, parsing
      whole before writing anything.
- [x] 1.6 Patch-stack entry (0020).
- [x] 1.7 Tests, including a stale sidecar not overwriting a newer edit.

## 2. C API
- [x] 2.1 Set list/active/create/activate/delete/rename, sidecar serialize/deserialize.
- [x] 2.2 The active name on the handle, with a static_assert pinning its default to the engine's.
- [x] 2.3 Tests.

## 3. CyberKit + document
- [x] 3.1 `Mesh` set operations and sidecar accessors.
- [x] 3.2 `Mesh.fromPayload(_:uvSets:)` as the SINGLE place payload and sidecar are paired.
- [x] 3.3 `Object.uvSetsFile` derived from the id; no manifest field, no schema bump.
- [x] 3.4 `DocumentCommand.uvSetEdit`, with lock enforcement including it and payload-identity
      excluding it.
- [x] 3.5 Tests: a full FileWrapper save/load round trip; a wrong-topology sidecar ignored.

## 4. App
- [x] 4.1 Create/activate/delete/rename commands, each ONE journaled step.
- [x] 4.2 Activation journals a COMPOUND so one undo restores layout and set list together.
- [x] 4.3 Every live-mesh rebuild restores the sidecar.
- [x] 4.4 Tests, including that undo removes the sidecar entirely.

## 5. Close out
- [x] 5.1 validate; engine, simulator, device.
- [x] 5.2 Master 6.7a entry recording both defects.

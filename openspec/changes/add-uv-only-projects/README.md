# add-uv-only-projects

Phase 6's 6.1a: UV-only projects and the split-view layout gestures. Corrects a scoping claim of mine — the spec asks for a DERIVED behaviour ("an EditMesh with no Target opens in UV with snapping disabled"), not a second document type, UTI or browser entry, and two of its three parts already held. The layout gesture lives on the 2D panel rather than a container above the viewport, because attaching it above broke a camera-gesture UI test.

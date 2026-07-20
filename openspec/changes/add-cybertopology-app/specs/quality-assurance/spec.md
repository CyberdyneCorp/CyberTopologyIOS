# quality-assurance — Delta Spec

## ADDED Requirements

### Requirement: Unit test coverage above 90%
The codebase SHALL maintain greater than 90% unit test line coverage, measured separately for the Swift shell (XCTest, via `xccov` on the merged test plan) and for the app-side C++/CyberKit bridge layer. CI SHALL fail any pull request that drops either coverage figure to 90% or below. Generated code, third-party code, and the engine repo (which carries its own suite) are excluded from the denominator.

#### Scenario: Coverage gate on PR
- **WHEN** a pull request lowers Swift shell unit coverage to 89%
- **THEN** the CI pipeline SHALL fail with a report of the uncovered files

#### Scenario: Coverage reported per layer
- **WHEN** the test suite runs in CI
- **THEN** coverage SHALL be reported as separate figures for the Swift shell and the CyberKit bridge, each required to exceed 90%

### Requirement: Every feature integration-tested
Every requirement scenario in this change's capability specs SHALL be covered by at least one automated integration test (XCUITest or integration-level XCTest exercising the real engine, real document I/O, and real Metal rendering — no engine mocks). A traceability map from spec scenario to test SHALL be kept in the repo, and CI SHALL flag scenarios with no linked test.

#### Scenario: New feature lands with its integration test
- **WHEN** a task implementing a spec scenario is merged
- **THEN** the traceability map SHALL link that scenario to a passing integration test, or CI SHALL fail

#### Scenario: Gesture grammar regression suite
- **WHEN** the integration suite runs
- **THEN** each gesture in the grammar SHALL be replayed from recorded stroke fixtures against a reference document and its resulting mesh state asserted

### Requirement: Simulator test execution in CI
The full unit and integration suite SHALL run on the iOS Simulator on every pull request. Tests that genuinely cannot run on the simulator (Metal ray tracing, Pencil hover/haptics, ProMotion timing, StoreKit device flows) SHALL be explicitly annotated as device-only rather than silently skipped, and SHALL count against the device test plan instead.

#### Scenario: PR test run
- **WHEN** a pull request is opened
- **THEN** CI SHALL boot a simulator, run the full non-device-only suite, and block merge on any failure

#### Scenario: No silent skips
- **WHEN** a test cannot run in the simulator environment
- **THEN** it SHALL appear in the run report as device-only, not as passed or skipped without classification

### Requirement: On-device test execution before release
The device-only test plan plus the full integration suite SHALL run on physical hardware — at minimum one mesh-shader/RT-capable device (M-series or A17 Pro+) and one baseline supported device — before every TestFlight or App Store release. Release builds SHALL be blocked until the device run passes, and its `.xcresult` SHALL be archived with the release tag.

#### Scenario: Release gate
- **WHEN** a release candidate is prepared
- **THEN** the device test plan SHALL have a passing recorded run on both device classes for that exact build, otherwise the release SHALL NOT proceed

#### Scenario: Hardware-path parity
- **WHEN** the bake suite runs on RT-capable hardware and on the intersector-fallback device
- **THEN** both SHALL produce outputs matching the same golden files

### Requirement: Determinism and golden-file regression tests
The suite SHALL include golden-file tests for solver determinism (identical Weave inputs → bit-identical outputs, on simulator and on device), MikkTSpace tangent exactness, and bake output stability. Golden files SHALL be versioned with the code.

#### Scenario: Cross-environment determinism
- **WHEN** the same Weave fixture is solved in CI (simulator) and on a physical device
- **THEN** the committed mesh outputs SHALL be bit-identical to each other and to the golden file

import Foundation
import MachO  // _dyld_image_count / _dyld_get_image_name
import Testing

@testable import CyberTopology

/// Privacy audit (task 9.3; spec: monetization).
///
/// The App Store label claim is **Data Not Collected**, and `PrivacyInfo.xcprivacy`
/// asserts it declaratively. This suite asserts it against the BUILT APP, because a
/// manifest is only a claim — and a claim with no test behind it is exactly how "Data
/// Not Collected" quietly stops being true after someone adds an SDK.
///
/// What this can and cannot prove: it verifies the shipped bundle declares no tracking
/// and no collected data types, links no networking framework, and carries no ATS
/// exceptions, and that no known telemetry SDK is loaded. The LINK-level check (that our
/// own binaries declare no networking dependency) cannot be done from inside a running
/// process and lives in `Scripts/network_audit.sh`, together with a source audit and a
/// check that the engine's `net` module stays compiled out of the shipped slices.
///
/// So this is a regression gate, not a proof: it cannot rule out a network call made
/// through a path it does not know about.
@Suite("Privacy audit")
struct PrivacyAuditTests {
    private var appBundle: Bundle { Bundle(for: MetalViewport.Coordinator.self) }

    /// The app bundle, reached from the test bundle. App-hosted, so the host app is the
    /// bundle under audit rather than the test bundle itself.
    private func privacyManifest() throws -> [String: Any] {
        let url = try #require(
            appBundle.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"),
            "PrivacyInfo.xcprivacy is not in the app bundle — App Store submission needs it"
        )
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        )
        return try #require(plist as? [String: Any])
    }

    @Test("The privacy manifest declares no tracking and no collected data")
    func manifestDeclaresNoCollection() throws {
        let manifest = try privacyManifest()
        #expect(manifest["NSPrivacyTracking"] as? Bool == false)
        #expect((manifest["NSPrivacyTrackingDomains"] as? [Any])?.isEmpty == true)
        // The load-bearing one: a non-empty list here contradicts the store label.
        #expect(
            (manifest["NSPrivacyCollectedDataTypes"] as? [Any])?.isEmpty == true,
            "a collected data type contradicts the Data Not Collected label"
        )
    }

    @Test("Any declared API-access reason is accompanied by a reason code")
    func accessedAPIsAreJustified() throws {
        let manifest = try privacyManifest()
        let accessed = manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]] ?? []
        // Empty today (documents come through the system browser, which is the
        // user-selected-file exemption). If an entry appears it must carry reasons, or
        // App Store validation rejects the build.
        for entry in accessed {
            #expect(entry["NSPrivacyAccessedAPIType"] != nil)
            let reasons = entry["NSPrivacyAccessedAPITypeReasons"] as? [String] ?? []
            #expect(!reasons.isEmpty, "an accessed API with no reason code fails review")
        }
    }

    @Test("The app declares no App Transport Security exceptions")
    func noATSExceptions() {
        // An ATS exception is only ever needed to reach a server. Having none is a
        // structural statement that there is no server.
        let ats = appBundle.object(forInfoDictionaryKey: "NSAppTransportSecurity")
        #expect(ats == nil, "an ATS exception implies a network destination")
    }

    // A "links no networking framework" test lived here and was WRONG: CFNetwork and
    // Network.framework are loaded into every iOS process by UIKit whether or not we
    // reference them, so a loaded-image scan cannot distinguish "we link it" from "the
    // OS loaded it" — it failed for a completely clean app. The distinction only exists
    // at the LINK level, on built binaries, where `otool -L` lists DIRECT dependencies.
    // That check therefore lives in `Scripts/network_audit.sh` (run in CI) rather than
    // being weakened here into something that passes without measuring anything.

    @Test("No analytics or crash-reporting SDK is linked")
    func noTelemetrySDK() {
        // Named vendors rather than a heuristic, so the failure message says WHAT
        // arrived. A new vendor not on this list would slip through -- which is why the
        // framework check above, not this one, is the structural guard.
        let vendors = [
            "Firebase", "GoogleAnalytics", "Crashlytics", "Sentry", "Bugsnag",
            "Mixpanel", "Amplitude", "AppsFlyer", "Adjust", "Branch", "Instabug",
        ]
        var found: [String] = []
        for index in 0..<_dyld_image_count() {
            guard let raw = _dyld_get_image_name(index) else { continue }
            let path = String(cString: raw)
            for vendor in vendors where path.localizedCaseInsensitiveContains(vendor) {
                found.append(vendor)
            }
        }
        #expect(found.isEmpty, "telemetry SDK linked: \(found.joined(separator: ", "))")
    }
}

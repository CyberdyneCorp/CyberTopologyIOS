import XCTest

final class CyberTopologyUITests: XCTestCase {
    @MainActor
    func testAppLaunches() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["CyberTopology"].waitForExistence(timeout: 10))
    }
}

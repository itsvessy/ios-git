import XCTest

final class GitPhoneUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testOpenAddRepositoryFlow() throws {
        let app = XCUIApplication()
        app.launchArguments.append("UITEST_BYPASS_LOCK")
        app.launch()

        let addButton = app.buttons["Add"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        addButton.tap()

        XCTAssertTrue(app.textFields["add-remote-url"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["clone-button"].exists)
    }

    @MainActor
    func testRepoHubPrimaryControlsExist() throws {
        let app = XCUIApplication()
        app.launchArguments.append("UITEST_BYPASS_LOCK")
        app.launch()

        XCTAssertTrue(app.buttons["Refresh"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Sort"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Add"].waitForExistence(timeout: 5))
    }
}

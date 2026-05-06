import XCTest

final class CommitSyncUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testOpenAddRepositoryFlow() throws {
        let app = makeApp(seedRepo: false)

        let addButton = app.buttons["Add"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        addButton.tap()

        XCTAssertTrue(app.textFields["add-remote-url"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["clone-button"].exists)
    }

    @MainActor
    func testRepoHubPrimaryControlsExist() throws {
        let app = makeApp(seedRepo: false)

        XCTAssertTrue(app.buttons["Refresh"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Sort"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Add"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testRepoCardShowsQuickSyncMoreControls() throws {
        let app = makeApp(seedRepo: true)

        XCTAssertTrue(app.staticTexts["ui-test"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Quick Commit and Push"].exists)
        XCTAssertTrue(app.buttons["Sync repository"].exists)
        XCTAssertTrue(app.buttons["More actions"].exists)
    }

    @MainActor
    func testQuickButtonOpensGitActionsComposer() throws {
        let app = makeApp(seedRepo: true)

        let quickButton = app.buttons["Quick Commit and Push"]
        XCTAssertTrue(quickButton.waitForExistence(timeout: 5))
        quickButton.tap()

        XCTAssertTrue(app.navigationBars["Git Actions"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Commit & Push"].exists)
    }

    @MainActor
    func testRepoFilesToolbarOpensGitActionsSheet() throws {
        let app = makeApp(seedRepo: true)

        let repoTitle = app.staticTexts["ui-test"]
        XCTAssertTrue(repoTitle.waitForExistence(timeout: 5))
        repoTitle.tap()

        XCTAssertTrue(app.navigationBars["ui-test"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Changed Files (0)"].exists)

        let actionsButton = app.buttons["Git Actions"]
        XCTAssertTrue(actionsButton.waitForExistence(timeout: 5))
        actionsButton.tap()

        XCTAssertTrue(app.navigationBars["Git Actions"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Commit & Push"].exists)
    }

    @MainActor
    private func makeApp(seedRepo: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments.append("UITEST_BYPASS_LOCK")
        if seedRepo {
            app.launchArguments.append("UITEST_SEED_REPO")
        }
        app.launch()
        return app
    }
}

import SecurityEngine
import XCTest

@MainActor
final class AppLockCoordinatorConfigTests: XCTestCase {
    func testRelockIntervalCanBeUpdated() {
        let coordinator = AppLockCoordinator(relockInterval: 300)

        XCTAssertEqual(coordinator.relockInterval(), 300)

        coordinator.setRelockInterval(5)
        XCTAssertEqual(coordinator.relockInterval(), 5)
    }

    func testHandleBecameActiveLocksAfterConfiguredInterval() async {
        let coordinator = AppLockCoordinator(relockInterval: 1)
        coordinator.markUnlocked()

        coordinator.handleDidEnterBackground()
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        coordinator.handleBecameActive()

        XCTAssertFalse(coordinator.isUnlocked)
    }

    func testHandleBecameActiveKeepsUnlockedBeforeInterval() async {
        let coordinator = AppLockCoordinator(relockInterval: 5)
        coordinator.markUnlocked()

        coordinator.handleDidEnterBackground()
        try? await Task.sleep(nanoseconds: 150_000_000)
        coordinator.handleBecameActive()

        XCTAssertTrue(coordinator.isUnlocked)
    }
}

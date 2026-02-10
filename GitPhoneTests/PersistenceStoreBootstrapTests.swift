import Foundation
import XCTest
@testable import GitPhone

final class PersistenceStoreBootstrapTests: XCTestCase {
    private var tempRoot: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("PersistenceStoreBootstrapTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? fileManager.removeItem(at: tempRoot)
        }
        tempRoot = nil
    }

    func testPrepareStoreURLCreatesMissingParentDirectoryChain() throws {
        let appSupport = tempRoot.appendingPathComponent("Sandbox/Library/Application Support", isDirectory: true)
        let bootstrap = PersistenceStoreBootstrap(
            fileManager: fileManager,
            applicationSupportDirectory: { appSupport },
            fallbackDirectory: tempRoot
        )

        let storeDirectory = appSupport.appendingPathComponent("GitPhone", isDirectory: true)
        XCTAssertFalse(fileManager.fileExists(atPath: storeDirectory.path))

        _ = try bootstrap.prepareStoreURL()

        var isDirectory: ObjCBool = false
        XCTAssertTrue(fileManager.fileExists(atPath: storeDirectory.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testPrepareStoreURLReturnsDeterministicStorePath() throws {
        let appSupport = tempRoot.appendingPathComponent("Library/Application Support", isDirectory: true)
        let bootstrap = PersistenceStoreBootstrap(
            fileManager: fileManager,
            applicationSupportDirectory: { appSupport },
            fallbackDirectory: tempRoot
        )

        let storeURL = try bootstrap.prepareStoreURL()

        XCTAssertEqual(storeURL.path, appSupport.appendingPathComponent("GitPhone/default.store").path)
    }

    func testPrepareStoreURLIsIdempotent() throws {
        let appSupport = tempRoot.appendingPathComponent("Library/Application Support", isDirectory: true)
        let bootstrap = PersistenceStoreBootstrap(
            fileManager: fileManager,
            applicationSupportDirectory: { appSupport },
            fallbackDirectory: tempRoot
        )

        let first = try bootstrap.prepareStoreURL()
        let second = try bootstrap.prepareStoreURL()

        XCTAssertEqual(first.path, second.path)
    }

    func testPrepareStoreURLThrowsWhenBasePathIsAFile() throws {
        let fileBase = tempRoot.appendingPathComponent("not-a-directory")
        try Data("blocked".utf8).write(to: fileBase, options: .atomic)

        let bootstrap = PersistenceStoreBootstrap(
            fileManager: fileManager,
            applicationSupportDirectory: { fileBase },
            fallbackDirectory: tempRoot
        )

        XCTAssertThrowsError(try bootstrap.prepareStoreURL()) { error in
            guard case let PersistenceStoreBootstrap.Error.cannotCreateStoreDirectory(path, _) = error else {
                return XCTFail("Unexpected error: \(error)")
            }

            XCTAssertTrue(path.hasSuffix("not-a-directory/GitPhone"))
            XCTAssertTrue(error.localizedDescription.contains("Unable to create persistence directory"))
        }
    }
}

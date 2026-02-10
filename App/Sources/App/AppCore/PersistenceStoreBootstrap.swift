import Foundation

struct PersistenceStoreBootstrap {
    enum Error: Swift.Error, LocalizedError {
        case cannotCreateStoreDirectory(path: String, underlying: Swift.Error)

        var errorDescription: String? {
            switch self {
            case let .cannotCreateStoreDirectory(path, underlying):
                return "Unable to create persistence directory at \(path): \(underlying.localizedDescription)"
            }
        }
    }

    private let fileManager: FileManager
    private let applicationSupportDirectory: () -> URL?
    private let fallbackDirectory: URL

    init(
        fileManager: FileManager = .default,
        applicationSupportDirectory: (() -> URL?)? = nil,
        fallbackDirectory: URL? = nil
    ) {
        self.fileManager = fileManager
        self.applicationSupportDirectory = applicationSupportDirectory
            ?? { fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first }
        self.fallbackDirectory = fallbackDirectory ?? fileManager.temporaryDirectory
    }

    func prepareStoreURL() throws -> URL {
        let base = applicationSupportDirectory() ?? fallbackDirectory
        let storeDirectory = base.appendingPathComponent("GitPhone", isDirectory: true)

        do {
            try fileManager.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        } catch {
            throw Error.cannotCreateStoreDirectory(path: storeDirectory.path, underlying: error)
        }

        return storeDirectory.appendingPathComponent("default.store")
    }
}

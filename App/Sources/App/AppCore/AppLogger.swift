import Foundation

actor AppLogger {
    enum Level: String {
        case info
        case warning
        case error
    }

    private let logURL: URL
    private let formatter: ISO8601DateFormatter

    init(fileManager: FileManager = .default) {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let dir = base.appendingPathComponent("Logs", isDirectory: true)

        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        self.logURL = dir.appendingPathComponent("gitphone.log")
        self.formatter = ISO8601DateFormatter()
    }

    func log(_ message: String, level: Level = .info) {
        let line = "[\(formatter.string(from: Date()))] [\(level.rawValue.uppercased())] \(message)\n"
        guard let data = line.data(using: .utf8) else {
            return
        }

        if FileManager.default.fileExists(atPath: logURL.path) {
            if let handle = try? FileHandle(forWritingTo: logURL) {
                do {
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                    try handle.close()
                } catch {
                    try? handle.close()
                }
            }
        } else {
            try? data.write(to: logURL, options: .atomic)
        }
    }

    func logFilePath() -> String {
        logURL.path
    }
}

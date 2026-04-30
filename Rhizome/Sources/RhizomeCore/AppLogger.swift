import Foundation

public final class AppLogger: @unchecked Sendable {
    public let logDirectory: URL
    public let logFileURL: URL

    private let fileManager: FileManager
    private let maxBytes: Int
    private let keepFiles: Int
    private let queue = DispatchQueue(label: "com.walkerhyman.rhizome.logger")

    public init(
        logDirectory: URL? = nil,
        fileManager: FileManager = .default,
        maxBytes: Int = 5 * 1024 * 1024,
        keepFiles: Int = 3
    ) {
        self.fileManager = fileManager
        self.maxBytes = maxBytes
        self.keepFiles = keepFiles
        let baseDirectory = logDirectory
            ?? fileManager.homeDirectoryForCurrentUser
                .appending(path: "Library/Logs/Rhizome", directoryHint: .isDirectory)
        self.logDirectory = baseDirectory
        self.logFileURL = baseDirectory.appending(path: "rhizome.log", directoryHint: .notDirectory)
    }

    public func log(_ message: String) {
        queue.sync {
            do {
                try fileManager.createDirectory(at: logDirectory, withIntermediateDirectories: true)
                try rotateIfNeeded()
                let line = "[\(Self.timestamp())] \(message)\n"
                let data = Data(line.utf8)
                if !fileManager.fileExists(atPath: logFileURL.path) {
                    fileManager.createFile(atPath: logFileURL.path, contents: data)
                    return
                }
                let handle = try FileHandle(forWritingTo: logFileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                fputs("Rhizome logger failure: \(error)\n", stderr)
            }
        }
    }

    private func rotateIfNeeded() throws {
        guard fileManager.fileExists(atPath: logFileURL.path) else {
            return
        }
        let attributes = try fileManager.attributesOfItem(atPath: logFileURL.path)
        let currentSize = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard currentSize >= maxBytes else {
            return
        }

        let oldestURL = rotatedLogURL(index: keepFiles)
        if fileManager.fileExists(atPath: oldestURL.path) {
            try fileManager.removeItem(at: oldestURL)
        }

        if keepFiles > 1 {
            for index in stride(from: keepFiles - 1, through: 1, by: -1) {
                let sourceURL = rotatedLogURL(index: index)
                let destinationURL = rotatedLogURL(index: index + 1)
                if fileManager.fileExists(atPath: sourceURL.path) {
                    if fileManager.fileExists(atPath: destinationURL.path) {
                        try fileManager.removeItem(at: destinationURL)
                    }
                    try fileManager.moveItem(at: sourceURL, to: destinationURL)
                }
            }
        }

        let firstRotatedURL = rotatedLogURL(index: 1)
        if fileManager.fileExists(atPath: firstRotatedURL.path) {
            try fileManager.removeItem(at: firstRotatedURL)
        }
        try fileManager.moveItem(at: logFileURL, to: firstRotatedURL)
    }

    private func rotatedLogURL(index: Int) -> URL {
        logDirectory.appending(path: "rhizome.log.\(index)", directoryHint: .notDirectory)
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}

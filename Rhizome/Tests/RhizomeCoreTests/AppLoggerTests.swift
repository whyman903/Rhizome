import Foundation
import XCTest
@testable import RhizomeCore

final class AppLoggerTests: XCTestCase {
    func testRotatesLogs() throws {
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let logger = AppLogger(logDirectory: tempDirectory, maxBytes: 64, keepFiles: 3)

        logger.log(String(repeating: "a", count: 80))
        logger.log(String(repeating: "b", count: 80))

        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDirectory.appending(path: "rhizome.log").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDirectory.appending(path: "rhizome.log.1").path))
    }
}

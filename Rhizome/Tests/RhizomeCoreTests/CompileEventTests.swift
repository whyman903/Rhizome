import XCTest
@testable import RhizomeCore

final class CompileEventTests: XCTestCase {
    func testSourceNoteWrittenDecoding() throws {
        let json = """
        {"event":"source_note_written","id":"job-1","source":"paper.pdf","raw_path":"raw/paper.pdf","note_path":"wiki/sources/Paper.md","status":"created"}
        """

        let event = try JSONDecoder().decode(CompileEvent.self, from: Data(json.utf8))

        XCTAssertEqual(
            event,
            .sourceNoteWritten(
                id: "job-1",
                source: "paper.pdf",
                rawPath: "raw/paper.pdf",
                notePath: "wiki/sources/Paper.md",
                status: "created"
            )
        )
    }
}

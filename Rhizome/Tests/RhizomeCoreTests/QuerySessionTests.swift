import Foundation
import XCTest
@testable import RhizomeCore

@MainActor
final class QuerySessionTests: XCTestCase {
    func testStartClearsPreviousState() {
        let session = QuerySession()
        session.start(question: "first")
        session.handle(.assistantText("partial"))
        session.handle(.toolCall(name: "Read"))
        session.start(question: "second")

        XCTAssertEqual(session.question, "second")
        XCTAssertEqual(session.status, .running)
        XCTAssertEqual(session.assistantText, "")
        XCTAssertTrue(session.toolCalls.isEmpty)
    }

    func testHandleFinishedEventTransitionsToCompleted() {
        let session = QuerySession()
        session.start(question: "q")
        session.handle(.finished(
            text: "answer",
            costUSD: 0.05,
            durationMs: 1234,
            permissionDenials: [],
            sessionID: "claude-session-1"
        ))

        XCTAssertEqual(session.status, .completed)
        XCTAssertEqual(session.assistantText, "answer")
        XCTAssertEqual(session.costUSD, 0.05)
        XCTAssertEqual(session.durationMs, 1234)
        XCTAssertEqual(session.claudeSessionID, "claude-session-1")
    }

    func testHandleFailedEventTransitionsToFailed() {
        let session = QuerySession()
        session.start(question: "q")
        session.handle(.failed(message: "boom"))

        XCTAssertEqual(session.status, .failed)
        XCTAssertEqual(session.errorMessage, "boom")
    }

    func testAssistantTextReplacesRatherThanAppends() {
        let session = QuerySession()
        session.start(question: "q")
        session.handle(.assistantText("first draft"))
        session.handle(.assistantText("final answer"))
        XCTAssertEqual(session.assistantText, "final answer")
    }

    func testClearResetsSessionToIdle() {
        let session = QuerySession()
        session.start(question: "q")
        session.handle(.finished(
            text: "done",
            costUSD: nil,
            durationMs: nil,
            permissionDenials: [],
            sessionID: nil
        ))
        session.clear()
        XCTAssertEqual(session.status, .idle)
        XCTAssertEqual(session.assistantText, "")
        XCTAssertEqual(session.question, "")
    }

    func testCancelTransitionsWithoutClearing() {
        let session = QuerySession()
        session.start(question: "q")
        session.handle(.assistantText("partial"))
        session.cancel()
        XCTAssertEqual(session.status, .cancelled)
        XCTAssertEqual(session.assistantText, "partial")
    }
}

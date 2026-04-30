import Foundation
import Observation

public struct QueryTurn: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let question: String
    public let answer: String
    public let askedAt: Date

    public init(question: String, answer: String, askedAt: Date = Date()) {
        self.id = UUID()
        self.question = question
        self.answer = answer
        self.askedAt = askedAt
    }
}

/// Lightweight serializable record of a completed query conversation.
public struct QueryHistoryRecord: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let turns: [QueryTurn]
    public let claudeSessionID: String?
    public let archivedAt: Date

    public var firstQuestion: String {
        turns.first?.question ?? ""
    }

    public init(
        id: UUID = UUID(),
        turns: [QueryTurn],
        claudeSessionID: String? = nil,
        archivedAt: Date = Date()
    ) {
        self.id = id
        self.turns = turns
        self.claudeSessionID = claudeSessionID
        self.archivedAt = archivedAt
    }
}

@MainActor
@Observable
public final class QuerySession: Identifiable {
    public enum Status: Equatable, Sendable {
        case idle
        case running
        case completed
        case failed
        case cancelled
    }

    public let id: UUID
    public private(set) var status: Status = .idle
    public private(set) var question: String = ""
    public private(set) var assistantText: String = ""
    public private(set) var toolCalls: [String] = []
    public private(set) var errorMessage: String?
    public private(set) var costUSD: Double?
    public private(set) var durationMs: Int?
    public private(set) var permissionDenials: [String] = []
    public private(set) var startedAt: Date?
    public private(set) var statusDetail: String = ""
    public private(set) var turns: [QueryTurn] = []
    public private(set) var claudeSessionID: String?

    public var firstQuestion: String {
        turns.first?.question ?? question
    }

    public init(id: UUID = UUID()) {
        self.id = id
    }

    public func start(question: String) {
        self.question = question
        self.status = .running
        self.assistantText = ""
        self.toolCalls = []
        self.errorMessage = nil
        self.costUSD = nil
        self.durationMs = nil
        self.permissionDenials = []
        self.startedAt = Date()
        self.statusDetail = ""
        self.turns = []
        self.claudeSessionID = nil
    }

    public func startFollowUp(question: String) {
        self.question = question
        self.status = .running
        self.assistantText = ""
        self.toolCalls = []
        self.errorMessage = nil
        self.costUSD = nil
        self.durationMs = nil
        self.permissionDenials = []
        self.startedAt = Date()
        self.statusDetail = ""
    }

    public func updateStatusDetail(_ detail: String) {
        self.statusDetail = detail
    }

    public func handle(_ event: ClaudeQueryEvent) {
        switch event {
        case .assistantText(let text):
            self.assistantText = text
        case .toolCall(let name):
            self.toolCalls.append(name)
            switch name {
            case "Grep": self.statusDetail = "Searching the wiki…"
            case "Read": self.statusDetail = "Reading a page…"
            case "Glob": self.statusDetail = "Listing pages…"
            case "LS": self.statusDetail = "Walking directories…"
            case "Bash": self.statusDetail = "Searching with Bash…"
            case "Task": self.statusDetail = "Running a research subtask…"
            case "WebSearch", "WebFetch": self.statusDetail = "Checking the web…"
            default: self.statusDetail = "Using \(name)…"
            }
        case .toolResult:
            break
        case .finished(let text, let cost, let duration, let denials, let sessionID):
            if !text.isEmpty {
                self.assistantText = text
            }
            self.costUSD = cost
            self.durationMs = duration
            self.permissionDenials = denials
            if let sessionID, !sessionID.isEmpty {
                self.claudeSessionID = sessionID
            }
            self.turns.append(QueryTurn(
                question: self.question,
                answer: self.assistantText,
                askedAt: self.startedAt ?? Date()
            ))
            self.status = .completed
        case .failed(let message):
            self.errorMessage = message
            self.status = .failed
        }
    }

    public func fail(_ message: String) {
        self.errorMessage = message
        self.status = .failed
    }

    public func cancel() {
        // A cancelled Claude process may not emit a result event, so there may be no session id to resume.
        self.status = .cancelled
    }

    /// Restore a session from saved history.
    public func restore(turns: [QueryTurn], claudeSessionID: String? = nil) {
        self.turns = turns
        self.toolCalls = []
        self.errorMessage = nil
        self.costUSD = nil
        self.durationMs = nil
        self.permissionDenials = []
        self.startedAt = nil
        self.statusDetail = ""
        self.claudeSessionID = claudeSessionID
        if let last = turns.last {
            self.question = last.question
            self.assistantText = last.answer
            self.status = .completed
        } else {
            self.question = ""
            self.assistantText = ""
            self.status = .idle
        }
    }

    public func clear() {
        self.status = .idle
        self.question = ""
        self.assistantText = ""
        self.toolCalls = []
        self.errorMessage = nil
        self.costUSD = nil
        self.durationMs = nil
        self.permissionDenials = []
        self.startedAt = nil
        self.statusDetail = ""
        self.turns = []
        self.claudeSessionID = nil
    }
}

import Foundation

public enum CompileEvent: Equatable, Sendable {
    case started(id: String, source: String, workspace: String?)
    case fetched(id: String, source: String?, rawPath: String, title: String?)
    case extracting(id: String, source: String?, rawPath: String?)
    case sourceNoteWritten(id: String, source: String?, rawPath: String?, notePath: String, status: String)
    case navigationRefreshed(id: String, source: String?, indexPath: String?, overviewPath: String?)
    case completed(id: String, source: String?, rawPath: String?, notePath: String, needsDocumentReview: Bool)
    case failed(id: String, source: String?, rawPath: String?, message: String)
    case preserved(id: String, source: String?, rawPath: String?, notePath: String)

    public var id: String {
        switch self {
        case .started(let id, _, _),
             .fetched(let id, _, _, _),
             .extracting(let id, _, _),
             .sourceNoteWritten(let id, _, _, _, _),
             .navigationRefreshed(let id, _, _, _),
             .completed(let id, _, _, _, _),
             .failed(let id, _, _, _),
             .preserved(let id, _, _, _):
            return id
        }
    }

    public var source: String? {
        switch self {
        case .started(_, let source, _):
            return source
        case .fetched(_, let source, _, _),
             .extracting(_, let source, _),
             .sourceNoteWritten(_, let source, _, _, _),
             .navigationRefreshed(_, let source, _, _),
             .completed(_, let source, _, _, _),
             .failed(_, let source, _, _),
             .preserved(_, let source, _, _):
            return source
        }
    }

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .preserved:
            return true
        default:
            return false
        }
    }
}

extension CompileEvent: Decodable {
    private enum CodingKeys: String, CodingKey {
        case event
        case id
        case source
        case workspace
        case rawPath = "raw_path"
        case notePath = "note_path"
        case status
        case title
        case message
        case indexPath = "index_path"
        case overviewPath = "overview_path"
        case needsDocumentReview = "needs_document_review"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let event = try container.decode(String.self, forKey: .event)
        let id = try container.decode(String.self, forKey: .id)
        let source = try container.decodeIfPresent(String.self, forKey: .source)
        let rawPath = try container.decodeIfPresent(String.self, forKey: .rawPath)

        switch event {
        case "started":
            self = .started(
                id: id,
                source: source ?? "",
                workspace: try container.decodeIfPresent(String.self, forKey: .workspace)
            )
        case "fetched":
            self = .fetched(
                id: id,
                source: source,
                rawPath: try container.decode(String.self, forKey: .rawPath),
                title: try container.decodeIfPresent(String.self, forKey: .title)
            )
        case "extracting":
            self = .extracting(id: id, source: source, rawPath: rawPath)
        case "source_note_written":
            self = .sourceNoteWritten(
                id: id,
                source: source,
                rawPath: rawPath,
                notePath: try container.decode(String.self, forKey: .notePath),
                status: try container.decode(String.self, forKey: .status)
            )
        case "navigation_refreshed":
            self = .navigationRefreshed(
                id: id,
                source: source,
                indexPath: try container.decodeIfPresent(String.self, forKey: .indexPath),
                overviewPath: try container.decodeIfPresent(String.self, forKey: .overviewPath)
            )
        case "completed":
            self = .completed(
                id: id,
                source: source,
                rawPath: rawPath,
                notePath: try container.decode(String.self, forKey: .notePath),
                needsDocumentReview: try container.decodeIfPresent(Bool.self, forKey: .needsDocumentReview) ?? false
            )
        case "failed":
            self = .failed(
                id: id,
                source: source,
                rawPath: rawPath,
                message: try container.decode(String.self, forKey: .message)
            )
        case "preserved":
            self = .preserved(
                id: id,
                source: source,
                rawPath: rawPath,
                notePath: try container.decode(String.self, forKey: .notePath)
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .event,
                in: container,
                debugDescription: "Unknown compile event: \(event)"
            )
        }
    }
}

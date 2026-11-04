import Foundation
import GRDB

/// Shared GRDB conventions: snake_case columns, Swift camelCase properties.
protocol DBRecord: Codable, FetchableRecord, PersistableRecord {}

extension DBRecord {
    static var databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy { .convertFromSnakeCase }
    static var databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy { .convertToSnakeCase }
}

protocol AutoRow: Codable, FetchableRecord, MutablePersistableRecord { var id: Int64? { get set } }

extension AutoRow {
    static var databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy { .convertFromSnakeCase }
    static var databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy { .convertToSnakeCase }
    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

struct Meeting: DBRecord, Identifiable, Hashable {
    static let databaseTableName = "meetings"
    var id: String
    var title: String
    var createdAt: Date
    var duration: Double
    var status: String  // recording | processing:<step> | done | error:<msg>
    var summary: String  // short overview paragraph
    var folderId: String?
    var templateId: String?
    var notes: String = ""
    var deletedAt: Date?
    var modifiedAt: Date?
    var eventId: String?
    var maxSpeakers: Int?  // upper bound for diarization, from the calendar event's attendees
    var expectedSpeakers: Int?  // exact number of voices, set by the user ("Re-identify Speakers…")

    var folder: URL { Store.dataDir.appending(path: "recordings/\(id)") }
    var isProcessing: Bool { status.hasPrefix("processing") }
    var statusLabel: String {
        switch status {
        case "recording": String(localized: "Recording…")
        case "processing:transcribing": String(localized: "Transcribing…")
        case "processing:transcribing-local": String(localized: "Cloud transcription failed — transcribing on this Mac…")
        case let s where s.hasPrefix("processing:transcribing "): String(localized: "Transcribing part \(s.dropFirst("processing:transcribing ".count))…")
        case "processing:diarizing": String(localized: "Identifying speakers…")
        case "processing:cleanup": String(localized: "Cleaning up transcription…")
        case "processing:summarizing": String(localized: "Generating summary…")
        case "processing:indexing": String(localized: "Indexing for search…")
        case "queued": String(localized: "Transcription queued")
        case "recovered": String(localized: "Recovered after the app quit unexpectedly — processing…")
        case let s where s.hasPrefix("processing:summarizing "): String(localized: "Summarizing part \(s.dropFirst("processing:summarizing ".count))…")
        case "awaiting:speakers": String(localized: "New speakers detected — identify them to generate the summary")
        default: status.hasPrefix("error:") ? String(localized: "Failed: ") + status.dropFirst(6) : status
        }
    }

    static func new(title: String) -> Meeting {
        Meeting(id: UUID().uuidString, title: title, createdAt: .now, duration: 0, status: "recording", summary: "")
    }
}

struct Speaker: DBRecord, Identifiable, Hashable {
    static let databaseTableName = "speakers"
    static let meID = "me"
    var id: String
    var name: String
    var embedding: [Float]  // ponytail: JSON text, 256 floats; switch to BLOB if the registry grows to thousands
    var embeddingModel: String
    var createdAt: Date
    var email: String?
    var company: String?
    var position: String?
    var notes: String?
    var parentId: String?  // set when merged into another person; the voice keeps matching, name comes from root
    /// Extra voice samples from confident matches in later meetings (at most 5). `embedding` stays the
    /// first sample, so one wrong match can't drag the voice toward someone else.
    var voiceSamples: [[Float]] = []
}

struct Segment: AutoRow, Identifiable, Hashable {
    static let databaseTableName = "segments"
    var id: Int64?
    var meetingId: String
    var speakerId: String?
    var source: String  // mic | system | file
    var start: Double
    var end: Double
    var text: String
    var originalText: String?
    var irrelevant: Bool = false
    var userEdited: Bool = false
    var overlap: Bool = false  // another speaker talks at the same time in this block
}

struct Folder: DBRecord, Identifiable, Hashable {
    static let databaseTableName = "folders"
    var id: String
    var name: String
    var icon: String  // SF Symbol name or a single emoji
    var color: String  // palette key, see Palette
    var parentId: String?
    var templateId: String?
    var context: String = ""
    var sortOrder: Int = 0
    var createdAt: Date = .now
}

struct Tag: DBRecord, Identifiable, Hashable {
    static let databaseTableName = "tags"
    var id: String
    var name: String
}

struct Insight: AutoRow, Identifiable, Hashable {
    static let databaseTableName = "insights"
    var id: Int64?
    var meetingId: String
    var text: String
    var time: Double?
    var sortOrder: Int
}

struct ActionItem: AutoRow, Identifiable, Hashable {
    static let databaseTableName = "action_items"
    var id: Int64?
    var meetingId: String
    var text: String
    var assignee: String?
    var dueDate: Date?
    var completed: Bool = false
    var createdAt: Date = .now
    var taskRef: String?  // link or id of the task created from it in an external tracker (via MCP)
}

struct Bookmark: AutoRow, Identifiable, Hashable {
    static let databaseTableName = "bookmarks"
    var id: Int64?
    var meetingId: String
    var time: Double
    var label: String = ""
}

struct ChatSession: DBRecord, Identifiable, Hashable {
    static let databaseTableName = "chat_sessions"
    var id: String
    var meetingId: String?  // nil = global chat
    var title: String
    var createdAt: Date
    var updatedAt: Date
}

struct Citation: Codable, Hashable {
    var meetingId: String
    var title: String
    var start: Double
    var end: Double
    var text: String
}

struct ChatMessage: AutoRow, Identifiable, Hashable {
    static let databaseTableName = "chat_messages"
    var id: Int64?
    var sessionId: String
    var role: String  // user | assistant
    var content: String
    var citations: [Citation] = []
    var createdAt: Date = .now
}

struct Template: DBRecord, Identifiable, Hashable {
    static let databaseTableName = "templates"
    var id: String
    var name: String
    var insightsPrompt: String
    var actionsPrompt: String
    var isDefault: Bool = false
    var builtin: Bool = false
}

struct Chunk: AutoRow, Identifiable {
    static let databaseTableName = "chunks"
    var id: Int64?
    var meetingId: String
    var start: Double
    var end: Double
    var text: String
    var embedding: [Float]?
}

/// A file attached to a meeting. Screenshots taken during a call carry the recording time they were taken at.
struct Attachment: AutoRow, Identifiable, Hashable {
    static let databaseTableName = "attachments"
    var id: Int64?
    var meetingId: String
    var fileName: String
    var fileSize: Int64
    var isImage: Bool
    var recordingTime: Double?
    var createdAt: Date = .now

    var url: URL { Store.dataDir.appending(path: "recordings/\(meetingId)/attachments/\(fileName)") }
}

/// A saved "live query": a chat prompt re-run over a rolling period of meetings, by hand or on a schedule.
struct SavedQuery: DBRecord, Identifiable, Hashable {
    static let databaseTableName = "saved_queries"
    var id: String
    var name: String
    var prompt: String
    var scopeKind: String = "all"  // all | folder | tag | person
    var scopeId: String?
    var periodDays: Int = 7
    var schedule: String = "manual"  // manual | daily | weekly
    var hour: Int = 9
    var weekday: Int = 2  // Calendar weekday, 2 = Monday
    var sessionId: String?
    var lastRunAt: Date?
    var nextRunAt: Date?
    var lastStatus: String?
    var createdAt: Date = .now

    var scope: Store.Scope {
        switch (scopeKind, scopeId) {
        case ("folder", let id?): .folder(id)
        case ("tag", let id?): .tag(id)
        case ("person", let id?): .person(id)
        default: .all
        }
    }

    /// Next scheduled run strictly after `date`.
    func nextRun(after date: Date) -> Date? {
        let cal = Calendar.current
        switch schedule {
        case "daily": return cal.nextDate(after: date, matching: DateComponents(hour: hour, minute: 0), matchingPolicy: .nextTime)
        case "weekly": return cal.nextDate(after: date, matching: DateComponents(hour: hour, minute: 0, weekday: weekday), matchingPolicy: .nextTime)
        default: return nil
        }
    }
}

/// A transcript passage joined with its meeting, for search results and chat context.
struct Hit: FetchableRecord, Decodable, Hashable {
    var meetingId: String
    var title: String
    var name: String?
    var start: Double
    var end: Double
    var text: String
    var rank: Double
    enum CodingKeys: String, CodingKey { case meetingId = "meeting_id", title, name, start, end, text, rank }
}

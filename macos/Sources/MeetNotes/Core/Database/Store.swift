import Foundation
import GRDB
import UniformTypeIdentifiers

final class Store {
    /// Library folder. `--demo` and `--selftest` point it at a temporary folder so they never touch real data.
    nonisolated(unsafe) static var dataDir: URL = URL.applicationSupportDirectory.appending(path: "MeetNotes") {
        didSet { try? FileManager.default.createDirectory(at: dataDir.appending(path: "recordings"), withIntermediateDirectories: true) }
    }

    static func useTemporaryLibrary() {
        dataDir = FileManager.default.temporaryDirectory.appending(path: "meetnotes-\(UUID().uuidString)")
    }

    let db: DatabaseQueue

    init(path: String? = nil) throws {
        try? FileManager.default.createDirectory(at: Store.dataDir.appending(path: "recordings"), withIntermediateDirectories: true)
        let path = path ?? Store.dataDir.appending(path: "meetnotes.sqlite").path
        var config = Configuration()
        config.foreignKeysEnabled = true
        db = try DatabaseQueue(path: path, configuration: config)
        try db.write { db in
            // Libraries from 0.1.0 recorded the v2 migration under an earlier name.
            if try db.tableExists("grdb_migrations") { try db.execute(sql: Self.renameV2Migration) }
        }
        try Self.migrator.migrate(db)
        try db.write { try BuiltinTemplates.localize($0) }
        try db.write { db in
            // A crash mid-pipeline leaves a stale status; surface it instead of spinning forever.
            // Interrupted while recording: the audio is on disk, so process it on launch ("recovered").
            // Interrupted while processing: don't retry automatically (it may be what crashed); the user retries.
            try db.execute(sql: "UPDATE meetings SET status = 'recovered' WHERE status = 'recording'")
            try db.execute(sql: "UPDATE meetings SET status = 'error:interrupted' WHERE status LIKE 'processing%' OR status = 'queued'")
            // Recently Deleted keeps notes for 30 days.
            let expired = try Meeting.filter(sql: "deleted_at < ?", arguments: [Date.now.addingTimeInterval(-30 * 86400)]).fetchAll(db)
            for m in expired {
                try m.delete(db)
                try? FileManager.default.removeItem(at: m.folder)
            }
        }
    }

    static let renameV2Migration = "UPDATE grdb_migrations SET identifier = 'v2_folders_tags' WHERE identifier LIKE 'v2!_%' ESCAPE '!' AND identifier <> 'v2_folders_tags'"

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "meetings") { t in
                t.primaryKey("id", .text)
                t.column("title", .text).notNull()
                t.column("created_at", .datetime).notNull().indexed()
                t.column("duration", .double).notNull().defaults(to: 0)
                t.column("status", .text).notNull()
                t.column("summary", .text).notNull().defaults(to: "")
                t.column("action_items", .text).notNull().defaults(to: "[]")
                t.column("tags", .text).notNull().defaults(to: "[]")
            }
            try db.create(table: "speakers") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("embedding", .text).notNull()
                t.column("embedding_model", .text).notNull()
                t.column("created_at", .datetime).notNull()
            }
            try db.create(table: "segments") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("meeting_id", .text).notNull().indexed().references("meetings", onDelete: .cascade)
                t.column("speaker_id", .text).references("speakers", onDelete: .setNull)
                t.column("source", .text).notNull()
                t.column("start", .double).notNull()
                t.column("end", .double).notNull()
                t.column("text", .text).notNull()
                t.column("original_text", .text)
                t.column("irrelevant", .boolean).notNull().defaults(to: false)
            }
            try db.create(virtualTable: "segments_fts", using: FTS5()) { t in
                t.synchronize(withTable: "segments")
                t.tokenizer = .porter(wrapping: .unicode61())
                t.column("text")
            }
            try db.create(virtualTable: "meetings_fts", using: FTS5()) { t in
                t.synchronize(withTable: "meetings")
                t.tokenizer = .porter(wrapping: .unicode61())
                t.column("title")
                t.column("summary")
            }
            try db.execute(sql: "INSERT INTO speakers VALUES ('me', 'Me', '[]', '', ?)", arguments: [Date.now])
        }
        m.registerMigration("v2_folders_tags") { db in
            try db.create(table: "folders") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("icon", .text).notNull().defaults(to: "folder")
                t.column("color", .text).notNull().defaults(to: "blue")
                t.column("parent_id", .text).references("folders", onDelete: .cascade)
                t.column("template_id", .text)
                t.column("context", .text).notNull().defaults(to: "")
                t.column("sort_order", .integer).notNull().defaults(to: 0)
                t.column("created_at", .datetime).notNull()
            }
            try db.alter(table: "meetings") { t in
                t.add(column: "folder_id", .text).references("folders", onDelete: .setNull)
                t.add(column: "template_id", .text)
                t.add(column: "notes", .text).notNull().defaults(to: "")
                t.add(column: "deleted_at", .datetime)
                t.add(column: "modified_at", .datetime)
                t.add(column: "event_id", .text)
            }
            try db.create(table: "tags") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull().unique().collate(.nocase)
            }
            try db.create(table: "meeting_tags") { t in
                t.column("meeting_id", .text).notNull().references("meetings", onDelete: .cascade)
                t.column("tag_id", .text).notNull().indexed().references("tags", onDelete: .cascade)
                t.primaryKey(["meeting_id", "tag_id"])
            }
            try db.create(table: "insights") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("meeting_id", .text).notNull().indexed().references("meetings", onDelete: .cascade)
                t.column("text", .text).notNull()
                t.column("time", .double)
                t.column("sort_order", .integer).notNull()
            }
            try db.create(table: "action_items") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("meeting_id", .text).notNull().indexed().references("meetings", onDelete: .cascade)
                t.column("text", .text).notNull()
                t.column("assignee", .text)
                t.column("due_date", .datetime)
                t.column("completed", .boolean).notNull().defaults(to: false)
                t.column("created_at", .datetime).notNull()
            }
            try db.create(table: "bookmarks") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("meeting_id", .text).notNull().indexed().references("meetings", onDelete: .cascade)
                t.column("time", .double).notNull()
                t.column("label", .text).notNull().defaults(to: "")
            }
            try db.alter(table: "speakers") { t in
                t.add(column: "email", .text)
                t.add(column: "company", .text)
                t.add(column: "position", .text)
                t.add(column: "notes", .text)
                t.add(column: "parent_id", .text).references("speakers", onDelete: .setNull)
            }
            try db.alter(table: "segments") { t in t.add(column: "user_edited", .boolean).notNull().defaults(to: false) }
            try db.create(table: "chat_sessions") { t in
                t.primaryKey("id", .text)
                t.column("meeting_id", .text).indexed().references("meetings", onDelete: .cascade)
                t.column("title", .text).notNull()
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }
            try db.create(table: "chat_messages") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("session_id", .text).notNull().indexed().references("chat_sessions", onDelete: .cascade)
                t.column("role", .text).notNull()
                t.column("content", .text).notNull()
                t.column("citations", .text).notNull().defaults(to: "[]")
                t.column("created_at", .datetime).notNull()
            }
            try db.create(table: "templates") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("insights_prompt", .text).notNull()
                t.column("actions_prompt", .text).notNull()
                t.column("is_default", .boolean).notNull().defaults(to: false)
                t.column("builtin", .boolean).notNull().defaults(to: false)
            }
            try db.create(table: "chunks") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("meeting_id", .text).notNull().indexed().references("meetings", onDelete: .cascade)
                t.column("start", .double).notNull()
                t.column("end", .double).notNull()
                t.column("text", .text).notNull()
                t.column("embedding", .text)
            }
            // Move v1's JSON columns into real tables.
            for row in try GRDB.Row.fetchAll(db, sql: "SELECT id, action_items, tags FROM meetings") {
                let id: String = row["id"]
                let items = (try? JSONDecoder().decode([String].self, from: Data((row["action_items"] as String).utf8))) ?? []
                for text in items { var a = ActionItem(meetingId: id, text: text); try a.insert(db) }
                let tags = (try? JSONDecoder().decode([String].self, from: Data((row["tags"] as String).utf8))) ?? []
                for name in tags { try Store.attach(tag: name, to: id, db) }
            }
            try db.alter(table: "meetings") { t in
                t.drop(column: "action_items")
                t.drop(column: "tags")
            }
            for (i, t) in BuiltinTemplates.all.enumerated() {
                try Template(id: t.id, name: t.name, insightsPrompt: t.insights, actionsPrompt: t.actions,
                             isDefault: i == 0, builtin: true).insert(db)
            }
        }
        m.registerMigration("v3_attachments_live_queries") { db in
            try db.create(table: "attachments") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("meeting_id", .text).notNull().indexed().references("meetings", onDelete: .cascade)
                t.column("file_name", .text).notNull()
                t.column("file_size", .integer).notNull()
                t.column("is_image", .boolean).notNull()
                t.column("recording_time", .double)
                t.column("created_at", .datetime).notNull()
            }
            try db.create(table: "saved_queries") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("prompt", .text).notNull()
                t.column("scope_kind", .text).notNull()
                t.column("scope_id", .text)
                t.column("period_days", .integer).notNull()
                t.column("schedule", .text).notNull()
                t.column("hour", .integer).notNull()
                t.column("weekday", .integer).notNull()
                t.column("session_id", .text).references("chat_sessions", onDelete: .setNull)
                t.column("last_run_at", .datetime)
                t.column("next_run_at", .datetime)
                t.column("last_status", .text)
                t.column("created_at", .datetime).notNull()
            }
        }
        m.registerMigration("v4_task_refs") { db in
            try db.alter(table: "action_items") { t in t.add(column: "task_ref", .text) }
        }
        m.registerMigration("v5_diarization") { db in
            try db.alter(table: "speakers") { t in t.add(column: "voice_samples", .text).notNull().defaults(to: "[]") }
            try db.alter(table: "segments") { t in t.add(column: "overlap", .boolean).notNull().defaults(to: false) }
            try db.alter(table: "meetings") { t in
                t.add(column: "max_speakers", .integer)
                t.add(column: "expected_speakers", .integer)
            }
        }
        return m
    }

    // MARK: - Attachments

    func attachments(of meetingID: String) throws -> [Attachment] {
        try db.read { try Attachment.filter(Column("meeting_id") == meetingID).order(Column("recording_time"), Column("created_at")).fetchAll($0) }
    }

    /// Copies a file into the meeting's attachments folder (unique name) and records it.
    @discardableResult
    func attach(file: URL, to meetingID: String, recordingTime: Double? = nil) throws -> Attachment {
        let dir = Store.dataDir.appending(path: "recordings/\(meetingID)/attachments")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var name = file.lastPathComponent
        var n = 1
        while FileManager.default.fileExists(atPath: dir.appending(path: name).path) {
            name = file.deletingPathExtension().lastPathComponent + " \(n)." + file.pathExtension
            n += 1
        }
        try FileManager.default.copyItem(at: file, to: dir.appending(path: name))
        let size = (try? FileManager.default.attributesOfItem(atPath: dir.appending(path: name).path)[.size] as? Int64) ?? 0
        let isImage = UTType(filenameExtension: file.pathExtension)?.conforms(to: .image) == true
        var a = Attachment(meetingId: meetingID, fileName: name, fileSize: size, isImage: isImage, recordingTime: recordingTime)
        try db.write { try a.insert($0) }
        return a
    }

    func removeAttachment(_ a: Attachment) throws {
        try? FileManager.default.removeItem(at: a.url)
        _ = try db.write { try a.delete($0) }
    }

    // MARK: - Live queries

    func savedQueries() throws -> [SavedQuery] { try db.read { try SavedQuery.order(Column("created_at")).fetchAll($0) } }
    func saveQuery(_ q: SavedQuery) throws { try db.write { try q.save($0) } }
    func deleteQuery(_ id: String) throws { try db.write { try $0.execute(sql: "DELETE FROM saved_queries WHERE id = ?", arguments: [id]) } }

    // MARK: - Meetings

    enum Scope: Hashable {
        case all, unsorted, folder(String), tag(String), person(String), deleted
    }

    func meetings(_ scope: Scope) throws -> [Meeting] {
        try db.read { db in
            let live = Meeting.filter(sql: "deleted_at IS NULL")
            let req: QueryInterfaceRequest<Meeting> = switch scope {
            case .all: live
            case .unsorted: live.filter(sql: "folder_id IS NULL")
            case .folder(let id):
                live.filter(sql: """
                    folder_id IN (WITH RECURSIVE sub(id) AS (SELECT ? UNION SELECT f.id FROM folders f JOIN sub ON f.parent_id = sub.id)
                                  SELECT id FROM sub)
                    """, arguments: [id])
            case .tag(let id): live.filter(sql: "id IN (SELECT meeting_id FROM meeting_tags WHERE tag_id = ?)", arguments: [id])
            case .person(let id):
                live.filter(sql: "id IN (SELECT meeting_id FROM segments WHERE speaker_id IN (\(Store.familySQL)))", arguments: [id])
            case .deleted: Meeting.filter(sql: "deleted_at IS NOT NULL")
            }
            return try req.order(sql: scope == .deleted ? "deleted_at DESC" : "created_at DESC").fetchAll(db)
        }
    }

    func meeting(_ id: String) -> Meeting? { try? db.read { try Meeting.fetchOne($0, key: id) } }

    /// The newest meeting outside the trash (the menu bar asks on every redraw, so one row only).
    func latestMeeting() -> Meeting? {
        try? db.read { try Meeting.filter(sql: "deleted_at IS NULL").order(sql: "created_at DESC").fetchOne($0) }
    }

    func save(_ meeting: Meeting) throws {
        var m = meeting
        m.modifiedAt = .now
        try db.write { try m.save($0) }
    }

    func update(_ id: String, _ change: (inout Meeting) -> Void) throws {
        try db.write { db in
            guard var m = try Meeting.fetchOne(db, key: id) else { return }
            change(&m)
            m.modifiedAt = .now
            try m.update(db)
        }
    }

    func setStatus(_ id: String, _ status: String) throws {
        try db.write { try $0.execute(sql: "UPDATE meetings SET status = ? WHERE id = ?", arguments: [status, id]) }
    }

    func trash(_ id: String) throws { try update(id) { $0.deletedAt = .now } }
    func restore(_ id: String) throws { try update(id) { $0.deletedAt = nil } }

    func deletePermanently(_ meeting: Meeting) throws {
        _ = try db.write { try meeting.delete($0) }
        try? FileManager.default.removeItem(at: meeting.folder)
    }

    func counts() throws -> (all: Int, unsorted: Int, deleted: Int, byFolder: [String: Int]) {
        try db.read { db in
            let all = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM meetings WHERE deleted_at IS NULL") ?? 0
            let uns = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM meetings WHERE deleted_at IS NULL AND folder_id IS NULL") ?? 0
            let del = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM meetings WHERE deleted_at IS NOT NULL") ?? 0
            var by: [String: Int] = [:]
            for r in try GRDB.Row.fetchAll(db, sql: "SELECT folder_id, COUNT(*) c FROM meetings WHERE deleted_at IS NULL AND folder_id IS NOT NULL GROUP BY folder_id") {
                by[r["folder_id"]] = r["c"]
            }
            return (all, uns, del, by)
        }
    }

    // MARK: - Transcript

    func segments(of meetingID: String) throws -> [Segment] {
        try db.read { try Segment.filter(Column("meeting_id") == meetingID).order(Column("start")).fetchAll($0) }
    }

    func editSegment(_ id: Int64, text: String) throws {
        try db.write {
            try $0.execute(sql: "UPDATE segments SET original_text = COALESCE(original_text, text), text = ?, user_edited = 1 WHERE id = ?",
                           arguments: [text, id])
        }
    }

    func restoreOriginal(_ id: Int64) throws {
        try db.write {
            try $0.execute(sql: "UPDATE segments SET text = COALESCE(original_text, text), original_text = NULL, irrelevant = 0, user_edited = 0 WHERE id = ?",
                           arguments: [id])
        }
    }

    func assign(segment id: Int64, to speakerID: String) throws {
        try db.write { try $0.execute(sql: "UPDATE segments SET speaker_id = ? WHERE id = ?", arguments: [speakerID, id]) }
    }

    func split(segment s: Segment, at offset: Int) throws {
        let idx = s.text.index(s.text.startIndex, offsetBy: offset)
        let first = s.text[..<idx].trimmingCharacters(in: .whitespaces), second = s.text[idx...].trimmingCharacters(in: .whitespaces)
        guard !first.isEmpty, !second.isEmpty else { return }
        // Split time proportionally to text length.
        let mid = s.start + (s.end - s.start) * Double(first.count) / Double(s.text.count)
        try db.write { db in
            var a = s; a.text = first; a.end = mid; try a.update(db)
            var b = s; b.id = nil; b.text = second; b.start = mid; b.originalText = nil; try b.insert(db)
        }
    }

    // MARK: - People

    /// All ids merged into `?` (the person plus its merged children), used inside IN (...).
    static let familySQL = "WITH RECURSIVE fam(id) AS (SELECT ? UNION SELECT s.id FROM speakers s JOIN fam ON s.parent_id = fam.id) SELECT id FROM fam"

    func speakers() throws -> [String: Speaker] {
        try db.read { Dictionary(uniqueKeysWithValues: try Speaker.fetchAll($0).map { ($0.id, $0) }) }
    }

    /// Display name, following merges up to the root person.
    func root(_ id: String?, in all: [String: Speaker]) -> Speaker? {
        var s = id.flatMap { all[$0] }
        var hops = 0
        while let p = s?.parentId, let parent = all[p], hops < 32 { s = parent; hops += 1 }
        return s
    }

    func people() throws -> [(Speaker, Int)] {
        let all = try speakers()
        let pairs = try db.read {
            try GRDB.Row.fetchAll($0, sql: """
                SELECT DISTINCT s.meeting_id, s.speaker_id FROM segments s JOIN meetings m ON m.id = s.meeting_id
                WHERE m.deleted_at IS NULL AND s.speaker_id IS NOT NULL
                """)
        }
        var meetingsByRoot: [String: Set<String>] = [:]
        for r in pairs {
            if let root = root(r["speaker_id"], in: all) { meetingsByRoot[root.id, default: []].insert(r["meeting_id"]) }
        }
        return all.values.filter { $0.parentId == nil }
            .sorted { ($0.id == Speaker.meID ? 0 : 1, $0.name.lowercased()) < ($1.id == Speaker.meID ? 0 : 1, $1.name.lowercased()) }
            .map { ($0, meetingsByRoot[$0.id]?.count ?? 0) }
    }

    func participants(of meetingID: String) throws -> [Speaker] {
        let all = try speakers()
        let ids = try db.read { try String.fetchAll($0, sql: "SELECT DISTINCT speaker_id FROM segments WHERE meeting_id = ? AND speaker_id IS NOT NULL ORDER BY start", arguments: [meetingID]) }
        var seen = Set<String>()
        return ids.compactMap { root($0, in: all) }.filter { seen.insert($0.id).inserted }
    }

    /// Named people per meeting in order of first speaking, for the avatars in the meeting list.
    func participantsByMeeting() throws -> [String: [Speaker]] {
        let all = try speakers()
        let rows = try db.read {
            try GRDB.Row.fetchAll($0, sql: "SELECT meeting_id, speaker_id FROM segments WHERE speaker_id IS NOT NULL GROUP BY meeting_id, speaker_id ORDER BY meeting_id, MIN(start)")
        }
        var out: [String: [Speaker]] = [:]
        for r in rows {
            let meeting: String = r["meeting_id"]
            guard let s = root(r["speaker_id"], in: all), !(out[meeting]?.contains { $0.id == s.id } ?? false) else { continue }
            out[meeting, default: []].append(s)
        }
        return out
    }

    func saveSpeaker(_ s: Speaker) throws { try db.write { try s.save($0) } }

    func newPerson(named name: String) throws -> Speaker {
        let s = Speaker(id: UUID().uuidString, name: name, embedding: [], embeddingModel: "", createdAt: .now)
        try db.write { try s.insert($0) }
        return s
    }

    func merge(_ id: String, into target: String) throws {
        guard id != target else { return }
        try db.write { try $0.execute(sql: "UPDATE speakers SET parent_id = ? WHERE id = ?", arguments: [target, id]) }
    }

    func deletePerson(_ id: String) throws {
        guard id != Speaker.meID else { return }
        try db.write { db in
            try db.execute(sql: "UPDATE speakers SET parent_id = NULL WHERE parent_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM speakers WHERE id = ?", arguments: [id])
        }
    }

    // MARK: - Folders & tags

    func folders() throws -> [Folder] { try db.read { try Folder.order(Column("sort_order"), Column("name")).fetchAll($0) } }
    func saveFolder(_ f: Folder) throws { try db.write { try f.save($0) } }
    func deleteFolder(_ id: String) throws { try db.write { try $0.execute(sql: "DELETE FROM folders WHERE id = ?", arguments: [id]) } }
    func move(_ meetingID: String, to folderID: String?) throws { try update(meetingID) { $0.folderId = folderID } }

    static func attach(tag name: String, to meetingID: String, _ db: Database) throws {
        let clean = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard !clean.isEmpty else { return }
        let tag = try Tag.filter(sql: "name = ? COLLATE NOCASE", arguments: [clean]).fetchOne(db) ?? {
            let t = Tag(id: UUID().uuidString, name: clean)
            try t.insert(db)
            return t
        }()
        try db.execute(sql: "INSERT OR IGNORE INTO meeting_tags (meeting_id, tag_id) VALUES (?, ?)", arguments: [meetingID, tag.id])
    }

    func addTag(_ name: String, to meetingID: String) throws { try db.write { try Store.attach(tag: name, to: meetingID, $0) } }
    func removeTag(_ tagID: String, from meetingID: String) throws {
        try db.write { try $0.execute(sql: "DELETE FROM meeting_tags WHERE meeting_id = ? AND tag_id = ?", arguments: [meetingID, tagID]) }
    }

    func tags(of meetingID: String) throws -> [Tag] {
        try db.read { try Tag.fetchAll($0, sql: "SELECT t.* FROM tags t JOIN meeting_tags mt ON mt.tag_id = t.id WHERE mt.meeting_id = ? ORDER BY t.name", arguments: [meetingID]) }
    }

    func tagsByMeeting() throws -> [String: [Tag]] {
        try db.read { db in
            var out: [String: [Tag]] = [:]
            for r in try GRDB.Row.fetchAll(db, sql: "SELECT mt.meeting_id, t.id, t.name FROM meeting_tags mt JOIN tags t ON t.id = mt.tag_id ORDER BY t.name") {
                out[r["meeting_id"], default: []].append(Tag(id: r["id"], name: r["name"]))
            }
            return out
        }
    }

    func allTags() throws -> [(Tag, Int)] {
        try db.read { db in
            try GRDB.Row.fetchAll(db, sql: """
                SELECT t.id, t.name, COUNT(m.id) cnt FROM tags t LEFT JOIN meeting_tags mt ON mt.tag_id = t.id
                LEFT JOIN meetings m ON m.id = mt.meeting_id AND m.deleted_at IS NULL GROUP BY t.id ORDER BY cnt DESC, t.name
                """).map { (Tag(id: $0["id"], name: $0["name"]), $0["cnt"] as Int) }
        }
    }

    func deleteTag(_ id: String) throws { try db.write { try $0.execute(sql: "DELETE FROM tags WHERE id = ?", arguments: [id]) } }
    func renameTag(_ id: String, _ name: String) throws {
        try db.write { try $0.execute(sql: "UPDATE tags SET name = ? WHERE id = ?", arguments: [name.lowercased(), id]) }
    }

    // MARK: - Insights, action items, bookmarks

    func insights(of id: String) throws -> [Insight] {
        try db.read { try Insight.filter(Column("meeting_id") == id).order(Column("sort_order")).fetchAll($0) }
    }

    func actionItems(of id: String) throws -> [ActionItem] {
        try db.read { try ActionItem.filter(Column("meeting_id") == id).order(Column("id")).fetchAll($0) }
    }

    func allActionItems() throws -> [(ActionItem, Meeting)] {
        try db.read { db in
            try GRDB.Row.fetchAll(db, sql: """
                SELECT a.*, m.id AS m_id FROM action_items a JOIN meetings m ON m.id = a.meeting_id
                WHERE m.deleted_at IS NULL ORDER BY a.completed, a.due_date IS NULL, a.due_date, m.created_at DESC
                """).compactMap { r in
                    guard let m = try Meeting.fetchOne(db, key: r["m_id"] as String) else { return nil }
                    return (try ActionItem(row: r), m)
                }
        }
    }

    func saveActionItem(_ a: ActionItem) throws { var a = a; try db.write { try a.save($0) } }
    func deleteActionItem(_ id: Int64) throws { try db.write { try $0.execute(sql: "DELETE FROM action_items WHERE id = ?", arguments: [id]) } }

    func bookmarks(of id: String) throws -> [Bookmark] {
        try db.read { try Bookmark.filter(Column("meeting_id") == id).order(Column("time")).fetchAll($0) }
    }

    func addBookmark(_ meetingID: String, at time: Double) throws {
        var b = Bookmark(meetingId: meetingID, time: time)
        try db.write { try b.insert($0) }
    }

    func deleteBookmark(_ id: Int64) throws { try db.write { try $0.execute(sql: "DELETE FROM bookmarks WHERE id = ?", arguments: [id]) } }

    // MARK: - Templates

    func templates() throws -> [Template] { try db.read { try Template.order(Column("builtin").desc, Column("name")).fetchAll($0) } }
    func saveTemplate(_ t: Template) throws {
        try db.write { db in
            if t.isDefault { try db.execute(sql: "UPDATE templates SET is_default = 0") }
            try t.save(db)
        }
    }
    func deleteTemplate(_ id: String) throws { try db.write { try $0.execute(sql: "DELETE FROM templates WHERE id = ? AND builtin = 0", arguments: [id]) } }

    /// Document template → folder template (walking up parents) → default template.
    func template(for m: Meeting) throws -> Template? {
        try db.read { db in
            if let id = m.templateId, let t = try Template.fetchOne(db, key: id) { return t }
            var folderID = m.folderId
            var hops = 0
            while let fid = folderID, hops < 32, let f = try Folder.fetchOne(db, key: fid) {
                if let id = f.templateId, let t = try Template.fetchOne(db, key: id) { return t }
                folderID = f.parentId
                hops += 1
            }
            return try Template.filter(Column("is_default") == true).fetchOne(db) ?? Template.fetchOne(db)
        }
    }

    func folderContext(for m: Meeting) throws -> String {
        try db.read { db in try m.folderId.flatMap { try Folder.fetchOne(db, key: $0) }?.context ?? "" }
    }

    // MARK: - Chat

    func chatSessions(meetingID: String?) throws -> [ChatSession] {
        try db.read { db in
            try ChatSession.filter(sql: meetingID == nil ? "meeting_id IS NULL" : "meeting_id = ?",
                                   arguments: meetingID.map { [$0] } ?? [])
                .order(Column("updated_at").desc).fetchAll(db)
        }
    }

    func messages(_ sessionID: String) throws -> [ChatMessage] {
        try db.read { try ChatMessage.filter(Column("session_id") == sessionID).order(Column("id")).fetchAll($0) }
    }

    func append(_ message: ChatMessage) throws {
        var msg = message
        try db.write { db in
            try msg.insert(db)
            try db.execute(sql: "UPDATE chat_sessions SET updated_at = ? WHERE id = ?", arguments: [Date.now, msg.sessionId])
        }
    }

    func saveSession(_ s: ChatSession) throws { try db.write { try s.save($0) } }
    func deleteSession(_ id: String) throws { try db.write { try $0.execute(sql: "DELETE FROM chat_sessions WHERE id = ?", arguments: [id]) } }

    // MARK: - Search

    /// Full-text matches over titles, notes summary and transcripts, best bm25 per meeting.
    func keywordHits(_ query: String, meetingIDs: [String]? = nil, limit: Int = 60) throws -> [Hit] {
        guard let p = FTS5Pattern(matchingAnyTokenIn: query) else { return [] }
        let scope = meetingIDs.map { "AND s.meeting_id IN (\($0.map { "'\($0.replacingOccurrences(of: "'", with: ""))'" }.joined(separator: ",")))" } ?? ""
        return try db.read {
            try Hit.fetchAll($0, sql: """
                SELECT s.meeting_id, m.title, sp.name, s.start, s.end, s.text, bm25(segments_fts) AS rank
                FROM segments_fts JOIN segments s ON s.id = segments_fts.rowid
                JOIN meetings m ON m.id = s.meeting_id LEFT JOIN speakers sp ON sp.id = s.speaker_id
                WHERE segments_fts MATCH ? AND s.irrelevant = 0 AND m.deleted_at IS NULL \(scope)
                ORDER BY rank LIMIT ?
                """, arguments: [p, limit])
        }
    }

    func titleMatches(_ query: String) throws -> Set<String> {
        guard let p = FTS5Pattern(matchingAllPrefixesIn: query) else { return [] }
        return try db.read { Set(try String.fetchAll($0, sql: "SELECT m.id FROM meetings m WHERE m.rowid IN (SELECT rowid FROM meetings_fts WHERE meetings_fts MATCH ?)", arguments: [p])) }
    }

    func chunks(meetingIDs: [String]? = nil) throws -> [Chunk] {
        try db.read { db in
            var req = Chunk.filter(sql: "embedding IS NOT NULL AND meeting_id IN (SELECT id FROM meetings WHERE deleted_at IS NULL)")
            if let ids = meetingIDs { req = req.filter(ids.contains(Column("meeting_id"))) }
            return try req.fetchAll(db)
        }
    }
}

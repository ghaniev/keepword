import Foundation

/// Builds tool arguments for a task from an action item, and finds pick-lists for ID fields.
enum TaskMapping {
    struct Draft: Identifiable, Hashable {
        var id = UUID()
        var title: String
        var details: String
        var due: Date?
        var assignee: String?
        var actionItemID: Int64?
    }

    static let titleKeys = ["title", "name", "summary", "subject"]
    static let detailKeys = ["description", "body", "content", "text", "details", "notes"]
    static let dueKeys = ["due_date", "due", "deadline", "due_at", "dueDate"]

    /// Picks the most likely "create a task" tool (create_card, create_task, create_issue…).
    static func suggestTaskTool(_ tools: [MCPTool]) -> String? {
        let words = ["card", "task", "issue", "ticket", "todo"]
        return tools.first { t in t.name.contains("create") && words.contains { t.name.contains($0) } }?.name
    }

    /// Fields the draft fills per task (title, description, due); everything else is shared across the batch.
    static func perTaskField(_ key: String) -> Bool { (titleKeys + detailKeys + dueKeys).contains(key) }

    static func arguments(for d: Draft, tool: MCPTool, shared: [String: String]) -> [String: Any] {
        var args: [String: Any] = [:]
        for (key, prop) in tool.properties {
            let type = prop["type"] as? String ?? "string"
            var raw: String?
            if titleKeys.contains(key) { raw = String(d.title.prefix(500)) }
            else if detailKeys.contains(key) { raw = d.details }
            else if dueKeys.contains(key) { raw = d.due.map { ISO8601DateFormatter().string(from: Calendar.current.startOfDay(for: $0).addingTimeInterval(86399)) } }
            else { raw = shared[key] }
            guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { continue }
            switch type {
            case "integer": if let v = Int(value) { args[key] = v }
            case "number": if let v = Double(value) { args[key] = v }
            case "boolean": args[key] = ["true", "1", "yes"].contains(value.lowercased())
            case "array": args[key] = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            default: args[key] = value
            }
        }
        return args
    }

    /// For an ID field like board_id → a listing tool like *_list_boards (owner_id → *_list_users).
    static func lookupTool(for field: String, in tools: [MCPTool]) -> MCPTool? {
        guard field.hasSuffix("_id") else { return nil }
        var base = String(field.dropLast(3))
        if ["owner", "responsible", "assignee", "member", "author"].contains(base) { base = "user" }
        if base == "type" { return tools.first { $0.name.hasSuffix("list_types") } }
        return tools.first { $0.name.hasSuffix("list_\(base)s") || $0.name.hasSuffix("list_\(base)es") }
    }

    /// Pulls (id, label) pairs out of a listing tool's result, JSON or text.
    static func options(from text: String) -> [(String, String)] {
        func collect(_ o: Any, into out: inout [(String, String)]) {
            if let arr = o as? [Any] { arr.forEach { collect($0, into: &out) } }
            else if let d = o as? [String: Any] {
                if let id = d["id"], let label = ["title", "name", "full_name", "username", "email"].lazy.compactMap({ d[$0] as? String }).first {
                    out.append(("\(id)", label))
                } else {
                    d.values.forEach { collect($0, into: &out) }
                }
            }
        }
        var out: [(String, String)] = []
        if let start = text.firstIndex(where: { $0 == "[" || $0 == "{" }),
           let obj = try? JSONSerialization.jsonObject(with: Data(text[start...].utf8)) {
            collect(obj, into: &out)
        }
        if out.isEmpty {  // text listings like "• Board name (id: 123)" or "123 — Board name"
            for line in text.split(separator: "\n") {
                let s = String(line)
                if let m = s.firstMatch(of: #/(?:id[:=#\s]+)(\d+)/#.ignoresCase()) {
                    let label = s.replacingOccurrences(of: String(s[m.range]), with: "").trimmingCharacters(in: CharacterSet(charactersIn: " -—•*()[]|:\t"))
                    out.append((String(m.1), label.isEmpty ? String(m.1) : label))
                }
            }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0.0).inserted }
    }

    /// First URL in a tool result (e.g. the created card's link).
    static func link(in text: String) -> String? {
        text.firstMatch(of: #/https?://[^\s"'<>)\]]+/#).map { String($0.0).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:")) }
    }
}

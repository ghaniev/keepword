import Foundation

/// What to know before a calendar meeting: earlier meetings of the same series or with the same people,
/// and the action items they left open. `write` turns them into a short AI brief.
struct MeetingBrief {
    var related: [Meeting]  // newest first
    var openItems: [(ActionItem, Meeting)]

    var isEmpty: Bool { related.isEmpty }

    /// Looks back half a year: the same calendar event (recurring series share one id), the same title,
    /// or a known person among the attendees (by name or email).
    static func build(for event: CalEvent, store: Store, limit: Int = 5) -> MeetingBrief {
        let attendees = Set(event.attendees.flatMap(names))
        let title = normalized(event.title)
        let since = event.start.addingTimeInterval(-183 * 86400)
        let earlier = ((try? store.meetings(.all)) ?? []).filter { $0.status == "done" && $0.createdAt < event.start && $0.createdAt > since }
        var related: [Meeting] = []
        for m in earlier where related.count < limit {
            if m.eventId == event.id || (!title.isEmpty && normalized(m.title) == title) {
                related.append(m)
            } else if !attendees.isEmpty, ((try? store.participants(of: m.id)) ?? []).contains(where: { p in
                p.id != Speaker.meID && (names(p.name) + [p.email?.lowercased()].compactMap { $0 }).contains(where: attendees.contains)
            }) {
                related.append(m)
            }
        }
        let ids = Set(related.map(\.id))
        return MeetingBrief(related: related, openItems: ((try? store.allActionItems()) ?? []).filter { !$0.0.completed && ids.contains($0.0.meetingId) })
    }

    func write(for event: CalEvent, store: Store) async throws -> String {
        var notes = ""
        for m in related {
            notes += "## \(m.title) — \(m.createdAt.formatted(date: .abbreviated, time: .omitted))\n\(m.summary)\n"
            for i in (try? store.insights(of: m.id)) ?? [] { notes += "- \(i.text)\n" }
            notes += "\n"
        }
        if !openItems.isEmpty {
            notes += "## Open follow-ups\n"
            for (a, m) in openItems {
                notes += "- \(a.text)" + (a.assignee.map { " (\($0))" } ?? "")
                    + (a.dueDate.map { ", due \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "") + " — from “\(m.title)”\n"
            }
        }
        let llm = LLM.current
        let system = """
        You prepare a brief for an upcoming meeting from the notes of earlier ones. Write in the language of the notes, \
        in Markdown, at most 200 words, with three bold headings: what was discussed and decided last time, \
        open action items (who owes what), and 2–4 topics or questions worth raising. Use only facts from the notes.
        """
        var user = "Upcoming meeting: \(event.title), \(event.start.formatted(date: .abbreviated, time: .shortened))."
        if !event.attendees.isEmpty { user += "\nAttendees: \(event.attendees.joined(separator: ", "))." }
        if let agenda = event.notes, !agenda.isEmpty { user += "\nAgenda: \(agenda)" }
        user += "\n\nNotes of earlier meetings:\n" + String(notes.prefix(llm.maxInputChars))
        return try await llm.chat(system: system, user: user)
    }

    /// Comparable forms of a person: "Doe, John" → "john doe"; "anna.k@x.com" → itself and "anna k".
    static func names(_ s: String) -> [String] {
        let t = s.lowercased().trimmingCharacters(in: .whitespaces)
        if t.contains("@") {
            return [t, String(t.split(separator: "@")[0]).replacingOccurrences(of: #"[._]"#, with: " ", options: .regularExpression)]
        }
        let parts = t.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return [normalized(parts.count == 2 ? "\(parts[1]) \(parts[0])" : t)]
    }

    private static func normalized(_ s: String) -> String {
        s.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

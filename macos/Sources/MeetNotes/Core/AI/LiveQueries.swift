import Foundation

/// Saved live queries: a starting prompt re-run over a rolling period of meetings,
/// e.g. "What did we decide this week?" every Friday. Each run appends to its own chat session with citations.
enum LiveQueries {
    static let system = """
        You write a periodic report from the user's meeting notes for the period given. Use only the numbered evidence; \
        cite every factual claim with its number in square brackets, e.g. [4]. Group by theme rather than by meeting when it helps. \
        Never claim a meeting was reviewed unless it appears in the evidence. If there is no evidence, say there were no meetings in the period. \
        Answer in the language of the prompt. Use markdown headings and lists.
        """

    /// Evidence is the already-distilled overview, insights and action items of each meeting in the period.
    static func evidence(_ q: SavedQuery, store: Store, now: Date = .now) throws -> (String, [Citation], Int) {
        let from = Calendar.current.startOfDay(for: now).addingTimeInterval(-Double(q.periodDays - 1) * 86400)
        let meetings = try store.meetings(q.scope).filter { $0.createdAt >= from && $0.createdAt <= now && $0.status == "done" }
            .sorted { $0.createdAt < $1.createdAt }
        var lines: [String] = []
        var cites: [Citation] = []
        func add(_ m: Meeting, _ text: String, _ time: Double) {
            cites.append(Citation(meetingId: m.id, title: m.title, start: time, end: time, text: text))
            lines.append("[\(cites.count)] \(text)")
        }
        for m in meetings {
            lines.append("\n## \(m.title) — \(m.createdAt.formatted(date: .abbreviated, time: .shortened))")
            if !m.summary.isEmpty { add(m, "Overview: \(m.summary)", 0) }
            for i in try store.insights(of: m.id) { add(m, i.text, i.time ?? 0) }
            for a in try store.actionItems(of: m.id) {
                add(m, "Action item\(a.completed ? " (done)" : ""): \(a.text)" + (a.assignee.map { " — \($0)" } ?? ""), 0)
            }
        }
        // ponytail: truncates oldest-first past ~60k chars; add a reduce step if periods get that large
        var text = lines.joined(separator: "\n")
        if text.count > 60_000 { text = "…\n" + text.suffix(60_000) }
        return (text, cites, meetings.count)
    }

    static func run(_ query: SavedQuery, store: Store) async {
        var q = query
        do {
            let session: ChatSession
            if let id = q.sessionId, let s = try store.chatSessions(meetingID: nil).first(where: { $0.id == id }) {
                session = s
            } else {
                session = ChatSession(id: UUID().uuidString, meetingId: nil, title: "⟳ \(q.name)", createdAt: .now, updatedAt: .now)
                try store.saveSession(session)
                q.sessionId = session.id
            }
            let (text, cites, count) = try evidence(q, store: store)
            let period = q.periodDays == 1 ? String(localized: "today") : String(localized: "the last \(q.periodDays) days")
            try store.append(ChatMessage(sessionId: session.id, role: "user", content: "\(q.prompt)\n\n_" + String(localized: "Live query over \(period) · \(plural(count, "meeting"))") + "_"))
            let reply = count == 0
                ? "No meetings in \(period)."
                : try await LLM.current.chat(system: system + "\n\nPeriod: \(period).\nEvidence:\n" + text, user: q.prompt)
            try store.append(ChatMessage(sessionId: session.id, role: "assistant", content: reply, citations: cites))
            q.lastStatus = "ok"
        } catch {
            q.lastStatus = "error: \(error.localizedDescription)"
        }
        q.lastRunAt = .now
        q.nextRunAt = q.nextRun(after: .now)
        try? store.saveQuery(q)
    }
}

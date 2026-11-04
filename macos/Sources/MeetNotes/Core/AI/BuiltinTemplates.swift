import Foundation
import GRDB

/// Built-in "attention templates": what the summary should pay attention to.
/// Each has two parts matching the summary layout: Key Insights and Action Items.
enum BuiltinTemplates {
    struct Entry {
        let id, name, insights, actions: String
        func english(_ field: String) -> String { field == "name" ? name : field == "insights" ? insights : actions }
        /// The field in the app language (Templates.strings, keys "<id>.<field>"); English when untranslated.
        func text(_ field: String) -> String {
            Bundle.main.localizedString(forKey: "\(id).\(field)", value: english(field), table: "Templates")
        }
    }

    /// Rewrites built-in templates in the app language. Fields the user edited (not matching
    /// any shipped translation) are left alone.
    static func localize(_ db: Database) throws {
        let tables = Bundle.main.localizations
            .compactMap { Bundle.main.url(forResource: "Templates", withExtension: "strings", subdirectory: nil, localization: $0) }
            .compactMap { NSDictionary(contentsOf: $0) as? [String: String] }
        for e in all {
            guard var t = try Template.fetchOne(db, key: e.id), t.builtin else { continue }
            let old = t
            for (field, value) in [("name", \Template.name), ("insights", \.insightsPrompt), ("actions", \.actionsPrompt)] {
                let known = [e.english(field)] + tables.compactMap { $0["\(e.id).\(field)"] }
                if known.contains(t[keyPath: value]) { t[keyPath: value] = e.text(field) }
            }
            if t != old { try t.update(db) }
        }
    }

    private static let strictActions = """
        List only follow-ups a participant clearly committed to ("I'll…", "we will…", "X will…"). \
        Each item says who does what, and by when if a time was mentioned. \
        Skip suggestions, opinions, past work, and anything you are unsure about.
        """

    static let all: [Entry] = [
        Entry(id: "general", name: "General Meeting",
              insights: """
                  Give 3-6 key insights, 1-2 sentences each: decisions and why they were made, \
                  disagreements, risks, open questions and important numbers. Skip greetings and small talk.
                  """,
              actions: strictActions),
        Entry(id: "one-on-one", name: "1-on-1",
              insights: """
                  Give 2-5 insights about growth and wellbeing: feedback given or received, blockers, goals and progress, \
                  frustrations, support the person needs. Skip routine status updates.
                  """,
              actions: strictActions + " Typical: manager removes a blocker, report finishes a development step, schedule a check-in."),
        Entry(id: "client", name: "Client Call",
              insights: """
                  Give 3-6 insights about the client: their situation and pain points, goals and success criteria, \
                  stakeholders, budget and timeline constraints, objections, and what they already tried.
                  """,
              actions: strictActions + " Typical: send a proposal or documents, make introductions, get approvals, book the next call."),
        Entry(id: "sales", name: "Sales Call",
              insights: """
                  Give 3-6 insights: customer needs, decision process and budget, competitors considered, \
                  objections and how they were handled, buying signals and concerns.
                  """,
              actions: strictActions + " Typical: send a quote, set up a trial, share references, loop in stakeholders."),
        Entry(id: "tech", name: "Technical Discussion",
              insights: """
                  Give 3-6 insights: architecture and design decisions with their trade-offs, chosen tools, \
                  known risks and tech debt, unresolved technical questions, dependencies between teams.
                  """,
              actions: strictActions + " Typical: write a design doc, spike or prototype, fix a bug, review a PR."),
        Entry(id: "status", name: "Project Status / Standup",
              insights: """
                  Give 2-5 insights: progress against milestones, blockers and who can unblock them, \
                  schedule or scope changes, risks to delivery.
                  """,
              actions: strictActions),
        Entry(id: "interview", name: "Interview",
              insights: """
                  Give 3-6 insights about the candidate: relevant experience, demonstrated skills, \
                  motivation, red flags, and what their questions reveal. Skip process logistics.
                  """,
              actions: strictActions + " Typical: schedule next round, check references, send a take-home task."),
        Entry(id: "workshop", name: "Brainstorm / Workshop",
              insights: """
                  Give 3-6 insights: strongest ideas and their rationale, where the group agreed, \
                  points of debate, priorities chosen, questions that need research.
                  """,
              actions: strictActions),
        Entry(id: "lecture", name: "Lecture / Learning",
              insights: """
                  Give 4-8 insights: the main concepts explained, definitions, examples worth remembering, \
                  and references or resources mentioned.
                  """,
              actions: "List homework, readings or exercises that were assigned, if any."),
    ]
}

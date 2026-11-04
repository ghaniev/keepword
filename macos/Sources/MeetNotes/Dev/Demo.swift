import AppKit
import SwiftUI

/// Sample library for `MeetNotes --demo`: a small product team getting a release ("Atlas") out of the door.
/// All people, companies and numbers are made up.
enum Demo {
    static let chatTitle = "Where are we on the Atlas launch?"
    static let budgetEventID = "demo-budget"

    static func calendarEvents() -> [CalEvent] {
        var cal = Calendar.current
        cal.firstWeekday = 2
        let week = cal.dateInterval(of: .weekOfYear, for: .now)!.start  // Monday
        func at(_ day: Int, _ h: Double, _ len: Double, _ title: String, _ color: Color, link: Bool = false, people: [String] = []) -> CalEvent {
            let s = cal.date(byAdding: .day, value: day, to: week)!.addingTimeInterval(h * 3600)
            return CalEvent(id: "demo-\(title)-\(day)", title: title, start: s, end: s.addingTimeInterval(len * 3600), color: color,
                            calendarName: "Work", notes: link ? "Join: https://meet.google.com/abc-defg-hij" : nil, attendees: people)
        }
        var evs: [CalEvent] = []
        for d in 0..<5 { evs.append(at(d, 9.5, 0.25, "Engineering standup", .blue, link: true, people: ["Maria Garcia", "Sandra Lee"])) }
        evs += [at(0, 11, 1, "Atlas Launch: Weekly Sync", .purple, link: true, people: ["Alex Chen", "Maria Garcia", "Priya Patel", "Robert Brown"]),
                at(0, 11.5, 1, "Customer call: Brightline", .orange, link: true, people: ["Tom Becker", "Alex Chen"]),
                at(1, 14, 1.5, "Design critique", .pink, people: ["Priya Patel", "Alex Chen"]),
                at(2, 13, 0.5, "1:1 Sandra", .green, link: true, people: ["Sandra Lee"]),
                at(3, 11, 1, "Atlas Launch: Go/No-Go", .purple, link: true, people: ["Alex Chen", "Maria Garcia", "Priya Patel"]),
                at(3, 16, 1, "Sprint planning", .blue, link: true),
                at(3, 16.5, 0.5, "Interview: Backend Engineer", .red)]
        let off = cal.date(byAdding: .day, value: 4, to: week)!
        evs.append(CalEvent(id: "demo-offsite", title: "Team offsite", start: off, end: off.addingTimeInterval(86400), isAllDay: true, color: .teal))
        let soon = Calendar.current.date(bySetting: .minute, value: 0, of: .now.addingTimeInterval(3600)) ?? .now.addingTimeInterval(3600)
        evs.append(CalEvent(id: budgetEventID, title: "Q4 budget sync", start: soon, end: soon.addingTimeInterval(1800), color: .indigo,
                            notes: "https://zoom.us/j/123456789", attendees: ["Maria Garcia", "Robert Brown", "Me"]))
        return evs
    }

    /// One line of a sample transcript: who, when (seconds) and what.
    typealias Line = (speaker: String, at: Double, text: String)

    static func seed(_ store: Store) throws {
        for f in [Folder(id: "product", name: "Product", icon: "shippingbox", color: "blue"),
                  Folder(id: "eng", name: "Engineering", icon: "wrench.and.screwdriver", color: "purple"),
                  Folder(id: "daily", name: "Standups", icon: "clock", color: "gray", parentId: "eng"),
                  Folder(id: "customers", name: "Customers", icon: "briefcase", color: "green"),
                  Folder(id: "people", name: "1:1s", icon: "person.2", color: "orange")] { try store.saveFolder(f) }

        func person(_ name: String, _ email: String, _ position: String, company: String = "Atlas") throws -> String {
            var p = try store.newPerson(named: name)
            (p.email, p.position, p.company) = (email, position, company)
            try store.saveSpeaker(p)
            return p.id
        }
        let alex = try person("Alex Chen", "alex@atlas.example", "Product Manager")
        let maria = try person("Maria Garcia", "maria@atlas.example", "Engineering Manager")
        let priya = try person("Priya Patel", "priya@atlas.example", "Product Designer")
        let robert = try person("Robert Brown", "robert@atlas.example", "Finance Lead")
        let sandra = try person("Sandra Lee", "sandra@atlas.example", "Backend Engineer")
        let tom = try person("Tom Becker", "tom@brightline.example", "Head of Operations", company: "Brightline Logistics")
        let me = Speaker.meID
        let day = 86400.0

        @discardableResult
        func meeting(_ title: String, ago: Double, folder: String?, summary: String, tags: [String], lines: [Line],
                     insights: [(String, Double)], actions: [(String, String?, Double?)], notes: String = "") throws -> Meeting {
            var m = Meeting.new(title: title)
            m.createdAt = .now.addingTimeInterval(-ago)
            m.status = "done"
            m.summary = summary
            m.folderId = folder
            m.notes = notes
            let ends = lines.indices.map { i in
                min(lines[i].at + max(6, Double(lines[i].text.split(separator: " ").count) * 0.42), i + 1 < lines.count ? lines[i + 1].at - 1 : .infinity)
            }
            m.duration = (ends.last ?? 0) + 40
            try store.save(m)
            try store.db.write { db in
                for (i, l) in lines.enumerated() {
                    var s = Segment(meetingId: m.id, speakerId: l.speaker, source: l.speaker == me ? "mic" : "system",
                                    start: l.at, end: ends[i], text: l.text)
                    try s.insert(db)
                }
                for (i, x) in insights.enumerated() { var ins = Insight(meetingId: m.id, text: x.0, time: x.1, sortOrder: i); try ins.insert(db) }
                for a in actions {
                    let due = a.2.map { Calendar.current.startOfDay(for: .now).addingTimeInterval($0 * day + 17 * 3600) }
                    var item = ActionItem(meetingId: m.id, text: a.0, assignee: a.1, dueDate: due)
                    try item.insert(db)
                }
                for t in tags { try Store.attach(tag: t, to: m.id, db) }
            }
            return m
        }

        // Oldest first, so the newest meeting is the one the list opens on.
        try meeting("1:1 with Sandra – Career Development", ago: 8 * day, folder: "people",
                    summary: "Sandra wants to grow towards a tech lead role. She will own the sync engine after launch and get weekly mentoring time.",
                    tags: ["1-1s", "career"],
                    lines: [(me, 0, "How are you feeling about the last few weeks?"),
                            (sandra, 6, "Good, but busy. I'd like to lead something end to end after the launch."),
                            (me, 19, "The sync engine needs an owner. Would that be interesting?"),
                            (sandra, 27, "Yes, a lot. I'd need some time for mentoring the new hire, though."),
                            (me, 40, "Let's block an hour a week for that starting next sprint.")],
                    insights: [("Sandra wants a tech lead path and will own the sync engine after launch.", 6),
                               ("An hour a week is set aside for mentoring the new hire.", 40)],
                    actions: [("Write the sync engine ownership doc", "Sandra Lee", 9)])
        try meeting("Design Critique: Onboarding Flow", ago: 3 * day + 5 * 3600, folder: "product",
                    summary: "The new onboarding cuts setup to three steps. Testers liked it but missed the import button, which needs more weight.",
                    tags: ["atlas", "design", "onboarding"],
                    lines: [(priya, 0, "Here's the new flow: sign in, pick a template, invite your team. Three steps instead of seven."),
                            (alex, 15, "Much cleaner. How did the usability sessions go?"),
                            (priya, 22, "Mostly well. Three of eight people never found the import button on the empty screen."),
                            (me, 41, "That's the first thing people coming from other tools want to do."),
                            (priya, 50, "Agreed. I'll try making it the primary action.")],
                    insights: [("Setup goes from seven steps to three: sign in, pick a template, invite the team.", 0),
                               ("Three of eight testers missed the import button on the empty screen.", 22)],
                    actions: [("Explore import as the primary empty-state action", "Priya Patel", 4)])
        let brightline = try meeting("Customer Call: Brightline Logistics", ago: 2 * day + 3 * 3600, folder: "customers",
                    summary: "Brightline's dispatchers lose notes when the warehouse connection drops. They want to pilot Atlas offline mode with one team in December; a SharePoint export is needed for a wider rollout.",
                    tags: ["customer", "pilot", "offline mode"],
                    lines: [(tom, 0, "Our dispatchers keep losing notes when the connection drops in the warehouse."),
                            (alex, 35, "That's exactly what offline mode in Atlas fixes. Everything syncs once you're back online."),
                            (tom, 80, "Could we pilot it with one warehouse team in December?"),
                            (me, 100, "Yes. We'll set up a pilot workspace for twenty users."),
                            (tom, 150, "For a wider rollout we'd also need an export to our SharePoint.")],
                    insights: [("Dispatchers lose notes when the warehouse connection drops; offline mode addresses it.", 0),
                               ("Brightline wants a December pilot with one warehouse team of 20 users.", 80),
                               ("A SharePoint export is required before a wider rollout.", 150)],
                    actions: [("Set up a pilot workspace for 20 users", "Alex Chen", 5), ("Estimate a SharePoint export", "Maria Garcia", 8)])
        // Imported recording that was never summarized (Home → Needs Attention).
        try meeting("Vendor Demo: Analytics Platform", ago: 2 * day, folder: nil, summary: "", tags: [],
                    lines: [(robert, 0, "Thanks for joining. Let me share my screen and walk you through the dashboard."),
                            (me, 20, "Can it pull events straight from our database?")],
                    insights: [], actions: [])
        let budget = try meeting("Q4 Budget Review", ago: day + 2 * 3600, folder: "product",
                    summary: "Q4 spend is at 82% with seven weeks left, mostly from staging cloud costs. Staging will scale down at night; travel stays as planned and hiring is revisited in January.",
                    tags: ["budget", "cloud costs"],
                    lines: [(robert, 0, "We're at eighty-two percent of the Q4 budget with seven weeks left."),
                            (maria, 40, "Most of the overrun is cloud costs. Staging ran at full size all of October."),
                            (me, 90, "Can we scale staging down at night?"),
                            (maria, 105, "Yes, that alone should save around four thousand a month."),
                            (robert, 190, "Then I'd keep the travel budget as it is and revisit hiring in January.")],
                    insights: [("Q4 spend is at 82% with seven weeks left; most of the overrun is staging cloud costs.", 0),
                               ("Scaling staging down at night saves about $4k a month.", 105),
                               ("Travel stays as planned; hiring is revisited in January.", 190)],
                    actions: [("Schedule staging to scale down at night", "Maria Garcia", -1), ("Send the updated Q4 forecast", "Robert Brown", 1)])
        try meeting("Engineering Standup", ago: day - 1800, folder: "daily",
                    summary: "Offline sync bugs are down to two. Load testing waits for the new database cluster.",
                    tags: ["standup"],
                    lines: [(maria, 0, "Quick round. Sandra, how are the offline bugs?"),
                            (sandra, 5, "Down to two. Both are conflict resolution edge cases, should be done tomorrow."),
                            (maria, 18, "Great. Load testing is blocked until the new database cluster is up.")],
                    insights: [("Two offline sync bugs remain, both conflict-resolution edge cases.", 5)],
                    actions: [("Fix the remaining conflict resolution bugs", "Sandra Lee", 1)])
        let sync = try meeting("Atlas Launch: Weekly Sync", ago: 3 * 3600, folder: "product",
                    summary: "The launch stays on November 18. The new database cluster arrives on the 12th, leaving less than a week for load testing; Robert can fund extra capacity. Onboarding gets a more visible import button, and the $12 tier stays for launch.",
                    tags: ["atlas", "launch", "load testing", "pricing"],
                    lines: [(alex, 0, "Okay, let's start. The main question today is whether we can still ship Atlas on the eighteenth."),
                            (maria, 42, "Engineering is mostly on track. The sync engine is done, and we're fixing the last offline bugs this week."),
                            (me, 130, "What about the server migration? Last week that was the biggest risk."),
                            (maria, 151, "It still is. The new database cluster won't be ready until the twelfth, so we'd have less than a week of load testing."),
                            (robert, 245, "If we need extra capacity for that, I can approve it from the Q4 infrastructure budget, up to about fifteen thousand."),
                            (alex, 320, "Good. Then let's not move the date yet. Maria, can you get a load test plan together by Friday?"),
                            (maria, 348, "Yes, I'll have it by Friday."),
                            (priya, 492, "On design, the new onboarding is ready. Testers liked it, but three of eight people missed the import button."),
                            (me, 570, "Can we make import the primary action on the empty screen?"),
                            (priya, 591, "Yes, I'll update the mockups today and share them in the channel."),
                            (alex, 876, "Last thing, pricing. Are we keeping the twelve dollar tier?"),
                            (robert, 902, "Keep it for launch. We'll look at the numbers again after the first month."),
                            (me, 1300, "Okay. So the date stays the eighteenth, load test plan by Friday, onboarding fix today, and pricing stays."),
                            (alex, 1335, "Perfect. Thanks, everyone.")],
                    insights: [("The launch date stays November 18; the database cluster arrives on the 12th, leaving under a week for load testing.", 151),
                               ("Robert can fund extra load-testing capacity from the Q4 infrastructure budget, up to $15k.", 245),
                               ("3 of 8 testers missed the import button; it becomes the primary action on the empty screen.", 492),
                               ("The $12 tier stays for launch; pricing is reviewed after the first month.", 902)],
                    actions: [("Write the load test plan", "Maria Garcia", 2),
                              ("Update onboarding mockups with import as the primary action", "Priya Patel", 0),
                              ("Approve extra load-testing capacity", "Robert Brown", 5),
                              ("Review launch pricing after the first month", "Alex Chen", 30)],
                    notes: "- Date: Nov 18, unless load testing finds blockers\n- Ask Robert about the budget cap")
        try store.addBookmark(sync.id, at: 151)
        try store.addBookmark(sync.id, at: 902)

        // A slide captured at 2:31, a voice nobody has named yet and a scheduled live query.
        let img = NSImage(size: NSSize(width: 960, height: 540), flipped: false) { r in
            NSColor(calibratedRed: 0.13, green: 0.16, blue: 0.27, alpha: 1).setFill(); r.fill()
            ("Atlas Launch Plan" as NSString).draw(at: NSPoint(x: 64, y: 400), withAttributes: [.font: NSFont.systemFont(ofSize: 52, weight: .bold), .foregroundColor: NSColor.white])
            ("Nov 12   Database cluster ready\nNov 13   Load testing\nNov 18   Public launch" as NSString).draw(at: NSPoint(x: 64, y: 150),
                withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 34, weight: .regular), .foregroundColor: NSColor.white.withAlphaComponent(0.85)])
            return true
        }
        let url = FileManager.default.temporaryDirectory.appending(path: "Launch plan.png")
        if let tiff = img.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try png.write(to: url)
            _ = try store.attach(file: url, to: sync.id, recordingTime: 151)
        }
        let unknown = Speaker(id: UUID().uuidString, name: "Speaker 6", embedding: [], embeddingModel: "", createdAt: .now)
        try store.saveSpeaker(unknown)
        try store.db.write { db in
            var s = Segment(meetingId: sync.id, speakerId: unknown.id, source: "system", start: 1110, end: 1121,
                            text: "From the infrastructure side we can free up one engineer next sprint to help with load testing.")
            try s.insert(db)
        }
        try store.saveQuery(SavedQuery(id: UUID().uuidString, name: "Weekly decisions", prompt: "What did we decide this week?",
                                       schedule: "weekly", hour: 17, weekday: 6))

        // A chat across meetings, with citations into the transcripts.
        let asked = Date.now.addingTimeInterval(-20 * 60)
        let session = ChatSession(id: UUID().uuidString, meetingId: nil, title: chatTitle, createdAt: asked, updatedAt: asked)
        try store.saveSession(session)
        func cite(_ m: Meeting, _ start: Double, _ text: String) -> Citation {
            Citation(meetingId: m.id, title: m.title, start: start, end: start + 20, text: text)
        }
        try store.append(ChatMessage(sessionId: session.id, role: "user", content: "Where are we on the Atlas launch, and what's still open?", createdAt: asked))
        try store.append(ChatMessage(sessionId: session.id, role: "assistant", content: """
            The launch is still planned for **November 18** [1]. The main risk is the new database cluster: it arrives on the 12th, \
            which leaves less than a week for load testing [2]. Robert can fund extra testing capacity from the Q4 infrastructure budget, up to $15k [3].

            Still open:
            - **Load test plan**: Maria, due Friday [4]
            - **Onboarding**: Priya is making import the primary action on the empty screen [5]
            - **Staging costs**: the night-time scale-down is overdue [6]
            - **Brightline pilot**: a workspace for 20 users in December [7]
            """, citations: [cite(sync, 0, "The main question today is whether we can still ship Atlas on the eighteenth."),
                             cite(sync, 151, "The new database cluster won't be ready until the twelfth, so we'd have less than a week of load testing."),
                             cite(sync, 245, "I can approve it from the Q4 infrastructure budget, up to about fifteen thousand."),
                             cite(sync, 348, "Yes, I'll have it by Friday."),
                             cite(sync, 591, "I'll update the mockups today and share them in the channel."),
                             cite(budget, 90, "Can we scale staging down at night?"),
                             cite(brightline, 100, "We'll set up a pilot workspace for twenty users.")], createdAt: asked + 9))
        try store.saveSession(session)  // `append` moved updated_at to now
        for (title, ago) in [("What did customers ask for this month?", 2 * day), ("Summarize the Q4 budget discussions", 5 * day)] {
            let s = ChatSession(id: UUID().uuidString, meetingId: nil, title: title, createdAt: .now - ago, updatedAt: .now - ago)
            try store.saveSession(s)
        }
    }

    /// Sample AI brief for the upcoming "Q4 budget sync" (shown by `--screenshots` without calling a model).
    static let budgetBrief = """
        **Last time**
        Q4 spend was at 82% with seven weeks left, mostly from staging cloud costs. Scaling staging down at night saves about $4k a month.

        **Open action items**
        - Maria: schedule staging to scale down at night (overdue)
        - Robert: send the updated Q4 forecast (due tomorrow)

        **Worth raising**
        - Did the night-time schedule land, and what did it save?
        - Extra load-testing capacity for Atlas, up to $15k
        - The hiring plan for January
        """

    /// Live transcript lines for the recording screenshot.
    static let liveLines: [(Bool, Double, String)] = [
        (false, 4, "Let's go through the checklist. Load testing finished last night."),
        (false, 11, "No errors at twice the expected traffic. p95 latency stayed under 200 milliseconds."),
        (true, 21, "Great. Any open bugs that would block the launch?"),
        (false, 27, "One. Sync can duplicate a note if two people edit it offline at the same time. Sandra has a fix in review."),
        (true, 41, "Can it ship before Wednesday?"),
        (false, 45, "Yes, it's a small change. We'll merge it tomorrow morning."),
    ]
}

extension Demo {
    /// `MeetNotes --demo --snapshot <dir>`: walks through the main screens and renders the window into PNGs
    /// (in-process, so no Screen Recording permission is needed). For checking the layout.
    @MainActor static func snapshots(_ model: AppModel, to dir: String) {
        let steps: [(String, () -> Void)] = [
            ("1-summary", { model.section = .documents(.all); model.selectedMeeting = try? model.store.meetings(.all).first?.id; model.documentTab = .summary }),
            ("2-transcript", { model.documentTab = .transcript }),
            ("3-chat-doc", { model.documentTab = .chat }),
            ("4-home", { model.section = .home }),
            ("5-actions", { model.section = .actionItems }),
            ("6-people", { model.section = .people }),
            ("7-tags", { model.section = .tags }),
            ("8-calendar", { model.section = .calendar }),
            ("9-chat", { model.section = .chat }),
            ("10-search", { model.searchText = "server dependency" }),
            ("11-folder", { model.searchText = ""; model.section = .documents(.folder("product")) }),
            ("12-attachments", { model.section = .documents(.all); model.selectedMeeting = try? model.store.meetings(.all).first?.id; model.documentTab = .summary }),
            ("13-wizard", { model.identifyingSpeakers = model.selectedMeeting }),
            ("15-transcript-shot", { model.documentTab = .transcript }),
            ("16-welcome", { model.showWelcome = true }),
            ("17-create-task", {
                // `-demoMCP <path to kaiten dist/index.js>`: an unsaved demo server, so the sheet has real tools.
                model.showWelcome = false; model.identifyingSpeakers = nil
                guard let path = UserDefaults.standard.string(forKey: "demoMCP"), let id = model.selectedMeeting else { return }
                var s = MCPServerConfig(); s.name = "Kaiten"; s.command = "node"; s.args = [path]; s.taskTool = "kaiten_create_card"
                s.taskDefaults = ["board_id": "42"]
                model.mcpClients.servers = [s]
                let items = (try? model.store.actionItems(of: id)) ?? []
                model.taskRequest = TaskRequest(drafts: items.map { .init(item: $0, meeting: model.store.meeting(id)) }, serverID: s.id)
            }),
            ("18-settings", {
                model.taskRequest = nil
                // The app menu's "Settings…" (⌘,) item, as a user would open it.
                if let item = NSApp.mainMenu?.items.first?.submenu?.items.first(where: { $0.keyEquivalent == "," }), let action = item.action {
                    NSApp.sendAction(action, to: item.target, from: item)
                }
            }),
            ("19-permissions", { model.permissionsRequested = true }),
            ("14-overlay", { model.taskRequest = nil; model.showWelcome = false; model.identifyingSpeakers = nil; model.recordingID = model.selectedMeeting; MeetingOverlay.shared.show(model) }),
        ]
        Task {
            for _ in 0..<60 where !NSApp.windows.contains(where: { $0.isVisible && $0.frame.width > 600 }) {
                try? await Task.sleep(for: .milliseconds(250))
            }
            try? await Task.sleep(for: .seconds(1))
            for (name, step) in steps {
                step()
                try? await Task.sleep(for: .seconds(name == "17-create-task" ? 4 : 1.2))
                let window = ["13-wizard", "16-welcome", "17-create-task"].contains(name) ? NSApp.windows.first(where: { $0.isSheet && $0.isVisible })
                    : name == "14-overlay" ? NSApp.windows.first(where: { $0 is NSPanel && $0.isVisible })
                    : name == "19-permissions" ? NSApp.windows.first(where: { $0.isVisible && $0.identifier?.rawValue == "permissions" })
                    : name == "18-settings" ? NSApp.windows.first(where: { $0.isVisible && $0.identifier?.rawValue.contains("Settings") == true || $0.identifier?.rawValue.contains("settings") == true })
                    : NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.width > 600 })
                guard let view = name == "18-settings" ? window?.contentView?.superview : window?.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(filePath: dir).appending(path: "\(name).png"))
            }
            exit(0)
        }
    }
}

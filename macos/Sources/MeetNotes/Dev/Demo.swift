import AppKit
import SwiftUI

/// Sample library for `MeetNotes --demo`.
enum Demo {
    static func calendarEvents() -> [CalEvent] {
        let cal = Calendar.current
        let week = cal.dateInterval(of: .weekOfYear, for: .now)!.start
        func at(_ day: Int, _ h: Double, _ len: Double, _ title: String, _ color: Color, link: Bool = false, people: [String] = []) -> CalEvent {
            let s = cal.date(byAdding: .day, value: day, to: week)!.addingTimeInterval(h * 3600)
            return CalEvent(id: "demo-\(title)-\(day)", title: title, start: s, end: s.addingTimeInterval(len * 3600), color: color,
                            calendarName: "Work", notes: link ? "Join: https://meet.google.com/abc-defg-hij" : nil, attendees: people)
        }
        var evs: [CalEvent] = []
        for d in 0..<5 { evs.append(at(d, 9.5, 0.25, "Daily standup", .blue, link: true, people: ["Maria Garcia", "Alex Chen"])) }
        evs += [at(0, 11, 1, "Roadmap review", .purple, link: true, people: ["Alex Chen", "Robert Brown"]),
                at(0, 11.5, 1, "Customer call: Acme", .orange, link: true),
                at(1, 14, 1.5, "Design critique", .pink),
                at(2, 13, 0.5, "1:1 Sandra", .green, link: true, people: ["Sandra"]),
                at(3, 16, 1, "Sprint planning", .blue, link: true),
                at(3, 16.5, 0.5, "Interview", .red)]
        let off = cal.date(byAdding: .day, value: 4, to: week)!
        evs.append(CalEvent(id: "demo-offsite", title: "Team offsite", start: off, end: off.addingTimeInterval(86400), isAllDay: true, color: .teal))
        let soon = Date.now.addingTimeInterval(3600)
        evs.append(CalEvent(id: "demo-soon", title: "Q4 budget sync", start: soon, end: soon.addingTimeInterval(1800), color: .indigo,
                            notes: "https://zoom.us/j/123456789", attendees: ["Maria Garcia", "Robert Brown", "Me"]))
        return evs
    }

    static func seed(_ store: Store) throws {
        let team = Folder(id: "team", name: "Team", icon: "❤️", color: "red")
        let eng = Folder(id: "eng", name: "Engineering", icon: "wrench.and.screwdriver", color: "blue")
        let daily = Folder(id: "daily", name: "Daily", icon: "clock", color: "gray", parentId: "team")
        for f in [team, eng, daily] { try store.saveFolder(f) }
        let maria = try store.newPerson(named: "Maria Garcia"), robert = try store.newPerson(named: "Robert Brown")
        let alex = try store.newPerson(named: "Alex Chen")

        func meeting(_ title: String, daysAgo: Double, folder: String?, summary: String, tags: [String],
                     lines: [(Speaker.ID, String)], insights: [(String, Double)], actions: [(String, String?)]) throws {
            var m = Meeting.new(title: title)
            m.createdAt = .now.addingTimeInterval(-daysAgo * 86400)
            m.status = "done"
            m.summary = summary
            m.folderId = folder
            m.duration = Double(lines.count) * 25
            try store.save(m)
            try store.db.write { db in
                for (i, l) in lines.enumerated() {
                    var s = Segment(meetingId: m.id, speakerId: l.0, source: l.0 == Speaker.meID ? "mic" : "system",
                                    start: Double(i) * 25, end: Double(i) * 25 + 22, text: l.1)
                    try s.insert(db)
                }
                for (i, x) in insights.enumerated() { var ins = Insight(meetingId: m.id, text: x.0, time: x.1, sortOrder: i); try ins.insert(db) }
                for a in actions {
                    var item = ActionItem(meetingId: m.id, text: a.0, assignee: a.1, dueDate: .now.addingTimeInterval(86400))
                    try item.insert(db)
                }
                for t in tags { try Store.attach(tag: t, to: m.id, db) }
            }
            try store.addBookmark(m.id, at: 50)
        }

        try meeting("Critical Dependencies & Resource Reallocation", daysAgo: 0, folder: "daily",
                    summary: "The team reviewed blocked tasks after a reassignment and agreed to involve the infrastructure group to unblock the server dependency.",
                    tags: ["ci/cd improvements", "kubernetes", "q1 engineering offsite"],
                    lines: [(maria.id, "Okay, thanks again. Yesterday I started the discussions for the interfacing zone environment."),
                            (robert.id, "We had some issues with Joel's tasks, so they were reassigned to a new person."),
                            (alex.id, "The server dependency is about two months out, that's the real bottleneck."),
                            (Speaker.meID, "Let's follow up after this meeting and loop in the infrastructure team."),
                            (maria.id, "I will finish the interfacing zone discussions by tomorrow.")],
                    insights: [("A delay is caused by Joel's tasks being reassigned; a new team member is joining, which may impact the timeline.", 25),
                               ("Alex identified a two-month server dependency as the main external bottleneck.", 50),
                               ("The infrastructure group must be involved to find the right resource.", 75)],
                    actions: [("Finish the interfacing zone discussions", "Maria Garcia"), ("Write automated tests once the code is complete", "Robert Brown")])
        // A screenshot taken at 1:00, an unidentified voice and a live query.
        if let first = try store.meetings(.all).first {
            let img = NSImage(size: NSSize(width: 640, height: 360), flipped: false) { r in
                NSColor.systemBlue.withAlphaComponent(0.15).setFill(); r.fill()
                ("Q3 Infrastructure Plan\n• Server migration\n• Staffing" as NSString).draw(at: NSPoint(x: 40, y: 200),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 34, weight: .semibold)])
                return true
            }
            let url = FileManager.default.temporaryDirectory.appending(path: "Slide.png")
            if let tiff = img.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try png.write(to: url)
                try store.attach(file: url, to: first.id, recordingTime: 60)
            }
            let unknown = Speaker(id: UUID().uuidString, name: "Speaker 4", embedding: [], embeddingModel: "", createdAt: .now)
            try store.saveSpeaker(unknown)
            try store.db.write { db in
                var s = Segment(meetingId: first.id, speakerId: unknown.id, source: "system", start: 130, end: 140,
                                text: "From the infra side we can free up one engineer next sprint.")
                try s.insert(db)
            }
            try store.saveQuery(SavedQuery(id: UUID().uuidString, name: "Weekly decisions", prompt: "What did we decide this week?",
                                           schedule: "weekly", hour: 17, weekday: 6))
        }
        try meeting("Q1 Roadmap Prioritization", daysAgo: 3, folder: "eng",
                    summary: "Redesign of the dashboard with task overview and recent activity was prioritized for Q1.",
                    tags: ["saas", "data aggregation layer", "enterprise customers", "roadmap"],
                    lines: [(alex.id, "The dashboard redesign should come first, customers keep asking for it."),
                            (Speaker.meID, "Agreed. What about the data aggregation layer?"),
                            (alex.id, "That can wait until February.")],
                    insights: [("Dashboard redesign is the top Q1 priority, driven by enterprise customer requests.", 0)],
                    actions: [("Draft the dashboard redesign spec", "Alex Chen")])
        try meeting("1:1 with Sandra – Career Development", daysAgo: 8, folder: "team",
                    summary: "Discussed growth towards a tech lead role and a plan for mentoring.",
                    tags: ["1-1s", "career"],
                    lines: [(Speaker.meID, "How do you feel about leading the next project?"), (maria.id, "I'd love to, but I need more time for mentoring.")],
                    insights: [("Sandra wants a tech lead path and asked for mentoring time.", 0)], actions: [])
    }
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
            ("11-folder", { model.searchText = ""; model.section = .documents(.folder("team")) }),
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

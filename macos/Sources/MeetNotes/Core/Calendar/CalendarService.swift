import AppKit
import EventKit
import SwiftUI

/// One calendar event, whether it comes from macOS calendars (EventKit) or an imported Google/iCal feed.
struct CalEvent: Identifiable, Hashable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var color: Color
    var calendarName: String
    var location: String?
    var notes: String?
    var url: URL?
    var attendees: [String]

    init(id: String, title: String, start: Date, end: Date, isAllDay: Bool = false, color: Color = .blue,
         calendarName: String = "", location: String? = nil, notes: String? = nil, url: URL? = nil, attendees: [String] = []) {
        (self.id, self.title, self.start, self.end, self.isAllDay, self.color) = (id, title, start, end, isAllDay, color)
        (self.calendarName, self.location, self.notes, self.url, self.attendees) = (calendarName, location, notes, url, attendees)
    }

    init(_ e: EKEvent) {
        self.init(id: e.eventIdentifier ?? UUID().uuidString, title: e.title ?? "Untitled", start: e.startDate, end: e.endDate,
                  isAllDay: e.isAllDay, color: Color(cgColor: e.calendar.cgColor), calendarName: e.calendar.title,
                  location: e.location, notes: e.notes, url: e.url,
                  attendees: (e.attendees ?? []).compactMap { $0.name ?? $0.url.absoluteString.replacingOccurrences(of: "mailto:", with: "") })
    }

    /// Zoom / Meet / Teams / … link found in the event's URL, location or notes.
    var videoLink: URL? {
        let text = [url?.absoluteString, location, notes].compactMap { $0 }.joined(separator: " ")
        let pattern = #"https?://[^\s<>"]*(zoom\.us|meet\.google\.com|teams\.microsoft\.com|teams\.live\.com|webex\.com|whereby\.com|meet\.jit\.si|telemost\.yandex)[^\s<>"]*"#
        guard let r = text.range(of: pattern, options: .regularExpression) else { return nil }
        return URL(string: String(text[r]))
    }
}

/// An imported calendar feed: Google Calendar's "Secret address in iCal format" (or any .ics URL).
/// The URL is a credential, so it lives in the Keychain; only name and color are in preferences.
struct CalendarFeed: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var colorHex: String
    var url: String { Keychain.get("calendarFeed.\(id)") }
}

@MainActor
final class CalendarService: ObservableObject {
    private(set) var store = EKEventStore()
    @Published var status = EKEventStore.authorizationStatus(for: .event)
    @Published var events: [CalEvent] = []  // the visible window (calendar page)
    @Published var upcoming: [CalEvent] = []  // now … end of tomorrow (Home, prompts, menu bar)
    @Published var feeds: [CalendarFeed] = []
    @Published var feedErrors: [String: String] = [:]
    private var feedEvents: [String: [CalEvent]] = [:]
    private var window = DateInterval(start: Calendar.current.startOfDay(for: .now).addingTimeInterval(-7 * 86400), duration: 35 * 86400)
    private var observer: NSObjectProtocol?
    private var feedTimer: Timer?
    private var demo = false

    var authorized: Bool { status == .fullAccess }
    var canRead: Bool { authorized || !feeds.isEmpty || !feedEvents.isEmpty }

    init() {
        feeds = (try? JSONDecoder().decode([CalendarFeed].self, from: UserDefaults.standard.data(forKey: "calendarFeeds") ?? Data())) ?? []
        // Calendar.app, iCloud or Google sync changed something: reload.
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        feedTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshFeeds() }
        }
        Task { await refreshFeeds() }
    }

    /// Asks once; if the user said no before, macOS won't ask again — send them to Privacy settings instead.
    func requestAccess() async {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined:
            _ = try? await store.requestFullAccessToEvents()
            store = EKEventStore()  // a store created before the grant can stay empty
        case .fullAccess: break
        default:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
        }
        status = EKEventStore.authorizationStatus(for: .event)
        refresh()
    }

    /// Sample events for `--demo`. They replace the Mac's calendars and feeds, so no real event shows up in a demo or a screenshot.
    func useDemoEvents(_ events: [CalEvent]) {
        demo = true
        feedEvents = ["demo": events]
        refresh()
    }

    func show(_ interval: DateInterval) {
        window = interval
        refresh()
    }

    func refresh() {
        status = EKEventStore.authorizationStatus(for: .event)
        let today = Calendar.current.startOfDay(for: .now)
        let soon = DateInterval(start: today, end: today.addingTimeInterval(2 * 86400))
        func load(_ i: DateInterval) -> [CalEvent] {
            var out: [CalEvent] = []
            if authorized && !demo {
                let hidden = Set(UserDefaults.standard.stringArray(forKey: "hiddenCalendars") ?? [])
                let cals = store.calendars(for: .event).filter { !hidden.contains($0.calendarIdentifier) }
                if !cals.isEmpty {
                    out += store.events(matching: store.predicateForEvents(withStart: i.start, end: i.end, calendars: cals)).map(CalEvent.init)
                }
            }
            out += (demo ? feedEvents["demo"] ?? [] : Array(feedEvents.values.joined())).filter { $0.end > i.start && $0.start < i.end }
            // The same meeting can arrive from macOS and from a feed; keep one.
            var seen = Set<String>()
            return out.filter { seen.insert("\($0.title)|\(Int($0.start.timeIntervalSince1970))").inserted }
                .sorted { $0.start < $1.start }
        }
        events = load(window)
        upcoming = load(soon).filter { !$0.isAllDay && $0.end > .now }
    }

    // MARK: Google Calendar / iCal feeds

    func addFeed(name: String, url: String) async -> String? {
        var u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if u.hasPrefix("webcal://") { u = "https://" + u.dropFirst("webcal://".count) }
        guard let parsed = URL(string: u), parsed.scheme == "https" else { return "Paste the https:// address (Google: Settings → your calendar → Secret address in iCal format)." }
        let feed = CalendarFeed(id: UUID().uuidString, name: name.isEmpty ? "Google Calendar" : name, colorHex: "#4285F4")
        do {
            _ = try await Self.fetch(parsed, feed: feed)
        } catch {
            return "Could not read this calendar: \(error.localizedDescription)"
        }
        Keychain.set("calendarFeed.\(feed.id)", u)
        feeds.append(feed)
        saveFeeds()
        await refreshFeeds()
        return nil
    }

    func removeFeed(_ f: CalendarFeed) {
        Keychain.set("calendarFeed.\(f.id)", "")
        feeds.removeAll { $0.id == f.id }
        feedEvents[f.id] = nil
        saveFeeds()
        refresh()
    }

    private func saveFeeds() { UserDefaults.standard.set(try? JSONEncoder().encode(feeds), forKey: "calendarFeeds") }

    func refreshFeeds() async {
        for f in feeds {
            guard let url = URL(string: f.url) else { continue }
            do {
                feedEvents[f.id] = try await Self.fetch(url, feed: f)
                feedErrors[f.id] = nil
            } catch {
                feedErrors[f.id] = error.localizedDescription  // keep the last good copy
            }
        }
        refresh()
    }

    private static func fetch(_ url: URL, feed: CalendarFeed) async throws -> [CalEvent] {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw LLMError(message: "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        let text = String(decoding: data, as: UTF8.self)
        guard text.contains("BEGIN:VCALENDAR") else { throw LLMError(message: "Not an iCal calendar") }
        let now = Date.now
        return ICS.parse(text, calendarName: feed.name, color: Color(hex: feed.colorHex),
                         from: now.addingTimeInterval(-90 * 86400), to: now.addingTimeInterval(365 * 86400))
    }

    // MARK: Reminders

    /// Sends open action items to the default Reminders list.
    func sendToReminders(_ items: [ActionItem], meetingTitle: String) async throws -> Int {
        guard try await store.requestFullAccessToReminders() else { throw LLMError(message: "Reminders access denied.") }
        guard let list = store.defaultCalendarForNewReminders() else {
            throw LLMError(message: "No Reminders list is available. Open the Reminders app to create one.")
        }
        var sent = 0
        for item in items where !item.completed {
            let r = EKReminder(eventStore: store)
            r.calendar = list
            r.title = item.text
            r.notes = "From: \(meetingTitle)" + (item.assignee.map { "\nAssignee: \($0)" } ?? "")
            if let due = item.dueDate { r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day], from: due) }
            try store.save(r, commit: false)
            sent += 1
        }
        try store.commit()
        return sent
    }
}

import SwiftUI

struct CalendarSettings: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var calendar: CalendarService
    @AppStorage("promptForCalendarMeetings") private var prompt = true
    @State private var hidden = Set(UserDefaults.standard.stringArray(forKey: "hiddenCalendars") ?? [])
    @State private var showConnect = false

    init(calendar: CalendarService) { self.calendar = calendar }

    var body: some View {
        Form {
            Section("macOS Calendars") {
                switch calendar.status {
                case .fullAccess: Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .notDetermined: Button("Allow Calendar Access") { Task { await calendar.requestAccess() } }
                default:
                    Label("Access is off", systemImage: "xmark.circle.fill").foregroundStyle(.red)
                    Button("Open Privacy Settings") { Task { await calendar.requestAccess() } }
                }
                Button("Open Internet Accounts (add Google, Exchange…)") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension")!)
                }
                Toggle("Offer to record meetings with a video link when they start", isOn: $prompt)
            }
            if calendar.authorized {
                Section("Select Calendars") {
                    ForEach(calendar.store.calendars(for: .event), id: \.calendarIdentifier) { cal in
                        Toggle(isOn: Binding(get: { !hidden.contains(cal.calendarIdentifier) }, set: { on in
                            if on { hidden.remove(cal.calendarIdentifier) } else { hidden.insert(cal.calendarIdentifier) }
                            UserDefaults.standard.set(Array(hidden), forKey: "hiddenCalendars")
                            calendar.refresh()
                        })) {
                            HStack { Circle().fill(Color(cgColor: cal.cgColor)).frame(width: 9); Text(cal.title); Text(cal.source.title).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            Section("Imported Google Calendars") {
                ForEach(calendar.feeds) { f in
                    HStack {
                        Circle().fill(Color(hex: f.colorHex)).frame(width: 9)
                        Text(f.name)
                        if let err = calendar.feedErrors[f.id] { Text(err).font(.caption).foregroundStyle(.red).lineLimit(1) }
                        Spacer()
                        Button("Remove", role: .destructive) { calendar.removeFeed(f) }
                    }
                }
                HStack {
                    Button("Import Google Calendar…") { showConnect = true }
                    if !calendar.feeds.isEmpty { Button("Refresh Now") { Task { await calendar.refreshFeeds() } } }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showConnect) { ConnectGoogleSheet(calendar: calendar) }
    }
}

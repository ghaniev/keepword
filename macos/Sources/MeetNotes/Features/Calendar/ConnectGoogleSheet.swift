import SwiftUI

/// Two ways to bring Google Calendar in: the macOS account (full sync, attendees) or the secret iCal address.
struct ConnectGoogleSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var calendar: CalendarService
    @State private var name = "Google Calendar"
    @State private var url = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect Google Calendar").font(.title2.weight(.semibold))
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Add your Google account to macOS (recommended)", systemImage: "person.crop.circle.badge.checkmark").font(.headline)
                    Text("All your calendars with attendees, kept in sync by macOS. System Settings → Internet Accounts → Google → turn on Calendars.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Open Internet Accounts") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension")!)
                        }
                        if !calendar.authorized { Button("Allow Calendar Access") { Task { await calendar.requestAccess() } } }
                    }
                }
                .padding(6).frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Or import with the secret iCal address", systemImage: "link").font(.headline)
                    Text("Google Calendar on the web → Settings → your calendar → Integrate calendar → copy “Secret address in iCal format”. Read-only; Keepword refreshes it every 15 minutes. Keep the address private — it's stored in your Keychain.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Open Google Calendar Settings") { NSWorkspace.shared.open(URL(string: "https://calendar.google.com/calendar/r/settings")!) }
                        .buttonStyle(.link)
                    TextField("Name", text: $name)
                    TextField("https://calendar.google.com/calendar/ical/…/private-…/basic.ics", text: $url)
                    if let error { Text(error).font(.caption).foregroundStyle(.red) }
                    HStack {
                        Spacer()
                        if busy { ProgressView().controlSize(.small) }
                        Button("Import") {
                            busy = true
                            Task {
                                error = await calendar.addFeed(name: name, url: url)
                                busy = false
                                if error == nil { dismiss() }
                            }
                        }
                        .buttonStyle(.borderedProminent).disabled(url.isEmpty || busy)
                    }
                }
                .padding(6).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack { Spacer(); Button("Done") { dismiss() } }
        }
        .padding(22).frame(width: 560)
    }
}

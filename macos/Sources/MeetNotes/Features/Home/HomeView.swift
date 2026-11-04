import SwiftUI

struct HomeView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var calendar: CalendarService
    @State private var recent: [Meeting] = []
    @State private var due: [(ActionItem, Meeting)] = []
    @State private var attention: [AttentionItem] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Text(greeting).font(.system(size: 24, weight: .semibold))
                section("Upcoming Meetings", icon: "calendar") {
                    if !calendar.canRead {
                        HStack {
                            Text("Connect your calendar to see your schedule").foregroundStyle(.secondary)
                            Button("Connect Calendar") { model.section = .calendar }
                        }
                    } else if calendar.upcoming.isEmpty {
                        Text("Nothing scheduled for today or tomorrow").foregroundStyle(.secondary)
                    } else {
                        ForEach(calendar.upcoming) { UpcomingMeetingRow(event: $0) }
                    }
                }
                section("Needs Attention", icon: "exclamationmark.circle") {
                    if due.isEmpty && attention.isEmpty {
                        Text("Nothing needs your attention.").foregroundStyle(.secondary)
                    } else {
                        ForEach(attention) { AttentionRow(item: $0) }
                        ForEach(due, id: \.0.id) { a, m in ActionItemRow(item: a, meetingTitle: m.title) }
                    }
                }
                section("Recent Documents", icon: "doc.text") {
                    if recent.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Record Your First Call").font(.headline)
                            Text("Press Record (⌘R) when a call starts. Keepword captures your microphone and the other participants through system audio — no bot joins the call.")
                                .foregroundStyle(.secondary)
                            Button { model.startRecording() } label: { Label("Start Recording", systemImage: "record.circle") }
                        }
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12)], spacing: 12) {
                            ForEach(recent) { m in
                                Card {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(m.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                        Text("\(m.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(durationLabel(m.duration))")
                                            .font(.caption).foregroundStyle(.secondary)
                                        Text(m.status == "done" ? m.summary : m.statusLabel).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 70, alignment: .topLeading)
                                }
                                .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.035)))
                                .onTapGesture { model.open(m.id) }
                            }
                        }
                    }
                }
            }
            .padding(28).frame(maxWidth: 980, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: model.revision) {
            recent = Array(((try? model.store.meetings(.all)) ?? []).prefix(6))
            let soon = Calendar.current.startOfDay(for: .now).addingTimeInterval(3 * 86400)
            due = ((try? model.store.allActionItems()) ?? []).filter { !$0.0.completed && ($0.0.dueDate.map { $0 < soon } ?? false) }
                .sorted { $0.0.dueDate! < $1.0.dueDate! }
            attention = AttentionItem.find(in: model.store)
        }
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: .now)
        return h < 12 ? String(localized: "Good morning") : h < 18 ? String(localized: "Good afternoon") : String(localized: "Good evening")
    }

    private func section<C: View>(_ title: LocalizedStringKey, icon: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).font(.system(size: 14, weight: .semibold))
            content()
        }
    }
}

struct UpcomingMeetingRow: View {
    @EnvironmentObject var model: AppModel
    let event: CalEvent

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2).fill(event.color).frame(width: 4, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).font(.system(size: 13, weight: .medium))
                Text("\(Calendar.current.isDateInToday(event.start) ? String(localized: "Today") : String(localized: "Tomorrow")) \(event.start.hhmm)–\(event.end.hhmm)"
                     + (event.attendees.isEmpty ? "" : " · \(plural(event.attendees.count, "attendee"))"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            MeetingBriefButton(event: event)
            if let link = event.videoLink {
                Button("Join & Record") { NSWorkspace.shared.open(link); model.startRecording(event: event) }
                    .disabled(model.recordingID != nil)
            }
            Button("Record") { model.startRecording(event: event) }.disabled(model.recordingID != nil)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.035)))
    }
}

import SwiftUI

struct EventDetail: View {
    @EnvironmentObject var model: AppModel
    let event: CalEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle().fill(event.color).frame(width: 9, height: 9)
                Text(event.title).font(.headline)
            }
            Label(event.isAllDay ? event.start.formatted(date: .complete, time: .omitted)
                  : "\(event.start.formatted(date: .abbreviated, time: .shortened)) – \(event.end.hhmm)", systemImage: "clock")
            if !event.calendarName.isEmpty { Label(event.calendarName, systemImage: "calendar").foregroundStyle(.secondary) }
            if let loc = event.location, !loc.isEmpty { Label(loc, systemImage: "mappin").lineLimit(2) }
            if !event.attendees.isEmpty {
                Text("Attendees").font(.caption).foregroundStyle(.secondary)
                FlowLayout { ForEach(event.attendees.prefix(12), id: \.self) { PersonChip(name: $0) } }
            }
            if let linked = (try? model.store.meetings(.all))?.first(where: { $0.eventId == event.id }) {
                Button { model.open(linked.id) } label: { Label("Open linked document", systemImage: "doc.text") }
            }
            HStack {
                if let link = event.videoLink {
                    Button("Join") { NSWorkspace.shared.open(link) }
                    Button("Join & Record") { NSWorkspace.shared.open(link); model.startRecording(event: event) }.disabled(model.recordingID != nil)
                }
                Button("Record") { model.startRecording(event: event) }.disabled(model.recordingID != nil)
            }
        }
        .font(.system(size: 12.5)).padding(16).frame(width: 320, alignment: .leading)
    }
}

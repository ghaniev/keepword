import SwiftUI

/// Popover with what to know before a meeting: an AI brief on request, earlier meetings and their open items.
struct MeetingBriefView: View {
    @EnvironmentObject var model: AppModel
    let event: CalEvent
    let brief: MeetingBrief
    @State private var writing = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(event.title).font(.headline)
                if let text = model.briefs[event.id] {
                    MarkdownText(text: text).textSelection(.enabled)
                } else {
                    Button { write() } label: {
                        Label(writing ? String(localized: "Writing brief…") : String(localized: "Write AI Brief"), systemImage: "sparkles")
                    }
                    .disabled(writing)
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                VStack(alignment: .leading, spacing: 6) {
                    SectionTitle(title: "Earlier Meetings", count: "\(brief.related.count)")
                    ForEach(brief.related) { m in
                        Button { model.open(m.id) } label: {
                            HStack {
                                Image(systemName: "doc.text").foregroundStyle(.secondary)
                                Text(m.title).lineLimit(1)
                                Spacer()
                                Text(m.createdAt.formatted(date: .abbreviated, time: .omitted)).foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                if !brief.openItems.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionTitle(title: "Open Action Items", count: "\(brief.openItems.count)")
                        ForEach(brief.openItems, id: \.0.id) { a, m in ActionItemRow(item: a, meetingTitle: m.title) }
                    }
                }
            }
            .font(.system(size: 12.5)).padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 440, height: 460)
    }

    private func write() {
        writing = true
        error = nil
        Task {
            do { model.briefs[event.id] = try await brief.write(for: event, store: model.store) } catch { self.error = error.localizedDescription }
            writing = false
        }
    }
}

/// "Brief" button for an upcoming meeting; hidden when there is nothing earlier to brief from.
struct MeetingBriefButton: View {
    @EnvironmentObject var model: AppModel
    let event: CalEvent
    @State private var brief: MeetingBrief?
    @State private var showing = false

    var body: some View {
        // A stack, not a Group: an empty Group has no lifetime of its own, so its task would never run.
        HStack(spacing: 0) {
            if let brief, !brief.isEmpty {
                Button { showing = true } label: { Label("Brief", systemImage: "text.page") }
                    .help("\(plural(brief.related.count, "earlier meeting")) · \(plural(brief.openItems.count, "open action item"))")
                    .popover(isPresented: $showing, arrowEdge: .bottom) { MeetingBriefView(event: event, brief: brief) }
            }
        }
        .task(id: "\(event.id)-\(model.revision)") { brief = MeetingBrief.build(for: event, store: model.store) }
    }
}

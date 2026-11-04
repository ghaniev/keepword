import SwiftUI

struct SummaryTab: View {
    @EnvironmentObject var model: AppModel
    let meeting: Meeting
    @State private var people: [Speaker] = []
    @State private var tags: [Tag] = []
    @State private var insights: [Insight] = []
    @State private var items: [ActionItem] = []
    @State private var similar: [(Meeting, Double)] = []
    @State private var notes = ""
    @State private var newTag = ""
    @State private var newItem = ""
    @State private var addingTag = false
    @State private var unnamed: [Speaker] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                statusBanner
                if !people.isEmpty || !tags.isEmpty || meeting.status == "done" {
                    VStack(alignment: .leading, spacing: 8) {
                        if !people.isEmpty {
                            FlowLayout { ForEach(people) { p in PersonChip(name: p.name).onTapGesture { model.selectedPerson = p.id; model.section = .people } } }
                        }
                        FlowLayout {
                            ForEach(tags) { t in TagChip(name: t.name) { try? model.store.removeTag(t.id, from: meeting.id) } }
                            if addingTag {
                                TextField("tag", text: $newTag).textFieldStyle(.roundedBorder).frame(width: 110).font(.caption)
                                    .onSubmit { try? model.store.addTag(newTag, to: meeting.id); newTag = ""; addingTag = false }
                            } else {
                                Button { addingTag = true } label: { Label("Add tag", systemImage: "plus").font(.caption) }.buttonStyle(.plain).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if !meeting.summary.isEmpty {
                    Text(meeting.summary).font(.system(size: 13)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                if !insights.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionTitle(title: "Key Insights", count: "\(insights.count)")
                        ForEach(insights) { i in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("•").foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(i.text).font(.system(size: 13)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                    if let t = i.time { TimeChip(seconds: t) { model.open(meeting.id, at: t) } }
                                }
                            }
                        }
                    }
                }
                actionItems
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        SectionTitle(title: "Notes")
                        Spacer()
                        if let server = model.mcpClients.taskServers.first, !notes.isEmpty {
                            Button {
                                model.taskRequest = TaskRequest(drafts: [.init(title: meeting.title, details: notes + "\n\nmeetnotes://open?id=\(meeting.id)")], serverID: server.id)
                            } label: { Label("Create Task…", systemImage: "arrow.up.forward.app") }
                            .buttonStyle(.borderless).font(.caption)
                        }
                    }
                    TextEditor(text: $notes).font(.system(size: 13)).frame(minHeight: 70)
                        .scrollContentBackground(.hidden).padding(6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                        .overlay(alignment: .topLeading) {
                            if notes.isEmpty { Text("Jot down notes during the meeting…").foregroundStyle(.tertiary).padding(11).allowsHitTesting(false) }
                        }
                        .onChange(of: notes) { _, new in if new != meeting.notes { try? model.store.update(meeting.id) { $0.notes = new } } }
                }
                AttachmentsSection(meetingID: meeting.id)
                if !similar.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionTitle(title: "Similar Documents")
                        ForEach(similar, id: \.0.id) { m, score in
                            Button { model.open(m.id) } label: {
                                HStack {
                                    Image(systemName: "doc.text").foregroundStyle(.secondary)
                                    Text(m.title).lineLimit(1)
                                    Text(m.createdAt.formatted(date: .abbreviated, time: .omitted)).foregroundStyle(.secondary)
                                    Spacer()
                                    Text("\(Int(score * 100))%").font(.caption).foregroundStyle(.orange)
                                }
                                .font(.system(size: 12.5)).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, 22).padding(.bottom, 24).padding(.top, 6)
            .readableColumn()
        }
        .task(id: model.revision) {
            people = (try? model.store.participants(of: meeting.id)) ?? []
            tags = (try? model.store.tags(of: meeting.id)) ?? []
            insights = (try? model.store.insights(of: meeting.id)) ?? []
            items = (try? model.store.actionItems(of: meeting.id)) ?? []
            if notes != meeting.notes && notes.isEmpty { notes = meeting.notes }
            similar = (try? Pipeline.similar(to: meeting.id, store: model.store)) ?? []
            unnamed = (try? model.store.unnamedSpeakers(in: meeting.id)) ?? []
        }
        .onAppear { notes = meeting.notes }
    }

    @ViewBuilder private var statusBanner: some View {
        if meeting.id == model.recordingID {
            banner(icon: "record.circle", color: .red, text: "Recording in progress. Insights and action items appear after the call.")
        } else if meeting.isProcessing || meeting.status == "queued" {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(meeting.statusLabel).foregroundStyle(.secondary) }
        } else if meeting.status.hasPrefix("error") {
            VStack(alignment: .leading, spacing: 8) {
                banner(icon: "exclamationmark.triangle.fill", color: .orange, text: "\(meeting.statusLabel)")
                HStack {
                    Button("Retry Transcription") { try? model.store.setStatus(meeting.id, "queued"); model.enqueue(meeting.id) }
                    Button("Retry Summary") { model.enqueue(meeting.id, regenerateOnly: true) }
                }
            }
        } else if meeting.status == "awaiting:speakers" || !unnamed.isEmpty && meeting.status == "done" {
            HStack {
                banner(icon: "person.wave.2", color: .blue,
                       text: meeting.status == "awaiting:speakers" ? "\(meeting.statusLabel)" : "\(plural(unnamed.count, "new speaker")) in this meeting.")
                Button("Identify Speakers") { model.identifyingSpeakers = meeting.id }
            }
        }
        if meeting.status == "done" && insights.isEmpty && items.isEmpty && meeting.summary.isEmpty {
            Button { model.enqueue(meeting.id, regenerateOnly: true) } label: { Label("Generate Summary", systemImage: "sparkles") }
        }
    }

    private func banner(icon: String, color: Color, text: LocalizedStringKey) -> some View {
        Label { Text(text).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: icon).foregroundStyle(color) }
            .font(.system(size: 12.5)).padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.08)))
    }

    @ViewBuilder private var actionItems: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionTitle(title: "Action Items", count: items.isEmpty ? nil : "\(items.filter(\.completed).count)/\(items.count)")
                Spacer()
                if !items.isEmpty {
                    if let server = model.mcpClients.taskServers.first {
                        Button {
                            model.taskRequest = TaskRequest(drafts: items.filter { !$0.completed && $0.taskRef == nil }.map { .init(item: $0, meeting: meeting) }, serverID: server.id)
                        } label: { Label("Create Tasks…", systemImage: "arrow.up.forward.app") }
                        .buttonStyle(.borderless).font(.caption)
                        .disabled(!items.contains { !$0.completed && $0.taskRef == nil })
                    }
                    Button { sendToReminders() } label: { Label("Send to Reminders", systemImage: "checklist") }
                        .buttonStyle(.borderless).font(.caption)
                }
            }
            ForEach(items) { a in ActionItemRow(item: a) }
            TextField("Add action item, e.g. “Send the deck tomorrow @Anna”", text: $newItem).textFieldStyle(.plain).font(.system(size: 12.5)).foregroundStyle(.secondary)
                .onSubmit {
                    guard !newItem.isEmpty else { return }
                    let t = TaskText.parse(newItem)
                    let assignee = t.assignee.map { TaskText.resolve($0, among: people.map(\.name)) }
                    try? model.store.saveActionItem(ActionItem(meetingId: meeting.id, text: t.text, assignee: assignee, dueDate: t.dueDate))
                    newItem = ""
                }
                .padding(.leading, 22)
        }
    }

    private func sendToReminders() {
        Task {
            do {
                let n = try await model.calendar.sendToReminders(items, meetingTitle: meeting.title)
                model.toast = String(localized: "Sent \(n) item(s) to Reminders")
            } catch { model.toast = error.localizedDescription }
        }
    }
}

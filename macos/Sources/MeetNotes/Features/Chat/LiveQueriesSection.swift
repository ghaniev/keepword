import SwiftUI

/// "LIVE QUERIES" block at the top of the chat sessions column.
struct LiveQueriesSection: View {
    @EnvironmentObject var model: AppModel
    @State private var queries: [SavedQuery] = []
    @State private var editing: SavedQuery?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("LIVE QUERIES").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { editing = SavedQuery(id: UUID().uuidString, name: "", prompt: "") } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("New live query")
            }
            .padding(.horizontal, 6)
            ForEach(queries) { q in
                HStack(spacing: 8) {
                    Image(systemName: q.schedule == "manual" ? "arrow.clockwise" : "clock.arrow.2.circlepath").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(q.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                        Text(subtitle(q)).font(.system(size: 10)).foregroundStyle(q.lastStatus?.hasPrefix("error") == true ? .red : .secondary).lineLimit(1)
                    }
                    Spacer()
                    if model.runningQueries.contains(q.id) {
                        ProgressView().controlSize(.mini)
                    } else {
                        Button { model.runQuery(q) } label: { Image(systemName: "play.fill") }.buttonStyle(.plain).foregroundStyle(.secondary).help("Run now")
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7).fill(model.selectedChat == q.sessionId && q.sessionId != nil ? Color.accentColor.opacity(0.13) : .clear))
                .contentShape(Rectangle())
                .onTapGesture { if let s = q.sessionId { model.selectedChat = s } else { model.runQuery(q) } }
                .contextMenu {
                    Button("Run now") { model.runQuery(q) }
                    Button("Edit…") { editing = q }
                    Button("Delete", role: .destructive) { try? model.store.deleteQuery(q.id) }
                }
            }
        }
        .padding(.horizontal, 8).padding(.bottom, 8)
        .task(id: model.revision) { queries = (try? model.store.savedQueries()) ?? [] }
        .sheet(item: $editing) { SavedQueryEditor(query: $0) }
    }

    private func subtitle(_ q: SavedQuery) -> String {
        let sched = switch q.schedule {
        case "daily": String(localized: "Daily at \(q.hour):00")
        case "weekly": String(localized: "Weekly, \(Calendar.current.weekdaySymbols[(q.weekday + 6) % 7]) \(q.hour):00")
        default: String(localized: "Manual")
        }
        return String(localized: "\(sched) · last \(q.periodDays)d") + (q.lastRunAt.map { String(localized: " · ran \($0.formatted(.relative(presentation: .named)))") } ?? "")
    }
}

struct SavedQueryEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var query: SavedQuery
    @State private var folders: [Folder] = []
    @State private var tags: [Tag] = []
    @State private var people: [Speaker] = []

    var body: some View {
        Form {
            TextField("Name", text: $query.name, prompt: Text("Weekly decisions"))
            VStack(alignment: .leading) {
                Text("Starting prompt")
                TextEditor(text: $query.prompt).font(.body).frame(height: 80)
            }
            Picker("Meetings", selection: Binding(get: { "\(query.scopeKind):\(query.scopeId ?? "")" }, set: { v in
                let parts = v.split(separator: ":", maxSplits: 1).map(String.init)
                query.scopeKind = parts[0]
                query.scopeId = parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil
            })) {
                Text("All meetings").tag("all:")
                if !folders.isEmpty { Section("Folders") { ForEach(folders) { Text($0.name).tag("folder:\($0.id)") } } }
                if !tags.isEmpty { Section("Tags") { ForEach(tags) { Text("#\($0.name)").tag("tag:\($0.id)") } } }
                if !people.isEmpty { Section("People") { ForEach(people) { Text($0.name).tag("person:\($0.id)") } } }
            }
            Picker("Meeting period", selection: $query.periodDays) {
                Text("Today").tag(1); Text("Last 7 days").tag(7); Text("Last 14 days").tag(14); Text("Last 30 days").tag(30); Text("Last 90 days").tag(90)
            }
            Picker("Repeat", selection: $query.schedule) {
                Text("Manual").tag("manual"); Text("Daily").tag("daily"); Text("Weekly").tag("weekly")
            }
            if query.schedule != "manual" {
                Picker("Time", selection: $query.hour) { ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) } }
                if query.schedule == "weekly" {
                    Picker("Day", selection: $query.weekday) {
                        ForEach(1...7, id: \.self) { Text(Calendar.current.weekdaySymbols[$0 - 1]).tag($0) }
                    }
                }
            }
        }
        .formStyle(.grouped).frame(width: 460)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    query.nextRunAt = query.nextRun(after: .now)
                    try? model.store.saveQuery(query)
                    model.toast = String(localized: "Live query saved")
                    dismiss()
                }
                .disabled(query.name.trimmingCharacters(in: .whitespaces).isEmpty || query.prompt.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .task {
            folders = (try? model.store.folders()) ?? []
            tags = ((try? model.store.allTags()) ?? []).map(\.0)
            people = ((try? model.store.people()) ?? []).map(\.0)
        }
    }
}

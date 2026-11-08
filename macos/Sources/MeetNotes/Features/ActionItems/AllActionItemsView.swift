import SwiftUI

struct AllActionItemsView: View {
    @EnvironmentObject var model: AppModel
    @State private var items: [(ActionItem, Meeting)] = []
    @State private var filter = ""
    @AppStorage("showCompletedActions") private var showCompleted = false

    private var filtered: [(ActionItem, Meeting)] {
        items.filter { a, m in
            (showCompleted || !a.completed)
                && (filter.isEmpty || a.text.localizedCaseInsensitiveContains(filter) || (a.assignee ?? "").localizedCaseInsensitiveContains(filter)
                    || m.title.localizedCaseInsensitiveContains(filter))
        }
    }

    private var groups: [(String, [(ActionItem, Meeting)])] {
        let today = Calendar.current.startOfDay(for: .now).addingTimeInterval(86400)
        let open = filtered.filter { !$0.0.completed }
        return [
            ("Overdue & due today", open.filter { $0.0.dueDate.map { $0 < today } ?? false }),
            ("Upcoming", open.filter { $0.0.dueDate.map { $0 >= today } ?? false }),
            ("No due date", open.filter { $0.0.dueDate == nil }),
            ("Completed", filtered.filter { $0.0.completed }),
        ].filter { !$0.1.isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Follow-ups").font(.system(size: 17, weight: .semibold))
                CountBadge(count: items.filter { !$0.0.completed }.count)
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search action items", text: $filter).textFieldStyle(.plain)
                }
                .padding(.horizontal, 8).padding(.vertical, 4).frame(width: 220)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                Toggle("Show completed", isOn: $showCompleted).toggleStyle(.checkbox)
                Button { sendAll() } label: { Label("Send all to Reminders", systemImage: "checklist") }
            }
            .font(.system(size: 12)).padding(.horizontal, 22).padding(.vertical, 12)
            Divider()
            if groups.isEmpty {
                EmptyState(icon: "checkmark.circle", title: "No action items yet", message: "Action items appear here after meetings are summarized.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(groups, id: \.0) { title, rows in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                                ForEach(rows, id: \.0.id) { a, m in ActionItemRow(item: a, meetingTitle: m.title) }
                            }
                        }
                    }
                    .padding(22).frame(maxWidth: 900, alignment: .leading)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: model.revision) { items = (try? model.store.allActionItems()) ?? [] }
    }

    private func sendAll() {
        Task {
            do {
                let n = try await model.calendar.sendToReminders(filtered.map(\.0), meetingTitle: "Keepword")
                model.toast = String(localized: "Sent \(n) item(s) to Reminders")
            } catch { model.toast = error.localizedDescription }
        }
    }
}

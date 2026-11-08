import SwiftUI

struct ActionItemRow: View {
    @EnvironmentObject var model: AppModel
    let item: ActionItem
    var meetingTitle: String? = nil
    @State private var editing = false
    @State private var draft = ActionItem(meetingId: "", text: "")

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button {
                var a = item; a.completed.toggle(); try? model.store.saveActionItem(a)
            } label: {
                Image(systemName: item.completed ? "checkmark.circle.fill" : "circle").foregroundStyle(item.completed ? Palette.brand : .secondary)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.text).font(.system(size: 13)).strikethrough(item.completed).foregroundStyle(item.completed ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    if let who = item.assignee { HStack(spacing: 4) { Avatar(name: who, size: 14); Text(who) } }
                    if let due = item.dueDate {
                        Label(due.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)), systemImage: "calendar")
                            .foregroundStyle(due < Calendar.current.startOfDay(for: .now) && !item.completed ? .red : .secondary)
                    }
                    if let meetingTitle {
                        Button { model.open(item.meetingId) } label: { Label(meetingTitle, systemImage: "doc.text") }.buttonStyle(.plain)
                    }
                    if let ref = item.taskRef {
                        if let url = URL(string: ref), url.scheme?.hasPrefix("http") == true {
                            Link(destination: url) { Label("Task", systemImage: "arrow.up.forward.app") }
                        } else { Label(ref, systemImage: "arrow.up.forward.app") }
                    }
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .contextMenu {
            Button("Edit…") { draft = item; editing = true }
            ForEach(model.mcpClients.taskServers) { s in
                Button("Create Task in \(s.name)…") {
                    let m = model.store.meeting(item.meetingId)
                    model.taskRequest = TaskRequest(drafts: [.init(item: item, meeting: m)], serverID: s.id)
                }
            }
            Button(item.completed ? "Mark as incomplete" : "Mark as completed") { var a = item; a.completed.toggle(); try? model.store.saveActionItem(a) }
            Button("Delete", role: .destructive) { if let id = item.id { try? model.store.deleteActionItem(id) } }
        }
        .sheet(isPresented: $editing) {
            Form {
                TextField("Action item", text: $draft.text, axis: .vertical)
                TextField("Assignee", text: Binding(get: { draft.assignee ?? "" }, set: { draft.assignee = $0.isEmpty ? nil : $0 }))
                Toggle("Due date", isOn: Binding(get: { draft.dueDate != nil }, set: { draft.dueDate = $0 ? (draft.dueDate ?? .now) : nil }))
                if draft.dueDate != nil {
                    DatePicker("Due", selection: Binding(get: { draft.dueDate ?? .now }, set: { draft.dueDate = $0 }), displayedComponents: .date)
                }
            }
            .formStyle(.grouped).frame(width: 420)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { editing = false } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { try? model.store.saveActionItem(draft); editing = false } }
            }
        }
    }
}

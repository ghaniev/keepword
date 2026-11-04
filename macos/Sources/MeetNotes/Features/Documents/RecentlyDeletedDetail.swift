import SwiftUI

struct RecentlyDeletedDetail: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        if let id = model.selectedMeeting, let m = model.store.meeting(id), let deleted = m.deletedAt {
            VStack(alignment: .leading, spacing: 12) {
                Text(m.title).font(.system(size: 21, weight: .semibold))
                Text("Deleted \(deleted.formatted(date: .abbreviated, time: .shortened)) · removed permanently after 30 days")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(String(localized: "Restore")) { try? model.store.restore(m.id); model.toast = String(localized: "Restored") }
                    Button("Delete Permanently", role: .destructive) { try? model.store.deletePermanently(m); model.selectedMeeting = nil }
                }
                Divider()
                ScrollView { Text(m.summary).font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading) }
            }
            .padding(22).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            EmptyState(icon: "trash", title: "Select a note to restore it")
        }
    }
}

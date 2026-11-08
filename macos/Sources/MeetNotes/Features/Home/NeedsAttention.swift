import SwiftUI

/// A recent meeting that waits on the user (Home → Needs Attention): unknown speakers, a failure or no summary.
struct AttentionItem: Identifiable {
    enum Reason: Equatable { case speakers(Int), failed(String), noSummary }
    let meeting: Meeting
    let reason: Reason
    var id: String { meeting.id }

    /// Meetings from the last two weeks, newest first.
    static func find(in store: Store, now: Date = .now) -> [AttentionItem] {
        let since = now.addingTimeInterval(-14 * 86400)
        return ((try? store.meetings(.all)) ?? []).filter { $0.createdAt >= since }.compactMap { m in
            let unnamed = { (try? store.unnamedSpeakers(in: m.id).count) ?? 0 }
            if m.status == "awaiting:speakers" { return AttentionItem(meeting: m, reason: .speakers(unnamed())) }
            if m.status.hasPrefix("error:") { return AttentionItem(meeting: m, reason: .failed(m.statusLabel)) }
            guard m.status == "done" else { return nil }
            if case let n = unnamed(), n > 0 { return AttentionItem(meeting: m, reason: .speakers(n)) }
            let empty = m.summary.isEmpty && ((try? store.insights(of: m.id)) ?? []).isEmpty && ((try? store.actionItems(of: m.id)) ?? []).isEmpty
            return empty ? AttentionItem(meeting: m, reason: .noSummary) : nil
        }
    }
}

struct AttentionRow: View {
    @EnvironmentObject var model: AppModel
    let item: AttentionItem

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon.0).foregroundStyle(icon.1).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.meeting.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                detail.font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            switch item.reason {
            case .speakers: Button("Identify Speakers") { model.identifyingSpeakers = item.meeting.id }
            case .failed: Button("Retry Transcription") { try? model.store.setStatus(item.meeting.id, "queued"); model.enqueue(item.meeting.id) }
            case .noSummary: Button("Generate Recap") { model.enqueue(item.meeting.id, regenerateOnly: true) }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.035)))
        .contentShape(Rectangle())
        .onTapGesture { model.open(item.meeting.id) }
    }

    private var icon: (String, Color) {
        switch item.reason {
        case .speakers: ("person.wave.2", .blue)
        case .failed: ("exclamationmark.triangle.fill", .orange)
        case .noSummary: ("sparkles", .secondary)
        }
    }

    private var detail: Text {
        switch item.reason {
        case .speakers(let n): Text("\(plural(n, "new speaker")) in this meeting.")
        case .failed(let label): Text(label)
        case .noSummary: Text("No summary yet")
        }
    }
}

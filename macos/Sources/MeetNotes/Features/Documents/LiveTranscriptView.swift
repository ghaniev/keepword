import SwiftUI

struct LiveTranscriptView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var live: LiveTranscript

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    if !live.status.isEmpty { Text(live.status).font(.caption).foregroundStyle(.secondary).padding(.top, 8) }
                    if live.lines.isEmpty && live.volatile.isEmpty && live.status.isEmpty {
                        Text(UserDefaults.standard.flag("liveTranscription", true)
                             ? "Listening… speech will appear here." : "Live transcription is off. The transcript appears after the call.")
                            .font(.callout).foregroundStyle(.secondary).padding(.top, 30)
                    }
                    ForEach(live.lines) { bubble($0.text, isMic: $0.isMic, time: $0.time, volatile: false) }
                    ForEach([true, false], id: \.self) { isMic in
                        if let v = live.volatile[isMic], !v.isEmpty { bubble(v, isMic: isMic, time: nil, volatile: true) }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(16)
                .readableColumn()
            }
            .onChange(of: live.lines.count) { withAnimation { proxy.scrollTo("bottom") } }
        }
    }

    private func bubble(_ text: String, isMic: Bool, time: Double?, volatile: Bool) -> some View {
        HStack {
            if isMic { Spacer(minLength: 60) }
            VStack(alignment: isMic ? .trailing : .leading, spacing: 2) {
                Text((isMic ? "Me" : "Participant") + (time.map { " · \(timestamp($0))" } ?? "")).font(.caption2).foregroundStyle(.secondary)
                Text(text).font(.system(size: 13)).foregroundStyle(volatile ? .secondary : .primary)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 12).fill(isMic ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.06)))
            }
            if !isMic { Spacer(minLength: 60) }
        }
    }
}

import SwiftUI

/// Speaker identification wizard: walk through new voices, listen to excerpts, name or assign each one.
struct SpeakerWizard: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let meetingID: String
    @State private var speakers: [Speaker] = []
    @State private var index = 0
    @State private var name = ""
    @State private var people: [Speaker] = []
    @State private var excerpts: [Segment] = []

    private var current: Speaker? { speakers.indices.contains(index) ? speakers[index] : nil }
    private var matches: [Speaker] {
        let q = name.trimmingCharacters(in: .whitespaces).lowercased()
        return people.filter { $0.id != current?.id && $0.name.wholeMatch(of: #/Speaker \d+/#) == nil
            && (q.isEmpty || $0.name.lowercased().contains(q)) }.prefix(6).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Identify Speakers").font(.headline)
                Spacer()
                if !speakers.isEmpty { Text("\(min(index + 1, speakers.count)) of \(speakers.count)").foregroundStyle(.secondary) }
            }
            if let s = current {
                HStack(spacing: 12) {
                    Avatar(name: s.name, size: 36)
                    VStack(alignment: .leading) {
                        Text(s.name).font(.system(size: 15, weight: .semibold))
                        Text("Listen to the excerpts, then name this voice. It will be recognized in future meetings.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(excerpts) { e in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Button { playClip(e) } label: { Image(systemName: "play.circle.fill").font(.system(size: 16)) }.buttonStyle(.plain)
                            Text(timestamp(e.start)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            Text(e.text).font(.system(size: 12.5)).lineLimit(3)
                        }
                    }
                }
                .padding(10).background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                TextField("Search or enter new name...", text: $name).textFieldStyle(.roundedBorder).onSubmit(assignNew)
                if !matches.isEmpty {
                    FlowLayout {
                        ForEach(matches) { p in
                            Button { assign(to: p) } label: { PersonChip(name: p.name) }.buttonStyle(.plain).help("Same person as \(p.name)")
                        }
                    }
                }
                HStack {
                    Button("Cancel") { finish() }
                    Spacer()
                    Button("Skip") { next() }
                    Button(matches.first { $0.name.lowercased() == name.lowercased() } != nil ? "Assign" : "Save Name", action: assignNew)
                        .keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } else {
                Text(speakers.isEmpty ? "No new speakers in this meeting." : "All speakers reviewed.").foregroundStyle(.secondary)
                HStack { Spacer(); Button("Done") { finish() }.keyboardShortcut(.defaultAction) }
            }
        }
        .padding(20).frame(width: 520)
        .task {
            speakers = (try? model.store.unnamedSpeakers(in: meetingID)) ?? []
            people = ((try? model.store.people()) ?? []).map(\.0)
            loadExcerpts()
        }
    }

    private func loadExcerpts() {
        guard let s = current else { excerpts = []; return }
        let all = (try? model.store.speakers()) ?? [:]
        excerpts = ((try? model.store.segments(of: meetingID)) ?? [])
            .filter { model.store.root($0.speakerId, in: all)?.id == s.id && !$0.irrelevant }
            .sorted { $0.end - $0.start > $1.end - $1.start }.prefix(3).sorted { $0.start < $1.start }
        name = ""
    }

    private func playClip(_ e: Segment) {
        guard let m = model.store.meeting(meetingID) else { return }
        model.player.load(m)
        model.player.playClip(from: e.start, to: e.end)
    }

    private func assignNew() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard var s = current, !n.isEmpty else { return }
        if let existing = people.first(where: { $0.name.lowercased() == n.lowercased() && $0.id != s.id }) {
            assign(to: existing)
            return
        }
        s.name = n
        try? model.store.saveSpeaker(s)
        next()
    }

    /// Same person as an existing one: merge, so this voice sample also matches them next time.
    private func assign(to person: Speaker) {
        guard let s = current else { return }
        try? model.store.merge(s.id, into: person.id)
        next()
    }

    private func next() {
        model.player.pause()
        index += 1
        loadExcerpts()
    }

    private func finish() {
        model.player.pause()
        if model.store.meeting(meetingID)?.status == "awaiting:speakers" { model.enqueue(meetingID, regenerateOnly: true) }
        model.identifyingSpeakers = nil
        dismiss()
    }
}

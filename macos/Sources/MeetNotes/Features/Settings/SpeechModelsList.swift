import SwiftUI

/// On-device speech models: pick one, download or delete it. A model that isn't on disk is downloaded
/// when picked and becomes active once it's ready.
struct SpeechModelsList: View {
    @Binding var language: String
    @ObservedObject private var downloader = SpeechModelDownloader.shared
    @AppStorage("localSpeechModel") private var chosen = SpeechModels.defaultID

    private var active: SpeechModel { SpeechModels.selected }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Parakeet").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(SpeechModels.catalog.filter { !$0.isWhisper }) { row($0) }
            Text("Whisper").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 6)
            ForEach(SpeechModels.catalog.filter(\.isWhisper)) { row($0) }
        }
        .padding(.vertical, 4)
        if let err = downloader.error { Text(err).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        if active.isWhisper {
            Picker("Spoken language", selection: $language) {
                ForEach(TranscriptionLanguage.codes, id: \.self) { Text(TranscriptionLanguage.label($0)).tag($0) }
            }
        }
        Text("Everything runs on this Mac's Neural Engine; audio never leaves it. Parakeet is the fastest and detects the language itself. Whisper knows 99 languages and uses the language set here. Models are stored in Application Support (FluidAudio and MeetNotes/Models/Whisper).")
            .font(.caption).foregroundStyle(.secondary)
    }

    private func row(_ m: SpeechModel) -> some View {
        let isActive = active.id == m.id
        let downloaded = m.isDownloaded
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(isActive ? Color.accentColor : .secondary).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(m.name).font(.system(size: 13, weight: .semibold))
                Text(m.note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let p = downloader.progress[m.id] {
                if downloader.preparing.contains(m.id) {
                    ProgressView().controlSize(.small)
                    Text("Preparing…").font(.caption)
                } else {
                    ProgressView(value: p).frame(width: 80)
                    Text("\(Int(p * 100))%").font(.caption).monospacedDigit()
                }
                Button { downloader.cancel(m) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help(Text("Cancel Download"))
            } else if downloaded {
                Text("Downloaded").font(.caption).foregroundStyle(.green)
                Menu {
                    Button("Delete Model", role: .destructive) { downloader.delete(m) }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            } else {
                Text(m.sizeLabel).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Button("Download") { pick(m) }.controlSize(.small)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(isActive ? Color.accentColor.opacity(0.08) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { pick(m) }
    }

    private func pick(_ m: SpeechModel) {
        if m.isDownloaded { chosen = m.id; return }
        downloader.download(m) { chosen = m.id }
    }
}

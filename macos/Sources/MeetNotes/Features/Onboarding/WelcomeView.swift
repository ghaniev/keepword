import SwiftUI

/// "Choose how to generate summaries" screen.
struct WelcomeView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 6) {
            Text("Welcome to MeetNotes").font(.system(size: 30, weight: .bold))
            Text("Choose how to generate summaries").font(.title3).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 36) {
                LocalAIPicker(downloader: model.downloader) { finish() }
                    .frame(maxWidth: .infinity)
                Divider()
                CloudAICard { finish() }
                    .frame(maxWidth: .infinity)
            }
            .padding(.top, 34)
            HStack {
                Spacer()
                Button("Decide later") { finish() }.buttonStyle(.link)
            }
            .padding(.top, 12)
        }
        .padding(40)
        .frame(width: 900)
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        dismiss()
    }
}

struct LocalAIPicker: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var downloader: ModelDownloader
    var onUse: () -> Void = {}
    @State private var selection = LocalModels.recommended.id
    @AppStorage("llmBaseURL") private var baseURL = "http://localhost:11434/v1"
    @AppStorage("llmModel") private var llmModel = ""

    private var selected: LocalModel { LocalModels.find(selection) ?? LocalModels.recommended }
    private var active: Bool { baseURL == LocalModels.providerURL && llmModel == selected.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "lock.fill").foregroundStyle(.green).font(.title2)
                Text("Local AI").font(.title3.weight(.semibold))
                Text("Recommended").font(.caption.weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(Color.green))
            }
            Text("Best for most professionals").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Label("Maximum privacy", systemImage: "lock.shield")
                Label("Works offline", systemImage: "wifi.slash")
            }
            VStack(spacing: 8) { ForEach(LocalModels.catalog) { row($0) } }
            if let err = downloader.error { Text(err).font(.caption).foregroundStyle(.red) }
            Button(action: use) {
                Label(buttonTitle, systemImage: selected.isDownloaded ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(downloader.progress[selected.id] != nil || active || LocalModels.ramGB < selected.minRAMGB)
            Text("Runs Qwen with llama.cpp on this Mac's GPU. The model unloads after 5 idle minutes to free memory.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear {
            if baseURL == LocalModels.providerURL, LocalModels.find(llmModel) != nil { selection = llmModel }
        }
    }

    private var buttonTitle: String {
        if active { return String(localized: "Using \(selected.name)") }
        if downloader.progress[selected.id] != nil { return String(localized: "Downloading…") }
        return selected.isDownloaded ? String(localized: "Use Local AI") : String(localized: "Download and use Local AI")
    }

    private func row(_ m: LocalModel) -> some View {
        let fits = LocalModels.ramGB >= m.minRAMGB
        return HStack(spacing: 12) {
            Image(systemName: selection == m.id ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(selection == m.id ? Color.accentColor : .secondary).font(.title3)
            Text(m.name).font(.system(size: 15, weight: .semibold))
            if m.id == LocalModels.recommended.id {
                Text("Best for\nyour Mac").font(.system(size: 12, weight: .semibold)).foregroundStyle(.green).fixedSize()
            } else if !fits {
                Text("Needs \(m.minRAMGB) GB RAM").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let p = downloader.progress[m.id] {
                ProgressView(value: p).frame(width: 90)
                Text("\(Int(p * 100))%").font(.caption).monospacedDigit()
                Button { downloader.cancel(m) } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary)
            } else if m.isDownloaded {
                Text("Downloaded").font(.caption).foregroundStyle(.green)
                Menu {
                    Button("Delete Model", role: .destructive) {
                        downloader.delete(m)
                        if active { baseURL = "http://localhost:11434/v1" }
                    }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            } else {
                Text(m.sizeLabel).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 10).fill(selection == m.id ? Color.accentColor.opacity(0.13) : Color.primary.opacity(0.05)))
        .contentShape(Rectangle())
        .onTapGesture { if fits { selection = m.id } }
        .opacity(fits ? 1 : 0.5)
    }

    private func use() {
        let m = selected
        let activate = {
            baseURL = LocalModels.providerURL
            llmModel = m.id
            model.toast = String(localized: "Summaries now use \(m.name) on this Mac")
            onUse()
        }
        if m.isDownloaded { activate() } else { downloader.download(m, then: activate) }
    }
}

struct CloudAICard: View {
    var onUse: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "cloud.fill").foregroundStyle(.blue).font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cloud AI").font(.title3.weight(.semibold))
                    Text("ChatGPT or Claude subscription, OpenAI, Anthropic, etc.").foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Label("Higher quality summaries", systemImage: "sparkles")
                Label("Self-host for privacy", systemImage: "server.rack")
            }
            .padding(.top, 8)
            Text("If you choose a cloud provider, MeetNotes sends text transcripts of your calls, including participant names and meeting titles, to that provider to generate insights. Recorded audio never leaves your Mac.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            Spacer(minLength: 0)
            SettingsLink { Text("Use Cloud AI").frame(maxWidth: .infinity) }
                .controlSize(.large)
                .simultaneousGesture(TapGesture().onEnded { onUse() })
        }
    }
}

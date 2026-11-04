import SwiftUI

struct ExportSettings: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("exportFolder") private var folder = ""
    @AppStorage("autoExportMarkdown") private var auto = true
    @AppStorage("exportFrontmatter") private var frontmatter = true
    @AppStorage("exportAttachments") private var copyAttachments = true

    var body: some View {
        Form {
            Section("Markdown Export") {
                LabeledContent("Export Folder") {
                    HStack {
                        Text(folder.isEmpty ? String(localized: "Not set") : folder).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Choose…") {
                            let p = NSOpenPanel()
                            p.canChooseDirectories = true
                            p.canChooseFiles = false
                            if p.runModal() == .OK, let url = p.url { folder = url.path }
                        }
                        if !folder.isEmpty { Button("Clear") { folder = "" } }
                    }
                }
                Toggle("Auto-export markdown after each change", isOn: $auto)
                Toggle("Include YAML frontmatter (title, date, participants, tags)", isOn: $frontmatter)
                Toggle("Copy attachments next to the exported note", isOn: $copyAttachments)
                Text("Point this at an Obsidian or Logseq vault. Files are named by date and title and replaced when a meeting is renamed.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Export All Now") {
                    for m in (try? model.store.meetings(.all)) ?? [] { MarkdownExport.autoExport(m.id, store: model.store) }
                    model.toast = String(localized: "Exported")
                }
                .disabled(folder.isEmpty)
            }
        }
        .formStyle(.grouped)
    }
}

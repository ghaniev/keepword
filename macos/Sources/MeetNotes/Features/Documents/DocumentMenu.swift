import SwiftUI

/// Context/⋯ menu shared by the card and the document header.
struct DocumentMenu: View {
    @EnvironmentObject var model: AppModel
    let meeting: Meeting
    @State private var folders: [Folder] = []
    @State private var templates: [Template] = []

    var body: some View {
        Menu("Move to Folder") {
            Button("None (Unsorted)") { try? model.store.move(meeting.id, to: nil) }
            ForEach((try? model.store.folders()) ?? []) { f in Button(f.name) { try? model.store.move(meeting.id, to: f.id) } }
        }
        Menu("Change Template") {
            Button("Use Folder / Default") { try? model.store.update(meeting.id) { $0.templateId = nil } }
            ForEach((try? model.store.templates()) ?? []) { t in Button(t.name) { try? model.store.update(meeting.id) { $0.templateId = t.id } } }
        }
        Divider()
        Button("Regenerate Summary") { model.enqueue(meeting.id, regenerateOnly: true) }.disabled(meeting.id == model.recordingID)
        Button("Re-transcribe") { try? model.store.setStatus(meeting.id, "queued"); model.enqueue(meeting.id) }.disabled(meeting.id == model.recordingID)
        Button("Clean Up Transcript") { model.cleanUp(meeting.id) }.disabled(meeting.id == model.recordingID)
        Button("Identify Speakers…") { model.identifyingSpeakers = meeting.id }.disabled(meeting.id == model.recordingID)
        Button("Re-identify Speakers…") { model.respeaking = meeting.id }.disabled(meeting.id == model.recordingID)
        Divider()
        Button("Export Markdown…") { MarkdownExport.exportWithPanel(meeting.id, store: model.store) }
        Button("Copy Transcript") { copyToPasteboard((try? MarkdownExport.render(meeting.id, store: model.store, frontmatter: false)) ?? "") }
        Button("Copy Insights & Action Items") { copyInsights() }
        Button("Send Summary via Email…") { email() }
        Button("Show Audio in Finder") { NSWorkspace.shared.activateFileViewerSelecting([meeting.folder]) }
        Divider()
        Button("Delete", role: .destructive) { model.trash(meeting.id) }.disabled(meeting.id == model.recordingID)
    }

    private func copyInsights() {
        let ins = (try? model.store.insights(of: meeting.id)) ?? []
        let acts = (try? model.store.actionItems(of: meeting.id)) ?? []
        var s = "\(meeting.title)\n\nKey Insights\n"
        for i in ins { s += "• \(i.text)\n" }
        s += "\nAction Items\n"
        for a in acts { s += "☐ \(a.text)" + (a.assignee.map { " (\($0))" } ?? "") + "\n" }
        copyToPasteboard(s)
        model.toast = String(localized: "Copied to clipboard")
    }

    private func email() {
        let ins = (try? model.store.insights(of: meeting.id)) ?? []
        let acts = (try? model.store.actionItems(of: meeting.id)) ?? []
        var body = meeting.summary + "\n\nKey Insights\n"
        for i in ins { body += "- \(i.text)\n" }
        body += "\nAction Items\n"
        for a in acts { body += "- \(a.text)\n" }
        body += "\nPrepared with MeetNotes"
        var c = URLComponents(string: "mailto:")!
        c.queryItems = [URLQueryItem(name: "subject", value: meeting.title), URLQueryItem(name: "body", value: body)]
        if let url = c.url { NSWorkspace.shared.open(url) }
    }
}

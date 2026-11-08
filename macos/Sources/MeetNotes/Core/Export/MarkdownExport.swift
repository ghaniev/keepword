import AppKit

enum MarkdownExport {
    static func exportedName(_ a: Attachment) -> String { "\(a.meetingId.prefix(8))-\(a.fileName)" }

    static func render(_ id: String, store: Store, frontmatter: Bool = UserDefaults.standard.flag("exportFrontmatter", true),
                       attachmentsCopied: Bool = false) throws -> String {
        guard let m = store.meeting(id) else { return "" }
        let all = try store.speakers()
        let people = try store.participants(of: id).map(\.name)
        let tags = try store.tags(of: id).map(\.name)
        func yaml(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        var md = ""
        if frontmatter {
            md += """
                ---
                title: \(yaml(m.title))
                date: \(m.createdAt.formatted(.iso8601))
                duration_min: \(Int(m.duration / 60))
                participants: [\(people.map(yaml).joined(separator: ", "))]
                tags: [\(tags.map(yaml).joined(separator: ", "))]
                meetnotes_id: \(m.id)
                ---

                """
        }
        md += "# \(m.title)\n\n"
        if !m.summary.isEmpty { md += m.summary + "\n\n" }
        let insights = try store.insights(of: id)
        if !insights.isEmpty {
            md += "## Highlights\n"
            for i in insights {
                let time: String = i.time.map { " (\(timestamp($0)))" } ?? ""
                md += "- \(i.text)\(time)\n"
            }
            md += "\n"
        }
        let items = try store.actionItems(of: id)
        if !items.isEmpty {
            md += "## Follow-ups\n"
            for a in items {
                let who: String = a.assignee.map { " — \($0)" } ?? ""
                let due: String = a.dueDate.map { " 📅 " + $0.formatted(.iso8601.year().month().day()) } ?? ""
                md += "- [\(a.completed ? "x" : " ")] \(a.text)\(who)\(due)\n"
            }
            md += "\n"
        }
        if !m.notes.isEmpty { md += "## Notes\n\(m.notes)\n\n" }
        let files = try store.attachments(of: id)
        if !files.isEmpty {
            md += "## Attachments\n"
            for a in files {
                // Auto-export copies files next to the note; elsewhere link the library copy.
                let link = attachmentsCopied ? "Attachments/\(exportedName(a))" : a.url.absoluteString
                let label = a.recordingTime.map { "Screenshot \(timestamp($0))" } ?? a.fileName
                md += (a.isImage ? "![\(label)](\(link.replacingOccurrences(of: " ", with: "%20")))" : "- [\(label)](\(link.replacingOccurrences(of: " ", with: "%20")))") + "\n"
            }
            md += "\n"
        }
        md += "## Transcript\n\n"
        for s in try store.segments(of: id) where !s.irrelevant {
            md += "**\(store.root(s.speakerId, in: all)?.name ?? "?")** [\(timestamp(s.start))]: \(s.text)\n\n"
        }
        md += "*Exported from Keepword on \(Date.now.formatted(date: .abbreviated, time: .shortened))*\n"
        return md
    }

    static func fileName(_ m: Meeting) -> String {
        let date = m.createdAt.formatted(.iso8601.year().month().day())
        let safe = m.title.components(separatedBy: CharacterSet(charactersIn: "/\\:?*\"<>|")).joined(separator: "-")
        return "\(date) \(safe) (\(m.id.prefix(8))).md"
    }

    /// Auto-export into the chosen folder (e.g. an Obsidian vault). The id suffix lets a renamed meeting replace its old file.
    static func autoExport(_ id: String, store: Store) {
        let d = UserDefaults.standard
        guard d.flag("autoExportMarkdown", true),
              let path = d.string(forKey: "exportFolder"), !path.isEmpty, let m = store.meeting(id), m.status == "done" else { return }
        let folder = URL(filePath: path)
        let tag = "(\(m.id.prefix(8))).md"
        for old in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where old.hasSuffix(tag) {
            try? FileManager.default.removeItem(at: folder.appending(path: old))
        }
        let copy = d.flag("exportAttachments", true)
        if copy, let files = try? store.attachments(of: id), !files.isEmpty {
            let dir = folder.appending(path: "Attachments")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for a in files where !FileManager.default.fileExists(atPath: dir.appending(path: exportedName(a)).path) {
                try? FileManager.default.copyItem(at: a.url, to: dir.appending(path: exportedName(a)))
            }
        }
        guard m.deletedAt == nil, let md = try? render(id, store: store, attachmentsCopied: copy) else { return }
        try? md.write(to: folder.appending(path: fileName(m)), atomically: true, encoding: .utf8)
    }

    @MainActor static func exportWithPanel(_ id: String, store: Store) {
        guard let m = store.meeting(id), let md = try? render(id, store: store) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileName(m)
        panel.allowedContentTypes = [.init(filenameExtension: "md")!]
        if panel.runModal() == .OK, let url = panel.url { try? md.write(to: url, atomically: true, encoding: .utf8) }
    }
}

import SwiftUI

struct AttachmentsSection: View {
    @EnvironmentObject var model: AppModel
    let meetingID: String
    @State private var items: [Attachment] = []
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionTitle(title: "Attachments", count: items.isEmpty ? nil : "\(items.count)")
                Spacer()
                Button { pick() } label: { Label("Attach Files", systemImage: "paperclip") }.buttonStyle(.borderless).font(.caption)
            }
            if items.isEmpty {
                Text("Drop files to attach").font(.caption).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(RoundedRectangle(cornerRadius: 8).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4])).foregroundStyle(.tertiary))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 10)], spacing: 10) {
                    ForEach(items) { a in AttachmentTile(attachment: a) }
                }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 10).fill(targeted ? Color.accentColor.opacity(0.08) : .clear))
        .dropDestination(for: URL.self) { urls, _ in
            for u in urls where u.isFileURL { _ = try? model.store.attach(file: u, to: meetingID) }
            return true
        } isTargeted: { targeted = $0 }
        .task(id: model.revision) { items = (try? model.store.attachments(of: meetingID)) ?? [] }
    }

    private func pick() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        if p.runModal() == .OK { for u in p.urls { _ = try? model.store.attach(file: u, to: meetingID) } }
    }
}

struct AttachmentTile: View {
    @EnvironmentObject var model: AppModel
    let attachment: Attachment

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if attachment.isImage, let img = NSImage(contentsOf: attachment.url) {
                    Image(nsImage: img).resizable().scaledToFill()
                } else {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: attachment.url.path)).resizable().scaledToFit().padding(18)
                }
            }
            .frame(height: 80).frame(maxWidth: .infinity).clipped()
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            Text(attachment.fileName).font(.caption).lineLimit(1).truncationMode(.middle)
            Text(attachment.recordingTime.map { "Screenshot · \(timestamp($0))" }
                 ?? ByteCountFormatter.string(fromByteCount: attachment.fileSize, countStyle: .file))
                .font(.caption2).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { NSWorkspace.shared.open(attachment.url) }
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(attachment.url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([attachment.url]) }
            if let t = attachment.recordingTime { Button("Play from \(timestamp(t))") { model.open(attachment.meetingId, at: t) } }
            Divider()
            Button("Remove", role: .destructive) { try? model.store.removeAttachment(attachment) }
        }
        .help(attachment.fileName)
    }
}

/// Screenshot shown inline in the transcript at the moment it was taken.
struct TranscriptScreenshot: View {
    let attachment: Attachment
    let play: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button(timestamp(attachment.recordingTime ?? 0)) { play(attachment.recordingTime ?? 0) }.buttonStyle(.plain).monospacedDigit()
                Text("·")
                Label("Screenshot", systemImage: "camera.viewfinder")
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            if let img = NSImage(contentsOf: attachment.url) {
                Image(nsImage: img).resizable().scaledToFit().frame(maxWidth: 420, maxHeight: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.1)))
                    .onTapGesture { NSWorkspace.shared.open(attachment.url) }
                    .help("Open screenshot")
            }
        }
        .padding(6)
    }
}

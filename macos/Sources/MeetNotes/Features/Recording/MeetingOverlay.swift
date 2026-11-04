import AppKit
import SwiftUI

/// Floating meeting overlay: stays above the call window while recording.
@MainActor
final class MeetingOverlay {
    static let shared = MeetingOverlay()
    private var panel: NSPanel?

    func show(_ model: AppModel) {
        if let panel { panel.orderFrontRegardless(); return }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 470),
                        styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .utilityWindow, .fullSizeContentView],
                        backing: .buffered, defer: false)
        p.title = "MeetNotes"
        p.titlebarAppearsTransparent = true
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isMovableByWindowBackground = true
        p.contentView = NSHostingView(rootView: OverlayView(live: model.live).environmentObject(model))
        if let screen = NSScreen.main?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: screen.maxX - 420, y: screen.maxY - 490))
        }
        p.orderFrontRegardless()
        panel = p
    }

    func setCollapsed(_ collapsed: Bool) {
        guard let p = panel else { return }
        var f = p.frame
        let h: CGFloat = collapsed ? 92 : 470
        f.origin.y += f.height - h
        f.size.height = h
        p.setFrame(f, display: true, animate: true)
    }

    func close() { panel?.close(); panel = nil }
}

private enum OverlayTab: Hashable { case notes, transcript, prep }

struct OverlayView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var live: LiveTranscript
    @State private var tab: OverlayTab = .notes
    @State private var collapsed = false
    @State private var notes = ""

    var body: some View {
        VStack(spacing: 0) {
            controls.padding(.horizontal, 12).padding(.top, 26).padding(.bottom, 8)
            if !collapsed {
                TextTabs(tabs: [(OverlayTab.notes, "Notes"), (.transcript, "Transcript"), (.prep, "Prep")], selection: $tab)
                    .padding(.bottom, 6)
                Divider()
                switch tab {
                case .notes:
                    TextEditor(text: $notes).font(.system(size: 13)).scrollContentBackground(.hidden).padding(8)
                        .overlay(alignment: .topLeading) {
                            if notes.isEmpty { Text("Jot down notes during the meeting…").foregroundStyle(.tertiary).padding(13).allowsHitTesting(false) }
                        }
                        .onChange(of: notes) { _, new in
                            if let id = model.recordingID { try? model.store.update(id) { $0.notes = new } }
                        }
                case .transcript: LiveTranscriptView(live: live)
                case .prep: PrepView()
                }
            }
        }
        .frame(minWidth: 320)
        .background(.regularMaterial)
        .onAppear { notes = model.recordingID.flatMap { model.store.meeting($0)?.notes } ?? "" }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            if model.paused { Image(systemName: "pause.fill").foregroundStyle(.orange) } else { PulsingDot() }
            RecordingTimeText(meter: model.meter).font(.system(size: 15, weight: .semibold)).fixedSize()
            VStack(alignment: .leading, spacing: 3) {
                RecordingLevels(meter: model.meter, micMuted: model.micMuted)
            }
            Spacer()
            Group {
                button(model.paused ? "play.fill" : "pause.fill", model.paused ? "Resume" : "Pause", model.togglePause)
                button(model.micMuted ? "mic.slash" : "mic", "Mute microphone", model.toggleMute)
                button("bookmark", "Add bookmark", model.addBookmark)
                Menu {
                    Button("Capture Screen") { model.takeScreenshot(area: false) }
                    Button("Select Area…") { model.takeScreenshot(area: true) }
                } label: { Image(systemName: "camera.viewfinder") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Capture a screenshot of the screen")
                button(collapsed ? "chevron.down" : "chevron.up", collapsed ? "Show Controls" : "Hide Controls") {
                    collapsed.toggle()
                    MeetingOverlay.shared.setCollapsed(collapsed)
                }
            }
            .foregroundStyle(.secondary)
            Button { model.stopRecording() } label: {
                Image(systemName: "stop.fill").font(.system(size: 10)).foregroundStyle(.white)
                    .frame(width: 26, height: 26).background(Circle().fill(Color.red))
            }
            .buttonStyle(.plain).help("Stop Recording")
        }
        .font(.system(size: 13))
    }

    private func button(_ icon: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon) }.buttonStyle(.plain).help(help)
    }
}

/// "Before your next meetings": earlier meetings with the same people or a similar title, and their open action items.
struct PrepView: View {
    @EnvironmentObject var model: AppModel
    @State private var related: [Meeting] = []
    @State private var open: [(ActionItem, Meeting)] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if related.isEmpty {
                    Text("No preparation context for this meeting yet.").foregroundStyle(.secondary).font(.callout)
                }
                if !open.isEmpty {
                    SectionTitle(title: "Open action items", count: "\(open.count)")
                    ForEach(open, id: \.0.id) { a, m in ActionItemRow(item: a, meetingTitle: m.title) }
                }
                if !related.isEmpty {
                    SectionTitle(title: "Previous meetings")
                    ForEach(related) { m in
                        VStack(alignment: .leading, spacing: 3) {
                            Button(m.title) { model.open(m.id) }.buttonStyle(.plain).font(.system(size: 12.5, weight: .medium))
                            Text(m.createdAt.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
                            if !m.summary.isEmpty { Text(m.summary).font(.caption).lineLimit(4) }
                        }
                    }
                }
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { load() }
    }

    private func load() {
        guard let id = model.recordingID, let current = model.store.meeting(id) else { return }
        related = Prep.related(to: current, attendees: current.eventId.flatMap { eid in
            (model.calendar.upcoming + model.calendar.events).first { $0.id == eid }?.attendees } ?? [], store: model.store)
        let ids = Set(related.map(\.id))
        open = ((try? model.store.allActionItems()) ?? []).filter { !$0.0.completed && ids.contains($0.1.id) }
    }
}

enum Prep {
    /// Earlier meetings sharing a known person (by attendee name) or a significant title word.
    static func related(to m: Meeting, attendees: [String], store: Store) -> [Meeting] {
        let all = ((try? store.meetings(.all)) ?? []).filter { $0.id != m.id && $0.status == "done" }
        let names = Set(attendees.map { $0.lowercased() })
        let personIDs = Set(((try? store.people()) ?? []).map(\.0)
            .filter { p in names.contains { $0.contains(p.name.lowercased()) || p.name.lowercased().contains($0) } }.map(\.id))
        let byPerson = Set(personIDs.flatMap { ((try? store.meetings(.person($0))) ?? []).map(\.id) })
        let words = Pipeline.tokens(m.title).filter { $0.count > 3 && !$0.hasPrefix("meeting") }
        return all.filter { byPerson.contains($0.id) || !Pipeline.tokens($0.title).intersection(words).isEmpty }.prefix(5).map { $0 }
    }
}

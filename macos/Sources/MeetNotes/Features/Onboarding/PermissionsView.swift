import SwiftUI

/// The "Permissions" window: every macOS permission Keepword uses, its status and a button to grant it.
/// Opens at launch while recording permissions are missing, from the app menu, and when a recording
/// can't start because of a permission.
struct PermissionsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("permissionsAtLaunch") private var showAtLaunch = true
    @State private var statuses: [Permission: Permission.Status] = [:]
    @State private var asking: Permission?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Permissions").font(.title2.weight(.semibold))
                Text("Recording needs the microphone and system audio; the rest is optional. Recordings and transcripts stay on this Mac.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 0) {
                ForEach(Permission.allCases) { p in
                    row(p)
                    if p != Permission.allCases.last { Divider().padding(.leading, 52) }
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
            Text("After you turn on Screen or System Audio Recording in System Settings, macOS may ask to reopen Keepword.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Toggle("Open at launch while something required is missing", isOn: $showAtLaunch)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 580)
        .onAppear(perform: refresh)
        // Coming back from System Settings, or a prompt was answered.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private func row(_ p: Permission) -> some View {
        HStack(spacing: 12) {
            Image(systemName: p.icon).font(.system(size: 17)).foregroundStyle(Color.accentColor).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(p.title).font(.system(size: 13, weight: .semibold))
                    if p.isRequired {
                        Text("Required").font(.system(size: 10, weight: .medium)).foregroundStyle(.orange)
                            .padding(.horizontal, 6).padding(.vertical, 1).background(Capsule().fill(Color.orange.opacity(0.14)))
                    }
                }
                Text(p.purpose).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            switch statuses[p] ?? .unknown {
            case .granted:
                Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
            case .notDetermined:
                Button(asking == p ? "Waiting…" : "Allow") { ask(p) }.disabled(asking != nil)
            case .denied, .unknown:
                Button("Open Settings") { p.openSettings() }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private func ask(_ p: Permission) {
        asking = p
        Task {
            await p.request()
            asking = nil
            refresh()
            if p == .calendar { model.calendar.refresh() }
        }
    }

    private func refresh() {
        statuses = Dictionary(uniqueKeysWithValues: Permission.allCases.map { ($0, $0.status) })
    }
}

extension Permission {
    var title: LocalizedStringKey {
        switch self {
        case .microphone: "Microphone"
        case .systemAudio: "System Audio Recording"
        case .screenRecording: "Screen Recording"
        case .calendar: "Calendars"
        case .reminders: "Reminders"
        }
    }

    var purpose: LocalizedStringKey {
        switch self {
        case .microphone: "Your side of the call."
        case .systemAudio: "The other participants, captured from the Mac's sound output. No bot joins the call."
        case .screenRecording: "Screenshots during a call."
        case .calendar: "Upcoming meetings and the prompt to record them."
        case .reminders: "Sending follow-ups to the Reminders app."
        }
    }

    var icon: String {
        switch self {
        case .microphone: "mic.fill"
        case .systemAudio: "speaker.wave.2.fill"
        case .screenRecording: "rectangle.dashed.badge.record"
        case .calendar: "calendar"
        case .reminders: "checklist"
        }
    }
}

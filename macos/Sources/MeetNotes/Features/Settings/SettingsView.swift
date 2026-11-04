import SwiftUI

/// Settings sections, listed in a sidebar like System Settings (a tab toolbar hides
/// the last sections behind "»" once there are many, or labels get long in Russian).
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, recording, transcription, aiProvider, templates, calendar, integrations, export, mcpServer
    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .general: "General"
        case .recording: "Recording"
        case .transcription: "Transcription"
        case .aiProvider: "AI Provider"
        case .templates: "Summary Templates"
        case .calendar: "Calendar"
        case .integrations: "Integrations"
        case .export: "Export"
        case .mcpServer: "MCP Server"
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .recording: "record.circle"
        case .transcription: "waveform"
        case .aiProvider: "sparkles"
        case .templates: "doc.text"
        case .calendar: "calendar"
        case .integrations: "puzzlepiece.extension"
        case .export: "square.and.arrow.up"
        case .mcpServer: "point.3.connected.trianglepath.dotted"
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("settingsPane") private var pane: SettingsPane = .general

    var body: some View {
        // A fixed sidebar: NavigationSplitView ignores column widths inside the Settings window.
        HStack(spacing: 0) {
            List(SettingsPane.allCases, selection: Binding(get: { pane }, set: { if let p = $0 { pane = p } })) { p in
                Label(p.title, systemImage: p.icon).tag(p)
            }
            .listStyle(.sidebar)
            .frame(width: 220)
            Divider()
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(pane.title)
        .frame(width: 860, height: 580)
    }

    @ViewBuilder private var detail: some View {
        switch pane {
        case .general: GeneralSettings()
        case .recording: RecordingSettings()
        case .transcription: TranscriptionSettings()
        case .aiProvider: AIProviderSettings()
        case .templates: TemplatesSettings()
        case .calendar: CalendarSettings(calendar: model.calendar)
        case .integrations: IntegrationsSettings(mcp: model.mcpClients)
        case .export: ExportSettings()
        case .mcpServer: MCPSettings()
        }
    }
}

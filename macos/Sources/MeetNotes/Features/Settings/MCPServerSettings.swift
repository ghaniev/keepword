import SwiftUI

struct MCPSettings: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("mcpEnabled") private var enabled = false
    @AppStorage("mcpPort") private var port = 8765
    @State private var token = ""
    @State private var reveal = false

    private var url: String { "http://127.0.0.1:\(port)/mcp" }
    private var claudeCode: String { "claude mcp add --transport http keepword \(url) --header \"Authorization: Bearer \(token)\"" }
    private var desktopJSON: String {
        """
        {"mcpServers": {"keepword": {"command": "npx", "args": ["-y", "mcp-remote", "\(url)", "--header", "Authorization: Bearer \(token)"]}}}
        """
    }

    var body: some View {
        Form {
            Section("Local MCP server") {
                Toggle("Let MCP clients on this Mac read my meetings", isOn: $enabled)
                    .onChange(of: enabled) { _, on in on ? model.startMCP() : model.mcp.stop() }
                TextField("Port", value: $port, format: .number.grouping(.never))
                    .onSubmit { if enabled { model.startMCP() } }
                MCPStatus(server: model.mcp)
                Text("Tools: search_meetings, list_meetings, get_transcript, get_summary, get_action_items. Listens on 127.0.0.1 only; clients need the token below.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Bearer token") {
                HStack {
                    Text(reveal ? token : String(repeating: "•", count: 24)).font(.system(.body, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button(reveal ? "Hide" : "Show") { reveal.toggle() }
                    Button("Copy") { copyToPasteboard(token) }
                    Button("Regenerate token") { token = MCPServer.regenerateToken() }
                }
            }
            Section("Connect a client") {
                LabeledContent(String(localized: "Claude Code")) { Button(String(localized: "Copy command")) { copyToPasteboard(claudeCode); model.toast = String(localized: "Copied") } }
                LabeledContent(String(localized: "Claude Desktop (claude_desktop_config.json)")) { Button(String(localized: "Copy configuration")) { copyToPasteboard(desktopJSON); model.toast = String(localized: "Copied") } }
                Text("Anyone with the token can read your transcripts. Regenerate it to revoke access.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { token = MCPServer.token }
    }
}

private struct MCPStatus: View {
    @ObservedObject var server: MCPServer
    var body: some View {
        Label(server.status, systemImage: server.status.hasPrefix("Running") ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(server.status.hasPrefix("Running") ? .green : server.status.hasPrefix("Failed") ? .red : .secondary)
    }
}

import SwiftUI

struct IntegrationsSettings: View {
    @ObservedObject var mcp: MCPConnections
    @State private var editing: MCPServerConfig?
    @State private var importing = false

    var body: some View {
        Form {
            Section {
                if mcp.servers.isEmpty {
                    Text("No services yet. Add Jira, Linear, Notion or another MCP server to create tasks from action items and notes.")
                        .foregroundStyle(.secondary)
                }
                ForEach(mcp.servers) { s in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.name).font(.headline)
                            Group {
                                if let err = mcp.status[s.id] { Text(err).foregroundStyle(.red).lineLimit(2) }
                                else if let tools = mcp.tools[s.id] {
                                    Text("Connected · \(tools.count) tools") + Text(s.taskTool.map { " · \($0)" } ?? "")
                                } else { Text(s.transport == "http" ? s.url : ([s.command] + s.args).joined(separator: " ")).lineLimit(1) }
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if mcp.signingIn == s.id { ProgressView().controlSize(.small) }
                        else if mcp.mustSignIn(s) { Button("Sign In…") { Task { await mcp.signIn(s) } } }
                        else { Button("Test") { Task { await mcp.connect(s) } } }
                        Button("Edit") { editing = s }
                        Button(role: .destructive) { mcp.remove(s) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                }
                Menu("Add") {
                    ForEach(MCPPresets.all) { p in Button(p.name) { editing = p.config } }
                    Divider()
                    Button("Other MCP Server…") { editing = MCPServerConfig() }
                    Button("Import JSON…") { importing = true }
                }
                .fixedSize()
            } header: {
                Text("MCP servers (Keepword as client)")
            } footer: {
                Text("Jira, Linear, Notion, Asana and Miro sign in through the browser. Any other MCP server works too: a command with arguments and environment variables, or an HTTP URL, in the same format as Claude Desktop. Tokens are stored in the Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { MCPServerEditor(mcp: mcp, config: $0) }
        .sheet(isPresented: $importing) { MCPImportSheet(mcp: mcp) }
    }
}

struct MCPServerEditor: View {
    @ObservedObject var mcp: MCPConnections
    @Environment(\.dismiss) private var dismiss
    @State var config: MCPServerConfig
    @State private var argsText = ""
    @State private var secretsText = ""
    @State private var clientSecret = ""
    private var preset: MCPPreset? { MCPPresets.find(config.preset) }
    @State private var testing = false
    @State private var tools: [MCPTool] = []
    @State private var error: String?

    var body: some View {
        Form {
            TextField("Name", text: $config.name)
            Picker("Transport", selection: $config.transport) {
                Text("Command (stdio)").tag("stdio")
                Text("HTTP").tag("http")
            }
            if config.transport == "stdio" {
                TextField("Command", text: $config.command, prompt: Text("node, npx, uvx or a full path"))
                VStack(alignment: .leading) {
                    Text("Arguments (one per line)")
                    TextEditor(text: $argsText).font(.system(size: 12, design: .monospaced)).frame(height: 54)
                }
            } else {
                TextField("URL", text: $config.url, prompt: Text("https://…/mcp"))
                Picker("Sign-in", selection: Binding(get: { config.auth ?? "headers" }, set: { config.auth = $0 == "headers" ? nil : $0 })) {
                    Text("Browser (OAuth)").tag("oauth")
                    Text("Token in headers").tag("headers")
                }
            }
            if let preset { Text(preset.note).font(.caption).foregroundStyle(.secondary) }
            // Presets that register themselves need no client; custom servers and Asana do.
            if config.usesOAuth && (preset == nil || preset?.needsClient == true || config.clientID != nil) {
                TextField("Client ID", text: Binding(get: { config.clientID ?? "" }, set: { config.clientID = $0.isEmpty ? nil : $0 }),
                          prompt: Text(preset?.needsClient == true ? "Required" : "Optional"))
                SecureField("Client secret", text: $clientSecret, prompt: Text("Optional"))
                Text("Only for services that don't register apps automatically. Use the redirect URL \(MCPOAuth.fixedRedirect).")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            } else if !config.usesOAuth {
                VStack(alignment: .leading) {
                    Text(config.transport == "stdio" ? "Environment (KEY=value per line, stored in Keychain)" : "Headers (Name: value per line, stored in Keychain)")
                    TextEditor(text: $secretsText).font(.system(size: 12, design: .monospaced)).frame(height: 70)
                }
            }
            HStack {
                if config.usesOAuth && MCPOAuth.signedIn(config.id) && mcp.signingIn != config.id {
                    Button("Sign Out") { mcp.signOut(config); tools = [] }
                }
                Button(config.usesOAuth && mcp.mustSignIn(config) ? "Sign In and Test" : "Test Connection") { Task { await test() } }
                    .disabled(testing || mcp.signingIn != nil)
                if testing { ProgressView().controlSize(.small) }
                if let error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(3) }
                else if !tools.isEmpty { Text("\(tools.count) tools").font(.caption).foregroundStyle(.green) }
            }
            if !tools.isEmpty {
                Picker("Create tasks with", selection: Binding(get: { config.taskTool ?? "" }, set: { config.taskTool = $0.isEmpty ? nil : $0 })) {
                    Text("— not used for tasks —").tag("")
                    ForEach(tools) { Text($0.name).tag($0.name) }
                }
            }
        }
        .formStyle(.grouped).frame(width: 560)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { apply(); mcp.save(config); dismiss() }
                    .disabled(config.name.isEmpty || (config.transport == "stdio" ? config.command.isEmpty : config.url.isEmpty)
                              || (config.usesOAuth && preset?.needsClient == true && (config.clientID ?? "").isEmpty))
            }
        }
        .onAppear {
            argsText = config.args.joined(separator: "\n")
            let sep = config.transport == "stdio" ? "=" : ": "
            secretsText = config.secrets.sorted { $0.key < $1.key }.map { "\($0.key)\(sep)\($0.value)" }.joined(separator: "\n")
            clientSecret = config.clientSecret
        }
    }

    private func apply() {
        config.args = argsText.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var secrets: [String: String] = [:]
        for line in secretsText.split(separator: "\n") {
            let sep: Character = config.transport == "stdio" ? "=" : ":"
            guard let i = line.firstIndex(of: sep) else { continue }
            let k = line[..<i].trimmingCharacters(in: .whitespaces), v = line[line.index(after: i)...].trimmingCharacters(in: .whitespaces)
            if !k.isEmpty, !v.isEmpty { secrets[k] = v }
        }
        config.secrets = config.usesOAuth ? [:] : secrets
        config.clientSecret = config.usesOAuth ? clientSecret : ""
    }

    private func test() async {
        apply()
        mcp.save(config)
        testing = true
        error = nil
        if config.usesOAuth && mcp.mustSignIn(config) { await mcp.signIn(config) }
        tools = await mcp.connect(config)
        error = mcp.status[config.id]
        if config.taskTool.map({ t in !tools.contains { $0.name == t } }) ?? true { config.taskTool = TaskMapping.suggestTaskTool(tools) }
        testing = false
    }
}

struct MCPImportSheet: View {
    @ObservedObject var mcp: MCPConnections
    @Environment(\.dismiss) private var dismiss
    @State private var json = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Import MCP servers").font(.headline)
            Text("Paste a Claude Desktop / Cursor configuration (the \"mcpServers\" object).").foregroundStyle(.secondary)
            TextEditor(text: $json).font(.system(size: 12, design: .monospaced)).frame(height: 200)
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Import") {
                    do {
                        let parsed = try MCPServerConfig.parse(json: json)
                        guard !parsed.isEmpty else { throw LLMError(message: "No servers found") }
                        for (c, secrets) in parsed {
                            c.secrets = secrets
                            mcp.save(c)
                        }
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 560)
    }
}

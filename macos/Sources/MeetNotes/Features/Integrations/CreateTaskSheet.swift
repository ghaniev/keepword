import SwiftUI

/// What the "Create tasks" sheet works on: action items or notes from one meeting.
struct TaskRequest: Identifiable {
    let id = UUID()
    let drafts: [TaskMapping.Draft]
    let serverID: String?
}

extension TaskMapping.Draft {
    /// Task text for an action item, with a link back to the meeting in Keepword.
    init(item: ActionItem, meeting: Meeting?) {
        var details = item.text
        if let who = item.assignee { details += "\n\nAssignee: \(who)" }
        if let m = meeting {
            details += "\n\nFrom meeting “\(m.title)” (\(m.createdAt.formatted(date: .abbreviated, time: .shortened)))"
            details += "\nmeetnotes://open?id=\(m.id)"
        }
        self.init(title: item.text, details: details, due: item.dueDate, assignee: item.assignee, actionItemID: item.id)
    }
}

struct CreateTaskSheet: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var mcp: MCPConnections
    @Environment(\.dismiss) private var dismiss
    let request: TaskRequest

    init(mcp: MCPConnections, request: TaskRequest) {
        self.mcp = mcp
        self.request = request
        _drafts = State(initialValue: request.drafts)
        _serverID = State(initialValue: request.serverID ?? mcp.taskServers.first?.id ?? "")
    }

    @State private var serverID: String
    @State private var tools: [MCPTool] = []
    @State private var toolName = ""
    @State private var drafts: [TaskMapping.Draft]
    @State private var shared: [String: String] = [:]
    @State private var options: [String: [(String, String)]] = [:]
    @State private var loadingField: String?
    @State private var connecting = false
    @State private var creating = false
    @State private var results: [UUID: Result<String, Error>] = [:]

    private var server: MCPServerConfig? { mcp.servers.first { $0.id == serverID } }
    private var tool: MCPTool? { tools.first { $0.name == toolName } }
    private var preset: MCPPreset? { MCPPresets.find(server?.preset) }

    /// The listing tool that offers choices for a field: the preset's, else one guessed from the field name.
    private func lookup(for key: String) -> (tool: MCPTool, spec: MCPPreset.Lookup?)? {
        if let spec = preset?.lookups[key], let t = tools.first(where: { $0.name == spec.tool }) { return (t, spec) }
        return TaskMapping.lookupTool(for: key, in: tools).map { ($0, nil) }
    }

    /// Tool fields shared by all tasks, plus ID fields the pick-lists need (e.g. space_id for list_boards).
    private var sharedFields: [(key: String, prop: [String: Any], required: Bool)] {
        guard let tool else { return [] }
        let hidden = preset?.build == nil || tool.name != preset?.taskTool ? [] : preset?.hidden ?? []
        var fields = tool.properties.filter { !TaskMapping.perTaskField($0.key) && $0.key != "idempotency_key" && !hidden.contains($0.key) }
            .map { (key: $0.key, prop: $0.value, required: tool.required.contains($0.key)) }
        for f in fields {
            guard let lookup = TaskMapping.lookupTool(for: f.key, in: tools) else { continue }
            for (k, p) in lookup.properties where k.hasSuffix("_id") && !fields.contains(where: { $0.key == k }) {
                fields.append((key: k, prop: p, required: false))
            }
        }
        // Required first, then the order a human fills them in (space before board before column).
        let order = ["space_id", "board_id", "column_id", "lane_id", "type_id", "owner_id"]
        return fields.sorted { a, b in
            if a.required != b.required { return a.required }
            return (order.firstIndex(of: a.key) ?? 99, a.key) < (order.firstIndex(of: b.key) ?? 99, b.key)
        }
    }

    private var missingRequired: Bool {
        guard let tool else { return true }
        let hidden = preset?.build == nil || tool.name != preset?.taskTool ? [] : preset?.hidden ?? []
        return tool.required.contains { k in !TaskMapping.perTaskField(k) && !hidden.contains(k) && (shared[k] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(drafts.count == 1 ? "Create Task" : "Create \(drafts.count) Tasks").font(.title2.weight(.semibold))
                Spacer()
                if mcp.taskServers.count > 1 {
                    Picker("", selection: $serverID) { ForEach(mcp.taskServers) { Text($0.name).tag($0.id) } }.labelsHidden().fixedSize()
                } else if let server {
                    Text(server.name).foregroundStyle(.secondary)
                }
            }
            if connecting || mcp.signingIn == serverID {
                HStack { ProgressView().controlSize(.small); Text(mcp.signingIn == serverID ? "Waiting for the browser…" : "Connecting to \(server?.name ?? "server")…") }
            } else if let server, mcp.mustSignIn(server) {
                HStack {
                    Text("Sign in to \(server.name) to create tasks there.").foregroundStyle(.secondary)
                    Button("Sign In…") { Task { await mcp.signIn(server); await load() } }
                }
            } else if let err = mcp.status[serverID] {
                Text(err).foregroundStyle(.red).font(.callout)
            }
            if tool != nil {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        tasksList
                        Divider()
                        fieldsForm
                    }
                }
                .frame(maxHeight: 460)
            }
            HStack {
                if !tools.isEmpty {
                    Picker("Tool", selection: $toolName) { ForEach(tools) { Text($0.name).tag($0.name) } }.fixedSize()
                }
                Spacer()
                Button(results.isEmpty ? "Cancel" : "Done") { dismiss() }
                if creating { ProgressView().controlSize(.small) }
                Button(drafts.count == 1 ? "Create Task" : "Create \(drafts.count) Tasks", action: create)
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(tool == nil || missingRequired || creating || drafts.allSatisfy { results[$0.id].map { (try? $0.get()) != nil } ?? false })
            }
        }
        .padding(22).frame(width: 620)
        .task(id: serverID) { await load() }
    }

    private var tasksList: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach($drafts) { $d in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField("Title", text: $d.title).textFieldStyle(.roundedBorder)
                        if let r = results[d.id] {
                            switch r {
                            case .success(let text):
                                if let link = TaskMapping.link(in: text), let url = URL(string: link) {
                                    Link(destination: url) { Label("Open", systemImage: "checkmark.circle.fill") }.foregroundStyle(.green)
                                } else { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                            case .failure(let e): Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).help(e.localizedDescription)
                            }
                        }
                    }
                    if case .failure(let e) = results[d.id] { Text(e.localizedDescription).font(.caption).foregroundStyle(.red).lineLimit(3) }
                    TextEditor(text: $d.details).font(.system(size: 12)).frame(height: drafts.count == 1 ? 110 : 54)
                        .scrollContentBackground(.hidden).padding(4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
                    if tool?.properties.keys.contains(where: TaskMapping.dueKeys.contains) == true {
                        Toggle("Due date", isOn: Binding(get: { d.due != nil }, set: { d.due = $0 ? (d.due ?? .now) : nil }))
                        if d.due != nil {
                            DatePicker("Due", selection: Binding(get: { d.due ?? .now }, set: { d.due = $0 }), displayedComponents: .date)
                        }
                    }
                }
                .padding(10).background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.03)))
            }
        }
    }

    private var fieldsForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Fields").font(.headline)
            ForEach(sharedFields, id: \.key) { f in
                HStack(alignment: .firstTextBaseline) {
                    Text(f.key + (f.required ? " *" : "")).font(.system(size: 12, design: .monospaced))
                        .frame(width: 130, alignment: .trailing)
                        .help((f.prop["description"] as? String) ?? "")
                    input(for: f.key, prop: f.prop)
                }
            }
            Text("Values you enter here are remembered for the next tasks.").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func input(for key: String, prop: [String: Any]) -> some View {
        let binding = Binding(get: { shared[key] ?? "" }, set: { shared[key] = $0 })
        if let values = prop["enum"] as? [Any] {
            Picker("", selection: binding) {
                Text("—").tag("")
                ForEach(values.map { "\($0)" }, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
        } else if prop["type"] as? String == "boolean" {
            Toggle("", isOn: Binding(get: { binding.wrappedValue == "true" }, set: { binding.wrappedValue = $0 ? "true" : "" })).labelsHidden()
            Spacer()
        } else {
            TextField(preset?.placeholders[key] ?? (prop["type"] as? String) ?? "", text: binding).textFieldStyle(.roundedBorder)
            if let lookup = lookup(for: key) {
                if let opts = options[key], !opts.isEmpty {
                    Menu("Choose") {
                        ForEach(opts, id: \.0) { id, label in Button("\(label)  (\(id))") { shared[key] = id } }
                    }
                    .fixedSize()
                } else {
                    Button(loadingField == key ? "Loading…" : "Look up") { Task { await lookUp(key, with: lookup.tool, spec: lookup.spec) } }
                        .disabled(loadingField != nil).help("Load choices with \(lookup.tool.name)")
                }
            }
        }
    }

    // MARK: actions

    private func load() async {
        guard let server, !mcp.mustSignIn(server) else { return }
        connecting = true
        tools = mcp.tools[server.id] ?? []
        if tools.isEmpty { tools = await mcp.connect(server) }
        connecting = false
        toolName = [server.taskTool, preset?.taskTool, TaskMapping.suggestTaskTool(tools)].compactMap { $0 }.first { n in tools.contains { $0.name == n } }
            ?? tools.first?.name ?? ""
        shared = server.taskDefaults
        options = [:]
    }

    private func lookUp(_ key: String, with lookup: MCPTool, spec: MCPPreset.Lookup?) async {
        guard let server else { return }
        loadingField = key
        defer { loadingField = nil }
        var args: [String: Any] = [:]
        for (k, p) in lookup.properties {
            if let v = shared[k], !v.isEmpty { args[k] = (p["type"] as? String == "integer" || p["type"] as? String == "number") ? (Int(v) as Any? ?? v) : v }
            if let e = p["enum"] as? [String], e.contains("json"), k.contains("format") { args[k] = "json" }
        }
        // Preset parameters: top level if the tool declares them, else inside its `inputs` object (Atlassian's style).
        var inputs: [String: Any] = [:]
        for (param, field) in spec?.args ?? [:] {
            guard let v = shared[field], !v.isEmpty else { continue }
            if lookup.properties[param] != nil || lookup.properties["inputs"] == nil { args[param] = v } else { inputs[param] = v }
        }
        if !inputs.isEmpty { args["inputs"] = inputs }
        do {
            let text = try await mcp.call(server, lookup.name, args)
            options[key] = TaskMapping.options(from: text, value: spec?.value ?? "id")
            if options[key]?.isEmpty != false { mcp.status[server.id] = "\(lookup.name) returned nothing to choose from." }
        } catch {
            mcp.status[server.id] = error.localizedDescription
        }
    }

    private func create() {
        guard var server, let tool else { return }
        creating = true
        Task {
            for d in drafts where (results[d.id].map { (try? $0.get()) == nil } ?? true) {
                do {
                    let args = preset?.taskTool == tool.name ? preset?.build?(d, shared) : nil
                    let text = try await mcp.call(server, tool.name, args ?? TaskMapping.arguments(for: d, tool: tool, shared: shared))
                    results[d.id] = .success(text)
                    if let itemID = d.actionItemID,
                       var item = try? await model.store.db.read({ try ActionItem.fetchOne($0, key: itemID) }) {
                        item.taskRef = TaskMapping.link(in: text) ?? server.name
                        try? model.store.saveActionItem(item)
                    }
                } catch {
                    results[d.id] = .failure(error)
                }
            }
            // Remember shared choices (board, column…) and the tool for next time.
            server.taskDefaults = shared.filter { !$0.value.isEmpty }
            server.taskTool = tool.name
            mcp.save(server)
            creating = false
            let ok = results.values.filter { (try? $0.get()) != nil }.count
            model.toast = String(localized: "Created \(ok) of \(drafts.count) tasks in \(server.name)")
        }
    }
}

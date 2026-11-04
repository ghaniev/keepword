import Foundation

/// A user-configured MCP server MeetNotes talks to as a client (e.g. kaiten-mcp-server to create tasks).
/// Env values and headers can hold tokens, so they live in the Keychain; the rest is in preferences.
struct MCPServerConfig: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var name = ""
    var transport = "stdio"  // stdio | http
    var command = ""
    var args: [String] = []
    var url = ""
    var taskTool: String?  // tool used to create a task, e.g. kaiten_create_card
    var taskDefaults: [String: String] = [:]  // remembered non-task fields (board_id, column_id…)

    /// KEY=VALUE environment (stdio) or Name: value headers (http), stored together in the Keychain.
    var secrets: [String: String] {
        get { (try? JSONDecoder().decode([String: String].self, from: Data(Keychain.get("mcp.\(id)").utf8))) ?? [:] }
        nonmutating set { Keychain.set("mcp.\(id)", newValue.isEmpty ? "" : String(decoding: (try? JSONEncoder().encode(newValue)) ?? Data(), as: UTF8.self)) }
    }

    /// Reads Claude Desktop / Cursor style `{"mcpServers": {"name": {"command", "args", "env"} | {"url", "headers"}}}`.
    static func parse(json: String) throws -> [(MCPServerConfig, [String: String])] {
        guard let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { throw LLMError(message: "Not a JSON object") }
        let servers = (obj["mcpServers"] as? [String: Any]) ?? obj
        return servers.compactMap { name, value in
            guard let v = value as? [String: Any] else { return nil }
            var c = MCPServerConfig()
            c.name = name
            if let url = v["url"] as? String {
                c.transport = "http"
                c.url = url
                return (c, v["headers"] as? [String: String] ?? [:])
            }
            guard let command = v["command"] as? String else { return nil }
            c.command = command
            c.args = v["args"] as? [String] ?? []
            return (c, v["env"] as? [String: String] ?? [:])
        }.sorted { $0.0.name < $1.0.name }
    }
}

struct MCPTool: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let description: String
    let schemaJSON: Data  // JSON Schema of the arguments

    var schema: [String: Any] { (try? JSONSerialization.jsonObject(with: schemaJSON) as? [String: Any]) ?? [:] }
    var properties: [String: [String: Any]] { schema["properties"] as? [String: [String: Any]] ?? [:] }
    var required: [String] { schema["required"] as? [String] ?? [] }
}

/// JSON-RPC client over stdio (a child process, newline-delimited JSON) or Streamable HTTP.
actor MCPClient {
    private enum PipeEvent: @unchecked Sendable { case out(Data), err(Data), exit(Process) }
    let config: MCPServerConfig
    private var process: Process?
    private var stdin: FileHandle?
    private var buffer = Data()
    private var stderrTail = ""
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var nextID = 1
    private var sessionID: String?
    private var initialized = false
    private var starting: Task<Void, Error>?  // concurrent callers share one startup

    init(config: MCPServerConfig) { self.config = config }

    func tools() async throws -> [MCPTool] {
        try await ensureStarted()
        var out: [MCPTool] = []
        var cursor: String?
        repeat {
            let r = try await request("tools/list", cursor.map { ["cursor": $0] } ?? [:])
            for t in r["tools"] as? [[String: Any]] ?? [] {
                guard let name = t["name"] as? String else { continue }
                let schema = (t["inputSchema"] as? [String: Any]).flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data("{}".utf8)
                out.append(MCPTool(name: name, description: t["description"] as? String ?? "", schemaJSON: schema))
            }
            cursor = r["nextCursor"] as? String
        } while cursor != nil
        return out
    }

    /// Calls a tool; returns its text content. Tool-level failures (isError) throw with the server's message.
    func call(_ tool: String, _ arguments: [String: Any]) async throws -> String {
        try await ensureStarted()
        let r = try await request("tools/call", ["name": tool, "arguments": arguments], timeout: 120)
        let text = (r["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
        if r["isError"] as? Bool == true { throw LLMError(message: text.isEmpty ? "\(tool) failed" : text) }
        return text
    }

    func stop() {
        process?.terminate()
        process = nil
        initialized = false
        for (_, c) in pending { c.resume(throwing: LLMError(message: "MCP server stopped")) }
        pending = [:]
    }

    // MARK: lifecycle

    private func ensureStarted() async throws {
        if initialized, config.transport == "http" || process?.isRunning == true { return }
        if let starting { return try await starting.value }
        let t = Task { try await start() }
        starting = t
        defer { starting = nil }
        try await t.value
    }

    private func start() async throws {
        initialized = false
        if config.transport == "stdio" { try launch() }
        _ = try await request("initialize", [
            "protocolVersion": "2025-06-18", "capabilities": [String: Any](),
            "clientInfo": ["name": "MeetNotes", "version": "0.4"],
        ], timeout: 60)
        try await notify("notifications/initialized")
        initialized = true
    }

    private func launch() throws {
        stop()
        let cmd = config.command.trimmingCharacters(in: .whitespaces)
        guard let exe = cmd.hasPrefix("/") ? URL(filePath: cmd) : CLIProvider.locate(cmd) else {
            throw LLMError(message: "“\(cmd)” not found. Use a full path (e.g. /usr/local/bin/node) or install it.")
        }
        let p = Process()
        p.executableURL = exe
        p.arguments = config.args
        var env = ProcessInfo.processInfo.environment
        // GUI apps lack the shell PATH; node-based servers need their own bin dir to find `node`.
        env["PATH"] = [exe.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", env["PATH"] ?? ""].joined(separator: ":")
        for (k, v) in config.secrets { env[k] = v }
        p.environment = env
        p.currentDirectoryURL = FileManager.default.temporaryDirectory
        let input = Pipe(), output = Pipe(), errors = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = errors
        // Pipe callbacks run on arbitrary threads. One stream keeps chunks and the exit in arrival order
        // (a Task per chunk may run out of order and garble a large JSON reply).
        let (events, sink) = AsyncStream.makeStream(of: PipeEvent.self)
        output.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil } else { sink.yield(.out(data)) }
        }
        errors.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil } else { sink.yield(.err(data)) }
        }
        p.terminationHandler = { proc in sink.yield(.exit(proc)); sink.finish() }
        Task { [weak self] in
            for await e in events {
                switch e {
                case .out(let d): await self?.received(d)
                case .err(let d): await self?.stderr(String(decoding: d, as: UTF8.self))
                case .exit(let proc): await self?.exited(proc)
                }
            }
        }
        try p.run()
        process = p
        stdin = input.fileHandleForWriting
    }

    private func stderr(_ text: String) { stderrTail = String((stderrTail + text).suffix(2000)) }

    private func exited(_ proc: Process) {
        guard proc === process else { return }  // an older process we replaced or stopped
        let status = proc.terminationStatus
        let why = stderrTail.split(separator: "\n").suffix(3).joined(separator: " ")
        for (_, c) in pending { c.resume(throwing: LLMError(message: "MCP server exited (\(status)). \(why)")) }
        pending = [:]
        process = nil
        initialized = false
    }

    private func received(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            if let msg = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { deliver(msg) }
        }
    }

    private func deliver(_ msg: [String: Any]) {
        guard let id = msg["id"] as? Int, let c = pending.removeValue(forKey: id) else { return }  // ignore notifications
        if let err = msg["error"] as? [String: Any] {
            c.resume(throwing: LLMError(message: err["message"] as? String ?? "MCP error"))
        } else {
            c.resume(returning: msg["result"] as? [String: Any] ?? [:])
        }
    }

    // MARK: JSON-RPC

    private func notify(_ method: String) async throws {
        let msg: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if config.transport == "http" { _ = try await post(msg) } else { try write(msg) }
    }

    private func request(_ method: String, _ params: [String: Any], timeout: TimeInterval = 60) async throws -> [String: Any] {
        let id = nextID
        nextID += 1
        let msg: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        if config.transport == "http" {
            guard let reply = try await post(msg, expecting: id) else { throw LLMError(message: "No response to \(method)") }
            if let err = reply["error"] as? [String: Any] { throw LLMError(message: err["message"] as? String ?? "MCP error") }
            return reply["result"] as? [String: Any] ?? [:]
        }
        try write(msg)
        return try await withCheckedThrowingContinuation { c in
            pending[id] = c
            Task {
                try? await Task.sleep(for: .seconds(timeout))
                self.timeout(id, method)
            }
        }
    }

    private func timeout(_ id: Int, _ method: String) {
        pending.removeValue(forKey: id)?.resume(throwing: LLMError(message: "MCP server did not answer \(method) in time"))
    }

    private func write(_ msg: [String: Any]) throws {
        guard let stdin, process?.isRunning == true else { throw LLMError(message: "MCP server is not running") }
        var data = try JSONSerialization.data(withJSONObject: msg)
        data.append(0x0A)
        try stdin.write(contentsOf: data)
    }

    /// Streamable HTTP: one POST per message; the reply is JSON or an SSE stream carrying the response.
    private func post(_ msg: [String: Any], expecting id: Int? = nil) async throws -> [String: Any]? {
        guard let url = URL(string: config.url) else { throw LLMError(message: "Invalid MCP server URL") }
        var r = URLRequest(url: url, timeoutInterval: 120)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let sessionID { r.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        for (k, v) in config.secrets { r.setValue(v, forHTTPHeaderField: k) }
        r.httpBody = try JSONSerialization.data(withJSONObject: msg)
        let (data, response) = try await URLSession.shared.data(for: r)
        let http = response as? HTTPURLResponse
        if let s = http?.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionID = s }
        guard let code = http?.statusCode, (200..<300).contains(code) else {
            throw LLMError(message: "MCP server HTTP \(http?.statusCode ?? 0): \(String(decoding: data.prefix(200), as: UTF8.self))")
        }
        guard let id else { return nil }
        if http?.value(forHTTPHeaderField: "Content-Type")?.contains("text/event-stream") == true {
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") where line.hasPrefix("data:") {
                if let m = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8)) as? [String: Any], m["id"] as? Int == id { return m }
            }
            return nil
        }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

/// Configured servers, their live clients and tool lists.
@MainActor
final class MCPConnections: ObservableObject {
    @Published var servers: [MCPServerConfig] = []
    @Published var tools: [String: [MCPTool]] = [:]  // server id → tools
    @Published var status: [String: String] = [:]  // server id → error text
    private var clients: [String: MCPClient] = [:]

    init() {
        servers = (try? JSONDecoder().decode([MCPServerConfig].self, from: UserDefaults.standard.data(forKey: "mcpClientServers") ?? Data())) ?? []
    }

    /// Servers that have a task tool chosen: these get "Create task in …" actions.
    var taskServers: [MCPServerConfig] { servers.filter { $0.taskTool != nil } }

    func save(_ s: MCPServerConfig) {
        if let i = servers.firstIndex(where: { $0.id == s.id }) { servers[i] = s } else { servers.append(s) }
        persist()
        Task { await clients.removeValue(forKey: s.id)?.stop() }  // reconnect with the new settings
    }

    func remove(_ s: MCPServerConfig) {
        s.secrets = [:]
        servers.removeAll { $0.id == s.id }
        tools[s.id] = nil
        persist()
        Task { await clients.removeValue(forKey: s.id)?.stop() }
    }

    private func persist() { UserDefaults.standard.set(try? JSONEncoder().encode(servers), forKey: "mcpClientServers") }

    private func client(_ s: MCPServerConfig) -> MCPClient {
        if let c = clients[s.id] { return c }
        let c = MCPClient(config: s)
        clients[s.id] = c
        return c
    }

    @discardableResult
    func connect(_ s: MCPServerConfig) async -> [MCPTool] {
        do {
            let list = try await client(s).tools()
            tools[s.id] = list
            status[s.id] = nil
            return list
        } catch {
            status[s.id] = error.localizedDescription
            return []
        }
    }

    func call(_ s: MCPServerConfig, _ tool: String, _ args: [String: Any]) async throws -> String {
        try await client(s).call(tool, args)
    }

    func stopAll() {
        for c in clients.values { Task { await c.stop() } }
        clients = [:]
    }
}

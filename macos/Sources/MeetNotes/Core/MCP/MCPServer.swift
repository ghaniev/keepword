import Foundation
import Network
import Security

/// Local MCP server (Streamable HTTP transport, JSON-RPC 2.0) so Claude Code / Claude Desktop / other MCP clients
/// can search and read your meetings. Listens on 127.0.0.1 only and requires a bearer token.
final class MCPServer: ObservableObject, @unchecked Sendable {
    @Published private(set) var status = String(localized: "Stopped")
    private var listener: NWListener?
    private var store: Store?
    private let queue = DispatchQueue(label: "meetnotes.mcp")

    static var token: String {
        let existing = Keychain.get("mcpToken")
        if !existing.isEmpty { return existing }
        return regenerateToken()
    }

    @discardableResult
    static func regenerateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let t = bytes.map { String(format: "%02x", $0) }.joined()
        Keychain.set("mcpToken", t)
        return t
    }

    func start(port: UInt16, store: Store) throws {
        stop()
        self.store = store
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? 8765)
        let l = try NWListener(using: params)
        l.newConnectionHandler = { [weak self] c in self?.serve(c) }
        l.stateUpdateHandler = { [weak self] state in
            let text: String = switch state {
            case .ready: "Running on http://127.0.0.1:\(port)/mcp"
            case .failed(let e): "Failed: \(e.localizedDescription)"
            case .cancelled: "Stopped"
            default: "Starting…"
            }
            DispatchQueue.main.async { self?.status = text }
        }
        l.start(queue: queue)
        listener = l
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: HTTP

    private func serve(_ c: NWConnection) {
        c.start(queue: queue)
        receive(c, buffer: Data())
    }

    private func receive(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if buf.count > 4 << 20 { return self.send(c, status: 413, body: nil) }
            if let req = HTTPRequest.parse(buf) {
                self.handle(req, c)
            } else if done || error != nil {
                c.cancel()
            } else {
                self.receive(c, buffer: buf)
            }
        }
    }

    private func handle(_ req: HTTPRequest, _ c: NWConnection) {
        guard req.path.split(separator: "?").first == "/mcp" else { return send(c, status: 404, body: nil) }
        // DNS-rebinding guard from the MCP spec: browsers send Origin; only local pages may talk to us.
        if let origin = req.headers["origin"], !(origin.hasPrefix("http://localhost") || origin.hasPrefix("http://127.0.0.1")) {
            return send(c, status: 403, body: nil)
        }
        guard req.headers["authorization"] == "Bearer \(Self.token)" else { return send(c, status: 401, body: nil) }
        guard req.method == "POST" else { return send(c, status: 405, body: nil) }  // no server-initiated SSE stream
        guard let store, let msg = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any] else {
            return send(c, status: 400, body: nil)
        }
        Task {
            if let reply = await MCPHandler.handle(msg, store: store) {
                self.send(c, status: 200, body: try? JSONSerialization.data(withJSONObject: reply))
            } else {
                self.send(c, status: 202, body: nil)  // notification
            }
        }
    }

    private func send(_ c: NWConnection, status: Int, body: Data?) {
        let reason = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
                      404: "Not Found", 405: "Method Not Allowed", 413: "Payload Too Large"][status] ?? "Error"
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: \(body?.count ?? 0)\r\nConnection: close\r\n"
        if body != nil { head += "Content-Type: application/json\r\n" }
        if status == 401 { head += "WWW-Authenticate: Bearer\r\n" }
        var out = Data((head + "\r\n").utf8)
        if let body { out.append(body) }
        c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
    }
}

struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]  // lowercased names
    let body: Data

    /// Returns nil until the full request (headers + Content-Length body) has arrived.
    static func parse(_ data: Data) -> HTTPRequest? {
        guard let sep = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<sep.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let parts = head.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in head.dropFirst() {
            guard let i = line.firstIndex(of: ":") else { continue }
            headers[line[..<i].lowercased()] = line[line.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = data[sep.upperBound...]
        guard body.count >= length else { return nil }
        return HTTPRequest(method: String(parts[0]), path: String(parts[1]), headers: headers, body: Data(body.prefix(length)))
    }
}

enum MCPHandler {
    static let tools: [[String: Any]] = [
        tool("search_meetings", "Semantic + keyword search across all meetings. Returns meeting ids, titles, dates and a matching snippet. Use the ids with get_transcript, get_summary or get_action_items.",
             ["query": prop("string", "Topic, phrase or keywords."), "limit": prop("integer", "Max meetings, default 10, max 50.")], required: ["query"]),
        tool("list_meetings", "List meetings, newest first, optionally filtered by person, tag or date range.",
             ["person": prop("string", "Attendee name (matches renamed and merged people)."), "tag": prop("string", "Tag name."),
              "date_from": prop("string", "yyyy-MM-dd"), "date_to": prop("string", "yyyy-MM-dd"), "limit": prop("integer", "Default 20.")]),
        tool("get_transcript", "Full transcript of one meeting. Each line: [mm:ss] Speaker: text.",
             ["meeting_id": prop("string", "Meeting id.")], required: ["meeting_id"]),
        tool("get_summary", "Overview, highlights (with times), follow-ups, tags, participants and notes of one meeting.",
             ["meeting_id": prop("string", "Meeting id.")], required: ["meeting_id"]),
        tool("get_action_items", "Follow-ups across meetings.",
             ["meeting_ids": ["type": "array", "items": ["type": "string"], "description": "Optional meeting ids; omit for all meetings."],
              "open_only": prop("boolean", "Only incomplete items (default true).")]),
    ]

    private static func prop(_ type: String, _ d: String) -> [String: Any] { ["type": type, "description": d] }
    private static func tool(_ name: String, _ d: String, _ props: [String: Any], required: [String] = []) -> [String: Any] {
        ["name": name, "description": d, "inputSchema": ["type": "object", "properties": props, "required": required]]
    }

    static func handle(_ msg: [String: Any], store: Store) async -> [String: Any]? {
        guard let id = msg["id"] else { return nil }  // notifications get 202
        let params = msg["params"] as? [String: Any] ?? [:]
        func ok(_ r: Any) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "result": r] }
        switch msg["method"] as? String {
        case "initialize":
            return ok(["protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                       "capabilities": ["tools": ["listChanged": false]],
                       "serverInfo": ["name": "Keepword", "version": "0.3"],
                       "instructions": "Search the user's recorded meetings with search_meetings or list_meetings, then read them with get_summary or get_transcript."])
        case "ping": return ok([String: Any]())
        case "tools/list": return ok(["tools": tools])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            do {
                return ok(["content": [["type": "text", "text": try await call(name, args, store: store)]], "isError": false])
            } catch {
                return ok(["content": [["type": "text", "text": error.localizedDescription]], "isError": true])
            }
        default:
            return ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found"]]
        }
    }

    static func call(_ name: String, _ a: [String: Any], store: Store) async throws -> String {
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        func meeting(_ key: String = "meeting_id") throws -> Meeting {
            guard let id = a[key] as? String, let m = store.meeting(id), m.deletedAt == nil else { throw LLMError(message: "Unknown meeting_id") }
            return m
        }
        func line(_ m: Meeting) -> String { "- \(m.id) · \(m.title) · \(day.string(from: m.createdAt)) · \(durationLabel(m.duration))" }

        switch name {
        case "search_meetings":
            guard let q = a["query"] as? String, !q.isEmpty else { throw LLMError(message: "query is required") }
            let results = try await Pipeline.search(q, store: store).prefix(min(a["limit"] as? Int ?? 10, 50))
            return results.isEmpty ? "No matching meetings." : results.map {
                line($0.meeting) + " · \(Int($0.score * 100))%\n  " + $0.snippet.prefix(300)
            }.joined(separator: "\n")
        case "list_meetings":
            var ms = try store.meetings(.all)
            if let p = a["person"] as? String, !p.isEmpty {
                let ids = try store.people().map(\.0).filter { $0.name.localizedCaseInsensitiveContains(p) }.map(\.id)
                let hits = Set(try ids.flatMap { try store.meetings(.person($0)).map(\.id) })
                ms = ms.filter { hits.contains($0.id) }
            }
            if let t = a["tag"] as? String, let tag = try store.allTags().first(where: { $0.0.name == t.lowercased() })?.0 {
                let hits = Set(try store.meetings(.tag(tag.id)).map(\.id))
                ms = ms.filter { hits.contains($0.id) }
            }
            if let f = (a["date_from"] as? String).flatMap(day.date(from:)) { ms = ms.filter { $0.createdAt >= f } }
            if let t = (a["date_to"] as? String).flatMap(day.date(from:)) { ms = ms.filter { $0.createdAt < t.addingTimeInterval(86400) } }
            let out = ms.prefix(a["limit"] as? Int ?? 20).map(line)
            return out.isEmpty ? "No meetings match." : out.joined(separator: "\n")
        case "get_transcript":
            let m = try meeting()
            let all = try store.speakers()
            return String(("# \(m.title)\n" + (try store.segments(of: m.id).filter { !$0.irrelevant }
                .map { "[\(timestamp($0.start))] \(store.root($0.speakerId, in: all)?.name ?? "Speaker"): \($0.text)" }
                .joined(separator: "\n"))).prefix(200_000))
        case "get_summary":
            let m = try meeting()
            return try MarkdownExport.render(m.id, store: store, frontmatter: true).components(separatedBy: "\n## Transcript")[0]
        case "get_action_items":
            let ids = (a["meeting_ids"] as? [String]).map(Set.init)
            let openOnly = a["open_only"] as? Bool ?? true
            let items = try store.allActionItems().filter { (ids?.contains($0.1.id) ?? true) && (!openOnly || !$0.0.completed) }
            return items.isEmpty ? "No follow-ups." : items.map { item, m in
                "- [\(item.completed ? "x" : " ")] \(item.text)" + (item.assignee.map { " — \($0)" } ?? "")
                    + (item.dueDate.map { " (due \(day.string(from: $0)))" } ?? "") + " · \(m.title) [\(m.id)]"
            }.joined(separator: "\n")
        default:
            throw LLMError(message: "Unknown tool \(name)")
        }
    }
}

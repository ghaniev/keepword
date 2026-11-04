import Foundation

/// Uses an AI CLI the user is already signed in to, so summaries run on their ChatGPT or Claude subscription
/// instead of an API key: `codex exec` (OpenAI Codex CLI) or `claude -p` (Claude Code).
/// Like any cloud provider, the transcript goes to that service.
enum CLIProvider {
    static let tools = ["codex": "Codex CLI (ChatGPT subscription)", "claude": "Claude Code CLI (Claude subscription)"]
    static let defaultModel = ["codex": "gpt-5.6-terra", "claude": "sonnet"]
    static let loginHint = ["codex": "codex login", "claude": "claude   (then type /login)"]

    static func chat(tool: String, model: String, messages: [[String: String]]) async throws -> String {
        guard tools[tool] != nil else { throw LLMError(message: "Unknown CLI provider “\(tool)”") }
        guard let exe = locate(tool) else {
            throw LLMError(message: "\(tool) CLI not found. Install it or set its path in Settings → AI Provider.")
        }
        let system = messages.filter { $0["role"] == "system" }.compactMap { $0["content"] }.joined(separator: "\n\n")
        let turns = messages.filter { $0["role"] != "system" }
        // CLIs take one prompt: earlier turns become a transcript, the last user message is the request.
        var prompt = turns.dropLast().map { "\($0["role"] == "assistant" ? "Assistant" : "User"): \($0["content"] ?? "")" }.joined(separator: "\n\n")
        if !prompt.isEmpty { prompt = "Conversation so far:\n\(prompt)\n\n---\n" }
        prompt += turns.last?["content"] ?? ""

        let work = FileManager.default.temporaryDirectory.appending(path: "meetnotes-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let answer = work.appending(path: "answer.txt")

        var args: [String]
        var input = prompt
        switch tool {
        case "claude":
            // No tools, no MCP, no user settings: a plain completion.
            args = ["-p", "--output-format", "text", "--tools", "", "--no-session-persistence", "--strict-mcp-config",
                    "--setting-sources", "", "--disable-slash-commands"]
            if !system.isEmpty { args += ["--system-prompt", system] }
        default:  // "codex" (checked above)
            args = ["exec", "--skip-git-repo-check", "--ephemeral", "-s", "read-only", "--color", "never",
                    "-c", "model_reasoning_effort=low", "-c", "mcp_servers={}", "-o", answer.path, "-"]
            input = (system.isEmpty ? "" : "Instructions (follow exactly, answer directly, do not run commands):\n\(system)\n\n---\n") + prompt
        }
        if !model.isEmpty { args += tool == "claude" ? ["--model", model] : ["-m", model] }

        let (status, stdout, stderr) = try await run(exe, args, input: input, cwd: work)
        let text = tool == "claude" ? stdout : ((try? String(contentsOf: answer, encoding: .utf8)) ?? "")
        guard status == 0, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let detail = (stderr + "\n" + stdout).split(separator: "\n").filter { !$0.contains("rmcp::") }.suffix(3).joined(separator: " ")
            throw LLMError(message: "\(tool) failed (exit \(status)): \(detail.prefix(400)). If you are signed out, run: \(loginHint[tool] ?? tool)")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated(unsafe) private static var located: [String: URL] = [:]
    private static let locateLock = NSLock()

    /// GUI apps don't get the shell PATH. Resolve a command the way the user's terminal does (login shell, so nvm /
    /// Homebrew versions win over an old system copy), then fall back to the usual install places. Cached per name.
    static func locate(_ tool: String) -> URL? {
        if let custom = UserDefaults.standard.string(forKey: "cliPath_\(tool)"), !custom.isEmpty,
           FileManager.default.isExecutableFile(atPath: custom) { return URL(filePath: custom) }
        if let hit = locateLock.withLock({ located[tool] }) { return hit }
        let found = shellLookup(tool) ?? directoryLookup(tool)
        if let found { locateLock.withLock { located[tool] = found } }
        return found
    }

    private static func shellLookup(_ tool: String) -> URL? {
        guard tool.allSatisfy({ $0.isLetter || $0.isNumber || "-_.".contains($0) }) else { return nil }
        let p = Process()
        p.executableURL = URL(filePath: "/bin/zsh")
        p.arguments = ["-lic", "command -v \(tool)"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let path = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return path.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: path) ? URL(filePath: path) : nil
    }

    private static func directoryLookup(_ tool: String) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let nvm = "\(home)/.nvm/versions/node"
        let nvmDirs = ((try? FileManager.default.contentsOfDirectory(atPath: nvm)) ?? [])
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }.map { "\(nvm)/\($0)/bin" }  // newest first
        let dirs = ["\(home)/.local/bin", "/opt/homebrew/bin"] + nvmDirs + ["/usr/local/bin", "\(home)/.npm-global/bin", "\(home)/.bun/bin", "/usr/bin"]
        return dirs.first { FileManager.default.isExecutableFile(atPath: "\($0)/\(tool)") }.map { URL(filePath: "\($0)/\(tool)") }
    }

    /// Runs a process with stdin text; output goes to files so large outputs can't deadlock pipes.
    static func run(_ exe: URL, _ args: [String], input: String, cwd: URL, timeout: TimeInterval = 900) async throws -> (Int32, String, String) {
        let outURL = cwd.appending(path: "stdout"), errURL = cwd.appending(path: "stderr"), inURL = cwd.appending(path: "stdin")
        try Data(input.utf8).write(to: inURL)
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        p.currentDirectoryURL = cwd
        // `#!/usr/bin/env node` scripts need their own bin dir on PATH.
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = [exe.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", env["PATH"] ?? ""]
            .joined(separator: ":")
        env["NO_COLOR"] = "1"
        p.environment = env
        p.standardInput = try FileHandle(forReadingFrom: inURL)
        p.standardOutput = try FileHandle(forWritingTo: outURL)
        p.standardError = try FileHandle(forWritingTo: errURL)
        return try await withCheckedThrowingContinuation { cont in
            p.terminationHandler = { proc in
                let out = (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
                let err = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
                cont.resume(returning: (proc.terminationStatus, out, err))
            }
            do { try p.run() } catch { cont.resume(throwing: error); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }
        }
    }
}

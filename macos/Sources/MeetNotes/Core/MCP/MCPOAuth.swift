import CryptoKit
import Foundation

/// The server wants a signed-in user (no tokens yet, or they were revoked).
struct MCPAuthRequired: LocalizedError {
    let server: String
    var errorDescription: String? { String(localized: "Sign in to \(server) to use it.") }
}

/// Tokens for one MCP server, kept in the Keychain.
struct MCPOAuthTokens: Codable, Sendable {
    var clientID: String
    var clientSecret: String?
    var clientAuth: String?  // token_endpoint_auth_method: none | client_secret_post | client_secret_basic
    var tokenEndpoint: String
    var resource: String?
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
}

/// OAuth 2.1 for remote MCP servers, following the MCP authorization spec: protected-resource and
/// authorization-server discovery, dynamic client registration (or a client registered by hand),
/// PKCE, the resource parameter, a loopback redirect and token refresh.
actor MCPOAuth {
    static let shared = MCPOAuth()
    /// Redirect port for clients registered by hand: their redirect URL has to be fixed.
    static let fixedPort: UInt16 = 47821
    static var fixedRedirect: String { "http://localhost:\(fixedPort)/callback" }

    /// Token storage; the self-test swaps the Keychain for memory.
    nonisolated(unsafe) static var load: @Sendable (String) -> String = { Keychain.get($0) }
    nonisolated(unsafe) static var save: @Sendable (String, String) -> Void = { Keychain.set($0, $1) }

    nonisolated static func tokens(_ serverID: String) -> MCPOAuthTokens? {
        try? JSONDecoder().decode(MCPOAuthTokens.self, from: Data(load("mcp.oauth.\(serverID)").utf8))
    }

    nonisolated static func setTokens(_ t: MCPOAuthTokens?, _ serverID: String) {
        save("mcp.oauth.\(serverID)", t.flatMap { try? JSONEncoder().encode($0) }.map { String(decoding: $0, as: UTF8.self) } ?? "")
    }

    nonisolated static func signedIn(_ serverID: String) -> Bool { tokens(serverID) != nil }

    private var refreshing: [String: Task<MCPOAuthTokens?, Error>] = [:]

    /// The bearer token for a request, refreshed a minute before it expires. nil means the user has to sign in.
    func accessToken(for c: MCPServerConfig, forceRefresh: Bool = false) async throws -> String? {
        guard let t = Self.tokens(c.id) else { return nil }
        let stale = t.expiresAt.map { $0 < .now.addingTimeInterval(60) } ?? false
        guard forceRefresh || stale else { return t.accessToken }
        guard t.refreshToken != nil else { return forceRefresh ? nil : t.accessToken }
        return try await refresh(c.id, t)?.accessToken
    }

    /// One refresh at a time per server: some servers rotate refresh tokens and revoke the grant when an old one is reused.
    private func refresh(_ id: String, _ t: MCPOAuthTokens) async throws -> MCPOAuthTokens? {
        if let running = refreshing[id] { return try await running.value }
        let task = Task<MCPOAuthTokens?, Error> {
            var params = ["grant_type": "refresh_token", "refresh_token": t.refreshToken ?? ""]
            if let r = t.resource { params["resource"] = r }
            do {
                var fresh = try await Self.tokenRequest(t, params)
                if fresh.refreshToken == nil { fresh.refreshToken = t.refreshToken }
                Self.setTokens(fresh, id)
                return fresh
            } catch let e as OAuthError where e.code == "invalid_grant" {
                Self.setTokens(nil, id)  // expired or revoked: sign in again
                return nil
            }
        }
        refreshing[id] = task
        defer { refreshing[id] = nil }
        return try await task.value
    }

    // MARK: sign-in

    /// Runs the browser sign-in and stores the tokens. `scope` overrides what the server advertises ("" sends none).
    /// `open` shows the authorization page (the app opens the browser; the self-test follows it with URLSession).
    func signIn(_ c: MCPServerConfig, scope override: String?, open: @escaping @Sendable (URL) async -> Void) async throws {
        guard let serverURL = URL(string: c.url) else { throw LLMError(message: "Invalid MCP server URL") }
        let found = try await Self.discover(serverURL)
        let manual = !(c.clientID ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        if !manual && found.registration == nil {
            throw LLMError(message: String(localized: "\(c.name) doesn't register apps automatically. Create an OAuth app in its developer settings with the redirect URL \(Self.fixedRedirect) and enter its client ID and secret."))
        }

        // The loopback listener comes first: dynamic registration needs the redirect URL with its port.
        let (callbacks, sink) = AsyncStream.makeStream(of: [String: String].self)
        let server: LoopbackHTTP
        do {
            server = try await LoopbackHTTP(port: manual ? Self.fixedPort : 0) { req in
                guard req.route == "/callback" else { return .init(status: 404) }
                sink.yield(req.query)
                let ok = req.query["code"] != nil
                return .html("<!doctype html><meta charset=utf-8><title>Keepword</title><body style=\"font:16px -apple-system,sans-serif;margin:3em\">"
                    + (ok ? String(localized: "Signed in. You can close this tab and return to Keepword.") : String(localized: "Sign-in failed. Return to Keepword for details."))
                    + "</body>")
            }
        } catch {
            throw LLMError(message: String(localized: "Port \(String(Self.fixedPort)) for the sign-in redirect is busy. Close the app that uses it and try again."))
        }
        defer { server.stop(); sink.finish() }
        let redirect = "http://localhost:\(server.port)/callback"

        var client = MCPOAuthTokens(clientID: c.clientID ?? "", clientSecret: c.clientSecret.isEmpty ? nil : c.clientSecret,
                                    clientAuth: nil, tokenEndpoint: found.token, resource: found.resource, accessToken: "")
        if !manual, let registration = found.registration {
            let reg = try await Self.postJSON(registration, [
                "client_name": "Keepword", "redirect_uris": [redirect], "grant_types": ["authorization_code", "refresh_token"],
                "response_types": ["code"], "token_endpoint_auth_method": "none",
            ])
            guard let id = reg["client_id"] as? String else { throw LLMError(message: "\(c.name): client registration returned no client_id") }
            client.clientID = id
            client.clientSecret = reg["client_secret"] as? String
            client.clientAuth = reg["token_endpoint_auth_method"] as? String
        }

        let verifier = Self.randomString()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = Self.randomString()
        var auth = URLComponents(string: found.authorize)!
        var items = (auth.queryItems ?? []) + [
            .init(name: "response_type", value: "code"), .init(name: "client_id", value: client.clientID),
            .init(name: "redirect_uri", value: redirect), .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"), .init(name: "state", value: state),
        ]
        if let r = found.resource { items.append(.init(name: "resource", value: r)) }
        if let s = override ?? found.scope, !s.isEmpty { items.append(.init(name: "scope", value: s)) }
        auth.queryItems = items
        await open(auth.url!)

        let reply: [String: String] = try await withThrowingTaskGroup(of: [String: String].self) { group in
            group.addTask {
                for await q in callbacks where q["state"] != nil || q["error"] != nil { return q }
                throw CancellationError()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(300))
                throw LLMError(message: String(localized: "Sign-in timed out."))
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
        if let e = reply["error"] { throw LLMError(message: "\(c.name): \(reply["error_description"] ?? e)") }
        guard reply["state"] == state, let code = reply["code"] else { throw LLMError(message: "\(c.name): the sign-in reply didn't match the request") }

        var params = ["grant_type": "authorization_code", "code": code, "redirect_uri": redirect, "code_verifier": verifier]
        if let r = found.resource { params["resource"] = r }
        let tokens = try await Self.tokenRequest(client, params)
        Self.setTokens(tokens, c.id)
    }

    // MARK: discovery

    struct Endpoints: Sendable {
        var authorize: String
        var token: String
        var registration: String?
        var resource: String?
        var scope: String?
    }

    /// Where to sign in for an MCP server: its protected-resource metadata (from the 401 challenge or the well-known URL),
    /// then the authorization server's metadata. Servers from before that spec get /authorize, /token and /register.
    static func discover(_ serverURL: URL) async throws -> Endpoints {
        let origin = "\(serverURL.scheme ?? "https")://\(serverURL.host() ?? "")" + (serverURL.port.map { ":\($0)" } ?? "")
        let path = serverURL.path() == "/" ? "" : serverURL.path()

        // An unauthenticated request: the 401 says where the metadata is and which scope the server wants.
        var probe = URLRequest(url: serverURL, timeoutInterval: 30)
        probe.httpMethod = "POST"
        probe.setValue("application/json", forHTTPHeaderField: "Content-Type")
        probe.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        probe.httpBody = Data(#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"Keepword","version":"0.4"}}}"#.utf8)
        let challenge = ((try? await URLSession.shared.data(for: probe))?.1 as? HTTPURLResponse)?.value(forHTTPHeaderField: "WWW-Authenticate") ?? ""
        let params = parseChallenge(challenge)

        var prm: [String: Any]?
        for candidate in [params["resource_metadata"], "\(origin)/.well-known/oauth-protected-resource\(path)", "\(origin)/.well-known/oauth-protected-resource"].compactMap({ $0 }) {
            if let m = try? await getJSON(candidate) { prm = m; break }
        }
        let issuer = (prm?["authorization_servers"] as? [String])?.first ?? origin
        guard let issuerURL = URL(string: issuer) else { throw LLMError(message: "Invalid authorization server \(issuer)") }
        let ip = issuerURL.path() == "/" ? "" : issuerURL.path()
        let io = "\(issuerURL.scheme ?? "https")://\(issuerURL.host() ?? "")" + (issuerURL.port.map { ":\($0)" } ?? "")
        let candidates = ip.isEmpty
            ? ["\(io)/.well-known/oauth-authorization-server", "\(io)/.well-known/openid-configuration"]
            : ["\(io)/.well-known/oauth-authorization-server\(ip)", "\(io)/.well-known/openid-configuration\(ip)", "\(io)\(ip)/.well-known/openid-configuration"]
        var meta: [String: Any]?
        for candidate in candidates { if let m = try? await getJSON(candidate) { meta = m; break } }

        let scope = params["scope"] ?? (prm?["scopes_supported"] as? [String])?.joined(separator: " ")
        return Endpoints(authorize: meta?["authorization_endpoint"] as? String ?? "\(io)/authorize",
                         token: meta?["token_endpoint"] as? String ?? "\(io)/token",
                         registration: meta == nil ? "\(io)/register" : meta?["registration_endpoint"] as? String,
                         resource: prm?["resource"] as? String ?? canonical(serverURL),
                         scope: scope)
    }

    /// `Bearer realm="x", resource_metadata="https://…", scope="a b"` → its parameters.
    static func parseChallenge(_ header: String) -> [String: String] {
        var out: [String: String] = [:]
        for m in header.matches(of: #/([A-Za-z_]+)="([^"]*)"/#) { out[String(m.1)] = String(m.2) }
        return out
    }

    /// The server URL as the token audience: no query or fragment.
    static func canonical(_ url: URL) -> String {
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        c?.query = nil
        c?.fragment = nil
        return c?.string ?? url.absoluteString
    }

    // MARK: HTTP

    struct OAuthError: LocalizedError {
        let code: String
        let message: String
        var errorDescription: String? { message }
    }

    private static func getJSON(_ url: String) async throws -> [String: Any] {
        guard let u = URL(string: url) else { throw URLError(.badURL) }
        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: u, timeoutInterval: 20))
        guard (response as? HTTPURLResponse)?.statusCode == 200, let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.badServerResponse)
        }
        return obj
    }

    private static func postJSON(_ url: String, _ body: [String: Any]) async throws -> [String: Any] {
        guard let u = URL(string: url) else { throw URLError(.badURL) }
        var r = URLRequest(url: u, timeoutInterval: 30)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: r)
        let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard let code = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(code) else {
            throw LLMError(message: "Client registration failed: \(obj["error_description"] as? String ?? obj["error"] as? String ?? String(decoding: data.prefix(200), as: UTF8.self))")
        }
        return obj
    }

    private static func tokenRequest(_ client: MCPOAuthTokens, _ params: [String: String]) async throws -> MCPOAuthTokens {
        guard let u = URL(string: client.tokenEndpoint) else { throw URLError(.badURL) }
        var form = params
        var r = URLRequest(url: u, timeoutInterval: 30)
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let secret = client.clientSecret, client.clientAuth == "client_secret_basic" {
            let pair = "\(formEncode(client.clientID)):\(formEncode(secret))"
            r.setValue("Basic \(Data(pair.utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
        } else {
            form["client_id"] = client.clientID
            if let secret = client.clientSecret { form["client_secret"] = secret }
        }
        r.httpBody = Data(form.map { "\(formEncode($0.key))=\(formEncode($0.value))" }.joined(separator: "&").utf8)
        let (data, response) = try await URLSession.shared.data(for: r)
        let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard (response as? HTTPURLResponse)?.statusCode == 200, let access = obj["access_token"] as? String else {
            let code = obj["error"] as? String ?? "http_\((response as? HTTPURLResponse)?.statusCode ?? 0)"
            throw OAuthError(code: code, message: "Sign-in failed: \(obj["error_description"] as? String ?? code)")
        }
        var t = client
        t.accessToken = access
        t.refreshToken = obj["refresh_token"] as? String
        t.expiresAt = (obj["expires_in"] as? Double ?? (obj["expires_in"] as? String).flatMap(Double.init)).map { Date.now.addingTimeInterval($0) }
        return t
    }

    private static func formEncode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")) ?? s
    }

    private static func randomString() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URL
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

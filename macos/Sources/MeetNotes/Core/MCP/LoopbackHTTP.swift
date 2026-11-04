import Foundation
import Network

/// A small HTTP/1.1 server on the loopback interface (IPv4 and IPv6). It receives the browser's OAuth redirect,
/// and the self-test runs mock OAuth and MCP servers on it.
final class LoopbackHTTP: @unchecked Sendable {
    struct Response: Sendable {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()

        static func json(_ object: Any, status: Int = 200) -> Response {
            Response(status: status, headers: ["Content-Type": "application/json"], body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
        }
        static func html(_ text: String) -> Response {
            Response(headers: ["Content-Type": "text/html; charset=utf-8"], body: Data(text.utf8))
        }
    }
    typealias Handler = @Sendable (HTTPRequest) async -> Response

    private let listener: NWListener
    private let queue = DispatchQueue(label: "keepword.loopback")
    private let handler: Handler
    private(set) var port: UInt16 = 0

    /// Starts listening; port 0 picks a free one. Throws if the port is taken.
    init(port: UInt16 = 0, handler: @escaping Handler) async throws {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        listener = try NWListener(using: params, on: port == 0 ? .any : NWEndpoint.Port(rawValue: port) ?? .any)
        self.handler = handler
        listener.newConnectionHandler = { [weak self] c in self?.serve(c) }
        let l = listener, q = queue
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            nonisolated(unsafe) var resumed = false
            l.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready: resumed = true; c.resume()
                case .failed(let e): resumed = true; c.resume(throwing: e)
                case .cancelled: resumed = true; c.resume(throwing: CancellationError())
                default: break
                }
            }
            l.start(queue: q)
        }
        self.port = listener.port?.rawValue ?? port
    }

    func stop() { listener.cancel() }

    private func serve(_ c: NWConnection) {
        c.start(queue: queue)
        receive(c, buffer: Data())
    }

    private func receive(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            guard let self else { return c.cancel() }
            var buf = buffer
            if let data { buf.append(data) }
            if let req = HTTPRequest.parse(buf) {
                Task {
                    let r = await self.handler(req)
                    self.send(c, r)
                }
            } else if done || error != nil || buf.count > 1 << 20 {
                c.cancel()
            } else {
                self.receive(c, buffer: buf)
            }
        }
    }

    private func send(_ c: NWConnection, _ r: Response) {
        var head = "HTTP/1.1 \(r.status) \(HTTPURLResponse.localizedString(forStatusCode: r.status))\r\nContent-Length: \(r.body.count)\r\nConnection: close\r\n"
        for (k, v) in r.headers { head += "\(k): \(v)\r\n" }
        var out = Data((head + "\r\n").utf8)
        out.append(r.body)
        c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
    }
}

extension HTTPRequest {
    /// Query parameters of the request path.
    var query: [String: String] {
        let items = URLComponents(string: "http://x" + path)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
    }

    /// The path without its query.
    var route: String { String(path.split(separator: "?", maxSplits: 1).first ?? "") }

    /// application/x-www-form-urlencoded body.
    var form: [String: String] {
        var c = URLComponents()
        c.percentEncodedQuery = String(decoding: body, as: UTF8.self).replacingOccurrences(of: "+", with: "%20")
        return Dictionary((c.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
    }
}

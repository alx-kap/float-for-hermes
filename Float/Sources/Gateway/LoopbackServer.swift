import Foundation
import Network

/// One-shot RFC 8252 loopback listener on 127.0.0.1:<ephemeral>.
/// Resolves with the request path+query of the first GET, then replies with a friendly page.
final class LoopbackServer {
    private var listener: NWListener?
    private var continuation: CheckedContinuation<String, Error>?
    private(set) var port: UInt16 = 0

    func start() async throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: params)
        self.listener = listener

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            var resumed = false
            listener.stateUpdateHandler = { [weak self] state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    let p = listener.port?.rawValue ?? 0
                    self?.port = p
                    cont.resume(returning: p)
                case .failed(let err):
                    resumed = true
                    cont.resume(throwing: err)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in
                self?.handle(conn)
            }
            listener.start(queue: .main)
        }
    }

    /// Waits for the browser to hit the redirect URI.
    func waitForCallback() async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .main)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                conn.cancel(); return
            }
            let firstLine = request.split(separator: "\r\n").first ?? ""
            let parts = firstLine.split(separator: " ")
            guard parts.count >= 2, parts[0] == "GET" else { conn.cancel(); return }
            let target = String(parts[1])
            if target.hasPrefix("/favicon") {
                self.reply(conn, status: "404 Not Found", body: "")
                return
            }
            self.reply(conn, status: "200 OK", body: Self.successPage)
            self.continuation?.resume(returning: target)
            self.continuation = nil
        }
    }

    private func reply(_ conn: NWConnection, status: String, body: String) {
        let payload = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + payload, completion: .contentProcessed { _ in conn.cancel() })
    }

    private static let successPage = """
    <!doctype html><html><head><meta charset="utf-8"><title>Float</title>
    <style>body{font:16px -apple-system,system-ui;display:grid;place-items:center;height:100vh;margin:0;background:#0b0b0f;color:#eee}
    div{text-align:center}h1{font-weight:600;font-size:22px}p{opacity:.6}</style></head>
    <body><div><h1>Signed in to Hermes</h1><p>You can close this tab and return to Float.</p></div>
    <script>setTimeout(()=>window.close(),1200)</script></body></html>
    """
}

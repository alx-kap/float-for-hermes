import Foundation
import Observation

typealias JSON = [String: Any]

struct RPCError: LocalizedError {
    let code: Int
    let message: String
    var errorDescription: String? { message }
}

/// JSON-RPC 2.0 over the gateway's `/api/ws` WebSocket (the same `tui_gateway` surface the
/// Hermes desktop app and TUI use). Handles calls, `event` notifications and server→client requests.
@Observable
final class GatewayClient {
    enum State: Equatable {
        case idle, connecting, connected, needsSignIn
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var version = ""

    /// (type, sessionId, payload)
    @ObservationIgnored var onEvent: ((String, String, JSON) -> Void)?
    /// (requestId, method, params)
    @ObservationIgnored var onServerRequest: ((String, String, JSON) -> Void)?
    @ObservationIgnored var onReconnect: (() -> Void)?

    @ObservationIgnored private let auth: AuthManager
    @ObservationIgnored private let prefs = Preferences.shared
    @ObservationIgnored private var task: URLSessionWebSocketTask?
    @ObservationIgnored private var session = URLSession(configuration: .default)
    @ObservationIgnored private var nextId = 1
    @ObservationIgnored private var pending: [Int: CheckedContinuation<JSON, Error>] = [:]
    @ObservationIgnored private var readyWaiters: [CheckedContinuation<Void, Error>] = []
    @ObservationIgnored private var connectTask: Task<Void, Error>?
    @ObservationIgnored private var pingTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var retryDelay: Double = 1
    @ObservationIgnored private var retriedAuth = false

    init(auth: AuthManager) { self.auth = auth }

    // MARK: Connection

    /// Connects if needed and waits for `gateway.ready`.
    func ensureConnected() async throws {
        if state == .connected { return }
        if let t = connectTask { return try await t.value }
        let t = Task { try await self.open() }
        connectTask = t
        defer { connectTask = nil }
        try await t.value
    }

    func disconnect() {
        generation += 1
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        pingTask?.cancel()
        failAll(RPCError(code: -1, message: "Disconnected"))
        state = .idle
    }

    private func open(forceRefresh: Bool = false) async throws {
        guard let base = prefs.baseURL else { state = .failed("No gateway URL"); throw AuthError.noGateway }
        guard auth.isSignedIn else { state = .needsSignIn; throw AuthError.sessionExpired }
        state = .connecting

        let token: String
        do { token = try await auth.accessToken(forceRefresh: forceRefresh) }
        catch { state = .needsSignIn; throw error }

        var comps = URLComponents(url: base.appending(path: "api/ws"), resolvingAgainstBaseURL: false)!
        comps.scheme = comps.scheme == "https" ? "wss" : "ws"
        comps.queryItems = [.init(name: "token", value: token)]

        generation += 1
        let gen = generation
        task?.cancel(with: .goingAway, reason: nil)
        let ws = session.webSocketTask(with: comps.url!)
        ws.maximumMessageSize = 64 * 1024 * 1024
        task = ws
        ws.resume()
        receive(ws, gen: gen)

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await self.waitReady() }
                group.addTask {
                    try await Task.sleep(for: .seconds(15))
                    throw RPCError(code: -2, message: "Timed out connecting to Hermes")
                }
                try await group.next()
                group.cancelAll()
            }
        } catch {
            if case .needsSignIn = state { throw AuthError.sessionExpired }
            state = .failed(error.localizedDescription)
            throw error
        }

        state = .connected
        retryDelay = 1
        retriedAuth = false
        _ = try? await call("client.capabilities", ["server_requests": true])
        startPing(gen: gen)
    }

    private func waitReady() async throws {
        if state == .connected { return }
        try await withCheckedThrowingContinuation { readyWaiters.append($0) }
    }

    private func receive(_ ws: URLSessionWebSocketTask, gen: Int) {
        ws.receive { [weak self] result in
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                switch result {
                case .success(let msg):
                    switch msg {
                    case .string(let s): self.handle(text: s)
                    case .data(let d): self.handle(text: String(decoding: d, as: UTF8.self))
                    @unknown default: break
                    }
                    self.receive(ws, gen: gen)
                case .failure(let err):
                    self.closed(ws, gen: gen, error: err)
                }
            }
        }
    }

    private func closed(_ ws: URLSessionWebSocketTask, gen: Int, error: Error) {
        let code = ws.closeCode.rawValue
        pingTask?.cancel()
        let waiters = readyWaiters
        readyWaiters.removeAll()

        if code == 4401 {
            // Token rejected: try one forced refresh, otherwise ask to sign in.
            failAll(AuthError.sessionExpired)
            guard !retriedAuth else {
                state = .needsSignIn
                waiters.forEach { $0.resume(throwing: AuthError.sessionExpired) }
                return
            }
            retriedAuth = true
            Task {
                do {
                    try await self.open(forceRefresh: true)
                    waiters.forEach { $0.resume() }
                    self.onReconnect?()
                } catch {
                    self.state = .needsSignIn
                    waiters.forEach { $0.resume(throwing: AuthError.sessionExpired) }
                }
            }
            return
        }
        let msg = code == 4403 ? "The gateway refused this connection (chat disabled?)" : error.localizedDescription
        waiters.forEach { $0.resume(throwing: RPCError(code: code, message: msg)) }
        failAll(RPCError(code: code, message: msg))
        if state == .connected {
            state = .failed("Reconnecting…")
            scheduleReconnect()
        }
    }

    private func scheduleReconnect() {
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 20)
        Task {
            try? await Task.sleep(for: .seconds(delay))
            guard self.state != .connected, self.state != .needsSignIn else { return }
            do {
                try await self.ensureConnected()
                self.onReconnect?()
            } catch {
                if self.state != .needsSignIn { self.scheduleReconnect() }
            }
        }
    }

    private func startPing(gen: Int) {
        pingTask?.cancel()
        pingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard gen == self.generation, let ws = self.task else { return }
                ws.sendPing { _ in }
            }
        }
    }

    // MARK: Frames

    private func handle(text: String) {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? JSON else { continue }
            dispatch(obj)
        }
    }

    private func dispatch(_ obj: JSON) {
        if let method = obj["method"] as? String {
            let params = obj["params"] as? JSON ?? [:]
            if method == "event" {
                let type = params["type"] as? String ?? ""
                let sid = params["session_id"] as? String ?? ""
                let payload = params["payload"] as? JSON ?? [:]
                if type == "gateway.ready" {
                    let waiters = readyWaiters
                    readyWaiters.removeAll()
                    waiters.forEach { $0.resume() }
                }
                onEvent?(type, sid, payload)
            } else if let id = obj["id"] as? String {
                if let handler = onServerRequest { handler(id, method, params) }
                else { respondError(id: id, code: -32601, message: "Not supported by Float") }
            }
            return
        }
        guard let id = (obj["id"] as? NSNumber)?.intValue, let cont = pending.removeValue(forKey: id) else { return }
        if let err = obj["error"] as? JSON {
            cont.resume(throwing: RPCError(code: (err["code"] as? NSNumber)?.intValue ?? 0,
                                           message: err["message"] as? String ?? "Gateway error"))
        } else {
            cont.resume(returning: obj["result"] as? JSON ?? [:])
        }
    }

    private func failAll(_ error: Error) {
        let p = pending
        pending.removeAll()
        p.values.forEach { $0.resume(throwing: error) }
    }

    // MARK: Public RPC

    @discardableResult
    func call(_ method: String, _ params: JSON = [:]) async throws -> JSON {
        if method != "client.capabilities" { try await ensureConnected() }
        guard let ws = task else { throw RPCError(code: -1, message: "Not connected") }
        let id = nextId
        nextId += 1
        let frame: JSON = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        let data = try JSONSerialization.data(withJSONObject: frame)
        return try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            ws.send(.string(String(decoding: data, as: UTF8.self))) { [weak self] err in
                guard let err else { return }
                Task { @MainActor in
                    if let c = self?.pending.removeValue(forKey: id) { c.resume(throwing: err) }
                }
            }
        }
    }

    func respond(id: String, result: JSON) {
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    func respondError(id: String, code: Int, message: String) {
        send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private func send(_ frame: JSON) {
        guard let ws = task, let data = try? JSONSerialization.data(withJSONObject: frame) else { return }
        ws.send(.string(String(decoding: data, as: UTF8.self))) { _ in }
    }
}

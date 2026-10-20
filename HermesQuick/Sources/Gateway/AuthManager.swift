import AppKit
import CryptoKit
import Foundation
import Observation

/// The token set returned by the gateway's /auth/native/{token,refresh} endpoints.
struct TokenSet: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Double
    var provider: String
    var userId: String

    init(json: [String: Any]) throws {
        guard let at = json["access_token"] as? String, !at.isEmpty else { throw AuthError.badResponse }
        accessToken = at
        refreshToken = json["refresh_token"] as? String ?? ""
        expiresAt = (json["expires_at"] as? NSNumber)?.doubleValue ?? 0
        provider = json["provider"] as? String ?? ""
        userId = json["user_id"] as? String ?? ""
    }
}

enum AuthError: LocalizedError {
    case noGateway, badResponse, stateMismatch, rejected(String), sessionExpired

    var errorDescription: String? {
        switch self {
        case .noGateway: "Set your gateway URL in Settings."
        case .badResponse: "The gateway sent an unexpected response."
        case .stateMismatch: "Sign-in callback didn't match. Try again."
        case .rejected(let m): m
        case .sessionExpired: "Your Hermes session expired. Sign in again."
        }
    }
}

/// RFC 8252 native sign-in brokered by the Hermes gateway: system browser + loopback + PKCE.
/// Mirrors the Hermes desktop app's flow, so the password is only ever typed into the gateway's own page.
@Observable
final class AuthManager {
    private(set) var isSignedIn = false
    private(set) var isSigningIn = false
    private(set) var userId = ""

    @ObservationIgnored private var tokens: TokenSet?
    @ObservationIgnored private var refreshTask: Task<String?, Error>?
    @ObservationIgnored private var loopback: LoopbackServer?
    @ObservationIgnored private let prefs = Preferences.shared

    private var account: String { "tokens:" + (prefs.baseURL?.absoluteString ?? "") }

    init() { reload() }

    func reload() {
        if let data = Keychain.get(account), let t = try? JSONDecoder().decode(TokenSet.self, from: data) {
            tokens = t
            userId = t.userId
            isSignedIn = true
        } else {
            tokens = nil
            isSignedIn = false
        }
    }

    // MARK: Sign in

    func signIn() async throws {
        guard let base = prefs.baseURL else { throw AuthError.noGateway }
        loopback?.stop()
        isSigningIn = true
        defer { isSigningIn = false }

        let verifier = Self.b64url(Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
        let challenge = Self.b64url(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = Self.b64url(Data((0..<24).map { _ in UInt8.random(in: 0...255) }))

        let server = LoopbackServer()
        loopback = server
        let port = try await server.start()
        let redirect = "http://127.0.0.1:\(port)/callback"

        var comps = URLComponents(url: base.appending(path: "auth/native/authorize"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "state", value: state),
        ]
        NSWorkspace.shared.open(comps.url!)

        let target = try await server.waitForCallback()
        server.stop()
        loopback = nil
        NSApp.activate()

        let cb = URLComponents(string: "http://127.0.0.1" + target)
        let q = Dictionary((cb?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        if let err = q["error"] { throw AuthError.rejected("Gateway rejected sign-in: \(err) \(q["error_description"] ?? "")") }
        guard q["state"] == state else { throw AuthError.stateMismatch }
        guard let code = q["code"], !code.isEmpty else { throw AuthError.badResponse }

        let json = try await post(base.appending(path: "auth/native/token"), ["code": code, "code_verifier": verifier])
        store(try TokenSet(json: json))
    }

    func cancelSignIn() {
        loopback?.stop()
        loopback = nil
        isSigningIn = false
    }

    func signOut() {
        Keychain.delete(account)
        tokens = nil
        isSignedIn = false
    }

    // MARK: Tokens

    /// A valid access token, refreshing it first when it's at/near expiry.
    func accessToken(forceRefresh: Bool = false) async throws -> String {
        guard let t = tokens else { throw AuthError.sessionExpired }
        let now = Date().timeIntervalSince1970
        if !forceRefresh, t.expiresAt > 0, now < t.expiresAt - 60 { return t.accessToken }
        if !forceRefresh, t.expiresAt <= 0 { return t.accessToken }

        if let task = refreshTask { if let s = try await task.value { return s } else { throw AuthError.sessionExpired } }
        let task = Task<String?, Error> { try await self.refresh(t) }
        refreshTask = task
        defer { refreshTask = nil }
        guard let s = try await task.value else { throw AuthError.sessionExpired }
        return s
    }

    private func refresh(_ t: TokenSet) async throws -> String? {
        guard let base = prefs.baseURL, !t.refreshToken.isEmpty else { signOut(); return nil }
        do {
            let json = try await post(base.appending(path: "auth/native/refresh"),
                                      ["refresh_token": t.refreshToken, "provider": t.provider])
            let rotated = try TokenSet(json: json)
            store(rotated)
            return rotated.accessToken
        } catch AuthError.sessionExpired {
            signOut()
            return nil
        }
    }

    private func store(_ t: TokenSet) {
        tokens = t
        userId = t.userId
        if let data = try? JSONEncoder().encode(t) { Keychain.set(data, for: account) }
        isSignedIn = true
    }

    private func post(_ url: URL, _ body: [String: Any]) async throws -> [String: Any] {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 30
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if status == 401 { throw AuthError.sessionExpired }
        guard (200..<300).contains(status) else {
            throw AuthError.rejected((json["detail"] as? String) ?? "Gateway returned HTTP \(status)")
        }
        return json
    }

    private static func b64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

import Foundation
import Observation
import SwiftUI

/// Owns the conversation with one Hermes bot (profile) over the gateway.
@Observable
final class ChatStore {
    let auth: AuthManager
    let gateway: GatewayClient
    let voice: VoiceEngine
    private let prefs = Preferences.shared

    var messages: [ChatMessage] = []
    var draft = ""
    var attachments: [Attachment] = []
    var isBusy = false
    var status = ""
    var currentModel = ""
    var currentProvider = ""
    var models: [ModelChoice] = []
    var bots: [BotProfile] = []
    var pendingApproval: ApprovalRequest?
    var lastError: String?

    private(set) var sessionId: String?
    private var streamingIndex: Int?
    private var sessionTask: Task<String, Error>?

    private var storedSessionKey: String { "storedSession:\(prefs.gatewayURL):\(prefs.profile)" }

    init() {
        auth = AuthManager()
        gateway = GatewayClient(auth: auth)
        voice = VoiceEngine()
        MediaLoader.shared.auth = auth
        gateway.onEvent = { [weak self] type, sid, payload in self?.handleEvent(type, sid, payload) }
        gateway.onServerRequest = { [weak self] id, method, params in self?.handleServerRequest(id, method, params) }
        gateway.onReconnect = { [weak self] in
            // Runtime session ids don't survive a socket; rebind to the stored session.
            self?.sessionId = nil
        }
        voice.onUtterance = { [weak self] text in self?.sendVoice(text) }
    }

    var activeBot: BotProfile? { bots.first { $0.name == prefs.profile } }

    // MARK: Lifecycle

    func warmUp() {
        guard auth.isSignedIn else { return }
        Task {
            do {
                _ = try await ensureSession()
                await refreshBots()
                await refreshModels()
            } catch { report(error) }
        }
    }

    func signIn() {
        Task {
            do {
                try await auth.signIn()
                lastError = nil
                warmUp()
            } catch is CancellationError {
            } catch { report(error) }
        }
    }

    func signOut() {
        gateway.disconnect()
        auth.signOut()
        sessionId = nil
        messages.removeAll()
    }

    func newChat() {
        if isBusy { interrupt() }
        UserDefaults.standard.removeObject(forKey: storedSessionKey)
        if let sid = sessionId { Task { try? await gateway.call("session.close", ["session_id": sid]) } }
        sessionId = nil
        streamingIndex = nil
        withAnimation(.smooth(duration: 0.35)) {
            messages.removeAll()
            attachments.removeAll()
            pendingApproval = nil
            status = ""
        }
        warmUp()
    }

    func switchBot(_ bot: BotProfile) {
        guard bot.name != prefs.profile else { return }
        prefs.profile = bot.name
        sessionId = nil
        withAnimation(.smooth(duration: 0.35)) { messages.removeAll() }
        warmUp()
    }

    @discardableResult
    func ensureSession() async throws -> String {
        if let sid = sessionId { return sid }
        if let t = sessionTask { return try await t.value }
        let t = Task<String, Error> {
            try await gateway.ensureConnected()
            let profile = prefs.profile
            if let stored = UserDefaults.standard.string(forKey: storedSessionKey) {
                if let res = try? await gateway.call("session.resume", [
                    "session_id": stored, "profile": profile, "inline_images": false,
                ]), let sid = res["session_id"] as? String {
                    adopt(res, sid: sid, stored: res["stored_session_id"] as? String ?? stored)
                    return sid
                }
            }
            let res = try await gateway.call("session.create", ["profile": profile, "source": "desktop"])
            guard let sid = res["session_id"] as? String else { throw RPCError(code: 0, message: "No session id") }
            adopt(res, sid: sid, stored: res["stored_session_id"] as? String)
            return sid
        }
        sessionTask = t
        defer { sessionTask = nil }
        return try await t.value
    }

    private func adopt(_ res: JSON, sid: String, stored: String?) {
        sessionId = sid
        if let stored, !stored.isEmpty { UserDefaults.standard.set(stored, forKey: storedSessionKey) }
        if let info = res["info"] as? JSON { applyInfo(info) }
        let history = (res["messages"] as? [JSON] ?? []).compactMap(Self.transcriptMessage)
        if messages.isEmpty || !history.isEmpty {
            messages = Array(history.suffix(60))
        }
        if res["running"] as? Bool == true { isBusy = true }
    }

    private static func transcriptMessage(_ m: JSON) -> ChatMessage? {
        let role = m["role"] as? String ?? ""
        var text = m["text"] as? String ?? ""
        if text.isEmpty, let c = m["content"] as? String { text = c }
        if text.isEmpty, let parts = m["content"] as? [JSON] {
            text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        switch role {
        case "user": return ChatMessage(role: .user, text: text)
        case "assistant": return ChatMessage(role: .assistant, text: text)
        default: return nil
        }
    }

    private func applyInfo(_ info: JSON) {
        if let m = info["model"] as? String, !m.isEmpty { currentModel = m }
        if let p = info["provider"] as? String, !p.isEmpty { currentProvider = p }
        if let running = info["running"] as? Bool, !running, streamingIndex == nil { isBusy = false }
    }

    func refreshBots() async {
        guard let res = try? await gateway.call("profiles.list", [:]) else { return }
        bots = (res["profiles"] as? [JSON] ?? []).compactMap { p in
            guard let name = p["name"] as? String else { return nil }
            return BotProfile(name: name,
                              displayName: (p["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? name.capitalized,
                              model: p["model"] as? String ?? "",
                              description: p["description"] as? String ?? "",
                              isDefault: p["is_default"] as? Bool ?? false)
        }
    }

    func refreshModels() async {
        var params: JSON = ["profile": prefs.profile]
        if let sid = sessionId { params["session_id"] = sid }
        guard let res = try? await gateway.call("model.options", params) else { return }
        var out: [ModelChoice] = []
        for p in res["providers"] as? [JSON] ?? [] {
            if (p["authenticated"] as? Bool) == false { continue }
            let slug = p["slug"] as? String ?? ""
            let name = p["name"] as? String ?? slug
            let featured = p["featured_models"] as? [String] ?? []
            let all = p["models"] as? [String] ?? []
            let list = (featured.isEmpty ? all : featured + all.filter { !featured.contains($0) }).prefix(40)
            out += list.map { ModelChoice(provider: slug, providerName: name, model: $0) }
        }
        models = out
        if let m = res["model"] as? String, !m.isEmpty { currentModel = m }
        if let p = res["provider"] as? String, !p.isEmpty { currentProvider = p }
    }

    func selectModel(_ choice: ModelChoice) {
        let previous = (currentModel, currentProvider)
        withAnimation(.snappy) {
            currentModel = choice.model
            currentProvider = choice.provider
        }
        Task {
            do {
                let sid = try await ensureSession()
                var params: JSON = ["key": "model", "value": "\(choice.model) --provider \(choice.provider)", "session_id": sid]
                var res = try await gateway.call("config.set", params)
                if res["confirm_required"] as? Bool == true {
                    params["confirm_expensive_model"] = true
                    res = try await gateway.call("config.set", params)
                }
            } catch {
                (currentModel, currentProvider) = previous
                report(error)
            }
        }
    }

    // MARK: Sending

    var canSend: Bool {
        !isBusy && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        let files = attachments
        draft = ""
        voice.markTypedTurn()
        withAnimation(.smooth(duration: 0.3)) { attachments.removeAll() }
        submit(text: text, files: files, voiceTurn: false)
    }

    private func sendVoice(_ text: String) {
        guard !text.isEmpty, !isBusy else { return }
        submit(text: text, files: attachments, voiceTurn: true)
        withAnimation { attachments.removeAll() }
    }

    private func submit(text: String, files: [Attachment], voiceTurn: Bool) {
        lastError = nil
        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
            messages.append(ChatMessage(role: .user, text: text, attachments: files.filter { !$0.isImage }.map(\.name),
                                        images: files.compactMap(\.thumbnail)))
            isBusy = true
            status = files.isEmpty ? "" : "Uploading \(files.count) file\(files.count == 1 ? "" : "s")…"
        }
        Task {
            do {
                let sid = try await ensureSession()
                var refs: [String] = []
                for f in files {
                    if f.isImage {
                        try await gateway.call("image.attach_bytes", [
                            "session_id": sid, "content_base64": f.data.base64EncodedString(),
                            "filename": f.name, "ext": f.ext,
                        ])
                    } else {
                        let res = try await gateway.call("file.attach", [
                            "session_id": sid, "name": f.name,
                            "data_url": "data:\(f.mimeType);base64,\(f.data.base64EncodedString())",
                        ])
                        if let ref = res["ref_text"] as? String, !ref.isEmpty { refs.append(ref) }
                    }
                }
                var prompt = ([refs.joined(separator: "\n"), text].filter { !$0.isEmpty }).joined(separator: "\n\n")
                if prompt.isEmpty { prompt = "What do you see in this image?" }
                status = ""
                var params: JSON = ["session_id": sid, "text": prompt]
                if voiceTurn { params["voice_turn"] = true }
                try await gateway.call("prompt.submit", params)
            } catch {
                isBusy = false
                status = ""
                report(error)
                voice.turnEndedWithoutSpeech()
            }
        }
    }

    func interrupt() {
        voice.stopSpeaking()
        guard let sid = sessionId else { return }
        Task { try? await gateway.call("session.interrupt", ["session_id": sid]) }
    }

    func respondToApproval(_ choice: String) {
        guard let req = pendingApproval else { return }
        gateway.respond(id: req.id, result: ["choice": choice])
        withAnimation(.snappy) { pendingApproval = nil }
    }

    // MARK: Attachments

    func addFiles(_ urls: [URL]) {
        let loaded = urls.compactMap(Attachment.load)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
            attachments.append(contentsOf: loaded.filter { a in a.url == nil || !attachments.contains { $0.url == a.url } })
        }
        if loaded.count < urls.count { lastError = "Some files were too large (25 MB max) or couldn't be read." }
    }

    func addAttachments(_ items: [Attachment]) {
        guard !items.isEmpty else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { attachments.append(contentsOf: items) }
    }

    /// Native open panel (SwiftUI's fileImporter is unreliable from a floating menu-bar panel).
    func chooseFiles(over window: NSWindow?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Attach"
        panel.message = "Choose files or images to send to Hermes"
        panel.level = .modalPanel
        NSApp.activate()
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            self?.addFiles(panel.urls)
        }
    }

    func removeAttachment(_ a: Attachment) {
        withAnimation(.snappy) { attachments.removeAll { $0.id == a.id } }
    }

    // MARK: Events

    private func handleEvent(_ type: String, _ sid: String, _ p: JSON) {
        guard sid.isEmpty || sid == sessionId else { return }
        switch type {
        case "message.start":
            beginAssistant()
        case "message.delta":
            let chunk = p["text"] as? String ?? ""
            if streamingIndex == nil { beginAssistant() }
            if let i = streamingIndex, i < messages.count { messages[i].text += chunk }
        case "reasoning.delta", "thinking.delta":
            if streamingIndex == nil { beginAssistant() }
            if let i = streamingIndex, i < messages.count { messages[i].reasoning += p["text"] as? String ?? "" }
        case "message.complete":
            finishAssistant(p)
        case "tool.start":
            if streamingIndex == nil { beginAssistant() }
            guard let i = streamingIndex, let id = p["tool_id"] as? String else { return }
            let tool = ToolActivity(id: id, name: p["name"] as? String ?? "tool",
                                    preview: (p["preview"] as? String) ?? (p["context"] as? String) ?? "")
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { messages[i].tools.append(tool) }
        case "tool.complete":
            guard let i = streamingIndex, let id = p["tool_id"] as? String,
                  let t = messages[i].tools.firstIndex(where: { $0.id == id }) else { return }
            withAnimation(.snappy) {
                messages[i].tools[t].done = true
                messages[i].tools[t].summary = p["summary"] as? String ?? ""
                messages[i].tools[t].duration = (p["duration_s"] as? NSNumber)?.doubleValue
            }
        case "status.update":
            let text = p["text"] as? String ?? ""
            withAnimation(.easeInOut(duration: 0.2)) { status = text }
        case "session.info":
            applyInfo(p)
        case "error":
            report(RPCError(code: 0, message: p["message"] as? String ?? "Error"))
            if streamingIndex == nil { isBusy = false }
        default:
            break
        }
    }

    private func beginAssistant() {
        guard streamingIndex == nil else { return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            messages.append(ChatMessage(role: .assistant, text: "", isStreaming: true))
            streamingIndex = messages.count - 1
            isBusy = true
        }
    }

    private func finishAssistant(_ p: JSON) {
        if streamingIndex == nil { beginAssistant() }
        guard let i = streamingIndex, i < messages.count else { return }
        if let final = p["text"] as? String, !final.isEmpty { messages[i].text = final }
        if let err = p["error"] as? String, !err.isEmpty {
            messages[i].text += (messages[i].text.isEmpty ? "" : "\n\n") + "⚠️ " + err
        }
        let status = p["status"] as? String ?? ""
        if messages[i].text.isEmpty {
            messages[i].text = status == "interrupted" ? "_Stopped._" : (messages[i].tools.isEmpty ? "_No response._" : "")
        }
        withAnimation(.smooth(duration: 0.3)) {
            messages[i].isStreaming = false
            isBusy = false
            self.status = ""
        }
        let reply = messages[i].text
        streamingIndex = nil
        if voice.isConversing || (prefs.speakReplies && voice.lastTurnWasVoice) {
            voice.speak(reply)
        } else {
            voice.turnEndedWithoutSpeech()
        }
    }

    private func handleServerRequest(_ id: String, _ method: String, _ params: JSON) {
        switch method {
        case "approval":
            let choices = (params["choices"] as? [String]).flatMap { $0.isEmpty ? nil : $0 } ?? ["once", "deny"]
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                pendingApproval = ApprovalRequest(id: id,
                                                  command: params["command"] as? String ?? "",
                                                  description: params["description"] as? String ?? "Hermes wants to run a command",
                                                  choices: choices)
            }
        default:
            gateway.respondError(id: id, code: -32601, message: "Hermes Quick can't answer '\(method)' — use the Hermes app.")
        }
    }

    private func report(_ error: Error) {
        if case .needsSignIn = gateway.state { lastError = nil; return }
        withAnimation(.snappy) { lastError = error.localizedDescription }
    }
}

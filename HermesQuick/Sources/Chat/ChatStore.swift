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
    var slashItems: [SlashItem] = []
    var slashSelection = 0
    @ObservationIgnored var slashTask: Task<Void, Never>?
    var lastError: String?

    // Past conversations
    var sessions: [SessionSummary] = []
    var isLoadingSessions = false
    var isOpeningSession = false
    var showingHistory = false
    var historyQuery = ""
    var historySelection = 0
    /// Bumped when the keyboard moves the selection, so only arrow keys scroll the list (not hovering).
    var historyScrollRequest = 0
    var currentTitle = ""

    private(set) var sessionId: String?
    private var streamingIndex: Int?
    private var sessionTask: Task<String, Error>?

    private var storedSessionKey: String { "storedSession:\(prefs.gatewayURL):\(prefs.profile)" }
    /// Stored id of the open chat (nil for a brand-new chat that hasn't been saved yet).
    var currentStoredId: String? { UserDefaults.standard.string(forKey: storedSessionKey) }

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
                await refreshSessions()
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
            currentTitle = ""
            showingHistory = false
        }
        warmUp()
    }

    func switchBot(_ bot: BotProfile) {
        guard bot.name != prefs.profile else { return }
        prefs.profile = bot.name
        sessionId = nil
        streamingIndex = nil
        sessions = []
        historySelection = 0
        withAnimation(.smooth(duration: 0.35)) {
            messages.removeAll()
            currentTitle = ""
        }
        warmUp()
    }

    @discardableResult
    func ensureSession() async throws -> String {
        if let sid = sessionId { return sid }
        if let t = sessionTask { return try await t.value }
        return try await bindSession {
            if let stored = self.currentStoredId, let sid = try? await self.resume(stored) { return sid }
            let res = try await self.gateway.call("session.create", ["profile": self.prefs.profile, "source": "desktop"])
            guard let sid = res["session_id"] as? String else { throw RPCError(code: 0, message: "No session id") }
            self.adopt(res, sid: sid, stored: res["stored_session_id"] as? String)
            return sid
        }
    }

    private func bindSession(_ work: @escaping () async throws -> String) async throws -> String {
        let t = Task<String, Error> {
            try await gateway.ensureConnected()
            return try await work()
        }
        sessionTask = t
        defer { if sessionTask == t { sessionTask = nil } }
        return try await t.value
    }

    private func resume(_ stored: String) async throws -> String {
        let res = try await gateway.call("session.resume", [
            "session_id": stored, "profile": prefs.profile, "inline_images": false,
        ])
        guard let sid = res["session_id"] as? String else { throw RPCError(code: 0, message: "Couldn't open that chat") }
        adopt(res, sid: sid, stored: res["stored_session_id"] as? String ?? stored)
        return sid
    }

    private func adopt(_ res: JSON, sid: String, stored: String?) {
        sessionId = sid
        if let stored, !stored.isEmpty { UserDefaults.standard.set(stored, forKey: storedSessionKey) }
        if let info = res["info"] as? JSON { applyInfo(info) }
        let history = Self.transcript(res["messages"] as? [JSON] ?? [])
        if messages.isEmpty || !history.isEmpty {
            withAnimation(.smooth(duration: 0.3)) { messages = Array(history.suffix(200)) }
        }
        if res["running"] as? Bool == true { isBusy = true }
        if let stored, let row = sessions.first(where: { $0.id == stored }), !row.title.isEmpty { currentTitle = row.title }
        Task {
            if let r = try? await gateway.call("session.title", ["session_id": sid]),
               let t = r["title"] as? String, !t.isEmpty, sessionId == sid { currentTitle = t }
        }
    }

    /// Rebuilds bubbles from a stored transcript. One assistant bubble per turn, like the live stream:
    /// tool rows become its tool strip and the turn's last reply is its text.
    static func transcript(_ rows: [JSON]) -> [ChatMessage] {
        var out: [ChatMessage] = []
        var turn: ChatMessage?
        func flush() {
            if let t = turn, !t.text.isEmpty || !t.tools.isEmpty { out.append(t) }
            turn = nil
        }
        for m in rows {
            let date = (m["timestamp"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            let text = messageText(m)
            switch m["role"] as? String ?? "" {
            case "user":
                flush()
                let (clean, files) = userDisplay(text)
                guard !clean.isEmpty || !files.isEmpty else { continue }
                var msg = ChatMessage(role: .user, text: clean, attachments: files)
                if let date { msg.date = date }
                out.append(msg)
            case "assistant":
                if turn == nil {
                    turn = ChatMessage(role: .assistant, text: "")
                    if let date { turn?.date = date }
                }
                if !text.isEmpty { turn?.text = text }
                if let r = m["reasoning"] as? String, !r.isEmpty { turn?.reasoning += r }
            case "tool":
                if turn == nil { turn = ChatMessage(role: .assistant, text: "") }
                turn?.tools.append(ToolActivity(id: m["tool_call_id"] as? String ?? UUID().uuidString,
                                                name: m["name"] as? String ?? "tool",
                                                preview: m["context"] as? String ?? "", done: true))
            default:
                continue
            }
        }
        flush()
        return out
    }

    /// What the user actually typed, plus the names of what they attached. Stored prompts carry the
    /// gateway's expansion (`@file:` refs, an "Attached Context" block, `@image:` paths); show them as chips.
    static func userDisplay(_ text: String) -> (String, [String]) {
        var body = text
        var tail = ""
        if let r = body.range(of: "--- Attached Context ---") {
            tail = String(body[r.upperBound...])
            body = String(body[..<r.lowerBound])
        }
        var files: [String] = []
        /// Attachment name and whatever text follows the ref on the same line.
        func ref(_ line: Substring) -> (name: String, rest: String)? {
            let t = line.trimmingCharacters(in: .whitespaces)
            for prefix in ["@file:", "@image:"] where t.hasPrefix(prefix) {
                let after = t.dropFirst(prefix.count)
                let path = after.prefix { !$0.isWhitespace }
                return ((String(path) as NSString).lastPathComponent,
                        after.dropFirst(path.count).trimmingCharacters(in: .whitespaces))
            }
            return nil
        }
        var kept: [String] = []
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            if let r = ref(line) {
                if !files.contains(r.name) { files.append(r.name) }
                if !r.rest.isEmpty { kept.append(r.rest) }
            } else { kept.append(String(line)) }
        }
        for line in tail.split(separator: "\n") {
            if let r = ref(line), !files.contains(r.name) { files.append(r.name) }
        }
        let clean = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (clean, files)
    }

    private static func messageText(_ m: JSON) -> String {
        var text = m["text"] as? String ?? ""
        if text.isEmpty, let c = m["content"] as? String { text = c }
        if text.isEmpty, let parts = m["content"] as? [JSON] {
            text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Past conversations

    func refreshSessions() async {
        guard auth.isSignedIn else { return }
        let profile = prefs.profile
        isLoadingSessions = true
        defer { isLoadingSessions = false }
        guard let res = try? await gateway.call("session.list", ["profile": profile, "limit": 100]),
              profile == prefs.profile else { return }
        let rows = (res["sessions"] as? [JSON] ?? []).compactMap(SessionSummary.init)
        withAnimation(.snappy) { sessions = rows.filter { ($0.messageCount > 0 && !$0.isAutomated) || $0.id == currentStoredId } }
        if let row = sessions.first(where: { $0.id == currentStoredId }), !row.title.isEmpty { currentTitle = row.title }
    }

    /// Switch the panel to a stored chat. A turn still running in the old chat keeps going on the gateway.
    func openSession(_ s: SessionSummary) {
        closeHistory()
        guard s.id != currentStoredId || sessionId == nil else { return }
        let previous = currentStoredId
        voice.stopSpeaking()
        if let sid = sessionId, !isBusy { Task { try? await gateway.call("session.close", ["session_id": sid]) } }
        UserDefaults.standard.set(s.id, forKey: storedSessionKey)
        sessionId = nil
        streamingIndex = nil
        withAnimation(.smooth(duration: 0.3)) {
            messages.removeAll()
            pendingApproval = nil
            status = ""
            isBusy = false
            currentTitle = s.title
            isOpeningSession = true
        }
        Task {
            do {
                _ = try await bindSession { try await self.resume(s.id) }
                await refreshModels()
            } catch {
                report(error)
                if let previous { UserDefaults.standard.set(previous, forKey: storedSessionKey) }
                else { UserDefaults.standard.removeObject(forKey: storedSessionKey) }
                currentTitle = ""
                warmUp()
            }
            withAnimation(.smooth(duration: 0.3)) { isOpeningSession = false }
        }
    }

    func renameCurrentChat(_ title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t != currentTitle else { return }
        let old = currentTitle
        currentTitle = t
        Task {
            do {
                let sid = try await ensureSession()
                let r = try await gateway.call("session.title", ["session_id": sid, "title": t])
                if let v = r["title"] as? String, !v.isEmpty { currentTitle = v }
                await refreshSessions()
            } catch {
                currentTitle = old
                report(error)
            }
        }
    }

    /// Archive hides the chat from lists but keeps its messages on the gateway.
    func archiveSession(_ s: SessionSummary) {
        removeFromList(s)
        Task {
            do {
                try await gateway.call("session.archive", ["session_id": s.id, "archived": true, "profile": prefs.profile])
                if s.id == currentStoredId { newChat() }
            } catch {
                report(error)
                await refreshSessions()
            }
        }
    }

    func deleteSession(_ s: SessionSummary) {
        removeFromList(s)
        let isCurrent = s.id == currentStoredId
        let live = isCurrent ? sessionId : nil
        Task {
            do {
                // The gateway refuses to delete a chat that is open, so let go of it first.
                if isCurrent {
                    newChat()
                    if let live { try? await gateway.call("session.close", ["session_id": live]) }
                }
                try await gateway.call("session.delete", ["session_id": s.id, "profile": prefs.profile])
            } catch {
                report(error)
                await refreshSessions()
            }
        }
    }

    private func removeFromList(_ s: SessionSummary) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            sessions.removeAll { $0.id == s.id }
            historySelection = min(historySelection, max(historyResults.count - 1, 0))
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
        if text.hasPrefix("/"), attachments.isEmpty {
            draft = ""
            dismissSlash()
            voice.markTypedTurn()
            runSlash(text)
            return
        }
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

    func submit(text: String, files: [Attachment], voiceTurn: Bool, showBubble: Bool = true) {
        lastError = nil
        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
            if showBubble {
                messages.append(ChatMessage(role: .user, text: text, attachments: files.filter { !$0.isImage }.map(\.name),
                                            images: files.compactMap(\.thumbnail)))
            }
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
        case "session.title":
            if let t = p["title"] as? String, !t.isEmpty {
                withAnimation(.snappy) { currentTitle = t }
                if let key = p["session_id"] as? String, let i = sessions.firstIndex(where: { $0.id == key }) { sessions[i].title = t }
            }
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
        Task { await refreshSessions() }
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

    func report(_ error: Error) {
        if case .needsSignIn = gateway.state { lastError = nil; return }
        withAnimation(.snappy) { lastError = error.localizedDescription }
    }
}

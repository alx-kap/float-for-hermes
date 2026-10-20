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
    /// Whether the composer's field has focus, so a long ⌘V there becomes a pasted-text chip.
    @ObservationIgnored var composerFocused = false
    var isBusy = false
    var status = ""
    var currentModel = ""
    var currentProvider = ""
    var models: [ModelChoice] = []
    /// Keyed by `ModelChoice.id`. A model missing here is assumed to think and not offer fast mode.
    var modelCapabilities: [String: ModelCapabilities] = [:]
    var thinking: ThinkingLevel = .medium
    /// The level the route actually sends when it can't do the one picked (e.g. Max on an older model).
    var thinkingSent: ThinkingLevel?
    var fastMode = false
    var bots: [BotProfile] = []
    /// Questions the gateway is waiting on, oldest first. The panel shows the first.
    var prompts: [GatewayPrompt] = []
    /// Multi-select picks for the clarifying question on screen.
    var clarifySelection: Set<String> = []
    var slashItems: [SlashItem] = []
    var slashSelection = 0
    @ObservationIgnored var slashTask: Task<Void, Never>?
    var lastError: String?
    /// A reply finished while the panel was hidden and hasn't been seen yet.
    var hasUnseenReply = false
    /// Token counters and context fill for the open chat.
    var usage: UsageInfo?
    var contextSlices: [ContextSlice] = []
    /// A send that hit a dropped connection; it goes out once the gateway is back.
    @ObservationIgnored private var queuedSend: QueuedSend?
    @ObservationIgnored private var queueTask: Task<Void, Never>?

    private struct QueuedSend {
        let bubble: UUID?
        let text: String
        let files: [Attachment]
        let rawPrompt: String?
        let voiceTurn: Bool
        let replacing: String?
        /// prompt.submit was on its way when the line dropped, so the gateway may already have it.
        let submitAttempted: Bool
    }

    /// The user message being edited in the composer.
    var editingMessageId: UUID?
    @ObservationIgnored private var editStash: (draft: String, attachments: [Attachment])?
    /// Set by the app: whether the panel is on screen.
    @ObservationIgnored var isPanelVisible: () -> Bool = { true }

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
            Task { await self?.flushQueue() }
        }
        voice.onUtterance = { [weak self] text in self?.sendVoice(text) }
    }

    var activeBot: BotProfile? { bots.first { $0.name == prefs.profile } }
    var botName: String { activeBot?.displayName ?? BotProfile.fallbackName(for: prefs.profile) }

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
        resetChatState()
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
            resetChatState()
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
            resetChatState()
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
            let (wanted, wantedFast) = (self.thinking, self.fastMode)
            self.adopt(res, sid: sid, stored: res["stored_session_id"] as? String)
            await self.carryOver(thinking: wanted, fast: wantedFast, to: sid)
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
            // A message still waiting to go out isn't in the stored transcript yet: keep it at the end.
            let waiting = messages.filter(\.queued)
            withAnimation(.smooth(duration: 0.3)) { messages = Array(history.suffix(200)) + waiting }
        }
        Task { await refreshUsage() }
        if res["running"] as? Bool == true { isBusy = true }
        // Questions still waiting from before we (re)attached; nothing listed means none are open.
        let open = res["open_requests"] as? [JSON] ?? []
        let openIds = Set(open.compactMap { $0["id"] as? String })
        withAnimation(.snappy) { prompts.removeAll { $0.sessionId != sid && !openIds.contains($0.id) } }
        for r in open {
            if let id = r["id"] as? String, let method = r["method"] as? String {
                handleServerRequest(id, method, r["params"] as? JSON ?? [:])
            }
        }
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
                msg.sentPrompt = text
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
            resetChatState()
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
        // "" is the provider's default, which Hermes treats as medium.
        if let e = info["reasoning_effort"] as? String { thinking = ThinkingLevel(gateway: e.isEmpty ? "medium" : e) }
        if let w = info["reasoning_effort_wire"] as? String {
            let sent = w.isEmpty ? nil : ThinkingLevel(gateway: w)
            thinkingSent = sent == thinking ? nil : sent
        }
        if let f = info["fast"] as? Bool { fastMode = f }
    }

    func refreshBots() async {
        guard let res = try? await gateway.call("profiles.list", ["include_sessions": false]) else { return }
        bots = (res["profiles"] as? [JSON] ?? []).compactMap { p in
            guard let name = p["name"] as? String else { return nil }
            // Same name the gateway's Bots roster shows: its Bot Mode title, then the profile's display name.
            let title = ((p["ui_meta"] as? JSON)?["hermes-bots"] as? JSON)?["title"] as? String
            let displayName = [title, p["display_name"] as? String]
                .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty }
            return BotProfile(name: name,
                              displayName: displayName ?? BotProfile.fallbackName(for: name),
                              model: p["model"] as? String ?? "",
                              description: p["description"] as? String ?? "",
                              isDefault: p["is_default"] as? Bool ?? false)
        }
    }

    func refreshModels() async {
        // explicit_only: just the providers you set up, not ones the gateway can merely reach
        // through a stray key on its machine (the Hermes desktop pickers ask for the same).
        var params: JSON = ["profile": prefs.profile, "explicit_only": true]
        if let sid = sessionId { params["session_id"] = sid }
        await refreshThinking()
        guard let res = try? await gateway.call("model.options", params) else { return }
        var out: [ModelChoice] = []
        var caps: [String: ModelCapabilities] = [:]
        for p in res["providers"] as? [JSON] ?? [] {
            if (p["authenticated"] as? Bool) == false { continue }
            let slug = p["slug"] as? String ?? ""
            let name = Self.shortProviderName(slug: slug, name: p["name"] as? String ?? slug)
            let featured = p["featured_models"] as? [String] ?? []
            let all = p["models"] as? [String] ?? []
            // Catalogs come newest first, so the top few are the ones worth a click; the rest go one level down.
            let newest = Set(featured.isEmpty ? Array(all.prefix(Self.newestModelsPerProvider)) : featured)
            let list = featured + all.filter { !featured.contains($0) }
            out += list.map { ModelChoice(provider: slug, providerName: name, model: $0, isNewest: newest.contains($0)) }
            for (model, c) in p["capabilities"] as? [String: JSON] ?? [:] {
                caps[slug + "/" + model] = ModelCapabilities(fast: c["fast"] as? Bool ?? false,
                                                             reasoning: c["reasoning"] as? Bool ?? true)
            }
        }
        models = out
        modelCapabilities = caps
        if let m = res["model"] as? String, !m.isEmpty { currentModel = m }
        if let p = res["provider"] as? String, !p.isEmpty { currentProvider = p }
    }

    private static let newestModelsPerProvider = 4

    /// Models for the top of a provider's menu section: your favourites there, else its newest few.
    /// The current model always counts, so its checkmark stays in view.
    func isPrimary(_ choice: ModelChoice) -> Bool {
        if choice.model == currentModel && choice.provider == currentProvider { return true }
        let hasFavorites = prefs.favoriteModels.contains { $0.hasPrefix(choice.provider + "/") }
        return hasFavorites ? prefs.isFavorite(choice) : choice.isNewest
    }

    /// The gateway's provider names are written for a setup wizard ("ChatGPT or Codex Subscription").
    private static func shortProviderName(slug: String, name: String) -> String {
        switch slug {
        case "openai-codex": "ChatGPT"
        case "anthropic": "Anthropic"
        default: name
        }
    }

    // MARK: Thinking and fast mode

    var currentCapabilities: ModelCapabilities {
        modelCapabilities[currentProvider + "/" + currentModel] ?? ModelCapabilities()
    }

    /// Before a chat exists the gateway answers with the profile's defaults.
    func refreshThinking() async {
        var params: JSON = ["key": "reasoning"]
        if let sid = sessionId { params["session_id"] = sid }
        if let res = try? await gateway.call("config.get", params), let v = res["value"] as? String {
            thinking = ThinkingLevel(gateway: v)
        }
        params["key"] = "fast"
        if let res = try? await gateway.call("config.get", params), let v = res["value"] as? String {
            fastMode = v != "normal"
        }
    }

    func setThinking(_ level: ThinkingLevel) {
        let previous = (thinking, thinkingSent)
        withAnimation(.snappy) { thinking = level; thinkingSent = nil }
        Task {
            do {
                let sid = try await ensureSession()
                try await gateway.call("config.set", ["key": "reasoning", "value": level.rawValue, "session_id": sid])
            } catch {
                (thinking, thinkingSent) = previous
                report(error)
            }
        }
    }

    func setFastMode(_ on: Bool) {
        let previous = fastMode
        withAnimation(.snappy) { fastMode = on }
        Task {
            do {
                let sid = try await ensureSession()
                try await gateway.call("config.set", ["key": "fast", "value": on ? "fast" : "normal", "session_id": sid])
            } catch {
                withAnimation(.snappy) { fastMode = previous }
                report(error)
            }
        }
    }

    /// The gateway starts each new chat on the profile's defaults; keep what was picked in the last one.
    private func carryOver(thinking wanted: ThinkingLevel, fast wantedFast: Bool, to sid: String) async {
        if thinking != wanted {
            if (try? await gateway.call("config.set", ["key": "reasoning", "value": wanted.rawValue, "session_id": sid])) != nil {
                thinking = wanted
            }
        }
        if fastMode != wantedFast, !wantedFast || currentCapabilities.fast {
            if (try? await gateway.call("config.set", ["key": "fast", "value": wantedFast ? "fast" : "normal", "session_id": sid])) != nil {
                fastMode = wantedFast
            }
        }
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
                await refreshUsage()
            } catch {
                (currentModel, currentProvider) = previous
                report(error)
            }
        }
    }

    // MARK: Sending

    var canSend: Bool {
        if let q = activeQuestion {
            return !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (q.multiSelect && !clarifySelection.isEmpty)
        }
        return !isBusy && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        // While Hermes is asking something, the composer types the answer.
        if let q = activeQuestion {
            draft = ""
            answerClarify(q.multiSelect ? multiAnswer(extra: text) : text)
            return
        }
        if editingMessageId != nil {
            commitEdit(text)
            return
        }
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
        var bubble: UUID?
        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
            if showBubble {
                var msg = ChatMessage(role: .user, text: text, attachments: files.filter { !$0.isImage }.map(\.name),
                                      images: files.compactMap(\.thumbnail))
                msg.files = files
                bubble = msg.id
                messages.append(msg)
            }
            isBusy = true
            status = files.isEmpty ? "" : "Uploading \(files.count) file\(files.count == 1 ? "" : "s")…"
        }
        deliver(text: text, files: files, rawPrompt: nil, bubble: bubble, voiceTurn: voiceTurn)
    }

    /// Uploads `files`, then submits `rawPrompt` (a prompt sent before, refs included) or `text` with the new refs.
    /// `replacing` first drops the gateway's last turn, but only if it is that message, so a send that
    /// never arrived can't take the turn before it with it.
    private func deliver(text: String, files: [Attachment], rawPrompt: String?, bubble: UUID?,
                         voiceTurn: Bool, replacing old: String? = nil) {
        if case .failed = gateway.state {
            // Already offline: don't make them wait out a connect timeout to find out.
            queue(QueuedSend(bubble: bubble, text: text, files: files, rawPrompt: rawPrompt,
                             voiceTurn: voiceTurn, replacing: old, submitAttempted: false))
            return
        }
        Task {
            var submitting = false
            do {
                let sid = try await ensureSession()
                if let old { try await undoLastTurn(ifItIs: old, sid: sid) }
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
                var prompt = ([refs.joined(separator: "\n"), rawPrompt ?? text].filter { !$0.isEmpty }).joined(separator: "\n\n")
                if prompt.isEmpty { prompt = "What do you see in this image?" }
                status = ""
                if let bubble, let i = messages.firstIndex(where: { $0.id == bubble }) {
                    messages[i].sentPrompt = prompt
                    messages[i].files = files.filter(\.isImage)  // non-image refs now live in the prompt
                }
                var params: JSON = ["session_id": sid, "text": prompt]
                if voiceTurn { params["voice_turn"] = true }
                submitting = true
                try await gateway.call("prompt.submit", params)
            } catch {
                status = ""
                if isConnectionLost(error) {
                    // Keep it and send it when the gateway is back, rather than failing.
                    queue(QueuedSend(bubble: bubble, text: text, files: files, rawPrompt: rawPrompt,
                                     voiceTurn: voiceTurn, replacing: old, submitAttempted: submitting))
                    return
                }
                isBusy = false
                if let bubble, let i = messages.firstIndex(where: { $0.id == bubble }) {
                    withAnimation(.snappy) { messages[i].failed = true }
                }
                report(error)
                voice.turnEndedWithoutSpeech()
            }
        }
    }

    private func undoLastTurn(ifItIs text: String, sid: String) async throws {
        let res = try await gateway.call("session.history", ["session_id": sid])
        guard let last = (res["messages"] as? [JSON] ?? []).last(where: { $0["role"] as? String == "user" }),
              Self.userDisplay(Self.messageText(last)).0 == text.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        try await gateway.call("session.undo", ["session_id": sid, "intent": "retry"])
    }

    // MARK: Offline queue

    var hasQueuedSend: Bool { messages.contains(where: \.queued) }

    private func isConnectionLost(_ error: Error) -> Bool {
        if case .needsSignIn = gateway.state { return false }
        return gateway.state != .connected || error is URLError
    }

    private func queue(_ q: QueuedSend) {
        queuedSend = q
        isBusy = true
        if let b = q.bubble, let i = messages.firstIndex(where: { $0.id == b }) {
            withAnimation(.snappy) { messages[i].queued = true; messages[i].failed = false }
        }
        guard queueTask == nil else { return }
        queueTask = Task {
            var delay = 1.0
            while queuedSend != nil, !Task.isCancelled {
                if (try? await gateway.ensureConnected()) != nil { await flushQueue(); break }
                try? await Task.sleep(for: .seconds(delay))
                delay = min(delay * 2, 15)
            }
            queueTask = nil
        }
    }

    private func flushQueue() async {
        guard let q = queuedSend else { return }
        queuedSend = nil
        if let b = q.bubble, let i = messages.firstIndex(where: { $0.id == b }) {
            withAnimation(.snappy) { messages[i].queued = false }
        }
        if q.submitAttempted, let sid = try? await ensureSession(),
           let res = try? await gateway.call("session.history", ["session_id": sid]),
           let last = (res["messages"] as? [JSON] ?? []).last(where: { $0["role"] as? String == "user" }),
           Self.userDisplay(Self.messageText(last)).0 == q.text {
            // It made it before the line dropped; the reopened chat already shows it (and the reply, if done).
            withAnimation(.snappy) {
                if let b = q.bubble { messages.removeAll { $0.id == b } }
                if messages.last?.role == .assistant, streamingIndex == nil { isBusy = false }
            }
            return
        }
        deliver(text: q.text, files: q.files, rawPrompt: q.rawPrompt, bubble: q.bubble,
                voiceTurn: q.voiceTurn, replacing: q.replacing)
    }

    /// Stop waiting. From the Stop button the message stays with a Retry; switching chats just drops it.
    func cancelQueuedSend(markFailed: Bool = true) {
        guard let q = queuedSend else { return }
        queuedSend = nil
        queueTask?.cancel()
        queueTask = nil
        isBusy = false
        if let b = q.bubble, let i = messages.firstIndex(where: { $0.id == b }) {
            withAnimation(.snappy) { messages[i].queued = false; messages[i].failed = markFailed }
        }
    }

    // MARK: Usage

    func refreshUsage() async {
        guard let sid = sessionId, let res = try? await gateway.call("session.usage", ["session_id": sid]),
              sid == sessionId else { return }
        withAnimation(.snappy) { usage = UsageInfo(res) ?? usage }
    }

    /// What's taking up the context window, for the usage popover.
    func refreshContextBreakdown() async {
        guard let sid = sessionId,
              let res = try? await gateway.call("session.context_breakdown", ["session_id": sid]), sid == sessionId else { return }
        contextSlices = (res["categories"] as? [JSON] ?? []).compactMap { c in
            guard let id = c["id"] as? String, let tokens = (c["tokens"] as? NSNumber)?.intValue, tokens > 0 else { return nil }
            return ContextSlice(id: id, label: c["label"] as? String ?? id, tokens: tokens)
        }
        // The breakdown carries fresher context numbers than the last usage tick.
        if var u = usage ?? UsageInfo(["total": 0]) {
            if let used = (res["context_used"] as? NSNumber)?.intValue, used > 0 { u.contextUsed = used }
            if let max = (res["context_max"] as? NSNumber)?.intValue, max > 0 { u.contextMax = max }
            if let pct = (res["context_percent"] as? NSNumber)?.intValue { u.contextPercent = pct }
            if let est = res["context_estimated"] as? Bool { u.contextEstimated = est }
            usage = u
        }
    }

    // MARK: Retry, regenerate, edit

    private var lastUserIndex: Int? { messages.lastIndex { $0.role == .user } }

    /// Regenerate and retry need an idle chat with something to resend.
    var canRegenerate: Bool {
        !isBusy && activePrompt == nil && editingMessageId == nil && !voice.isConversing && lastUserIndex != nil
    }

    /// Sends the last message again: a fresh reply, or a retry after it failed.
    func regenerate() {
        guard canRegenerate, let u = lastUserIndex else { return }
        let msg = messages[u]
        lastError = nil
        voice.markTypedTurn()
        withAnimation(.smooth(duration: 0.3)) {
            if u + 1 < messages.count { messages.removeSubrange((u + 1)...) }
            messages[u].failed = false
            isBusy = true
        }
        // A message that never got as far as submitting has no turn on the gateway to replace.
        let reachedGateway = msg.sentPrompt != nil
        deliver(text: msg.text, files: reachedGateway ? msg.files.filter(\.isImage) : msg.files,
                rawPrompt: msg.sentPrompt, bubble: msg.id, voiceTurn: false, replacing: reachedGateway ? msg.text : nil)
    }

    var canEdit: Bool { canRegenerate }

    /// Puts the last message back in the composer; sending replaces it and its reply.
    func beginEdit() {
        guard canEdit, let u = lastUserIndex else { return }
        let msg = messages[u]
        editStash = (draft, attachments)
        dismissSlash()
        withAnimation(.snappy) {
            editingMessageId = msg.id
            draft = msg.text
            attachments = msg.files
        }
    }

    func cancelEdit() {
        guard editingMessageId != nil else { return }
        withAnimation(.snappy) {
            editingMessageId = nil
            draft = editStash?.draft ?? ""
            attachments = editStash?.attachments ?? []
        }
        editStash = nil
    }

    private func commitEdit(_ text: String) {
        guard let id = editingMessageId, let u = messages.firstIndex(where: { $0.id == id }) else { return cancelEdit() }
        let old = messages[u]
        let files = attachments
        // Files attached in an earlier session are only refs in the stored prompt: keep them around the new text.
        var raw: String?
        if old.files.isEmpty, !old.attachments.isEmpty, let p = old.sentPrompt, !old.text.isEmpty, p.contains(old.text) {
            raw = p.replacingOccurrences(of: old.text, with: text)
        }
        var msg = ChatMessage(role: .user, text: text, attachments: files.filter { !$0.isImage }.map(\.name) + (raw == nil ? [] : old.attachments),
                              images: files.compactMap(\.thumbnail))
        msg.files = files
        lastError = nil
        draft = ""
        editStash = nil
        voice.markTypedTurn()
        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
            messages.removeSubrange(u...)
            messages.append(msg)
            editingMessageId = nil
            attachments = []
            isBusy = true
        }
        deliver(text: text, files: files, rawPrompt: raw, bubble: msg.id, voiceTurn: false,
                replacing: old.sentPrompt != nil ? old.text : nil)
    }

    /// ↑ in an empty composer: bring back the last thing you sent, to send again or tweak.
    func recallLastPrompt() -> Bool {
        guard draft.isEmpty, editingMessageId == nil, let u = lastUserIndex, !messages[u].text.isEmpty else { return false }
        draft = messages[u].text
        return true
    }

    func interrupt() {
        voice.stopSpeaking()
        if queuedSend != nil { return cancelQueuedSend(markFailed: true) }
        guard let sid = sessionId else { return }
        Task { try? await gateway.call("session.interrupt", ["session_id": sid]) }
    }

    // MARK: Prompts

    var activePrompt: GatewayPrompt? { prompts.first }

    /// The clarifying question on screen, if Hermes is asking one.
    var activeQuestion: ClarifyQuestion? {
        guard case .clarify(let qs) = activePrompt?.kind else { return nil }
        return qs.first { !$0.locked }
    }

    func respondToApproval(_ choice: String) {
        guard let p = activePrompt, case .approval = p.kind else { return }
        gateway.respond(id: p.id, result: ["choice": choice])
        removePrompt(p.id)
    }

    /// Locks the answer to the current question (nil skips it). The last one settles the request on the gateway.
    func answerClarify(_ answer: String?) {
        guard let p = activePrompt, case .clarify(var qs) = p.kind,
              let i = qs.firstIndex(where: { !$0.locked }) else { return }
        let qid = qs[i].id
        qs[i].locked = true
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            clarifySelection = []
            if qs.allSatisfy(\.locked) { prompts.removeAll { $0.id == p.id } }
            else if let j = prompts.firstIndex(where: { $0.id == p.id }) { prompts[j].kind = .clarify(qs) }
        }
        Task {
            do {
                let r = try await gateway.call("clarify.lock", [
                    "request_id": p.id, "question_id": qid, "answer": answer.map { $0 as Any } ?? NSNull(),
                ])
                if r["status"] as? String == "expired" { removePrompt(p.id) }
            } catch { report(error) }
        }
    }

    func toggleClarifyChoice(_ choice: String) {
        withAnimation(.snappy(duration: 0.2)) {
            if clarifySelection.contains(choice) { clarifySelection.remove(choice) } else { clarifySelection.insert(choice) }
        }
    }

    /// Multi-select answers go up as a JSON array: the ticked choices in order, then anything typed.
    func multiAnswer(extra: String = "") -> String {
        var picks = activeQuestion?.choices.filter(clarifySelection.contains) ?? []
        if !extra.isEmpty { picks.append(extra) }
        let data = (try? JSONSerialization.data(withJSONObject: picks)) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// Dismisses every remaining question; Hermes carries on without the answers.
    func cancelClarify() {
        guard let p = activePrompt, case .clarify = p.kind else { return }
        gateway.respond(id: p.id, result: [:])
        removePrompt(p.id)
    }

    /// Sends a password, secret or code. An empty value tells Hermes the user skipped it.
    func answerSecret(_ value: String, identifier: String = "") {
        guard let p = activePrompt, case .secret(let s) = p.kind else { return }
        var answer = value
        if s.style == .login, !value.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: ["identifier": identifier, "password": value]) {
            answer = String(decoding: data, as: UTF8.self)
        }
        gateway.respond(id: p.id, result: ["value": answer])
        removePrompt(p.id)
    }

    private func removePrompt(_ id: String) {
        Notifier.shared.withdraw(id)
        withAnimation(.snappy) {
            if prompts.first?.id == id { clarifySelection = [] }
            prompts.removeAll { $0.id == id }
        }
    }

    /// Everything tied to the open chat that shouldn't follow you to another one.
    private func resetChatState() {
        usage = nil
        contextSlices = []
        cancelQueuedSend(markFailed: false)
        if editingMessageId != nil {
            draft = editStash?.draft ?? ""
            attachments = editStash?.attachments ?? []
        }
        editingMessageId = nil
        editStash = nil
        prompts.forEach { Notifier.shared.withdraw($0.id) }
        prompts.removeAll()
        clarifySelection = []
    }

    // MARK: Attention

    /// The menu bar dot: a reply you haven't seen, or Hermes waiting on you.
    var needsAttention: Bool { prefs.menuBarBadge && (hasUnseenReply || !prompts.isEmpty) }

    /// The panel came on screen: whatever the banners were about is in front of you now.
    func panelDidShow() {
        hasUnseenReply = false
        Notifier.shared.clearAll()
    }

    private var chatName: String {
        currentTitle.isEmpty ? botName : currentTitle
    }

    private func announceReply(_ reply: String, failed: Bool) {
        guard !isPanelVisible() else { return }
        hasUnseenReply = true
        guard prefs.notifications else { return }
        let body = failed ? "Hermes ran into a problem with this reply." : Self.plainPreview(reply)
        Notifier.shared.post(id: "reply:\(currentStoredId ?? "new")", title: chatName,
                             body: body.isEmpty ? "Done." : body, thread: currentStoredId ?? "new")
    }

    private func announcePrompt(_ prompt: GatewayPrompt) {
        guard !isPanelVisible(), prefs.notifications else { return }
        let body: String
        switch prompt.kind {
        case let .approval(command, description, _):
            body = "\(description)" + (command.isEmpty ? "" : ": \(command)")
        case .clarify(let qs):
            body = qs.first { !$0.locked }?.question ?? "Hermes has a question."
        case .secret(let s):
            body = s.title
        }
        Notifier.shared.post(id: prompt.id, title: "\(chatName) needs you", body: String(body.prefix(200)),
                             thread: currentStoredId ?? "new")
    }

    /// A reply as one short plain-text line for a banner.
    static func plainPreview(_ text: String) -> String {
        var t = text.replacingOccurrences(of: "```[\\s\\S]*?```", with: " [code] ", options: .regularExpression)
        t = t.replacingOccurrences(of: "!?\\[([^\\]]*)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: "[*_`#>]+", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        t = t.trimmingCharacters(in: .whitespaces)
        return t.count > 180 ? String(t.prefix(179)) + "…" : t
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

    /// Puts a pasted-text chip back into the draft as plain text.
    func expandPaste(_ a: Attachment) {
        guard let text = a.pastedText else { return }
        removeAttachment(a)
        draft = draft.isEmpty ? text : draft + "\n\n" + text
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
            if let u = UsageInfo(p["usage"] as? JSON) { withAnimation(.snappy) { usage = u } }
            finishAssistant(p)
        case "session.usage":
            if let u = UsageInfo(p["usage"] as? JSON) { usage = u }
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
        case "request.cancel":
            // Timed out, interrupted, or answered somewhere else (the Hermes app, another window).
            if let id = p["id"] as? String { removePrompt(id) }
        case "error":
            report(RPCError(code: 0, message: p["message"] as? String ?? "Error"))
            if streamingIndex == nil {
                // The turn died before a reply started: offer a retry on the message.
                if isBusy, let last = messages.indices.last, messages[last].role == .user {
                    withAnimation(.snappy) { messages[last].failed = true }
                }
                isBusy = false
            }
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
            messages[i].failed = true
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
        if status != "interrupted" { announceReply(reply, failed: !(p["error"] as? String ?? "").isEmpty) }
        Task { await refreshSessions() }
        if voice.isConversing || (prefs.speakReplies && voice.lastTurnWasVoice) {
            voice.speak(reply)
        } else {
            voice.turnEndedWithoutSpeech()
        }
    }

    /// Window-owned desktop bridges: answering "not shown here" lets the agent move on at once.
    private static let windowRequests: Set<String> = ["preview.read", "preview.act", "terminal.read", "window.read", "tour"]

    private func handleServerRequest(_ id: String, _ method: String, _ params: JSON) {
        if let prompt = GatewayPrompt(id: id, method: method, params: params) {
            // A question from a chat that isn't open comes back in its open_requests when it is.
            if let sid = sessionId, !prompt.sessionId.isEmpty, prompt.sessionId != sid { return }
            let isNew = !prompts.contains { $0.id == id }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                if let i = prompts.firstIndex(where: { $0.id == id }) { prompts[i] = prompt } else { prompts.append(prompt) }
            }
            if isNew { announcePrompt(prompt) }
        } else if Self.windowRequests.contains(method) {
            gateway.respondError(id: id, code: 4404, message: "Hermes Quick has no window for '\(method)'.")
        } else {
            gateway.respondError(id: id, code: -32601, message: "Hermes Quick can't show '\(method)'.")
        }
    }

    func report(_ error: Error) {
        if case .needsSignIn = gateway.state { lastError = nil; return }
        withAnimation(.snappy) { lastError = error.localizedDescription }
    }
}

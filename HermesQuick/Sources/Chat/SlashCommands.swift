import SwiftUI

struct SlashItem: Identifiable, Equatable {
    var id: String { text }
    let text: String        // command name without the slash
    let display: String     // "/new"
    let meta: String        // description / usage
    let kind: String        // command, skill, …
}

/// Slash-command completion and execution, matching the Hermes desktop app:
/// `complete.slash` for suggestions, then `slash.exec` with a `command.dispatch` fallback.
extension ChatStore {
    var showSlash: Bool { !slashItems.isEmpty }

    /// Commands the quick panel handles itself rather than sending to the gateway.
    private static let localNewChat: Set<String> = ["new", "reset", "clear"]

    // MARK: Completion

    func updateSlash(for text: String) {
        slashTask?.cancel()
        guard text.hasPrefix("/"), !text.contains(" "), !text.contains("\n"), auth.isSignedIn else {
            dismissSlash()
            return
        }
        slashTask = Task {
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            var params: JSON = ["text": text, "profile": Preferences.shared.profile]
            if let sid = sessionId { params["session_id"] = sid }
            guard let res = try? await gateway.call("complete.slash", params), !Task.isCancelled, draft == text else { return }
            let items = (res["items"] as? [JSON] ?? []).compactMap { i -> SlashItem? in
                guard let t = i["text"] as? String else { return nil }
                return SlashItem(text: t, display: i["display"] as? String ?? "/" + t,
                                 meta: i["meta"] as? String ?? "", kind: i["kind"] as? String ?? "command")
            }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                slashItems = Array(items.prefix(40))
                slashSelection = 0
            }
        }
    }

    func moveSlash(_ delta: Int) {
        guard !slashItems.isEmpty else { return }
        slashSelection = (slashSelection + delta + slashItems.count) % slashItems.count
    }

    /// Tab: put the command in the composer so arguments can follow.
    func insertSlash(_ item: SlashItem? = nil) {
        guard let item = item ?? slashItems[safe: slashSelection] else { return }
        draft = "/" + item.text + " "
        dismissSlash()
    }

    /// Return: run the highlighted command right away.
    func runSelectedSlash() {
        guard let item = slashItems[safe: slashSelection] else { return }
        draft = "/" + item.text
        dismissSlash()
        send()
    }

    func dismissSlash() {
        slashTask?.cancel()
        guard !slashItems.isEmpty else { return }
        withAnimation(.snappy(duration: 0.2)) { slashItems = [] }
    }

    // MARK: Execution

    func runSlash(_ command: String, depth: Int = 0) {
        let body = String(command.drop(while: { $0 == "/" }))
        let name = String(body.prefix(while: { !$0.isWhitespace })).lowercased()
        let arg = body.dropFirst(name.count).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }

        if Self.localNewChat.contains(name) {
            newChat()
            return
        }
        if depth == 0 {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                messages.append(ChatMessage(role: .user, text: command))
            }
        }
        Task {
            do {
                let sid = try await ensureSession()
                let result: JSON
                do {
                    result = try await gateway.call("slash.exec", ["session_id": sid, "command": body])
                } catch let execError {
                    do {
                        result = try await gateway.call("command.dispatch", ["session_id": sid, "name": name, "arg": arg])
                    } catch {
                        let msg = error.localizedDescription
                        let routing = msg.range(of: "not a quick/plugin", options: .caseInsensitive) != nil
                        commandOutput("error: /\(name) failed: \(routing ? execError.localizedDescription : msg)", isError: true)
                        return
                    }
                }
                handleDispatch(result, name: name, arg: arg, command: command, depth: depth)
            } catch {
                commandOutput("error: \(error.localizedDescription)", isError: true)
            }
        }
    }

    private func handleDispatch(_ r: JSON, name: String, arg: String, command: String, depth: Int) {
        let type = r["type"] as? String ?? ""
        let notice = (r["notice"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let message = (r["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        switch type {
        case "alias":
            guard let target = r["target"] as? String, depth < 3 else { return }
            let t = target.hasPrefix("/") ? target : "/" + target
            runSlash(arg.isEmpty ? t : "\(t) \(arg)", depth: depth + 1)
        case "send", "skill":
            if !notice.isEmpty { commandOutput(notice) }
            guard !message.isEmpty else { commandOutput("/\(name): empty message", isError: true); return }
            submit(text: message, files: [], voiceTurn: false, showBubble: false)
        case "prefill":
            if !notice.isEmpty { commandOutput(notice) }
            if !message.isEmpty { draft = message }
        default:
            let body = (r["output"] as? String) ?? (r["message"] as? String) ?? ""
            let warning = (r["warning"] as? String).map { "warning: \($0)\n" } ?? ""
            commandOutput(warning + (body.isEmpty ? "/\(name): done" : body))
        }
    }

    private func commandOutput(_ text: String, isError: Bool = false) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            messages.append(ChatMessage(role: isError ? .error : .notice, text: text))
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

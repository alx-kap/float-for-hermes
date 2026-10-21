import AppKit
import Foundation
import UniformTypeIdentifiers

struct ToolActivity: Identifiable, Equatable {
    let id: String
    var name: String
    var preview: String
    var summary: String = ""
    var done = false
    var startedAt = Date()
    var duration: Double?

    var prettyName: String {
        name.replacingOccurrences(of: "_", with: " ").capitalized
    }

    var symbol: String {
        let n = name.lowercased()
        if n.contains("search") || n.contains("web") { return "globe" }
        if n.contains("terminal") || n.contains("shell") || n.contains("exec") { return "terminal" }
        if n.contains("file") || n.contains("read") || n.contains("write") || n.contains("patch") { return "doc.text" }
        if n.contains("browser") { return "safari" }
        if n.contains("memory") { return "brain" }
        if n.contains("image") || n.contains("vision") { return "photo" }
        if n.contains("todo") { return "checklist" }
        if n.contains("delegate") || n.contains("agent") { return "person.2" }
        return "wrench.and.screwdriver"
    }
}

struct Attachment: Identifiable, Equatable {
    let id = UUID()
    let url: URL?
    let name: String
    let data: Data
    let isImage: Bool
    var thumbnail: NSImage?
    /// Set when this is a long paste turned into a text file (see `pasted`).
    var pastedText: String?

    var ext: String { (name as NSString).pathExtension.lowercased() }

    var mimeType: String {
        UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
    }

    static let maxBytes = 25 * 1024 * 1024

    static func load(_ url: URL) -> Attachment? {
        guard let data = try? Data(contentsOf: url), data.count < maxBytes else { return nil }
        let type = UTType(filenameExtension: url.pathExtension)
        if type?.conforms(to: .image) == true, let image = image(data, name: url.lastPathComponent, url: url) {
            return image
        }
        return Attachment(url: url, name: url.lastPathComponent, data: data, isImage: false)
    }

    /// Images go up as PNG/JPEG no larger than 2048 px, so HEIC photos and huge screenshots work.
    static func image(_ data: Data, name: String, url: URL? = nil) -> Attachment? {
        guard let img = NSImage(data: data), let rep = NSBitmapImageRep(data: data) ?? img.tiffRepresentation.flatMap(NSBitmapImageRep.init) else { return nil }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension.lowercased()
        let px = max(rep.pixelsWide, rep.pixelsHigh)
        if ["png", "jpg", "jpeg", "gif", "webp"].contains(ext), px <= 2048 {
            return Attachment(url: url, name: name, data: data, isImage: true, thumbnail: img)
        }
        let scale = px > 2048 ? 2048 / CGFloat(px) : 1
        let size = NSSize(width: CGFloat(rep.pixelsWide) * scale, height: CGFloat(rep.pixelsHigh) * scale)
        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        img.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        let keepAlpha = ext == "png" || ext == "tiff"
        guard let encoded = keepAlpha
                ? out.representation(using: .png, properties: [:])
                : out.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { return nil }
        return Attachment(url: url, name: base + (keepAlpha ? ".png" : ".jpg"), data: encoded, isImage: true, thumbnail: img)
    }

    /// Files and images from a pasteboard (copy in Finder, a screenshot, an image copied from a browser).
    static func fromPasteboard(_ pb: NSPasteboard) -> [Attachment] {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return urls.compactMap(load)
        }
        for type in [NSPasteboard.PasteboardType.png, .tiff, NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic")] {
            if let data = pb.data(forType: type) {
                let ext = type == .png ? "png" : type == .tiff ? "tiff" : type.rawValue == "public.jpeg" ? "jpg" : "heic"
                if let a = image(data, name: "Pasted Image \(stamp()).\(ext)") { return [a] }
            }
        }
        return []
    }

    /// Pastes this long go up as a text file, shown as a chip, rather than filling the composer.
    static func isLongPaste(_ text: String) -> Bool {
        text.count >= 1500 || text.reduce(into: 0) { n, c in if c.isNewline { n += 1 } } >= 15
    }

    static func pasted(_ text: String) -> Attachment {
        Attachment(url: nil, name: "Pasted Text \(stamp()).txt", data: Data(text.utf8), isImage: false, pastedText: text)
    }

    static func isPastedName(_ name: String) -> Bool { name.hasPrefix("Pasted Text ") && name.hasSuffix(".txt") }

    static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH.mm.ss"
        return f.string(from: Date())
    }

    static func == (a: Attachment, b: Attachment) -> Bool { a.id == b.id }
}

struct ChatMessage: Identifiable, Equatable {
    enum Role { case user, assistant, notice, error }

    let id = UUID()
    var role: Role
    var text: String
    var reasoning = ""
    var tools: [ToolActivity] = []
    var attachments: [String] = []
    var images: [NSImage] = []
    var isStreaming = false
    var date = Date()
    /// User messages: exactly what went to `prompt.submit` (file refs included), for retry and edit.
    var sentPrompt: String?
    /// User messages: what was attached, so a retry can upload the images again.
    var files: [Attachment] = []
    /// A user message that didn't go through, or a reply that ended in an error.
    var failed = false
    /// A user message waiting for the connection to come back.
    var queued = false
}

/// Token counters and context-window fill from `session.usage` / `message.complete`.
struct UsageInfo: Equatable {
    var contextUsed: Int?
    var contextMax: Int?
    var contextPercent: Int?
    var contextEstimated = false
    var input = 0
    var output = 0
    var reasoning = 0
    var total = 0
    var calls = 0
    var compressions = 0
    var cacheHitPercent: Int?

    init?(_ j: JSON?) {
        guard let j, !j.isEmpty else { return nil }
        func int(_ k: String) -> Int? { (j[k] as? NSNumber)?.intValue }
        contextUsed = int("context_used")
        contextMax = int("context_max")
        contextPercent = int("context_percent")
        contextEstimated = j["context_estimated"] as? Bool ?? false
        input = int("input") ?? 0
        output = int("output") ?? 0
        reasoning = int("reasoning") ?? 0
        total = int("total") ?? 0
        calls = int("calls") ?? 0
        compressions = int("compressions") ?? 0
        cacheHitPercent = int("cache_hit_pct")
    }

    /// 0…1 of the context window in use, when the gateway knows both numbers.
    var contextFraction: Double? {
        guard let used = contextUsed, let max = contextMax, max > 0 else { return nil }
        return min(1, Double(used) / Double(max))
    }

    /// 1234 → "1.2K", 200000 → "200K", 1200000 → "1.2M".
    static func compact(_ n: Int) -> String {
        func trim(_ v: Double) -> String {
            let s = String(format: v < 10 ? "%.1f" : "%.0f", v)
            return s.hasSuffix(".0") ? String(s.dropLast(2)) : s
        }
        if n >= 1_000_000 { return trim(Double(n) / 1_000_000) + "M" }
        if n >= 1_000 { return trim(Double(n) / 1_000) + "K" }
        return "\(n)"
    }
}

/// One category of `session.context_breakdown` (system prompt, tools, conversation…).
struct ContextSlice: Identifiable, Equatable {
    let id: String
    let label: String
    let tokens: Int
}

/// Something the gateway is waiting on the user for (a server→client request): a command approval,
/// clarifying questions, or a password / secret / code.
struct GatewayPrompt: Identifiable, Equatable {
    enum Kind: Equatable {
        case approval(command: String, description: String, choices: [String])
        case clarify([ClarifyQuestion])
        case secret(SecretPrompt)
    }

    let id: String          // server request id (srq-…)
    let method: String
    let sessionId: String
    var kind: Kind

    /// Nil for request kinds Float can't show.
    init?(id: String, method: String, params: JSON) {
        self.id = id
        self.method = method
        sessionId = params["session_id"] as? String ?? ""
        let str = { (key: String) in (params[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        switch method {
        case "approval":
            let choices = (params["choices"] as? [String]).flatMap { $0.isEmpty ? nil : $0 } ?? ["once", "deny"]
            kind = .approval(command: str("command"),
                             description: str("description").isEmpty ? "Hermes wants to run a command" : str("description"),
                             choices: choices)
        case "clarify":
            let locked = params["answers"] as? JSON ?? [:]
            let questions = (params["questions"] as? [JSON] ?? []).compactMap { q -> ClarifyQuestion? in
                guard let qid = q["qid"] as? String, let text = q["question"] as? String else { return nil }
                var recommended: Int?
                let choices = (q["choices"] as? [String] ?? []).enumerated().map { i, c in
                    guard let r = c.range(of: "(Recommended)", options: [.caseInsensitive, .backwards, .anchored]) else { return c }
                    recommended = i
                    return c[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
                }
                return ClarifyQuestion(id: qid, question: text, choices: choices, recommended: recommended,
                                       multiSelect: q["multi_select"] as? Bool ?? false, locked: locked[qid] != nil)
            }
            guard questions.contains(where: { !$0.locked }) else { return nil }
            kind = .clarify(questions)
        case "sudo":
            kind = .secret(SecretPrompt(title: "Administrator Password",
                                        message: "Hermes needs your Mac password to run this with sudo.",
                                        detail: str("command"), symbol: "lock.shield.fill",
                                        placeholder: "Password", submit: "Run"))
        case "secret":
            let prompt = str("prompt")
            kind = .secret(SecretPrompt(title: prompt.isEmpty ? "Hermes needs a secret" : prompt,
                                        message: "It's saved to your Hermes settings, not shown in the chat.",
                                        detail: str("env_var"), symbol: "key.fill",
                                        placeholder: "Value", submit: "Save"))
        case "vault.unlock_prompt":
            let name = str("display_name").isEmpty ? str("backend") : str("display_name")
            kind = .secret(SecretPrompt(title: "Unlock \(name)",
                                        message: "Hermes needs your master password to use logins from \(name) in this chat.",
                                        symbol: "lock.open.fill", placeholder: "Master password", submit: "Unlock"))
        case "vault.code":
            let site = str("site")
            kind = .secret(SecretPrompt(title: site.isEmpty ? "Verification Code" : "Verification Code for \(site)",
                                        message: str("hint").isEmpty ? "Enter the code from your device." : str("hint"),
                                        symbol: "number.square.fill", placeholder: "Code", submit: "Continue", style: .code))
        case "vault.save_login":
            let site = str("site").isEmpty ? str("origin") : str("site")
            kind = .secret(SecretPrompt(title: "Save a Login for \(site)",
                                        message: "Hermes will use it to sign in. It's stored in your password manager.",
                                        detail: str("origin"), symbol: "person.badge.key.fill",
                                        placeholder: "Password", submit: "Save", style: .login))
        default:
            return nil
        }
    }
}

struct ClarifyQuestion: Identifiable, Equatable {
    let id: String          // qid, what `clarify.lock` takes
    let question: String
    let choices: [String]   // without the "(Recommended)" label
    let recommended: Int?
    let multiSelect: Bool
    var locked = false
}

struct SecretPrompt: Equatable {
    enum Style { case password, code, login }
    var title: String
    var message: String
    var detail = ""         // the command or env var it's for, shown monospaced
    var symbol: String
    var placeholder: String
    var submit: String
    var style = Style.password
}

struct BotProfile: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let displayName: String
    let model: String
    let description: String
    let isDefault: Bool

    /// What to call a profile the gateway hasn't named: the default profile is the Hermes bot itself.
    static func fallbackName(for profile: String) -> String {
        profile == "default" ? "Hermes" : profile.capitalized
    }
}

/// A stored conversation from `session.list`.
struct SessionSummary: Identifiable, Equatable {
    let id: String          // stored session id (what `session.resume` takes)
    var title: String
    let preview: String
    let startedAt: Date
    let messageCount: Int
    let source: String

    init?(_ row: JSON) {
        guard let id = row["id"] as? String, !id.isEmpty else { return nil }
        self.id = id
        title = (row["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // Previews are the first prompt as stored, so drop `@file:` refs and attached context.
        preview = ChatStore.userDisplay(row["preview"] as? String ?? "").0
        startedAt = Date(timeIntervalSince1970: (row["started_at"] as? NSNumber)?.doubleValue ?? 0)
        messageCount = (row["message_count"] as? NSNumber)?.intValue ?? 0
        source = (row["source"] as? String ?? "").lowercased()
    }

    var displayTitle: String {
        if !title.isEmpty { return title }
        let line = preview.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.isEmpty ? "New Chat" : line
    }

    /// Scheduled and automated runs: real sessions, but not conversations someone had.
    var isAutomated: Bool {
        ["cron", "schedule", "scheduler", "scheduled", "webhook", "automation", "heartbeat"].contains(source)
    }

    /// Where the chat started, when it wasn't one of the Hermes apps (e.g. "Telegram").
    var sourceLabel: String? {
        ["", "desktop", "tui", "cli", "unknown", "api"].contains(source) ? nil : source.capitalized
    }

    /// "9:41", "Yesterday", "Tuesday", "12 Oct", "12 Oct 2025", like Mail and Messages.
    var dateLabel: String {
        let cal = Calendar.current
        if cal.isDateInToday(startedAt) { return startedAt.formatted(date: .omitted, time: .shortened) }
        if cal.isDateInYesterday(startedAt) { return "Yesterday" }
        if let days = cal.dateComponents([.day], from: startedAt, to: .now).day, days < 7 {
            return startedAt.formatted(.dateTime.weekday(.wide))
        }
        if cal.isDate(startedAt, equalTo: .now, toGranularity: .year) {
            return startedAt.formatted(.dateTime.day().month(.abbreviated))
        }
        return startedAt.formatted(.dateTime.day().month(.abbreviated).year())
    }
}

struct ModelChoice: Identifiable, Hashable {
    var id: String { provider + "/" + model }
    let provider: String
    let providerName: String
    let model: String
    /// One of its provider's newest few, which the menu shows when no favourites are picked.
    var isNewest = true

    var displayName: String { Self.displayName(model) }

    /// "claude-opus-4-5-20251101" → "Opus 4.5", "gpt-5.6-terra" → "GPT-5.6 Terra", "kimi-k2.6" → "Kimi K2.6".
    static func displayName(_ id: String) -> String {
        var s = id.split(separator: "/").last.map(String.init) ?? id
        s = s.replacingOccurrences(of: #"-\d{8}$"#, with: "", options: .regularExpression)
        let parts = s.split(separator: "-").map(String.init)
        func word(_ p: String) -> String { p.prefix(1).uppercased() + p.dropFirst() }
        if parts.first == "claude", parts.count > 1 {
            let rest = parts.dropFirst()
            let words = rest.filter { !($0.first?.isNumber ?? false) }.map(word)
            let version = rest.filter { $0.first?.isNumber ?? false }.joined(separator: ".")
            return (words + (version.isEmpty ? [] : [version])).joined(separator: " ")
        }
        if parts.first == "gpt", parts.count > 1 {
            return (["GPT-" + parts[1]] + parts.dropFirst(2).map(word)).joined(separator: " ")
        }
        return parts.map(word).joined(separator: " ")
    }
}

/// How hard the model thinks before answering. Raw values are the gateway's `reasoning` words.
enum ThinkingLevel: String, CaseIterable, Identifiable {
    case none, low, medium, high, xhigh, max

    var id: String { rawValue }

    init(gateway word: String) {
        self = ThinkingLevel(rawValue: word.lowercased()) ?? (word.lowercased() == "minimal" ? .low : .medium)
    }

    var title: String {
        switch self {
        case .none: "Off"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .xhigh: "Extra High"
        case .max: "Max"
        }
    }

    /// For the header, where room is tight.
    var shortTitle: String {
        switch self {
        case .xhigh: "XHigh"
        case .medium: "Med"
        default: title
        }
    }
}

/// What the gateway says a model can do.
struct ModelCapabilities: Hashable {
    var fast = false
    var reasoning = true
}

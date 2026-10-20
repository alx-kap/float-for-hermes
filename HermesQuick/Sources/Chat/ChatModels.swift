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
}

struct ApprovalRequest: Identifiable, Equatable {
    let id: String          // server request id (srq-n)
    let command: String
    let description: String
    let choices: [String]
}

struct BotProfile: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let displayName: String
    let model: String
    let description: String
    let isDefault: Bool
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
}

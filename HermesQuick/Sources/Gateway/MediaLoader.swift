import AppKit
import Foundation

/// A file the agent referenced in a reply: a path on the gateway host or a web URL.
struct MediaRef: Hashable, Identifiable {
    enum Source: Hashable { case gateway(String), web(URL) }
    let source: Source
    var id: String { key }

    var key: String {
        switch source {
        case .gateway(let p): "gw:" + p
        case .web(let u): u.absoluteString
        }
    }

    var name: String {
        switch source {
        case .gateway(let p): (p as NSString).lastPathComponent
        case .web(let u): u.lastPathComponent.isEmpty ? (u.host() ?? "image") : u.lastPathComponent
        }
    }

    var ext: String { (name as NSString).pathExtension.lowercased() }
    var isImage: Bool { Self.imageExts.contains(ext) || (ext.isEmpty && isWeb) }
    private var isWeb: Bool { if case .web = source { true } else { false } }

    static let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tiff"]
    static let fileExts: Set<String> = ["pdf", "txt", "md", "csv", "json", "zip", "mp3", "m4a", "wav", "mp4", "mov",
                                        "docx", "xlsx", "pptx", "html", "svg", "py", "swift", "js", "ts", "log"]

    /// Finds media the agent pointed at: `![alt](src)`, `MEDIA:/path`, absolute gateway paths
    /// (often in backticks), and image URLs. Gateway files win over web URLs, since a reply like
    /// "here's the photo: /path/cat.jpg (source: https://…)" names the same image twice.
    static func extract(from text: String) -> [MediaRef] {
        var gateway: [String] = []
        var web: [URL] = []

        func addPath(_ raw: String) {
            var p = raw.trimmingCharacters(in: CharacterSet(charactersIn: "`'\"()<>[],;: \n"))
            while let last = p.last, ".!?".contains(last) { p.removeLast() }
            let ext = (p as NSString).pathExtension.lowercased()
            guard p.hasPrefix("/") || p.hasPrefix("~/"), imageExts.contains(ext) || fileExts.contains(ext),
                  !gateway.contains(p) else { return }
            gateway.append(p)
        }
        func addURL(_ raw: String) {
            let s = raw.trimmingCharacters(in: CharacterSet(charactersIn: "`'\"()<>[],; \n"))
            guard let u = URL(string: s), let scheme = u.scheme, scheme.hasPrefix("http"), !web.contains(u) else { return }
            let ext = u.pathExtension.lowercased()
            let host = u.host()?.lowercased() ?? ""
            guard imageExts.contains(ext) || host.hasPrefix("images.") || host.contains("fal.media") else { return }
            web.append(u)
        }

        for m in text.matches(of: /!\[[^\]]*\]\(([^)\s]+)\)/) {
            let src = String(m.1)
            src.hasPrefix("http") ? addURL(src) : addPath(src.replacingOccurrences(of: "file://", with: ""))
        }
        for m in text.matches(of: /MEDIA:\s*(\S+)/) { addPath(String(m.1)) }
        for m in text.matches(of: /(?:^|[\s`(])((?:~|\/)[^\s`()<>"']+\.[A-Za-z0-9]{2,5})/) { addPath(String(m.1)) }
        for m in text.matches(of: /https?:\/\/[^\s)<>"'`\]]+/) { addURL(String(m.0)) }

        let fromGateway = gateway.map { MediaRef(source: .gateway($0)) }
        let webImages = fromGateway.contains(where: \.isImage) ? [] : web.map { MediaRef(source: .web($0)) }
        return Array((fromGateway + webImages).prefix(8))
    }
}

/// Downloads gateway files (`/api/fs/download`, falling back to `/api/media`) and web images, with a cache.
@MainActor
final class MediaLoader {
    static let shared = MediaLoader()
    weak var auth: AuthManager?

    private let cache = NSCache<NSString, NSData>()
    private var inflight: [String: Task<Data, Error>] = [:]

    func data(for ref: MediaRef) async throws -> Data {
        if let hit = cache.object(forKey: ref.key as NSString) { return hit as Data }
        if let t = inflight[ref.key] { return try await t.value }
        let t = Task { try await self.fetch(ref) }
        inflight[ref.key] = t
        defer { inflight[ref.key] = nil }
        let data = try await t.value
        cache.setObject(data as NSData, forKey: ref.key as NSString, cost: data.count)
        return data
    }

    func image(for ref: MediaRef) async throws -> NSImage {
        let d = try await data(for: ref)
        guard let img = NSImage(data: d) else { throw RPCError(code: 0, message: "Not an image") }
        return img
    }

    /// Save to a temporary file and open with the default app (Preview for images).
    func open(_ ref: MediaRef) async throws {
        let url = try await saveTemp(ref)
        NSWorkspace.shared.open(url)
    }

    func saveToDownloads(_ ref: MediaRef) async throws -> URL {
        let data = try await data(for: ref)
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        var dest = downloads.appending(path: ref.name)
        var n = 2
        let base = (ref.name as NSString).deletingPathExtension, ext = ref.ext
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = downloads.appending(path: "\(base) \(n)" + (ext.isEmpty ? "" : ".\(ext)"))
            n += 1
        }
        try data.write(to: dest)
        return dest
    }

    private func saveTemp(_ ref: MediaRef) async throws -> URL {
        let data = try await data(for: ref)
        let dir = FileManager.default.temporaryDirectory.appending(path: "HermesQuick", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: ref.name.isEmpty ? "file" : ref.name)
        try data.write(to: url)
        return url
    }

    private func fetch(_ ref: MediaRef) async throws -> Data {
        switch ref.source {
        case .web(let url):
            let (data, resp) = try await URLSession.shared.data(from: url)
            try Self.check(resp)
            return data
        case .gateway(let path):
            guard let base = Preferences.shared.baseURL, let auth else { throw AuthError.noGateway }
            do {
                return try await get(base, "api/fs/download", path: path, auth: auth)
            } catch {
                // Older gateways / restricted paths: the media endpoint returns a data URL.
                let json = try JSONSerialization.jsonObject(with: try await get(base, "api/media", path: path, auth: auth)) as? JSON
                guard let dataURL = json?["data_url"] as? String, let comma = dataURL.firstIndex(of: ","),
                      let d = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])) else { throw error }
                return d
            }
        }
    }

    private func get(_ base: URL, _ endpoint: String, path: String, auth: AuthManager) async throws -> Data {
        var comps = URLComponents(url: base.appending(path: endpoint), resolvingAgainstBaseURL: false)!
        comps.queryItems = [.init(name: "path", value: path)]
        var req = URLRequest(url: comps.url!)
        req.timeoutInterval = 60
        req.setValue("Bearer \(try await auth.accessToken())", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.check(resp)
        return data
    }

    private static func check(_ resp: URLResponse) throws {
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw RPCError(code: code, message: "Download failed (HTTP \(code))") }
    }
}

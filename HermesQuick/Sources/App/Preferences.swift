import Foundation
import Observation

/// User-tunable settings, persisted in UserDefaults.
@Observable
final class Preferences {
    static let shared = Preferences()

    var gatewayURL: String { didSet { save("gatewayURL", gatewayURL) } }
    var profile: String { didSet { save("profile", profile) } }
    var hotKey: HotKeyPreset { didSet { save("hotKey", hotKey.rawValue); onHotKeyChange?() } }
    var speakReplies: Bool { didSet { save("speakReplies", speakReplies) } }
    var speechRate: Double { didSet { save("speechRate", speechRate) } }
    var autoSendOnPause: Bool { didSet { save("autoSendOnPause", autoSendOnPause) } }

    @ObservationIgnored var onHotKeyChange: (() -> Void)?

    private init() {
        let d = UserDefaults.standard
        gatewayURL = d.string(forKey: "gatewayURL") ?? Self.discoverHermesDesktopURL() ?? "http://127.0.0.1:9119"
        profile = d.string(forKey: "profile") ?? "default"
        hotKey = HotKeyPreset(rawValue: d.string(forKey: "hotKey") ?? "") ?? .optionSpace
        speakReplies = d.object(forKey: "speakReplies") as? Bool ?? true
        speechRate = d.object(forKey: "speechRate") as? Double ?? 0.52
        autoSendOnPause = d.object(forKey: "autoSendOnPause") as? Bool ?? true
    }

    private func save(_ key: String, _ value: Any) {
        UserDefaults.standard.set(value, forKey: key)
    }

    var baseURL: URL? {
        URL(string: gatewayURL.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/+$", with: "", options: .regularExpression))
    }

    /// Reuse the remote gateway the Hermes desktop app is already pointed at.
    static func discoverHermesDesktopURL() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Hermes/connection.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let remote = obj["remote"] as? [String: Any],
              let s = remote["url"] as? String, !s.isEmpty else { return nil }
        return s
    }
}

import Foundation
import Observation
import SwiftUI

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
    /// Banners when a reply finishes or Hermes needs an answer while the panel is hidden.
    var notifications: Bool { didSet { save("notifications", notifications) } }
    /// A dot on the menu bar icon for the same moments.
    var menuBarBadge: Bool { didSet { save("menuBarBadge", menuBarBadge) } }
    /// Multiplier for chat text (messages, code, cards, composer). See `Font.app`.
    var textScale: Double { didSet { save("textScale", textScale) } }
    /// The panel's card width and message-list height, set by dragging its edges.
    var panelWidth: Double { didSet { save("panelWidth", panelWidth) } }
    var listHeight: Double { didSet { save("listHeight", listHeight) } }

    static let textScales: [Double] = [0.85, 1, 1.15, 1.3, 1.5, 1.75]
    static let defaultPanelWidth = 680.0
    static let defaultListHeight = 440.0

    @ObservationIgnored var onHotKeyChange: (() -> Void)?

    private init() {
        let d = UserDefaults.standard
        gatewayURL = d.string(forKey: "gatewayURL") ?? Self.discoverHermesDesktopURL() ?? "http://127.0.0.1:9119"
        profile = d.string(forKey: "profile") ?? "default"
        hotKey = HotKeyPreset(rawValue: d.string(forKey: "hotKey") ?? "") ?? .optionSpace
        speakReplies = d.object(forKey: "speakReplies") as? Bool ?? true
        speechRate = d.object(forKey: "speechRate") as? Double ?? 0.52
        autoSendOnPause = d.object(forKey: "autoSendOnPause") as? Bool ?? true
        notifications = d.object(forKey: "notifications") as? Bool ?? true
        menuBarBadge = d.object(forKey: "menuBarBadge") as? Bool ?? true
        textScale = d.object(forKey: "textScale") as? Double ?? 1
        panelWidth = d.object(forKey: "panelWidth") as? Double ?? Self.defaultPanelWidth
        listHeight = d.object(forKey: "listHeight") as? Double ?? Self.defaultListHeight
    }

    private func save(_ key: String, _ value: Any) {
        UserDefaults.standard.set(value, forKey: key)
    }

    /// ⌘+ / ⌘− step through `textScales`; ⌘0 goes back to 100%.
    func stepTextSize(_ delta: Int) {
        let i = Self.textScales.firstIndex { $0 >= textScale - 0.001 } ?? 1
        textScale = Self.textScales[max(0, min(Self.textScales.count - 1, i + delta))]
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

extension Font {
    /// Chat text at the user's chosen size. Reading the preference inside a view body keeps it live.
    static func app(_ size: CGFloat, weight: Font.Weight? = nil, design: Font.Design? = nil) -> Font {
        .system(size: (size * Preferences.shared.textScale).rounded(), weight: weight, design: design)
    }
}

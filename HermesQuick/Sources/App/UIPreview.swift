import AppKit
import SwiftUI

/// Debug builds only: open the real panel on a sample chat, without the Keychain or the gateway,
/// to check layout without signing in.
///
///   -uiPreview                     show the panel on a sample chat
///   -uiPreviewLongTitle            give the chat a long title
///   -uiPreviewWidth 520            panel width for this run (your saved width is put back)
///   -uiPreviewSnapshot out.png     render the panel to a PNG and quit. Needs no Screen Recording
///                                  permission, but system glass and blur can't be captured in-process.
enum UIPreview {
    #if DEBUG
    static var isRequested: Bool { args.contains("-uiPreview") }
    /// Snapshots draw the card's glass flat (see PanelGlassContainer).
    static var isFlat: Bool { isRequested && args.contains("-uiPreviewSnapshot") }

    private static var args: [String] { ProcessInfo.processInfo.arguments }

    private static func value(after flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static func start(store: ChatStore, panel: PanelController) {
        let prefs = Preferences.shared
        let savedWidth = prefs.panelWidth
        if let w = value(after: "-uiPreviewWidth").flatMap(Double.init) { prefs.panelWidth = w }
        fill(store)
        panel.window.appearance = NSAppearance(named: .darkAqua)
        panel.show()

        guard let out = value(after: "-uiPreviewSnapshot") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            snapshot(store: store, to: out)
            prefs.panelWidth = savedWidth
            exit(0)
        }
    }

    private static func fill(_ store: ChatStore) {
        let bot = Preferences.shared.profile
        store.auth.previewSignIn()
        store.bots = [BotProfile(name: bot, displayName: bot.capitalized, model: "", description: "", isDefault: true)]
        store.models = [ModelChoice(provider: "anthropic", providerName: "Anthropic", model: "claude-sonnet-4.5")]
        store.currentProvider = "anthropic"
        store.currentModel = "claude-sonnet-4.5"
        store.currentTitle = args.contains("-uiPreviewLongTitle")
            ? "Figure out why the nightly restic backup to the Synology NAS keeps failing after the DSM update"
            : "Nightly backup"
        store.usage = UsageInfo(["context_used": 84_000, "context_max": 200_000])
        var tool1 = ToolActivity(id: "1", name: "terminal", preview: "ssh nas journalctl -u restic-backup")
        tool1.done = true
        var tool2 = ToolActivity(id: "2", name: "terminal", preview: "ssh nas df -h /volume1")
        tool2.done = true
        store.messages = [
            ChatMessage(role: .user, text: "Why did the nightly backup fail?"),
            ChatMessage(role: .assistant, text: """
                The 02:00 run stopped because **/volume1 is full**. Restic couldn't write its lock file, so nothing was uploaded.

                Two old photo-import snapshots are taking most of the space. Pruning them and rerunning the job should fix it:

                ```bash
                restic forget --keep-daily 7 --prune
                systemctl start restic-backup.service
                ```
                """, tools: [tool1, tool2]),
        ]
    }

    /// Renders a fresh QuickChatView with SwiftUI's ImageRenderer (AppKit's in-process capture leaves the
    /// card empty). Views backed by AppKit, like the behind-window blur, don't render.
    private static func snapshot(store: ChatStore, to path: String) {
        let presentation = PanelPresentation()
        presentation.isPresented = true
        let size = QuickPanel.fittingSize()
        let view = QuickChatView()
            .environment(store)
            .environment(presentation)
            .frame(width: size.width, height: size.height)
            .background(Color(red: 0.12, green: 0.14, blue: 0.2))
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let cg = renderer.cgImage else { return }
        try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
    #else
    static let isRequested = false
    static let isFlat = false
    #endif
}

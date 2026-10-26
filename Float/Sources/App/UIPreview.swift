import AppKit
import SwiftUI

/// Debug builds only: open the real panel on a sample chat, without the Keychain or the gateway,
/// to check layout without signing in.
///
///   -uiPreview                     show the panel on a sample chat
///   -uiPreviewLongTitle            give the chat a long title
///   -uiPreviewWidth 520            panel width for this run (your saved width is put back)
///   -uiPreviewCompact              show the compact bar, before a chat starts
///   -uiPreviewVoice listening|speaking|thinking|docked|draft   show voice mode in that state
///   -uiPreviewVoiceScript          play a voice turn with the chat showing, then quit; with
///                                  FLOAT_SCROLL_LOG=1 the list logs its distance from the bottom
///   -uiPreviewPicker               with -uiPreviewSnapshot, render the model picker instead
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
        if args.contains("-uiPreviewVoiceScript") { runVoiceTurn(store) }

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
        store.bots = [BotProfile(name: bot, displayName: BotProfile.fallbackName(for: bot), model: "", description: "", isDefault: true)]
        store.models = ["claude-opus-5-5", "claude-sonnet-5", "claude-fable-5.1", "claude-haiku-4-5-20251001", "claude-opus-4-5-20251101"]
            .enumerated().map { ModelChoice(provider: "anthropic", providerName: "Anthropic", model: $1, isNewest: $0 < 4) }
            + ["gpt-6-luna", "gpt-6-sol", "gpt-5.6-terra", "gpt-5.5", "gpt-5.4-mini"]
            .enumerated().map { ModelChoice(provider: "openai-codex", providerName: "ChatGPT", model: $1, isNewest: $0 < 4) }
        store.modelCapabilities = ["openai-codex/gpt-6-luna": ModelCapabilities(fast: true)]
        store.currentProvider = "openai-codex"
        store.currentModel = "gpt-6-luna"
        store.thinking = .high
        store.fastMode = args.contains("-uiPreviewFast")
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
        if args.contains("-uiPreviewCompact") { store.messages = [] }
        if let state = value(after: "-uiPreviewVoice") { store.voice.preview(state) }
    }

    /// A scripted voice turn with the chat showing: words arrive, they're sent, a reply streams in.
    /// Run with FLOAT_SCROLL_LOG=1 to log the list's distance from the bottom as it goes.
    private static func runVoiceTurn(_ store: ChatStore) {
        let voice = store.voice
        voice.preview("draft")
        voice.previewHear("")
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            print("SCRIPT hearing")
            let words = "And how much space would pruning those two snapshots free up on the volume".split(separator: " ")
            for n in 1...words.count {
                voice.previewHear(words.prefix(n).joined(separator: " "))
                try? await Task.sleep(for: .milliseconds(180))
            }
            try? await Task.sleep(for: .milliseconds(800))
            print("SCRIPT send")
            let (text, id) = voice.previewSend()
            withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                var msg = ChatMessage(role: .user, text: text)
                msg.id = id
                store.messages.append(msg)
                store.isBusy = true
            }
            try? await Task.sleep(for: .seconds(1.2))
            print("SCRIPT reply")
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                store.messages.append(ChatMessage(role: .assistant, text: "", isStreaming: true))
            }
            try? await Task.sleep(for: .seconds(0.6))
            print("SCRIPT tool")
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                store.messages[store.messages.count - 1].tools.append(ToolActivity(id: "9", name: "terminal", preview: "ssh nas du -sh snapshots"))
            }
            try? await Task.sleep(for: .seconds(0.8))
            print("SCRIPT stream")
            let reply = "Pruning both snapshots frees about 412 GB, which takes /volume1 from 98% to 61% full. That leaves plenty of room for the nightly run and a few weeks of growth."
            var shown = ""
            for word in reply.split(separator: " ") {
                shown += (shown.isEmpty ? "" : " ") + word
                store.messages[store.messages.count - 1].text = shown
                try? await Task.sleep(for: .milliseconds(60))
            }
            print("SCRIPT finish")
            withAnimation(.smooth(duration: 0.3)) {
                store.messages[store.messages.count - 1].isStreaming = false
                store.isBusy = false
                store.status = ""
            }
            print("SCRIPT done")
            try? await Task.sleep(for: .seconds(1))
            exit(0)
        }
    }

    /// Renders a fresh QuickChatView with SwiftUI's ImageRenderer (AppKit's in-process capture leaves the
    /// card empty). Views backed by AppKit, like the behind-window blur, don't render.
    private static func snapshot(store: ChatStore, to path: String) {
        let presentation = PanelPresentation()
        presentation.isPresented = true
        let size = QuickPanel.fittingSize()
        let panel = QuickChatView()
            .environment(store)
            .environment(presentation)
            .frame(width: size.width, height: size.height)
        let picker = ModelPicker(openSettings: {}, dismiss: {}).environment(store).padding(8)
        let view = Group {
            if args.contains("-uiPreviewPicker") { AnyView(picker) } else { AnyView(panel) }
        }
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

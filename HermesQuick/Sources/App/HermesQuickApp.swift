import AppKit
import SwiftUI

@main
struct HermesQuickApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
                .environment(delegate.store)
                .environment(\.panelToggle, { delegate.panel.toggle() })
                .environment(\.panelShow, { delegate.panel.show() })
        } label: {
            MenuBarIcon(store: delegate.store)
        }

        Settings {
            SettingsView()
                .environment(delegate.store)
        }
        .windowResizability(.contentSize)
        .windowToolbarStyle(.unified)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = ChatStore()
    lazy var panel = PanelController(store: store)
    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if UIPreview.isRequested { UIPreview.start(store: store, panel: panel); return }
        #endif
        registerHotKey()
        store.isPanelVisible = { [weak self] in self?.panel.isVisible ?? true }
        panel.onShow = { [weak self] in self?.store.panelDidShow() }
        Notifier.shared.onOpen = { [weak self] in self?.panel.show() }
        Preferences.shared.onHotKeyChange = { [weak self] in self?.registerHotKey() }
        store.warmUp()
        // Opening the app by hand shows the panel; a login-item launch stays quiet in the menu bar.
        let event = NSAppleEventManager.shared().currentAppleEvent
        let isLoginLaunch = event?.paramDescriptor(forKeyword: keyAELaunchedAsLogInItem) != nil
        if !isLoginLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.panel.show() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel.show()
        return false
    }

    private func registerHotKey() {
        hotKey?.invalidate()
        hotKey = HotKey(Preferences.shared.hotKey) { [weak self] in self?.panel.toggle() }
    }
}

private struct PanelToggleKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

private struct PanelShowKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var panelToggle: () -> Void {
        get { self[PanelToggleKey.self] }
        set { self[PanelToggleKey.self] = newValue }
    }
    var panelShow: () -> Void {
        get { self[PanelShowKey.self] }
        set { self[PanelShowKey.self] = newValue }
    }
}

struct MenuBarContent: View {
    @Environment(ChatStore.self) private var store
    @Environment(\.panelToggle) private var toggle
    @Environment(\.panelShow) private var show
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        // The shortcut sits at the right like the other items' (the global hotkey does the real work).
        let hotKey = Preferences.shared.hotKey
        Button("Open Hermes Quick") { toggle() }
            .keyboardShortcut(hotKey.menuKey, modifiers: hotKey.menuModifiers)
        Button("New Chat") { store.newChat(); show() }
        if store.auth.isSignedIn {
            Menu("Open Recent") {
                ForEach(store.sessions.prefix(8)) { s in
                    Button(s.displayTitle) { store.openSession(s); show() }
                }
                if store.sessions.isEmpty { Text("No Past Chats") }
                Divider()
                Button("Show All Chats…") { show(); store.openHistory() }
            }
        }
        Divider()
        if store.auth.isSignedIn {
            Text(statusText)
        } else {
            Button("Sign In to Hermes…") { store.signIn() }
        }
        Button("Settings…") {
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",")
        Divider()
        Button("Quit Hermes Quick") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var statusText: String {
        switch store.gateway.state {
        case .connected: "Connected · \(Preferences.shared.baseURL?.host() ?? "")"
        case .connecting: "Connecting…"
        case .needsSignIn: "Sign-in required"
        case .failed(let m): m.count > 40 ? String(m.prefix(40)) + "…" : m
        case .idle: "Idle"
        }
    }
}

/// The menu bar icon, with a dot while a reply is unseen or Hermes is waiting on you.
struct MenuBarIcon: View {
    let store: ChatStore

    var body: some View {
        Image(nsImage: store.needsAttention ? Self.badged : Self.plain)
            .accessibilityLabel(store.needsAttention ? "Hermes Quick, needs attention" : "Hermes Quick")
    }

    private static let plain = symbol()

    /// The symbol with a dot in its top-right corner, cut out with a thin gap. Template, so it follows the menu bar.
    private static let badged: NSImage = {
        let base = symbol()
        let image = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)
            let d: CGFloat = 6.5
            let dot = NSRect(x: rect.maxX - d, y: rect.maxY - d, width: d, height: d)
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: dot.insetBy(dx: -1.5, dy: -1.5)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.black.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        image.isTemplate = true
        return image
    }()

    private static func symbol() -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let image = NSImage(systemSymbolName: "bolt.horizontal.circle.fill", accessibilityDescription: nil)!
            .withSymbolConfiguration(config)!
        image.isTemplate = true
        return image
    }
}

private extension HotKeyPreset {
    var menuKey: KeyEquivalent { self == .optionCommandH ? "h" : .space }

    var menuModifiers: EventModifiers {
        switch self {
        case .optionSpace: .option
        case .controlSpace: .control
        case .controlOptionSpace: [.control, .option]
        case .commandShiftSpace: [.command, .shift]
        case .optionCommandH: [.option, .command]
        }
    }
}

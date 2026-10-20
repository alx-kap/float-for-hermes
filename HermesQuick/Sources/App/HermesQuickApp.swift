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
        } label: {
            Image(systemName: "bolt.horizontal.circle.fill")
        }

        Settings {
            SettingsView()
                .environment(delegate.store)
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = ChatStore()
    lazy var panel = PanelController(store: store)
    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        registerHotKey()
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

extension EnvironmentValues {
    var panelToggle: () -> Void {
        get { self[PanelToggleKey.self] }
        set { self[PanelToggleKey.self] = newValue }
    }
}

struct MenuBarContent: View {
    @Environment(ChatStore.self) private var store
    @Environment(\.panelToggle) private var toggle
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Open Hermes Quick  (\(Preferences.shared.hotKey.label))") { toggle() }
        Button("New Chat") { store.newChat(); toggle() }
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
        case .failed(let m): m
        case .idle: "Idle"
        }
    }
}

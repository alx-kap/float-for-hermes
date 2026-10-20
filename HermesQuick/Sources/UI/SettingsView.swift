import AVFoundation
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Environment(ChatStore.self) private var store
    @State private var prefs = Preferences.shared
    @State private var notifier = Notifier.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        @Bindable var prefs = prefs
        Form {
            Section("Gateway") {
                TextField("URL", text: $prefs.gatewayURL)
                    .font(.system(.body, design: .monospaced))
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle().fill(statusColor).frame(width: 8, height: 8)
                        Text(statusText).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    if store.auth.isSignedIn {
                        Button("Reconnect") {
                            store.gateway.disconnect()
                            store.auth.reload()
                            store.warmUp()
                        }
                        Button("Sign Out", role: .destructive) { store.signOut() }
                    } else {
                        Button("Sign In with Browser…") { store.auth.reload(); store.signIn() }
                    }
                }
            }

            Section("Bot") {
                Picker("Chat with", selection: Binding(
                    get: { prefs.profile },
                    set: { name in if let b = store.bots.first(where: { $0.name == name }) { store.switchBot(b) } })) {
                    if store.bots.isEmpty { Text(prefs.profile).tag(prefs.profile) }
                    ForEach(store.bots) { bot in
                        Text(bot.displayName + (bot.model.isEmpty ? "" : "  ·  \(bot.model)")).tag(bot.name)
                    }
                }
            }

            Section("Quick Chat") {
                Picker("Shortcut", selection: $prefs.hotKey) {
                    ForEach(HotKeyPreset.allCases) { Text($0.label).tag($0) }
                }
                LabeledContent("Text size") {
                    HStack(spacing: 8) {
                        Text("A").font(.system(size: 11))
                        Slider(value: Binding(
                            get: { Double(Preferences.textScales.firstIndex { $0 >= prefs.textScale - 0.001 } ?? 1) },
                            set: { prefs.textScale = Preferences.textScales[Int($0.rounded())] }),
                               in: 0...Double(Preferences.textScales.count - 1), step: 1)
                            .frame(width: 160)
                        Text("A").font(.system(size: 17))
                        Text("\(Int((prefs.textScale * 100).rounded()))%")
                            .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                            .frame(width: 36, alignment: .trailing)
                    }
                }
                .help("Also ⌘+ and ⌘− in the panel, and ⌘0 to reset")
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
                        catch { launchAtLogin = !on }
                    }
            }

            Section {
                Toggle("Notify me when a reply is ready or Hermes needs me", isOn: $prefs.notifications)
                    .onChange(of: prefs.notifications) { _, on in
                        if on { Task { await notifier.ensureAuthorized() } }
                    }
                Toggle("Show a dot on the menu bar icon", isOn: $prefs.menuBarBadge)
                if prefs.notifications && notifier.isDenied {
                    LabeledContent {
                        Button("Open System Settings…") { notifier.openSystemSettings() }
                    } label: {
                        Label("Notifications are turned off for Hermes Quick in System Settings.",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Notifications")
            } footer: {
                Text("Only while the panel is hidden. Click a notification to open the chat.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Voice") {
                Toggle("Speak replies to voice messages", isOn: $prefs.speakReplies)
                Toggle("Send automatically when I pause", isOn: $prefs.autoSendOnPause)
                LabeledContent("Voice") {
                    Text("System voice (set it to a Siri voice)").foregroundStyle(.secondary)
                }
                Slider(value: $prefs.speechRate, in: 0.4...0.62) { Text("Speed") }
                Button("Preview Voice") { store.voice.speak("Hi, I'm Hermes. What can I do for you?") }
                Button("Choose System Voice…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent")!)
                }
                Text("Replies use your Mac's system voice. macOS only lets Apple's own speech tools use Siri voices, so Hermes Quick speaks through the system voice. Pick a Siri voice under Accessibility › Read & Speak › System voice.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .task {
            await store.refreshBots()
        }
        .task { await notifier.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await notifier.refresh() }
        }
    }

    private var statusText: String {
        switch store.gateway.state {
        case .connected: "Connected"
        case .connecting: "Connecting…"
        case .needsSignIn: "Sign-in required"
        case .failed(let m): m
        case .idle: store.auth.isSignedIn ? "Idle" : "Signed out"
        }
    }

    private var statusColor: Color {
        switch store.gateway.state {
        case .connected: .green
        case .connecting: .yellow
        case .failed, .needsSignIn: .red
        case .idle: .gray
        }
    }
}

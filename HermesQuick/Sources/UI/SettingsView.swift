import AVFoundation
import ServiceManagement
import SwiftUI

/// The settings window, laid out like macOS System Settings: a searchable glass sidebar of panes,
/// each opening a grouped form with a header that names it.
struct SettingsView: View {
    @Environment(ChatStore.self) private var store
    @State private var notifier = Notifier.shared
    @State private var prefs = Preferences.shared
    @AppStorage("settingsPane") private var selection: SettingsPane = .general
    @State private var query = ""

    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            // Flush to the window's leading edge like System Settings, so the traffic lights sit
            // in open glass rather than against an inset corner.
            sidebar
                .frame(width: 232)
                // The window itself rounds the outer corners, so the glass stays square and nothing doubles up.
                .glassEffect(.regular, in: .rect)
                .overlay(alignment: .trailing) { Divider() }
            detail
                .id(selection)
                .transition(.opacity)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(.snappy(duration: 0.2), value: selection)
        .ignoresSafeArea(.container, edges: .top)
        // Capped so the form column doesn't stretch into long, empty rows.
        .frame(minWidth: 680, idealWidth: 720, maxWidth: 800, minHeight: 500, idealHeight: 560)
        // See-through like the panel, with the same blur and tint, so Appearance changes show here live.
        // A high floor on the opacity keeps it frosted and readable even when the panel is set clear.
        .background {
            PanelBackdrop(opacity: max(0.7, prefs.backgroundOpacity), tint: .panelTint(prefs.backgroundTint))
        }
        .ignoresSafeArea()
        .navigationTitle(selection.title)
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .background(SettingsWindowStyler())
        .task { await store.refreshBots() }
        .task { await notifier.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await notifier.refresh() }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 6) {
            searchField
                .padding(.horizontal, 10)
                // Below the traffic lights, matching System Settings' spacing.
                .padding(.top, 62)
            List(selection: Binding(get: { selection }, set: { if let p = $0 { selection = p } })) {
                if matches(.connection) {
                    AccountRow().tag(SettingsPane.connection)
                }
                Section {
                    ForEach(SettingsPane.allCases.filter { $0 != .connection && matches($0) }) { pane in
                        Label {
                            Text(pane.title)
                        } icon: {
                            SettingsIcon(pane: pane, size: 20)
                        }
                        .tag(pane)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .overlay {
                if !query.isEmpty && !SettingsPane.allCases.contains(where: matches) {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
        .onChange(of: query) {
            // Jump to the first pane that matches, the way System Settings follows its search field.
            if let first = SettingsPane.allCases.first(where: matches), !matches(selection) { selection = first }
        }
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search", text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onExitCommand { query = ""; searchFocused = false }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear")
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(.fill.tertiary, in: .capsule)
        .overlay(Capsule().strokeBorder(Color.accentColor.opacity(searchFocused ? 0.6 : 0), lineWidth: 1.5))
        .animation(.snappy(duration: 0.15), value: query.isEmpty)
        .animation(.snappy(duration: 0.15), value: searchFocused)
        .background {
            // ⌘F jumps to search, as in System Settings.
            Button("") { searchFocused = true }.keyboardShortcut("f").hidden()
        }
    }

    private func matches(_ pane: SettingsPane) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        return ([pane.title] + pane.keywords).contains { $0.localizedStandardContains(q) }
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        switch selection {
        case .connection: ConnectionPane()
        case .general: GeneralPane()
        case .models: ModelsPane()
        case .appearance: AppearancePane()
        case .notifications: NotificationsPane(notifier: notifier)
        case .voice: VoicePane()
        }
    }
}

// MARK: - Panes

enum SettingsPane: String, CaseIterable, Identifiable {
    case connection, general, models, appearance, notifications, voice

    var id: String { rawValue }

    var title: String {
        switch self {
        case .connection: "Hermes"
        case .general: "General"
        case .models: "Models"
        case .appearance: "Appearance"
        case .notifications: "Notifications"
        case .voice: "Voice"
        }
    }

    var subtitle: String {
        switch self {
        case .connection: "Your gateway, sign-in, and which bot you chat with."
        case .general: "How you summon Hermes Quick, and when it starts."
        case .models: "Pick the models the panel's menu puts first."
        case .appearance: "Text size and how the panel's glass looks over your desktop."
        case .notifications: "Get a heads-up when a reply lands while the panel is hidden."
        case .voice: "Talk to Hermes and hear replies read aloud."
        }
    }

    var symbol: String {
        switch self {
        case .connection: "bolt.horizontal.fill"
        case .general: "gearshape.fill"
        case .models: "cpu.fill"
        case .appearance: "paintbrush.fill"
        case .notifications: "bell.badge.fill"
        case .voice: "waveform"
        }
    }

    var color: Color {
        switch self {
        case .connection: .indigo
        case .general: .gray
        case .models: .purple
        case .appearance: .blue
        case .notifications: .red
        case .voice: .orange
        }
    }

    /// Words a search should find this pane by — the labels of the settings it holds.
    var keywords: [String] {
        switch self {
        case .connection: ["Gateway", "URL", "Status", "Sign In", "Sign Out", "Reconnect", "Account", "Bot", "Profile"]
        case .general: ["Shortcut", "Hotkey", "Keyboard", "Launch at login", "Startup"]
        case .models: ["Model", "Provider", "Favorite", "Favourite", "Menu", "Anthropic", "Claude", "ChatGPT", "OpenAI", "GPT"]
        case .appearance: ["Text size", "Font", "Zoom", "Background", "Opacity", "Blur", "Tint", "Color", "Glass"]
        case .notifications: ["Alerts", "Badge", "Menu bar", "Dot"]
        case .voice: ["Speak", "Speech", "Siri", "Speed", "Rate", "Microphone", "Dictation", "Auto send", "Pause"]
        }
    }
}

/// A pane's form, topped with the centered icon, title and blurb System Settings puts on every pane.
private struct PaneForm<Content: View>: View {
    let pane: SettingsPane
    @ViewBuilder var content: Content

    var body: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    SettingsIcon(pane: pane, size: 52)
                    Text(pane.title).font(.title2.weight(.semibold))
                    Text(pane.subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            content
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 18, for: .scrollContent)
        // Nothing sits over the detail's top edge (the traffic lights live in the sidebar), so no edge blur.
        .scrollEdgeEffectHidden(true, for: .top)
    }
}

private struct ConnectionPane: View {
    @Environment(ChatStore.self) private var store
    @State private var prefs = Preferences.shared

    var body: some View {
        @Bindable var prefs = prefs
        PaneForm(pane: .connection) {
            Section {
                TextField("URL", text: $prefs.gatewayURL)
                    .font(.system(.body, design: .monospaced))
                LabeledContent("Status") {
                    ConnectionStatus()
                }
            } header: {
                Text("Gateway")
            } footer: {
                HStack {
                    Spacer()
                    if store.auth.isSignedIn {
                        Button("Reconnect") {
                            store.gateway.disconnect()
                            store.auth.reload()
                            store.warmUp()
                        }
                        Button("Sign Out", role: .destructive) { store.signOut() }
                    } else {
                        Button("Sign In with Browser…") { store.auth.reload(); store.signIn() }
                            .buttonStyle(.glassProminent)
                    }
                }
            }

            Section {
                if store.bots.isEmpty {
                    BotRow(name: store.botName, model: "", selected: true) {}
                }
                ForEach(store.bots) { bot in
                    BotRow(name: bot.displayName, model: bot.model, selected: bot.name == prefs.profile) {
                        store.switchBot(bot)
                    }
                }
            } header: {
                Text("Chat With")
            } footer: {
                Text("The panel's bot menu switches between these too.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct BotRow: View {
    let name: String
    let model: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                BotAvatar(name: name).scaleEffect(1.3).frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                    if !model.isEmpty {
                        Text(model).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.2), value: selected)
    }
}

private struct GeneralPane: View {
    @State private var prefs = Preferences.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        @Bindable var prefs = prefs
        PaneForm(pane: .general) {
            Section {
                Picker("Open Quick Chat with", selection: $prefs.hotKey) {
                    ForEach(HotKeyPreset.allCases) { Text($0.label).tag($0) }
                }
            } footer: {
                Text("Press it anywhere to show or hide the panel.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
                        catch { launchAtLogin = !on }
                    }
            } footer: {
                Text("Hermes Quick starts quietly in the menu bar.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct AppearancePane: View {
    @State private var prefs = Preferences.shared

    var body: some View {
        @Bindable var prefs = prefs
        PaneForm(pane: .appearance) {
            Section {
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
            } footer: {
                Text("Also ⌘+ and ⌘− in the panel, and ⌘0 to reset.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Panel") {
                LabeledContent("Background") {
                    HStack(spacing: 8) {
                        Text("Clear").font(.system(size: 11)).foregroundStyle(.secondary)
                        Slider(value: $prefs.backgroundOpacity, in: 0...1)
                            .frame(width: 160)
                        Text("Solid").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .help("How much the panel blurs and dims what's behind it")
                LabeledContent("Tint") {
                    HStack(spacing: 7) {
                        ForEach(Preferences.tintPresets, id: \.value) { preset in
                            TintSwatch(color: .panelTint(preset.value), selected: prefs.backgroundTint == preset.value) {
                                prefs.backgroundTint = preset.value
                            }
                            .help(preset.name)
                        }
                        ColorPicker("Custom", selection: Binding(
                            get: { .panelTint(prefs.backgroundTint) },
                            set: { prefs.backgroundTint = $0.hex }), supportsOpacity: false)
                            .labelsHidden()
                            .help("Custom")
                    }
                }
            }
        }
    }
}

private struct ModelsPane: View {
    @Environment(ChatStore.self) private var store
    @State private var prefs = Preferences.shared

    var body: some View {
        PaneForm(pane: .models) {
            let groups = Dictionary(grouping: store.models, by: \.providerName)
            if store.models.isEmpty {
                Section {
                    LabeledContent("Loading models from your gateway…") { ProgressView().controlSize(.small) }
                }
            }
            ForEach(groups.keys.sorted(), id: \.self) { provider in
                let choices = groups[provider] ?? []
                let picked = choices.contains(where: prefs.isFavorite)
                Section {
                    ForEach(choices) { choice in
                        Toggle(choice.model, isOn: Binding(get: { prefs.isFavorite(choice) },
                                                           set: { prefs.setFavorite(choice, $0) }))
                    }
                } header: {
                    Text(provider)
                } footer: {
                    Text(picked ? "The rest are under More Models." : "None picked, so the menu shows the newest few.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                HStack {
                    Text("Only providers you've set up on the gateway are listed. Your picks are saved on this Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Refresh") { Task { await store.refreshModels() } }
                }
            }
        }
        .task { if store.models.isEmpty { await store.refreshModels() } }
    }
}

private struct NotificationsPane: View {
    let notifier: Notifier
    @State private var prefs = Preferences.shared

    var body: some View {
        @Bindable var prefs = prefs
        PaneForm(pane: .notifications) {
            Section {
                Toggle("Notify me when a reply is ready or Hermes needs me", isOn: $prefs.notifications)
                    .onChange(of: prefs.notifications) { _, on in
                        if on { Task { await notifier.ensureAuthorized() } }
                    }
                if prefs.notifications && notifier.isDenied {
                    LabeledContent {
                        Button("Open System Settings…") { notifier.openSystemSettings() }
                    } label: {
                        Label("Notifications are turned off for Hermes Quick in System Settings.",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("Only while the panel is hidden. Click a notification to open the chat.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Show a dot on the menu bar icon", isOn: $prefs.menuBarBadge)
            }
        }
    }
}

private struct VoicePane: View {
    @Environment(ChatStore.self) private var store
    @State private var prefs = Preferences.shared

    var body: some View {
        @Bindable var prefs = prefs
        PaneForm(pane: .voice) {
            Section("Talking") {
                Toggle("Send automatically when I pause", isOn: $prefs.autoSendOnPause)
            }
            Section {
                Toggle("Speak replies to voice messages", isOn: $prefs.speakReplies)
                LabeledContent("Speed") {
                    HStack(spacing: 8) {
                        Image(systemName: "tortoise.fill").font(.system(size: 11)).foregroundStyle(.secondary)
                        Slider(value: $prefs.speechRate, in: 0.4...0.62)
                            .frame(width: 160)
                        Image(systemName: "hare.fill").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Voice") {
                    HStack {
                        Button("Preview") { store.voice.speak("Hi, I'm Hermes. What can I do for you?") }
                        Button("Choose System Voice…") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent")!)
                        }
                    }
                }
            } header: {
                Text("Replies")
            } footer: {
                Text("Replies use your Mac's system voice. macOS only lets Apple's own speech tools use Siri voices, so Hermes Quick speaks through the system voice. Pick a Siri voice under Accessibility › Read & Speak › System voice.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Pieces

/// The sidebar's top row, like the Apple Account row in System Settings: the app, and how it's connected.
private struct AccountRow: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text("Hermes").font(.headline)
                ConnectionStatus(compact: true)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ConnectionStatus: View {
    @Environment(ChatStore.self) private var store
    var compact = false

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: compact ? 6 : 8, height: compact ? 6 : 8)
            Text(text)
                .font(compact ? .caption : .body)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .animation(.snappy, value: text)
    }

    private var text: String {
        switch store.gateway.state {
        case .connected: "Connected"
        case .connecting: "Connecting…"
        case .needsSignIn: "Sign-in required"
        case .failed(let m): compact ? "Can't connect" : m
        case .idle: store.auth.isSignedIn ? "Idle" : "Signed out"
        }
    }

    private var color: Color {
        switch store.gateway.state {
        case .connected: .green
        case .connecting: .yellow
        case .failed, .needsSignIn: .red
        case .idle: .gray
        }
    }
}

/// A System Settings–style pane icon: a white symbol on a glossy rounded tile of the pane's color.
private struct SettingsIcon: View {
    let pane: SettingsPane
    let size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(pane.color.gradient)
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                    .strokeBorder(.white.opacity(0.25), lineWidth: 0.5)
            )
            .overlay(
                Image(systemName: pane.symbol)
                    .font(.system(size: size * 0.52, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.15), radius: 0.5, y: 0.5)
            )
            .frame(width: size, height: size)
            .shadow(color: pane.color.opacity(size > 30 ? 0.35 : 0), radius: 8, y: 3)
    }
}

/// Lets the content run under a transparent title bar so the glass sidebar can hold the traffic lights.
private struct SettingsWindowStyler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.isOpaque = false
            window.backgroundColor = .clear
            window.titleVisibility = .hidden
            // An empty unified toolbar gives the title bar its taller height, which drops the
            // traffic lights down into the glass sidebar instead of hugging the window corner.
            window.toolbar = NSToolbar()
            window.toolbarStyle = .unified
            window.titlebarSeparatorStyle = .none
            // Don't open with the cursor in Search; the pane list is what you reach for first.
            window.makeFirstResponder(nil)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// A round color chip like System Settings' accent picker; a ring marks the selection.
private struct TintSwatch: View {
    let color: Color
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .overlay(Circle().strokeBorder(.primary.opacity(0.18)))
                .frame(width: 16, height: 16)
                .padding(2.5)
                .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: selected ? 2 : 0))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.15), value: selected)
    }
}

import SwiftUI
import UniformTypeIdentifiers

struct QuickChatView: View {
    @Environment(ChatStore.self) private var store
    @Environment(PanelPresentation.self) private var presentation
    @State private var isDropTargeted = false
    @Namespace private var glass

    private var prefs: Preferences { Preferences.shared }
    private var cardWidth: CGFloat { prefs.effectivePanelWidth }
    private var listHeight: CGFloat { prefs.listHeight }
    private var hasConversation: Bool {
        !store.messages.isEmpty || store.voice.isConversing || store.showingHistory || store.isOpeningSession
    }

    var body: some View {
        PanelGlassContainer {
            VStack(spacing: 10) {
                card
                if let err = store.lastError ?? store.voice.errorMessage {
                    ErrorPill(text: err) { store.lastError = nil; store.voice.errorMessage = nil }
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .frame(width: cardWidth)
        .scaleEffect(presentation.isPresented ? 1 : 0.94, anchor: .top)
        .offset(y: presentation.isPresented ? 0 : -14)
        .opacity(presentation.isPresented ? 1 : 0)
        .blur(radius: presentation.isPresented ? 0 : 6)
        .padding(.top, 28)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.42, dampingFraction: 0.84), value: hasConversation)
        .animation(.snappy, value: store.lastError)
        .onChange(of: store.showingHistory) { _, showing in
            if !showing { presentation.focusToken += 1 }
        }
        .onChange(of: prefs.panelWidth) { presentation.refit() }
        .onChange(of: prefs.listHeight) { presentation.refit() }
        .onChange(of: prefs.textScale) { presentation.refit() }
    }

    @ViewBuilder
    private var card: some View {
        VStack(spacing: 0) {
            if !store.auth.isSignedIn {
                SignInView()
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                if hasConversation {
                    HeaderBar()
                        .transition(.move(edge: .top).combined(with: .opacity))
                    if store.showingHistory {
                        HistoryView()
                            .frame(height: listHeight)
                            .transition(.handoff)
                    } else if store.voice.isConversing {
                        VoiceStage()
                            .frame(height: 300)
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    } else if store.isOpeningSession && store.messages.isEmpty {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                            .frame(height: listHeight)
                            .transition(.opacity)
                    } else {
                        // Shrinks to make room for a question card so the card never outgrows the fixed-size panel.
                        MessageList()
                            .frame(minHeight: 160, maxHeight: listHeight)
                            .transition(.handoff)
                    }
                }
                if let prompt = store.activePrompt, !store.showingHistory {
                    PromptCard(prompt: prompt)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 8)
                        // Grow out of the composer and shrink back into it, never sliding underneath.
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
                }
                if !store.showingHistory {
                    ComposerView()
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .background { PanelBackdrop(opacity: prefs.backgroundOpacity, tint: .panelTint(prefs.backgroundTint)) }
        .background {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.8), style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                    .padding(3)
                    .transition(.opacity)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .panelGlass(RoundedRectangle(cornerRadius: 28, style: .continuous), id: "card", in: glass)
        .shadow(color: .black.opacity(0.28), radius: 30, y: 16)
        // Grab strips straddle the card's edge (half outside, in the window's transparent margin).
        .overlay { if store.auth.isSignedIn { ResizeHandles(vertical: hasConversation && !store.voice.isConversing).padding(-ResizeHandles.overhang) } }
        .onDrop(of: [.fileURL, .image], isTargeted: $isDropTargeted.animation(.snappy)) { providers in
            loadDrop(providers)
            return true
        }
    }

    /// Finder files arrive as file URLs; images from Safari, Photos or the screenshot thumbnail as image data.
    private func loadDrop(_ providers: [NSItemProvider]) {
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in store.addFiles([url]) }
                }
            } else if let type = p.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) {
                let ext = UTType(type)?.preferredFilenameExtension ?? "png"
                let name = (p.suggestedName ?? "Dropped Image \(Attachment.stamp())") + "." + ext
                p.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                    guard let data else { return }
                    Task { @MainActor in
                        if let a = Attachment.image(data, name: name) { store.addAttachments([a]) }
                        else { store.lastError = "Couldn't read that image." }
                    }
                }
            }
        }
    }
}

/// The card's glass. Debug snapshots (`-uiPreviewSnapshot`) draw it flat: system glass can't be
/// rendered in-process, and content inside it comes out blank.
private struct PanelGlassContainer<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        if UIPreview.isFlat { content } else { GlassEffectContainer(spacing: 14) { content } }
    }
}

private extension View {
    @ViewBuilder
    func panelGlass<S: InsettableShape>(_ shape: S, id: String, in namespace: Namespace.ID) -> some View {
        if UIPreview.isFlat {
            self.overlay(shape.strokeBorder(.white.opacity(0.12)))
        } else {
            self.glassEffect(.regular, in: shape).glassEffectID(id, in: namespace)
        }
    }
}

extension AnyTransition {
    /// Swap two views that share a spot: the old one fades out first, then the new one fades in,
    /// so their contents never show through each other.
    static var handoff: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.985, anchor: .top))
                .animation(.easeOut(duration: 0.2).delay(0.1)),
            removal: .opacity.animation(.easeIn(duration: 0.1)))
    }
}

// MARK: - Header

struct HeaderBar: View {
    @Environment(ChatStore.self) private var store
    @Environment(\.openSettings) private var openSettings

    private var botName: String { store.activeBot?.displayName ?? Preferences.shared.profile.capitalized }

    var body: some View {
        HStack(spacing: 10) {
            // Title first; who and which model sit underneath as a subtitle that opens the bot/model menu.
            // Only the title flexes, so a long name truncates and nothing else moves.
            identityMenu {
                BotAvatar(name: botName, size: 30)
            }
            VStack(alignment: .leading, spacing: 1) {
                if store.showingHistory {
                    Text("Chats")
                        .font(.system(size: 14, weight: .semibold))
                        .transition(.handoff)
                } else {
                    ChatTitle()
                        .transition(.handoff)
                }
                identityMenu {
                    HStack(spacing: 3) {
                        Text("\(botName) · \(shortModel)")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .contentTransition(.numericText())
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if store.isBusy {
                ThinkingDots()
                    .transition(.scale.combined(with: .opacity))
            }
            HStack(spacing: 0) {
                if !store.showingHistory, let usage = store.usage, usage.contextFraction != nil {
                    ContextGauge(usage: usage, compact: true)
                        .transition(.scale.combined(with: .opacity))
                }
                IconButton(symbol: "clock.arrow.circlepath", help: "Past chats (⌘K)",
                           active: store.showingHistory) { store.toggleHistory() }
                IconButton(symbol: "square.and.pencil", help: "New chat (⌘N)") { store.newChat() }
            }
            .padding(.horizontal, 3)
            .frame(height: 34)
            .glassEffect(.regular, in: Capsule())
            .fixedSize()
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .background(WindowDragArea())
        .overlay(alignment: .top) { DragGrabber().padding(.top, 4) }
        .animation(.snappy, value: store.isBusy)
        .animation(.snappy, value: store.showingHistory)
        .task {
            if store.bots.isEmpty { await store.refreshBots() }
            if store.models.isEmpty { await store.refreshModels() }
        }
    }

    /// The avatar and the subtitle both open this: bots, then models by provider, then Settings.
    private func identityMenu<MenuLabel: View>(@ViewBuilder label: () -> MenuLabel) -> some View {
        Menu {
            Section("Bot") {
                if store.bots.isEmpty { Text("No bots found") }
                ForEach(store.bots) { bot in
                    Button {
                        store.switchBot(bot)
                    } label: {
                        if bot.name == Preferences.shared.profile { Label(bot.displayName, systemImage: "checkmark") }
                        else { Text(bot.displayName) }
                    }
                }
            }
            let groups = Dictionary(grouping: store.models, by: \.providerName)
            ForEach(groups.keys.sorted(), id: \.self) { provider in
                Section(provider) {
                    ForEach(groups[provider] ?? []) { choice in
                        Button {
                            store.selectModel(choice)
                        } label: {
                            if choice.model == store.currentModel && choice.provider == store.currentProvider {
                                Label(choice.model, systemImage: "checkmark")
                            } else {
                                Text(choice.model)
                            }
                        }
                    }
                }
            }
            if store.models.isEmpty { Text("Loading models…") }
            Divider()
            Button("Refresh Models") { Task { await store.refreshModels() } }
            Button("Settings…") {
                NSApp.activate()
                openSettings()
            }
        } label: {
            label()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Switch bot or model")
    }

    private var shortModel: String {
        let m = store.currentModel.isEmpty ? "Model" : store.currentModel
        return m.split(separator: "/").last.map(String.init) ?? m
    }
}

/// The open chat's title. Double-click (or right-click › Rename) to rename it in place.
struct ChatTitle: View {
    @Environment(ChatStore.self) private var store
    @State private var editing = false
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if editing {
                TextField("Chat name", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .semibold))
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand { editing = false }
                    .onChange(of: focused) { _, f in if !f && editing { commit() } }
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .padding(.leading, -6)
                    .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .frame(maxWidth: 320, alignment: .leading)
            } else if !store.currentTitle.isEmpty {
                Text(store.currentTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .contentTransition(.opacity)
                    .onTapGesture(count: 2, perform: beginEditing)
                    .contextMenu { Button("Rename…", action: beginEditing) }
                    .help(store.currentTitle + "\nDouble-click to rename")
            } else {
                Text("New Chat")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .animation(.snappy, value: store.currentTitle)
    }

    private func beginEditing() {
        text = store.currentTitle
        editing = true
        focused = true
    }

    private func commit() {
        editing = false
        store.renameCurrentChat(text)
    }
}

struct BotAvatar: View {
    let name: String
    var size: CGFloat = 18
    var body: some View {
        Text(String(name.prefix(1)).uppercased())
            .font(.system(size: size * 0.55, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(gradient, in: Circle())
    }

    /// Stable per-name hue (hashValue is randomized per launch).
    private var gradient: LinearGradient {
        let sum = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        let hue = Double(sum % 360) / 360.0
        let top = Color(hue: hue, saturation: 0.6, brightness: 0.95)
        let bottom = Color(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.75, brightness: 0.7)
        return LinearGradient(colors: [top, bottom], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    var active = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(active ? AnyShapeStyle(Color.accentColor) : hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        .background(Circle().fill(active ? Color.accentColor.opacity(0.15) : Color.primary.opacity(hovering ? 0.08 : 0)))
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .help(help)
    }
}

struct ThinkingDots: View {
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<3) { i in
                    Circle()
                        .frame(width: 5, height: 5)
                        .scaleEffect(0.6 + 0.4 * (sin(t * 5 - Double(i) * 0.7) + 1) / 2)
                        .opacity(0.4 + 0.6 * (sin(t * 5 - Double(i) * 0.7) + 1) / 2)
                }
            }
            .foregroundStyle(.secondary)
        }
        .frame(width: 26)
    }
}

struct ErrorPill: View {
    let text: String
    let dismiss: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).font(.system(size: 12)).lineLimit(2)
            Spacer(minLength: 0)
            Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .glassEffect(.regular, in: Capsule())
    }
}

/// Empty space that moves the panel when dragged (buttons on top keep their clicks).
struct WindowDragArea: View {
    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(WindowDragGesture())
            .allowsWindowActivationEvents(true)
    }
}

/// A small pill that brightens on hover to show the panel can be dragged.
struct DragGrabber: View {
    @State private var hovering = false
    var body: some View {
        Capsule()
            .fill(.primary.opacity(hovering ? 0.35 : 0.14))
            .frame(width: 36, height: 4)
            .padding(.vertical, 3)
            .padding(.horizontal, 20)
            .contentShape(Rectangle())
            .gesture(WindowDragGesture())
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                // Double-click puts the panel back to its standard size. Not animated: the window refits at
                // once, and a card still animating down from a bigger size would overflow it.
                Preferences.shared.panelWidth = Preferences.defaultPanelWidth
                Preferences.shared.listHeight = Preferences.defaultListHeight
            })
            .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
            .help("Drag to move. Double-click to reset the size.")
    }
}

/// Invisible strips along the card's sides and bottom. Dragging a side widens the card evenly
/// (the panel stays centred); dragging the bottom makes the message list taller.
struct ResizeHandles: View {
    /// Bottom edge and corners only when there's a message list to grow.
    let vertical: Bool
    @State private var start: (mouse: NSPoint, width: Double, height: Double)?

    private enum Edge { case left, right, bottom, bottomLeft, bottomRight }

    /// How far the strips reach past the card; they reach the same distance in.
    static let overhang: CGFloat = 8
    private let thickness = overhang * 2
    private let corner: CGFloat = 36

    var body: some View {
        ZStack {
            handle(.left).frame(width: thickness).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 30).padding(.bottom, vertical ? corner : 30)
            handle(.right).frame(width: thickness).frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.top, 30).padding(.bottom, vertical ? corner : 30)
            if vertical {
                handle(.bottom).frame(height: thickness).frame(maxHeight: .infinity, alignment: .bottom).padding(.horizontal, corner)
                handle(.bottomLeft).frame(width: corner, height: corner).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                handle(.bottomRight).frame(width: corner, height: corner).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
    }

    private func handle(_ edge: Edge) -> some View {
        // Not fully clear: the panel lets clicks through where nothing is drawn, and these sit partly
        // over that transparent margin.
        Color.black.opacity(0.002)
            .contentShape(Rectangle())
            .pointerStyle(.frameResize(position: position(edge)))
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { _ in drag(edge) }
                .onEnded { _ in start = nil })
    }

    private func position(_ edge: Edge) -> FrameResizePosition {
        switch edge {
        case .left: .leading
        case .right: .trailing
        case .bottom: .bottom
        case .bottomLeft: .bottomLeading
        case .bottomRight: .bottomTrailing
        }
    }

    /// Works in screen coordinates: the window itself moves while it resizes.
    private func drag(_ edge: Edge) {
        let prefs = Preferences.shared
        let mouse = NSEvent.mouseLocation
        if start == nil { start = (mouse, prefs.effectivePanelWidth, prefs.listHeight) }
        guard let start else { return }
        let dx = mouse.x - start.mouse.x
        let dy = start.mouse.y - mouse.y
        let screen = (NSApp.keyWindow?.screen ?? NSScreen.main)?.visibleFrame ?? .init(x: 0, y: 0, width: 1440, height: 900)
        var width = start.width, height = start.height
        switch edge {
        case .left, .bottomLeft: width -= 2 * dx
        case .right, .bottomRight: width += 2 * dx
        case .bottom: break
        }
        if edge == .bottom || edge == .bottomLeft || edge == .bottomRight { height += dy }
        prefs.panelWidth = min(max(width, Preferences.minPanelWidth), Preferences.maxPanelWidth, screen.width - 120).rounded()
        prefs.listHeight = min(max(height, 240), screen.height - 340).rounded()
    }
}

// MARK: - Sign in

struct SignInView: View {
    @Environment(ChatStore.self) private var store
    @State private var url = Preferences.shared.gatewayURL

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "bolt.horizontal.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
                .symbolEffect(.pulse, isActive: store.auth.isSigningIn)
            Text("Connect to Hermes")
                .font(.system(size: 20, weight: .semibold))
            Text("Sign in to your gateway in the browser. Your password stays on the gateway's page.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            TextField("Gateway URL", text: $url)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: Capsule())
                .frame(width: 320)
                .onSubmit(signIn)
            HStack {
                if store.auth.isSigningIn {
                    Button("Cancel") { store.auth.cancelSignIn() }
                        .buttonStyle(.glass)
                    ProgressView().controlSize(.small)
                    Text("Waiting for browser…").font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    Button("Sign In with Browser", action: signIn)
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity)
    }

    private func signIn() {
        Preferences.shared.gatewayURL = url
        store.auth.reload()
        if store.auth.isSignedIn { store.warmUp() } else { store.signIn() }
    }
}

/// Sits under the card's content, inside its glass: a behind-window blur that frosts the desktop,
/// then a tint (by default the window color: dark in Dark Mode, light in Light Mode) so text reads clearly.
struct PanelBackdrop: View {
    let opacity: Double
    let tint: Color

    var body: some View {
        ZStack {
            if !UIPreview.isFlat { BehindWindowBlur().opacity(min(1, opacity * 1.6)) }
            tint.opacity(opacity * 0.75)
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.2), value: opacity)
        .animation(.easeOut(duration: 0.25), value: tint)
    }
}

struct BehindWindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .underWindowBackground
        v.blendingMode = .behindWindow
        v.state = .active  // the panel often isn't key; keep blurring anyway
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

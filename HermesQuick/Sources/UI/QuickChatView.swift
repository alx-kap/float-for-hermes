import SwiftUI
import UniformTypeIdentifiers

struct QuickChatView: View {
    @Environment(ChatStore.self) private var store
    @Environment(PanelPresentation.self) private var presentation
    @State private var isDropTargeted = false
    @Namespace private var glass

    private let cardWidth: CGFloat = 680
    private var hasConversation: Bool {
        !store.messages.isEmpty || store.voice.isConversing || store.showingHistory || store.isOpeningSession
    }

    var body: some View {
        GlassEffectContainer(spacing: 14) {
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
                            .frame(height: 440)
                            .transition(.handoff)
                    } else if store.voice.isConversing {
                        VoiceStage()
                            .frame(height: 300)
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    } else if store.isOpeningSession && store.messages.isEmpty {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                            .frame(height: 440)
                            .transition(.opacity)
                    } else {
                        // Shrinks to make room for a question card so the card never outgrows the fixed-size panel.
                        MessageList()
                            .frame(minHeight: 160, maxHeight: 440)
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
        .background {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.8), style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                    .padding(3)
                    .transition(.opacity)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .glassEffectID("card", in: glass)
        .shadow(color: .black.opacity(0.28), radius: 30, y: 16)
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

    var body: some View {
        HStack(spacing: 8) {
            botMenu
            modelMenu
            if store.showingHistory {
                Text("Chats")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.leading, 4)
                    .transition(.handoff)
            } else {
                ChatTitle()
                    .transition(.handoff)
            }
            Spacer(minLength: 4)
            if store.isBusy {
                ThinkingDots()
                    .transition(.scale.combined(with: .opacity))
            }
            IconButton(symbol: "clock.arrow.circlepath", help: "Past chats (⌘K)",
                       active: store.showingHistory) { store.toggleHistory() }
            IconButton(symbol: "square.and.pencil", help: "New chat (⌘N)") { store.newChat() }
            IconButton(symbol: "gearshape", help: "Settings") {
                NSApp.activate()
                openSettings()
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .background(WindowDragArea())
        .overlay(alignment: .top) { DragGrabber().padding(.top, 4) }
        .animation(.snappy, value: store.isBusy)
        .animation(.snappy, value: store.showingHistory)
    }

    private var botMenu: some View {
        Menu {
            if store.bots.isEmpty { Text("No bots found") }
            ForEach(store.bots) { bot in
                Button {
                    store.switchBot(bot)
                } label: {
                    if bot.name == Preferences.shared.profile { Label(bot.displayName, systemImage: "checkmark") }
                    else { Text(bot.displayName) }
                }
            }
        } label: {
            HStack(spacing: 6) {
                BotAvatar(name: store.activeBot?.displayName ?? Preferences.shared.profile)
                Text(store.activeBot?.displayName ?? Preferences.shared.profile.capitalized)
                    .font(.system(size: 13, weight: .semibold))
            }
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .fixedSize()
        .task { if store.bots.isEmpty { await store.refreshBots() } }
    }

    private var modelMenu: some View {
        Menu {
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
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "cpu")
                    .font(.system(size: 11, weight: .semibold))
                Text(shortModel)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .contentTransition(.numericText())
            }
            .foregroundStyle(.secondary)
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .fixedSize()
        .task { if store.models.isEmpty { await store.refreshModels() } }
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
                    .font(.system(size: 12, weight: .medium))
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand { editing = false }
                    .onChange(of: focused) { _, f in if !f && editing { commit() } }
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .frame(maxWidth: 220)
            } else if !store.currentTitle.isEmpty {
                Text(store.currentTitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .contentTransition(.opacity)
                    .padding(.leading, 4)
                    .onTapGesture(count: 2, perform: beginEditing)
                    .contextMenu { Button("Rename…", action: beginEditing) }
                    .help("Double-click to rename")
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
    var body: some View {
        Text(String(name.prefix(1)).uppercased())
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 18, height: 18)
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
            .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
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

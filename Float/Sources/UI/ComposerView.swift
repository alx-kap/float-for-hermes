import SwiftUI
import UniformTypeIdentifiers

struct ComposerView: View {
    @Environment(ChatStore.self) private var store
    @Environment(PanelPresentation.self) private var presentation
    @FocusState private var focused: Bool
    @Namespace private var morph

    var body: some View {
        @Bindable var store = store
        let voice = store.voice

        VStack(spacing: 8) {
            if store.editingMessageId != nil {
                HStack(spacing: 6) {
                    Image(systemName: "pencil")
                    Text("Editing your last message. Sending replaces it and the reply.")
                    Spacer()
                    Button("Cancel") { store.cancelEdit() }
                        .buttonStyle(.link)
                        .help("Cancel (esc)")
                }
                .font(.app(11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if !store.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(store.attachments) { a in
                            AttachmentChip(attachment: a) { store.removeAttachment(a) }
                                .contextMenu {
                                    if a.pastedText != nil {
                                        Button("Insert as Text") { store.expandPaste(a) }
                                    }
                                    Button("Remove", role: .destructive) { store.removeAttachment(a) }
                                }
                                .transition(.scale(scale: 0.6).combined(with: .opacity))
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Every control is centred in a row one text line tall (it grows with the text size), so a
            // one-line draft lines up with the buttons; a longer draft grows upward and the buttons
            // stay with its last line.
            ZStack {
                if voice.isConversing {
                    VoiceBar(rowHeight: rowHeight, morph: morph)
                        .transition(.blurReplace)
                } else {
                    inputRow.transition(.blurReplace)
                }
            }
            // Under a conversation the input is its own glass pill, raised off the messages. With no
            // conversation the card itself is the input bar, so it stays flat.
            .padding(.horizontal, inPill ? 6 : 0)
            .padding(.vertical, inPill ? 5 : 0)
            .modifier(PillGlass(isOn: inPill))

            if store.showSlash {
                SlashMenu()
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.horizontal, inPill ? 12 : 14)
        .padding(.top, inPill ? 4 : 12)
        .padding(.bottom, 12)
        .background(WindowDragArea())
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: voice.isListening)
        .animation(.spring(response: 0.45, dampingFraction: 0.82), value: voice.isConversing)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: store.attachments.count)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: store.showSlash)
        .animation(.snappy, value: store.messages.isEmpty)
        .animation(.snappy, value: inPill)
        .animation(.snappy, value: store.currentModel.isEmpty)
        .animation(.snappy, value: store.editingMessageId)
        .onChange(of: store.draft) { _, text in store.updateSlash(for: text) }
        .onChange(of: presentation.focusToken) { focused = true }
        .onChange(of: voice.isConversing) { _, on in if !on { focused = true } }
        .onAppear { focused = true }
        .onChange(of: focused, initial: true) { _, f in store.composerFocused = f }
        .background(shortcuts)
    }

    /// The text field and its buttons. In voice mode the pill swaps this for `VoiceBar`.
    private var inputRow: some View {
        @Bindable var store = store
        let voice = store.voice
        return HStack(alignment: .bottom, spacing: 8) {
                IconButton(symbol: "plus", help: "Attach files (⌘O)") { store.chooseFiles(over: NSApp.keyWindow) }
                    .frame(height: rowHeight)
                if store.messages.isEmpty && !store.voice.isConversing && !store.isOpeningSession && !store.showingHistory {
                    // The header (with its own history button) only appears once a chat has started.
                    IconButton(symbol: "clock.arrow.circlepath", help: "Past chats (⌘K)") { store.openHistory() }
                        .frame(height: rowHeight)
                        .transition(.scale.combined(with: .opacity))
                }

                ZStack(alignment: .leading) {
                    if voice.isListening {
                        HStack(spacing: 10) {
                            LevelBars(level: voice.level)
                            Text(voice.transcript.isEmpty ? "Listening…" : voice.transcript)
                                .font(.app(17))
                                .foregroundStyle(voice.transcript.isEmpty ? .secondary : .primary)
                                .lineLimit(3)
                                .contentTransition(.opacity)
                                .animation(.easeOut(duration: 0.15), value: voice.transcript)
                        }
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    } else if UIPreview.isFlat {
                        // Debug snapshots: ImageRenderer can't draw the AppKit-backed text field.
                        Text(placeholder).font(.app(17)).foregroundStyle(.tertiary)
                    } else {
                        TextField(placeholder, text: $store.draft, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.app(17))
                            .lineLimit(1...8)
                            .focused($focused)
                            .onSubmit { store.send() }
                            .transition(.opacity)
                    }
                }
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading)

                if !inPill && !store.currentModel.isEmpty {
                    // Before a chat starts there's no header, so the model you'll start with sits here.
                    ModelChip().frame(height: rowHeight)
                        .transition(.scale(scale: 0.8, anchor: .trailing).combined(with: .opacity))
                }
                micButton.frame(height: rowHeight)
                conversationButton.frame(height: rowHeight)
                sendButton.frame(height: rowHeight)
            }
    }

    static let buttonSize: CGFloat = 32

    /// One line of the draft plus the field's vertical padding, never shorter than the buttons.
    private var rowHeight: CGFloat {
        let font = NSFont.systemFont(ofSize: (17 * Preferences.shared.textScale).rounded())
        return max(Self.buttonSize, ceil(NSLayoutManager().defaultLineHeight(for: font)) + 10)
    }

    /// Matches when QuickChatView shows a conversation above the composer.
    private var inPill: Bool {
        !store.messages.isEmpty || store.voice.isConversing || store.isOpeningSession
    }

    private var placeholder: String {
        let bot = store.botName
        if let q = store.activeQuestion { return q.choices.isEmpty ? "Type your answer…" : "Or type your own answer…" }
        if store.editingMessageId != nil { return "Edit your message…" }
        return "Ask \(bot)…"
    }

    private var micButton: some View {
        let listening = store.voice.isListening
        return Button { store.voice.toggleDictation() } label: {
            Image(systemName: listening ? "waveform" : "mic")
                .font(.app(14, weight: .semibold))
                .symbolEffect(.variableColor.iterative, isActive: listening)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: Self.buttonSize, height: Self.buttonSize)
        }
        .buttonStyle(.plain)
        .foregroundStyle(listening ? Color.red : .secondary)
        .glassEffect(listening ? .regular.tint(.red.opacity(0.25)).interactive() : .regular.interactive(), in: Circle())
        .help("Dictate (⌘D)")
    }

    private var conversationButton: some View {
        Button { store.voice.startConversation() } label: {
            Image(systemName: "waveform.circle.fill")
                .font(.app(17, weight: .semibold))
                .frame(width: Self.buttonSize, height: Self.buttonSize)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .glassEffect(.regular.interactive(), in: Circle())
        // Becomes voice mode's close button, in the same corner of the bar.
        .matchedGeometryEffect(id: "voiceToggle", in: morph)
        .help("Voice mode (⇧⌘D)")
    }

    private var sendButton: some View {
        // Busy shows Stop, unless the composer is answering one of Hermes's questions.
        let stops = store.isBusy && !store.canSend
        return Button {
            stops ? store.interrupt() : store.send()
        } label: {
            Image(systemName: stops ? "stop.fill" : "arrow.up")
                .font(.app(stops ? 11 : 14, weight: .bold))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(.white)
                .frame(width: Self.buttonSize, height: Self.buttonSize)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(store.isBusy || store.canSend ? .accentColor : .gray.opacity(0.5)).interactive(), in: Circle())
        .scaleEffect(store.canSend || store.isBusy ? 1 : 0.92)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: store.canSend)
        .disabled(!store.isBusy && !store.canSend)
        .help(stops ? "Stop (⌘.)" : store.activeQuestion != nil ? "Answer (↩)"
              : store.editingMessageId != nil ? "Send edited message (↩)" : "Send (↩)")
    }

    private var shortcuts: some View {
        Group {
            Button("") { store.newChat() }.keyboardShortcut("n", modifiers: .command)
            Button("") { store.interrupt() }.keyboardShortcut(".", modifiers: .command)
            Button("") { if !store.voice.isConversing { store.voice.toggleDictation() } }.keyboardShortcut("d", modifiers: .command)
            Button("") { store.voice.toggleConversation() }.keyboardShortcut("d", modifiers: [.command, .shift])
            Button("") { store.chooseFiles(over: NSApp.keyWindow) }.keyboardShortcut("o", modifiers: .command)
            Button("") { store.regenerate() }.keyboardShortcut("r", modifiers: .command)
            Button("") { Preferences.shared.stepTextSize(1) }.keyboardShortcut("=", modifiers: .command)
            Button("") { Preferences.shared.stepTextSize(1) }.keyboardShortcut("+", modifiers: .command)
            Button("") { Preferences.shared.stepTextSize(-1) }.keyboardShortcut("-", modifiers: .command)
            Button("") { Preferences.shared.textScale = 1 }.keyboardShortcut("0", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
    }

}

/// The compact bar's model: just its name, quiet until you point at it, opening the same picker as
/// the header. ⌘⇧M opens it from the keyboard.
private struct ModelChip: View {
    @Environment(ChatStore.self) private var store
    @Environment(\.openSettings) private var openSettings
    @AppStorage("settingsPane") private var settingsPane: SettingsPane = .general
    @State private var showingPicker = false
    @State private var hovering = false

    var body: some View {
        Button { showingPicker.toggle() } label: {
            HStack(spacing: 4) {
                if store.fastMode {
                    Image(systemName: "bolt.fill")
                        .font(.app(10, weight: .semibold))
                        .foregroundStyle(.orange)
                        .transition(.scale.combined(with: .opacity))
                }
                Text(ModelChoice.displayName(store.currentModel))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .contentTransition(.numericText())
                    .popover(isPresented: $showingPicker, arrowEdge: .bottom) {
                        ModelPicker(openSettings: {
                            settingsPane = .general
                            NSApp.activate()
                            openSettings()
                        }, dismiss: { showingPicker = false })
                        .environment(store)
                    }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.app(8.5, weight: .semibold))
                    .opacity(hovering || showingPicker ? 1 : 0.6)
            }
            .font(.app(12.5, weight: .medium))
            .foregroundStyle(hovering || showingPicker ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .frame(maxWidth: 150)
            .background(Capsule().fill(.primary.opacity(hovering || showingPicker ? 0.08 : 0.04)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .keyboardShortcut("m", modifiers: [.command, .shift])
        .help("Start this chat with \(ModelChoice.displayName(store.currentModel)) (⇧⌘M)")
        .animation(.snappy, value: store.currentModel)
        .animation(.snappy, value: store.fastMode)
    }
}

/// Slash-command suggestions under the input. ↑↓ choose, ↩ run, ⇥ insert, esc close.
struct SlashMenu: View {
    @Environment(ChatStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(store.slashItems.enumerated()), id: \.element.id) { i, item in
                            SlashRow(item: item, selected: i == store.slashSelection)
                                .id(item.id)
                                .onHover { if $0 { store.slashSelection = i } }
                                .onTapGesture { store.slashSelection = i; store.runSelectedSlash() }
                        }
                    }
                    .padding(4)
                }
                .frame(height: min(CGFloat(store.slashItems.count), 6) * 40 + 8)
                .onChange(of: store.slashSelection) { _, i in
                    if let id = store.slashItems[safe: i]?.id { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id) } }
                }
            }
            HStack(spacing: 12) {
                hint("↑↓", "navigate"); hint("↩", "run"); hint("⇥", "insert"); hint("esc", "close")
                Spacer()
                Text("\(store.slashItems.count) command\(store.slashItems.count == 1 ? "" : "s")")
            }
            .font(.app(10.5))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 3) {
            Text(key).font(.app(10, weight: .semibold, design: .rounded))
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            Text(label)
        }
    }
}

struct SlashRow: View {
    let item: SlashItem
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.kind == "skill" ? "sparkles" : "command")
                .font(.app(11, weight: .semibold))
                .foregroundStyle(selected ? Color.white : Color.secondary)
                .frame(width: 22, height: 22)
                .background(selected ? Color.accentColor : Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
            Text(item.display)
                .font(.app(13, weight: .semibold, design: .monospaced))
            Text(item.meta)
                .font(.app(12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 38)
        .background(selected ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
    }
}

struct AttachmentChip: View {
    let attachment: Attachment
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            if let text = attachment.pastedText {
                pastedLabel(text)
            } else {
                fileLabel
            }
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill").font(.app(12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(hovering ? 1 : 0.5)
        }
        .padding(.leading, 5).padding(.trailing, 8).padding(.vertical, 4)
        .glassEffect(.regular, in: Capsule())
        .onHover { hovering = $0 }
    }

    /// A long paste: what it starts with and how long it is, like a document rather than a file name.
    private func pastedLabel(_ text: String) -> some View {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
        let first = text.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return HStack(spacing: 7) {
            Image(systemName: "doc.plaintext")
                .font(.app(14))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text(first.isEmpty ? "Pasted text" : first)
                    .font(.app(12, weight: .medium))
                    .lineLimit(1)
                Text("Pasted · \(lines) line\(lines == 1 ? "" : "s")")
                    .font(.app(10.5))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 180, alignment: .leading)
        }
        .help(String(text.prefix(600)))
    }

    @ViewBuilder private var fileLabel: some View {
        if let thumb = attachment.thumbnail {
            Image(nsImage: thumb)
                .resizable().aspectRatio(contentMode: .fill)
                .frame(width: 26, height: 26)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            Image(nsImage: attachment.url.map { NSWorkspace.shared.icon(forFile: $0.path) }
                  ?? NSWorkspace.shared.icon(for: UTType(filenameExtension: attachment.ext) ?? .data))
                .resizable().frame(width: 22, height: 22)
        }
        Text(attachment.name)
            .font(.app(12, weight: .medium))
            .lineLimit(1)
            .frame(maxWidth: 160)
    }
}

struct LevelBars: View {
    let level: Float
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2.5) {
                ForEach(0..<5) { i in
                    let wobble = (sin(t * 9 + Double(i) * 1.3) + 1) / 2
                    Capsule()
                        .frame(width: 3, height: 5 + CGFloat(level) * 18 * (0.45 + 0.55 * wobble))
                }
            }
            .foregroundStyle(.red)
            .frame(height: 24)
        }
    }
}

/// The composer's pill. The glass stays applied and only switches between `.regular` and `.identity`,
/// so turning it on when a chat starts doesn't rebuild the text field and drop its focus.
/// Debug snapshots can't draw system glass, so they get the flat look instead.
private struct PillGlass: ViewModifier {
    let isOn: Bool
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 22, style: .continuous) }

    func body(content: Content) -> some View {
        if UIPreview.isFlat {
            content.background {
                if isOn { shape.fill(.primary.opacity(0.06)).strokeBorder(.primary.opacity(0.09)) }
            }
        } else {
            content.glassEffect(isOn ? .regular : .identity, in: shape)
        }
    }
}

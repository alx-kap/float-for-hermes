import SwiftUI
import UniformTypeIdentifiers

struct ComposerView: View {
    @Environment(ChatStore.self) private var store
    @Environment(PanelPresentation.self) private var presentation
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var store = store
        let voice = store.voice

        VStack(spacing: 8) {
            if !store.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(store.attachments) { a in
                            AttachmentChip(attachment: a) { store.removeAttachment(a) }
                                .transition(.scale(scale: 0.6).combined(with: .opacity))
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            HStack(alignment: .bottom, spacing: 8) {
                IconButton(symbol: "plus", help: "Attach files (⌘O)") { store.chooseFiles(over: NSApp.keyWindow) }
                    .padding(.bottom, 2)
                if store.messages.isEmpty && !store.voice.isConversing && !store.isOpeningSession && !store.showingHistory {
                    // The header (with its own history button) only appears once a chat has started.
                    IconButton(symbol: "clock.arrow.circlepath", help: "Past chats (⌘K)") { store.openHistory() }
                        .padding(.bottom, 2)
                        .transition(.scale.combined(with: .opacity))
                }

                ZStack(alignment: .leading) {
                    if voice.isListening && !voice.isConversing {
                        HStack(spacing: 10) {
                            LevelBars(level: voice.level)
                            Text(voice.transcript.isEmpty ? "Listening…" : voice.transcript)
                                .font(.system(size: 17))
                                .foregroundStyle(voice.transcript.isEmpty ? .secondary : .primary)
                                .lineLimit(3)
                                .contentTransition(.opacity)
                                .animation(.easeOut(duration: 0.15), value: voice.transcript)
                        }
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    } else {
                        TextField(placeholder, text: $store.draft, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.system(size: 17))
                            .lineLimit(1...8)
                            .focused($focused)
                            .onSubmit { store.send() }
                            .disabled(voice.isConversing)
                            .transition(.opacity)
                    }
                }
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)

                micButton
                conversationButton
                sendButton
            }

            if store.showSlash {
                SlashMenu()
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(WindowDragArea())
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: voice.isListening)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: store.attachments.count)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: store.showSlash)
        .animation(.snappy, value: store.messages.isEmpty)
        .onChange(of: store.draft) { _, text in store.updateSlash(for: text) }
        .onChange(of: presentation.focusToken) { focused = true }
        .onAppear { focused = true }
        .background(shortcuts)
    }

    private var placeholder: String {
        let bot = store.activeBot?.displayName ?? "Hermes"
        return store.voice.isConversing ? "Voice mode on" : "Ask \(bot)…"
    }

    private var micButton: some View {
        let listening = store.voice.isListening && !store.voice.isConversing
        return Button { store.voice.toggleDictation() } label: {
            Image(systemName: listening ? "waveform" : "mic")
                .font(.system(size: 14, weight: .semibold))
                .symbolEffect(.variableColor.iterative, isActive: listening)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .foregroundStyle(listening ? Color.red : .secondary)
        .glassEffect(listening ? .regular.tint(.red.opacity(0.25)).interactive() : .regular.interactive(), in: Circle())
        .help("Dictate (⌘D)")
        .disabled(store.voice.isConversing)
    }

    private var conversationButton: some View {
        Button { store.voice.toggleConversation() } label: {
            Image(systemName: store.voice.isConversing ? "xmark" : "waveform.circle.fill")
                .font(.system(size: store.voice.isConversing ? 13 : 17, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .foregroundStyle(store.voice.isConversing ? Color.primary : Color.accentColor)
        .glassEffect(.regular.interactive(), in: Circle())
        .help(store.voice.isConversing ? "End voice mode" : "Voice mode (⇧⌘D)")
    }

    private var sendButton: some View {
        Button {
            store.isBusy ? store.interrupt() : store.send()
        } label: {
            Image(systemName: store.isBusy ? "stop.fill" : "arrow.up")
                .font(.system(size: store.isBusy ? 11 : 14, weight: .bold))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(store.isBusy || store.canSend ? .accentColor : .gray.opacity(0.5)).interactive(), in: Circle())
        .scaleEffect(store.canSend || store.isBusy ? 1 : 0.92)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: store.canSend)
        .disabled(!store.isBusy && !store.canSend)
        .help(store.isBusy ? "Stop (⌘.)" : "Send (↩)")
    }

    private var shortcuts: some View {
        Group {
            Button("") { store.newChat() }.keyboardShortcut("n", modifiers: .command)
            Button("") { store.interrupt() }.keyboardShortcut(".", modifiers: .command)
            Button("") { store.voice.toggleDictation() }.keyboardShortcut("d", modifiers: .command)
            Button("") { store.voice.toggleConversation() }.keyboardShortcut("d", modifiers: [.command, .shift])
            Button("") { store.chooseFiles(over: NSApp.keyWindow) }.keyboardShortcut("o", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
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
            .font(.system(size: 10.5))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 3) {
            Text(key).font(.system(size: 10, weight: .semibold, design: .rounded))
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
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(selected ? Color.white : Color.secondary)
                .frame(width: 22, height: 22)
                .background(selected ? Color.accentColor : Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
            Text(item.display)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
            Text(item.meta)
                .font(.system(size: 12))
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
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .frame(maxWidth: 160)
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(hovering ? 1 : 0.5)
        }
        .padding(.leading, 5).padding(.trailing, 8).padding(.vertical, 4)
        .glassEffect(.regular, in: Capsule())
        .onHover { hovering = $0 }
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

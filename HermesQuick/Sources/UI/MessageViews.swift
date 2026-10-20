import SwiftUI

struct MessageList: View {
    @Environment(ChatStore.self) private var store
    @State private var position = ScrollPosition(edge: .bottom)
    /// Scrolled far enough up that the latest message is out of view.
    @State private var awayFromBottom = false

    var body: some View {
        if UIPreview.isFlat {
            // Debug snapshots: ImageRenderer can't draw the AppKit-backed scroll view.
            rows.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).clipped()
        } else {
            ScrollView { rows }
                .scrollPosition($position)
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .scrollIndicators(.automatic)
                .onScrollGeometryChange(for: Bool.self) { g in
                    g.contentSize.height - g.visibleRect.maxY > 160
                } action: { _, away in
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) { awayFromBottom = away }
                }
                .mask(
                    LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.04),
                                           .init(color: .black, location: 0.96), .init(color: .clear, location: 1)],
                                   startPoint: .top, endPoint: .bottom))
                .overlay(alignment: .bottom) {
                    if awayFromBottom {
                        ScrollToBottomButton {
                            withAnimation(.smooth(duration: 0.45)) { position.scrollTo(edge: .bottom) }
                        }
                        .padding(.bottom, 14)
                        .transition(.scale(scale: 0.6).combined(with: .opacity).combined(with: .offset(y: 8)))
                    }
                }
        }
    }

    /// Each exchange gets room: a new message of yours starts well clear of the reply above it,
    /// and a reply sits a little apart from the message it answers.
    static func gap(before msg: ChatMessage) -> CGFloat {
        msg.role == .user ? 30 : 22
    }

    private var rows: some View {
            LazyVStack(alignment: .leading, spacing: 0) {
                // Only the latest exchange can be edited, retried or regenerated (session.undo drops the last turn).
                let messages = store.messages
                let lastUser = messages.lastIndex { $0.role == .user }
                let lastReply = messages.lastIndex { $0.role == .assistant }.flatMap { $0 > (lastUser ?? -1) ? $0 : nil }
                ForEach(Array(messages.enumerated()), id: \.element.id) { i, msg in
                    let prev = i > 0 ? messages[i - 1] : nil
                    let next = i + 1 < messages.count ? messages[i + 1] : nil
                    let stamp = TimeDivider.shows(msg, after: prev)
                    // Like Messages: your messages in a row sit close together, and only the last one has a tail.
                    let joinsPrevious = !stamp && prev?.role == .user && msg.role == .user
                    let endsRun = !(next?.role == .user && msg.role == .user && !TimeDivider.shows(next!, after: msg))
                    VStack(spacing: 0) {
                        if stamp { TimeDivider(date: msg.date).padding(.top, i == 0 ? 0 : 6).padding(.bottom, 10) }
                        MessageRow(message: msg, isLatestUser: i == lastUser, isLatestReply: i == lastReply, hasTail: endsRun)
                    }
                    .padding(.top, i == 0 ? 0 : joinsPrevious ? 3 : Self.gap(before: msg) * Preferences.shared.textScale)
                        .id(msg.id)
                        .transition(.asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.98, anchor: .bottom)),
                            removal: .opacity))
                }
                if !store.status.isEmpty {
                    Label(store.status, systemImage: "sparkle")
                        .font(.app(12))
                        .foregroundStyle(.secondary)
                        .symbolEffect(.pulse)
                        .padding(.top, 14)
                        .transition(.opacity)
                }
            }
            // Inset as far as the card's corner radius, so text clears the rounded corners
            // and the column reads as sitting inside the shape.
            .padding(.horizontal, 28)
            .padding(.vertical, 12)
    }
}

/// Floats over the bottom of a scrolled-up chat and jumps back to the latest message.
struct ScrollToBottomButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(hovering ? .primary : .secondary)
                .frame(width: 36, height: 36)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .shadow(color: .black.opacity(0.28), radius: 10, y: 5)
        .scaleEffect(hovering ? 1.06 : 1)
        .onHover { h in withAnimation(.snappy(duration: 0.18)) { hovering = h } }
        .help("Scroll to latest")
        .accessibilityLabel("Scroll to latest message")
    }
}

struct MessageRow: View {
    @Environment(ChatStore.self) private var store
    let message: ChatMessage
    var isLatestUser = false
    var isLatestReply = false
    var hasTail = true
    @State private var hovering = false

    private var isEditing: Bool { store.editingMessageId == message.id }

    var body: some View {
        switch message.role {
        case .user: userBubble
        case .assistant: assistant
        case .notice, .error:
            CommandOutputCard(text: message.text, isError: message.role == .error)
        }
    }

    private var userBubble: some View {
        VStack(alignment: .trailing, spacing: 5) {
            HStack(alignment: .center, spacing: 6) {
                Spacer(minLength: 80)
                if isLatestUser && store.canEdit && !message.failed {
                    MessageAction(symbol: "pencil", help: "Edit") { store.beginEdit() }
                        .opacity(hovering ? 1 : 0)
                }
                bubble
                    .opacity(message.queued ? 0.6 : 1)
            }
            if isEditing {
                Label("Editing", systemImage: "pencil")
                    .font(.app(11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            } else if message.queued {
                HStack(spacing: 6) {
                    Label("Waiting for connection. It sends when Hermes is back.", systemImage: "clock")
                        .foregroundStyle(.secondary)
                    Button("Cancel") { store.cancelQueuedSend() }
                        .buttonStyle(.link)
                }
                .font(.app(11.5, weight: .medium))
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else if message.failed && isLatestUser {
                HStack(spacing: 6) {
                    Label("Didn't go through", systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                    Button("Retry") { store.regenerate() }
                        .buttonStyle(.link)
                        .disabled(!store.canRegenerate)
                }
                .font(.app(11.5, weight: .medium))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
        .contextMenu {
            Button("Copy") { copy(message.text) }
            if isLatestUser {
                Button("Edit") { store.beginEdit() }.disabled(!store.canEdit)
                Button(message.failed ? "Retry" : "Send Again") { store.regenerate() }.disabled(!store.canRegenerate)
            }
        }
    }

    private var bubble: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if !message.images.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(message.images.enumerated()), id: \.offset) { _, img in
                        Image(nsImage: img)
                            .resizable().aspectRatio(contentMode: .fill)
                            .frame(width: message.images.count == 1 ? 180 : 84, height: message.images.count == 1 ? 120 : 84)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            }
            if !message.attachments.isEmpty {
                HStack(spacing: 4) {
                    ForEach(message.attachments, id: \.self) { name in
                        Label(name, systemImage: "paperclip")
                            .font(.app(11))
                            .lineLimit(1)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.white.opacity(0.18), in: Capsule())
                    }
                }
            }
            if !message.text.isEmpty {
                Text(message.text)
                    .font(.app(14))
                    .textSelection(.enabled)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.82)],
                           startPoint: .top, endPoint: .bottom),
            in: BubbleShape(tail: hasTail))
        .padding(.trailing, 5)  // room for the tail, kept for every bubble so a run lines up
        .opacity(isEditing ? 0.45 : 1)
    }

    private var assistant: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !message.tools.isEmpty {
                ToolStrip(tools: message.tools)
            }
            if message.text.isEmpty && message.isStreaming {
                ShimmerText(text: message.tools.isEmpty ? "Thinking…" : "Working…")
            } else {
                MarkdownView(markdown: message.text)
                    .overlay(alignment: .bottomTrailing) {
                        if message.isStreaming { StreamingCaret().offset(x: 10) }
                    }
            }
            if !message.isStreaming {
                let media = MediaRef.extract(from: message.text)
                if !media.isEmpty { MediaGallery(refs: media) }
                if isLatestReply { replyActions }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
        .contextMenu {
            Button("Copy") { copy(message.text) }
            if isLatestReply {
                Button("Regenerate") { store.regenerate() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(!store.canRegenerate)
            }
        }
    }

    /// Under the latest reply: Copy and Regenerate on hover, or a Try Again that stays put after an error.
    @ViewBuilder
    private var replyActions: some View {
        if message.failed {
            Button { store.regenerate() } label: {
                Label("Try Again", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .disabled(!store.canRegenerate)
            .help("Try again (⌘R)")
        } else {
            HStack(spacing: 2) {
                MessageAction(symbol: "doc.on.doc", help: "Copy") { copy(message.text) }
                MessageAction(symbol: "arrow.clockwise", help: "Regenerate (⌘R)") { store.regenerate() }
                    .disabled(!store.canRegenerate)
            }
            .opacity(hovering ? 1 : 0)
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// A Messages-style bubble: rounded, with a tail curling off the bottom-right corner.
struct BubbleShape: Shape {
    var tail: Bool

    func path(in rect: CGRect) -> Path {
        let body = Path(roundedRect: rect, cornerRadius: 18, style: .continuous)
        guard tail else { return body }
        let x = rect.maxX, y = rect.maxY
        var t = Path()
        t.move(to: CGPoint(x: x - 2, y: y - 18))
        t.addCurve(to: CGPoint(x: x + 5, y: y), control1: CGPoint(x: x - 1, y: y - 7), control2: CGPoint(x: x + 1.5, y: y - 2))
        t.addCurve(to: CGPoint(x: x - 15, y: y - 3), control1: CGPoint(x: x - 2, y: y + 0.5), control2: CGPoint(x: x - 9, y: y))
        t.closeSubpath()
        return body.union(t)
    }
}

/// "Today 9:41 AM" between messages, like Messages: before the first one and after a long gap.
struct TimeDivider: View {
    let date: Date

    static func shows(_ msg: ChatMessage, after prev: ChatMessage?) -> Bool {
        guard let prev else { return true }
        return msg.date.timeIntervalSince(prev.date) > 15 * 60
    }

    var body: some View {
        (Text(day).fontWeight(.semibold) + Text(" ") + Text(date, format: .dateTime.hour().minute()))
            .font(.app(11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
    }

    private var day: String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        if let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: .now)).day, days < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(.dateTime.month(.abbreviated).day().year(cal.isDate(date, equalTo: .now, toGranularity: .year) ? .omitted : .defaultDigits))
    }
}

/// A small borderless icon button shown on hover next to a message.
struct MessageAction: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.app(11.5, weight: .medium))
                .frame(width: 24, height: 22)
                .background(.primary.opacity(hovering && isEnabled ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(hovering ? .primary : .secondary)
        .help(help)
        .onHover { hovering = $0 }
    }
}

struct ToolStrip: View {
    let tools: [ToolActivity]
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            let shown = expanded ? tools : Array(tools.suffix(3))
            if tools.count > 3 {
                Button(expanded ? "Show less" : "\(tools.count - 3) more steps") {
                    withAnimation(.snappy) { expanded.toggle() }
                }
                .buttonStyle(.plain)
                .font(.app(11, weight: .medium))
                .foregroundStyle(.secondary)
            }
            ForEach(shown) { tool in
                ToolChip(tool: tool)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
    }
}

struct ToolChip: View {
    let tool: ToolActivity

    var body: some View {
        HStack(spacing: 7) {
            ZStack {
                if tool.done {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Image(systemName: tool.symbol)
                        .symbolEffect(.pulse, options: .repeating)
                        .foregroundStyle(.tint)
                }
            }
            .font(.app(11, weight: .semibold))
            .frame(width: 14)
            Text(tool.prettyName)
                .font(.app(12, weight: .medium))
            Text(tool.done && !tool.summary.isEmpty ? tool.summary : tool.preview)
                .font(.app(11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let d = tool.duration {
                Text(String(format: "%.1fs", d))
                    .font(.app(10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .glassEffect(.regular, in: Capsule())
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: tool.done)
    }
}

struct StreamingCaret: View {
    @State private var on = false
    var body: some View {
        Capsule()
            .fill(.tint)
            .frame(width: 7, height: 14)
            .opacity(on ? 1 : 0.25)
            .onAppear { withAnimation(.easeInOut(duration: 0.55).repeatForever()) { on = true } }
    }
}

struct ShimmerText: View {
    let text: String
    var body: some View {
        TimelineView(.animation) { ctx in
            let phase = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
            Text(text)
                .font(.app(14, weight: .medium))
                .foregroundStyle(.secondary)
                .overlay {
                    LinearGradient(stops: [.init(color: .clear, location: phase - 0.25),
                                           .init(color: .primary, location: phase),
                                           .init(color: .clear, location: phase + 0.25)],
                                   startPoint: .leading, endPoint: .trailing)
                        .mask(Text(text).font(.app(14, weight: .medium)))
                }
        }
    }
}

/// Output of a slash command (or an error), shown as a quiet card in the transcript.
struct CommandOutputCard: View {
    let text: String
    let isError: Bool
    @State private var expanded = false

    var body: some View {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let long = lines.count > 14
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if isError {
                    Label(text, systemImage: "exclamationmark.triangle.fill")
                        .font(.app(12.5))
                        .foregroundStyle(.red)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(long && !expanded ? lines.prefix(14).joined(separator: "\n") : text)
                            .font(.app(11.5, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize()
                    }
                }
            }
            if long && !isError {
                Button(expanded ? "Show less" : "Show all \(lines.count) lines") {
                    withAnimation(.snappy) { expanded.toggle() }
                }
                .buttonStyle(.plain)
                .font(.app(11, weight: .medium))
                .foregroundStyle(.tint)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((isError ? Color.red : Color.primary).opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.primary.opacity(0.06)))
    }
}

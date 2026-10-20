import SwiftUI

struct MessageList: View {
    @Environment(ChatStore.self) private var store

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(store.messages) { msg in
                    MessageRow(message: msg)
                        .id(msg.id)
                        .transition(.asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.98, anchor: .bottom)),
                            removal: .opacity))
                }
                if !store.status.isEmpty {
                    Label(store.status, systemImage: "sparkle")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .symbolEffect(.pulse)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .scrollIndicators(.automatic)
        .mask(
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.04),
                                   .init(color: .black, location: 0.96), .init(color: .clear, location: 1)],
                           startPoint: .top, endPoint: .bottom))
    }
}

struct MessageRow: View {
    let message: ChatMessage

    var body: some View {
        switch message.role {
        case .user: userBubble
        case .assistant: assistant
        case .notice, .error:
            CommandOutputCard(text: message.text, isError: message.role == .error)
        }
    }

    private var userBubble: some View {
        HStack {
            Spacer(minLength: 80)
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
                                .font(.system(size: 11))
                                .lineLimit(1)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(.white.opacity(0.18), in: Capsule())
                        }
                    }
                }
                if !message.text.isEmpty {
                    Text(message.text)
                        .font(.system(size: 14))
                        .textSelection(.enabled)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.82)],
                               startPoint: .top, endPoint: .bottom),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
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
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.text, forType: .string)
            }
        }
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
                .font(.system(size: 11, weight: .medium))
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
            .font(.system(size: 11, weight: .semibold))
            .frame(width: 14)
            Text(tool.prettyName)
                .font(.system(size: 12, weight: .medium))
            Text(tool.done && !tool.summary.isEmpty ? tool.summary : tool.preview)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let d = tool.duration {
                Text(String(format: "%.1fs", d))
                    .font(.system(size: 10, design: .monospaced))
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
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .overlay {
                    LinearGradient(stops: [.init(color: .clear, location: phase - 0.25),
                                           .init(color: .primary, location: phase),
                                           .init(color: .clear, location: phase + 0.25)],
                                   startPoint: .leading, endPoint: .trailing)
                        .mask(Text(text).font(.system(size: 14, weight: .medium)))
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
                        .font(.system(size: 12.5))
                        .foregroundStyle(.red)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(long && !expanded ? lines.prefix(14).joined(separator: "\n") : text)
                            .font(.system(size: 11.5, design: .monospaced))
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
                .font(.system(size: 11, weight: .medium))
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

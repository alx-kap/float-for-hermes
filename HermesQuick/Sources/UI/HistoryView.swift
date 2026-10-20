import SwiftUI

/// Past chats with the current bot, shown in place of the conversation.
struct HistoryView: View {
    @Environment(ChatStore.self) private var store
    @FocusState private var searchFocused: Bool
    @State private var confirmingDelete: String?

    var body: some View {
        @Bindable var store = store
        let results = store.historyResults

        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Search chats", text: $store.historyQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($searchFocused)
                if store.isLoadingSessions && !store.sessions.isEmpty {
                    ProgressView().controlSize(.mini)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 14)
            .padding(.bottom, 8)

            Group {
                if store.sessions.isEmpty && store.isLoadingSessions {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if store.sessions.isEmpty {
                    ContentUnavailableView("No Past Chats", systemImage: "bubble.left.and.bubble.right",
                                           description: Text("Chats with \(store.activeBot?.displayName ?? "this bot") will appear here."))
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: store.historyQuery)
                } else {
                    list(results)
                }
            }
            .frame(maxHeight: .infinity)

            HStack(spacing: 12) {
                KeyHint(key: "↑↓", label: "navigate")
                KeyHint(key: "↩", label: "open")
                KeyHint(key: "esc", label: "back")
                Spacer()
                Text(countLabel(results.count))
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
        }
        .padding(.top, 2)
        .onAppear { searchFocused = true }
        .onChange(of: store.historyQuery) { store.historySelection = 0 }
        .animation(.easeOut(duration: 0.15), value: store.isLoadingSessions)
    }

    private func list(_ results: [SessionSummary]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { i, s in
                        HistoryRow(session: s,
                                   selected: i == store.historySelection,
                                   isCurrent: s.id == store.currentStoredId,
                                   confirmingDelete: confirmingDelete == s.id,
                                   onDelete: { withAnimation(.snappy) { confirmingDelete = s.id } },
                                   onCancelDelete: { withAnimation(.snappy) { confirmingDelete = nil } })
                            .id(s.id)
                            .onHover { if $0 { store.historySelection = i } }
                            .onTapGesture { if confirmingDelete != s.id { store.openSession(s) } }
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityLabel(s.displayTitle)
                            .accessibilityValue(s.id == store.currentStoredId ? "Open" : s.dateLabel)
                            .accessibilityAction { store.openSession(s) }
                            .accessibilityAction(named: "Archive") { store.archiveSession(s) }
                            .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            }
            .scrollIndicators(.automatic)
            .onChange(of: store.historyScrollRequest) {
                if let id = results[safe: store.historySelection]?.id { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id) } }
            }
            .onAppear {
                if let id = results[safe: store.historySelection]?.id { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .mask(
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.03),
                                   .init(color: .black, location: 0.97), .init(color: .clear, location: 1)],
                           startPoint: .top, endPoint: .bottom))
    }

    private func countLabel(_ n: Int) -> String {
        "\(n) chat\(n == 1 ? "" : "s")"
    }
}

struct HistoryRow: View {
    @Environment(ChatStore.self) private var store
    let session: SessionSummary
    let selected: Bool
    let isCurrent: Bool
    let confirmingDelete: Bool
    let onDelete: () -> Void
    let onCancelDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isCurrent ? "bubble.left.fill" : "bubble.left")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(selected ? Color.white : isCurrent ? Color.accentColor : Color.secondary)
                .frame(width: 24, height: 24)
                .background(selected ? Color.accentColor : Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))

            if confirmingDelete {
                Text("Delete “\(session.displayTitle)”?")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button("Cancel", action: onCancelDelete)
                    .buttonStyle(.glass)
                    .controlSize(.small)
                Button("Delete", role: .destructive) { store.deleteSession(session) }
                    .buttonStyle(.glassProminent)
                    .tint(.red)
                    .controlSize(.small)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(session.displayTitle)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        if let source = session.sourceLabel {
                            Text(source)
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(.primary.opacity(0.08), in: Capsule())
                        }
                    }
                    if let detail {
                        Text(detail)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if selected {
                    actionsMenu
                        .transition(.opacity)
                }
                Text(isCurrent ? "Open" : session.dateLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(isCurrent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 8)
        .frame(height: detail == nil || confirmingDelete ? 40 : 50)
        .background(selected ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .contextMenu { menuItems }
        .animation(.easeOut(duration: 0.12), value: selected)
    }

    /// The first line of the chat, when the title doesn't already say it.
    private var detail: String? {
        let line = session.preview.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.isEmpty || line == session.displayTitle ? nil : line
    }

    private var actionsMenu: some View {
        Menu { menuItems } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 22, height: 22)
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .fixedSize()
        .help("More")
    }

    @ViewBuilder
    private var menuItems: some View {
        Button { store.openSession(session) } label: { Label("Open", systemImage: "arrow.up.right") }
        Divider()
        Button { store.archiveSession(session) } label: { Label("Archive", systemImage: "archivebox") }
        Button(role: .destructive, action: onDelete) { Label("Delete…", systemImage: "trash") }
    }
}

struct KeyHint: View {
    let key: String
    let label: String
    var body: some View {
        HStack(spacing: 3) {
            Text(key).font(.system(size: 10, weight: .semibold, design: .rounded))
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            Text(label)
        }
    }
}

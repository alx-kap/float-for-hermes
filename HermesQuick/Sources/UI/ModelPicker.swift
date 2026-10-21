import SwiftUI

/// The header's model popover, laid out like Claude's: your models first (1–9 pick them), then how
/// hard the model thinks and fast mode, then the rest of the catalog one click down.
struct ModelPicker: View {
    @Environment(ChatStore.self) private var store
    let chooseModels: () -> Void
    let dismiss: () -> Void

    @State private var showingMore = false
    @FocusState private var focused: Bool

    private var primary: [ModelChoice] { store.models.filter(store.isPrimary) }
    private var more: [ModelChoice] { store.models.filter { !store.isPrimary($0) } }
    private var providers: [String] { store.models.map(\.providerName).uniqued() }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.bots.count > 1 {
                botRow
                divider
            }
            if store.models.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading models…").foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
            }
            modelList(primary, numbered: true)
            divider
            ThinkingRow()
            FastModeRow()
            if !more.isEmpty {
                divider
                PickerRow(action: { withAnimation(.snappy) { showingMore.toggle() } }) {
                    Text("More models")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(showingMore ? 90 : 0))
                }
                if showingMore {
                    // A scroll view in a popover collapses without a set height, so size it to the list.
                    ScrollView {
                        modelList(more, numbered: false)
                    }
                    .frame(height: min(listHeight(more), 260))
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            divider
            PickerRow(action: { dismiss(); chooseModels() }) {
                Text("Choose models…").foregroundStyle(.secondary)
                Spacer()
            }
        }
        .font(.system(size: 13))
        // Explicit, so the labels stay full strength when the popover's window isn't the active one
        // (the default style dims there); the secondary text below still sits back.
        .foregroundStyle(Color.primary)
        .padding(6)
        .frame(width: 300)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(characters: .decimalDigits) { press in
            guard let n = Int(press.characters), n >= 1, n <= min(primary.count, 9) else { return .ignored }
            pick(primary[n - 1])
            return .handled
        }
    }

    static let rowHeight: CGFloat = 28
    private static let headingHeight: CGFloat = 22

    private func listHeight(_ choices: [ModelChoice]) -> CGFloat {
        let headings = providers.count > 1 ? Set(choices.map(\.providerName)).count : 0
        return CGFloat(choices.count) * Self.rowHeight + CGFloat(headings) * Self.headingHeight
    }

    private var divider: some View {
        Divider().padding(.horizontal, 8).padding(.vertical, 4)
    }

    /// Grouped under small provider headings once you have more than one provider.
    @ViewBuilder private func modelList(_ choices: [ModelChoice], numbered: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(providers, id: \.self) { provider in
                let group = choices.filter { $0.providerName == provider }
                if !group.isEmpty {
                    if providers.count > 1 {
                        Text(provider)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.top, 6).padding(.bottom, 2)
                            .frame(height: Self.headingHeight, alignment: .bottomLeading)
                    }
                    ForEach(group) { choice in
                        let index = numbered ? primary.firstIndex(of: choice) : nil
                        modelRow(choice, shortcut: index.flatMap { $0 < 9 ? $0 + 1 : nil })
                    }
                }
            }
        }
    }

    private func modelRow(_ choice: ModelChoice, shortcut: Int?) -> some View {
        let current = choice.model == store.currentModel && choice.provider == store.currentProvider
        return PickerRow(action: { pick(choice) }) {
            Text(choice.displayName)
                .lineLimit(1)
                .help(choice.model)
            Spacer(minLength: 8)
            if current {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            } else if let shortcut {
                Text("\(shortcut)")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
    }

    private var botRow: some View {
        HStack(spacing: 8) {
            BotAvatar(name: store.botName, size: 20)
            Text(store.botName).lineLimit(1)
            Spacer()
            Menu("Switch") {
                ForEach(store.bots) { bot in
                    Button {
                        store.switchBot(bot)
                    } label: {
                        if bot.name == Preferences.shared.profile { Label(bot.displayName, systemImage: "checkmark") }
                        else { Text(bot.displayName) }
                    }
                }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .fixedSize()
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private func pick(_ choice: ModelChoice) {
        store.selectModel(choice)
        dismiss()
    }
}

/// How hard the model thinks, as one row of levels: the current one is filled in, so it's plain
/// what's on and a single click changes it.
private struct ThinkingRow: View {
    @Environment(ChatStore.self) private var store

    var body: some View {
        let caps = store.currentCapabilities
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "brain").foregroundStyle(.secondary).frame(width: 16)
                Text("Thinking")
                Spacer()
                if caps.reasoning {
                    Text(store.thinking == .none ? "Off" : store.thinking.title)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
            }
            if caps.reasoning {
                HStack(spacing: 2) {
                    ForEach(ThinkingLevel.allCases) { level in
                        LevelSegment(level: level, selected: level == store.thinking) {
                            store.setThinking(level)
                        }
                    }
                }
                .padding(2)
                .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                if let sent = store.thinkingSent {
                    Text("This model tops out at \(sent.title), so that's what it uses.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("This model doesn't think before answering.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .animation(.snappy, value: store.thinking)
    }
}

private struct LevelSegment: View {
    let level: ThinkingLevel
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(level.shortTitle)
                .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .frame(maxWidth: .infinity)
                .frame(height: 22)
                .background {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(selected ? Color.accentColor : Color.primary.opacity(hovering ? 0.08 : 0))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(level == .none ? "Answer without thinking first" : "Think at \(level.title) effort")
    }
}

private struct FastModeRow: View {
    @Environment(ChatStore.self) private var store

    var body: some View {
        let available = store.currentCapabilities.fast || store.fastMode
        HStack(spacing: 6) {
            Image(systemName: "bolt.fill")
                .foregroundStyle(store.fastMode ? Color.orange : Color.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text("Fast mode")
                if !available {
                    Text("Not available for this model")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Toggle("Fast mode", isOn: Binding(get: { store.fastMode }, set: { store.setFastMode($0) }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .disabled(!available)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .opacity(available ? 1 : 0.6)
    }
}

/// A full-width row that highlights on hover, like a menu item.
private struct PickerRow<Content: View>: View {
    let action: () -> Void
    @ViewBuilder var content: Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) { content }
                .padding(.horizontal, 10)
                .frame(height: ModelPicker.rowHeight)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.primary.opacity(hovering ? 0.08 : 0))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

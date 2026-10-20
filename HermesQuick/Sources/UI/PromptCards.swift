import SwiftUI

/// The card for whatever Hermes is waiting on, shown above the composer.
struct PromptCard: View {
    let prompt: GatewayPrompt

    var body: some View {
        switch prompt.kind {
        case let .approval(command, description, choices):
            ApprovalCard(command: command, description: description, choices: choices)
        case .clarify(let questions):
            ClarifyCard(questions: questions)
        case .secret(let secret):
            SecretCard(prompt: secret)
                .id(prompt.id)  // a fresh field (and focus) for each prompt
        }
    }
}

// MARK: - Approval

struct ApprovalCard: View {
    @Environment(ChatStore.self) private var store
    let command: String
    let description: String
    let choices: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(description, systemImage: "hand.raised.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.orange)
            if !command.isEmpty {
                Text(command)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
            }
            HStack {
                ForEach(Array(choices.enumerated()), id: \.element) { i, choice in
                    Group {
                        if choice == "deny" {
                            Button(Self.label(choice)) { store.respondToApproval(choice) }
                                .buttonStyle(.glass)
                        } else {
                            Button(Self.label(choice)) { store.respondToApproval(choice) }
                                .buttonStyle(.glassProminent)
                                .tint(.orange)
                        }
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                    .help("⌘\(i + 1)")
                }
            }
        }
        .padding(12)
        .glassEffect(.regular.tint(.orange.opacity(0.12)), in: RoundedRectangle(cornerRadius: 16))
    }

    static func label(_ c: String) -> String {
        switch c {
        case "once": "Allow Once"
        case "session": "Allow for Session"
        case "always": "Always Allow"
        case "deny": "Deny"
        default: c.capitalized
        }
    }
}

// MARK: - Clarify

/// One question at a time. Pick a choice (⌘1–⌘4), or type your own answer in the composer.
struct ClarifyCard: View {
    @Environment(ChatStore.self) private var store
    let questions: [ClarifyQuestion]

    private var current: ClarifyQuestion? { questions.first { !$0.locked } }
    private var position: Int { questions.firstIndex { !$0.locked }.map { $0 + 1 } ?? questions.count }

    var body: some View {
        if let q = current {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Label("Hermes is asking", systemImage: "questionmark.bubble.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tint)
                    if questions.count > 1 {
                        Text("\(position) of \(questions.count)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    }
                    Spacer()
                    Button { store.cancelClarify() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .frame(width: 20, height: 20)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(questions.count > 1 ? "Dismiss these questions" : "Dismiss this question")
                }

                // The whole question swaps as one piece: the old one fades out before the next fades in,
                // stacked in place so the two never sit one above the other.
                ZStack(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(q.question)
                            .font(.system(size: 14, weight: .medium))
                            .lineLimit(8)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)

                        if !q.choices.isEmpty {
                            VStack(spacing: 2) {
                                ForEach(Array(q.choices.enumerated()), id: \.offset) { i, choice in
                                    ChoiceRow(index: i, label: choice, recommended: q.recommended == i,
                                              multi: q.multiSelect, selected: store.clarifySelection.contains(choice)) {
                                        if q.multiSelect { store.toggleClarifyChoice(choice) } else { store.answerClarify(choice) }
                                    }
                                }
                            }
                        }

                        HStack(spacing: 8) {
                            Text(hint(q))
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                            Spacer()
                            Button("Skip") { store.answerClarify(nil) }
                                .buttonStyle(.glass)
                                .controlSize(.small)
                            if q.multiSelect {
                                Button("Continue") { store.answerClarify(store.multiAnswer()) }
                                    .buttonStyle(.glassProminent)
                                    .tint(.accentColor)
                                    .controlSize(.small)
                                    .disabled(store.clarifySelection.isEmpty)
                            }
                        }
                    }
                    .id(q.id)
                    .transition(.handoff)
                }
            }
            .padding(12)
            .glassEffect(.regular.tint(Color.accentColor.opacity(0.1)), in: RoundedRectangle(cornerRadius: 16))
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: q.id)
        }
    }

    private func hint(_ q: ClarifyQuestion) -> String {
        if q.choices.isEmpty { return "Type your answer below and press ↩" }
        return q.multiSelect ? "Pick any, or type your own below" : "Pick one, or type your own below"
    }
}

private struct ChoiceRow: View {
    let index: Int
    let label: String
    let recommended: Bool
    let multi: Bool
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if multi {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 15))
                        .foregroundStyle(selected ? Color.accentColor : .secondary)
                        .contentTransition(.symbolEffect(.replace))
                }
                Text(label)
                    .font(.system(size: 13))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if recommended {
                    Text("Recommended")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tint)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.14), in: Capsule())
                }
                Spacer(minLength: 8)
                Text("⌘\(index + 1)")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)  // at most 4 choices
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
    }

    private var background: Color {
        if selected { return Color.accentColor.opacity(0.16) }
        return .primary.opacity(hovering ? 0.08 : 0.04)
    }
}

// MARK: - Passwords, secrets and codes

struct SecretCard: View {
    @Environment(ChatStore.self) private var store
    @Environment(PanelPresentation.self) private var presentation
    let prompt: SecretPrompt
    @State private var value = ""
    @State private var identifier = ""
    @FocusState private var field: Field?

    private enum Field { case identifier, value }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: prompt.symbol)
                    .font(.system(size: 18))
                    .foregroundStyle(.tint)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(prompt.title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(prompt.message)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !prompt.detail.isEmpty {
                Text(prompt.detail)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(4)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
            }
            if prompt.style == .login {
                TextField("Email or username", text: $identifier)
                    .textContentType(.username)
                    .focused($field, equals: .identifier)
                    .onSubmit { field = .value }
                    .modifier(PromptFieldStyle())
            }
            HStack(spacing: 8) {
                Group {
                    if prompt.style == .code {
                        TextField(prompt.placeholder, text: $value)
                            .textContentType(.oneTimeCode)
                            .font(.system(size: 14, design: .monospaced))
                    } else {
                        SecureField(prompt.placeholder, text: $value)
                            .textContentType(.password)
                    }
                }
                .focused($field, equals: .value)
                .onSubmit(submit)
                .modifier(PromptFieldStyle())

                Button("Skip") { finish("") }
                    .buttonStyle(.glass)
                Button(prompt.submit, action: submit)
                    .buttonStyle(.glassProminent)
                    .disabled(!canSubmit)
            }
        }
        .padding(12)
        .glassEffect(.regular.tint(Color.accentColor.opacity(0.1)), in: RoundedRectangle(cornerRadius: 16))
        .onAppear {
            // Let the card land before taking focus from the composer.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                field = prompt.style == .login ? .identifier : .value
            }
        }
    }

    private var canSubmit: Bool {
        !value.isEmpty && (prompt.style != .login || !identifier.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    private func submit() {
        guard canSubmit else { return }
        finish(value)
    }

    private func finish(_ answer: String) {
        store.answerSecret(answer, identifier: identifier.trimmingCharacters(in: .whitespaces))
        value = ""
        presentation.focusToken += 1
    }
}

private struct PromptFieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .glassEffect(.regular, in: Capsule())
    }
}

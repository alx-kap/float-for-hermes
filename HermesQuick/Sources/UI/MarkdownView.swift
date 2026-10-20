import SwiftUI

/// Lightweight markdown: fenced code blocks, headings, bullets, quotes, and inline styling.
/// Parsing is cheap enough to redo on every streamed delta.
struct MarkdownView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.blocks(markdown).enumerated()), id: \.offset) { _, block in
                switch block {
                case .code(let lang, let code): CodeBlock(language: lang, code: code)
                case .text(let t): textBlock(t)
                }
            }
        }
        .textSelection(.enabled)
    }

    private func textBlock(_ t: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(Self.paragraphs(t).enumerated()), id: \.offset) { _, line in
                lineView(line)
            }
        }
    }

    @ViewBuilder
    private func lineView(_ line: String) -> some View {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if let level = Self.headingLevel(trimmed) {
            Text(Self.inline(String(trimmed.drop(while: { $0 == "#" }).drop(while: { $0 == " " }))))
                .font(.system(size: level == 1 ? 18 : level == 2 ? 16 : 14.5, weight: .semibold))
                .padding(.top, 4)
        } else if let item = Self.bullet(trimmed) {
            let indent = CGFloat(line.prefix(while: { $0 == " " }).count / 2) * 14
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(item.marker).foregroundStyle(.secondary).font(.system(size: 14))
                Text(Self.inline(item.text)).font(.system(size: 14))
            }
            .padding(.leading, indent)
        } else if trimmed.hasPrefix(">") {
            HStack(spacing: 8) {
                Capsule().fill(.secondary.opacity(0.5)).frame(width: 3)
                Text(Self.inline(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)))
                    .font(.system(size: 14)).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        } else if trimmed == "---" || trimmed == "***" {
            Divider().padding(.vertical, 2)
        } else {
            Text(Self.inline(line)).font(.system(size: 14)).lineSpacing(2)
        }
    }

    // MARK: Parsing

    enum Block { case text(String), code(String, String) }

    static func blocks(_ md: String) -> [Block] {
        var out: [Block] = []
        var buf: [Substring] = []
        var inCode = false
        var lang = ""
        for line in md.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inCode {
                    out.append(.code(lang, buf.joined(separator: "\n")))
                    buf.removeAll()
                    inCode = false
                } else {
                    if !buf.isEmpty { out.append(.text(buf.joined(separator: "\n"))) }
                    buf.removeAll()
                    lang = line.trimmingCharacters(in: .whitespaces).dropFirst(3).trimmingCharacters(in: .whitespaces)
                    inCode = true
                }
            } else {
                buf.append(line)
            }
        }
        if !buf.isEmpty { out.append(inCode ? .code(lang, buf.joined(separator: "\n")) : .text(buf.joined(separator: "\n"))) }
        return out
    }

    /// Split into display lines, merging soft-wrapped prose lines and dropping blank runs.
    static func paragraphs(_ t: String) -> [String] {
        var out: [String] = []
        for raw in t.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let s = raw.trimmingCharacters(in: .whitespaces)
            if s.isEmpty { if out.last != "" { out.append("") }; continue }
            out.append(raw)
        }
        while out.first == "" { out.removeFirst() }
        while out.last == "" { out.removeLast() }
        return out.filter { !$0.isEmpty }
    }

    static func headingLevel(_ s: String) -> Int? {
        let hashes = s.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes), s.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    static func bullet(_ s: String) -> (marker: String, text: String)? {
        for m in ["- ", "* ", "+ "] where s.hasPrefix(m) {
            var rest = String(s.dropFirst(2))
            if rest.hasPrefix("[ ] ") { rest = "☐ " + rest.dropFirst(4) }
            if rest.hasPrefix("[x] ") { rest = "☑︎ " + rest.dropFirst(4) }
            return ("•", rest)
        }
        if let dot = s.firstIndex(of: "."), s[..<dot].allSatisfy(\.isNumber), !s[..<dot].isEmpty,
           s[s.index(after: dot)...].hasPrefix(" ") {
            return (String(s[...dot]), String(s[s.index(dot, offsetBy: 2)...]))
        }
        return nil
    }

    static func inline(_ s: String) -> AttributedString {
        var a = (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
        for run in a.runs where run.inlinePresentationIntent?.contains(.code) == true {
            a[run.range].font = .system(size: 13, design: .monospaced)
            a[run.range].backgroundColor = Color.primary.opacity(0.08)
        }
        return a
    }
}

struct CodeBlock: View {
    let language: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language)
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    withAnimation(.snappy) { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { withAnimation { copied = false } }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10.5, weight: .medium))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12.5, design: .monospaced))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                    .fixedSize()
            }
        }
        .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.06)))
    }
}

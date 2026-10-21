import SwiftUI

/// Lightweight markdown: fenced code blocks (highlighted), tables, block quotes and callouts,
/// headings, lists and inline styling.
/// Parsing is cheap enough to redo on every streamed delta.
struct MarkdownView: View {
    let markdown: String

    var body: some View {
        let elements = Self.elements(markdown)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(elements.enumerated()), id: \.offset) { i, element in
                elementView(element)
                    .padding(.top, Self.spacing(after: i > 0 ? elements[i - 1] : nil, before: element) * scale)
            }
        }
        .textSelection(.enabled)
    }

    private var scale: CGFloat { Preferences.shared.textScale }

    @ViewBuilder
    private func elementView(_ element: Element) -> some View {
        switch element {
        case .heading(let level, let text):
            Text(Self.inline(text))
                .font(.app(Self.headingSize(level), weight: level <= 2 ? .bold : .semibold))
                .lineSpacing(2 * scale)
                .fixedSize(horizontal: false, vertical: true)
        case .paragraph(let text):
            Text(Self.inline(text))
                .font(.app(14))
                .lineSpacing(4.5 * scale)
                .fixedSize(horizontal: false, vertical: true)
        case .list(let items):
            ListBlock(items: items)
        case .rule:
            Divider()
        case .block(.code(let lang, let code)):
            CodeBlock(language: lang, code: code)
        case .block(.table(let table)):
            TableBlock(table: table)
        case .block(.quote(let callout, let body)):
            QuoteBlock(callout: callout, markdown: body)
        case .block(.text(let t)):
            Text(Self.inline(t)).font(.app(14))
        }
    }

    static func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: 19
        case 2: 17
        case 3: 15.5
        default: 14
        }
    }

    /// Space above `cur`, by what it follows: headings get room above and sit close to their content,
    /// rules breathe on both sides, everything else is a paragraph break.
    static func spacing(after prev: Element?, before cur: Element) -> CGFloat {
        guard let prev else { return 0 }
        switch (prev, cur) {
        case (.heading, .heading): return 8
        case (_, .heading(let level, _)): return level <= 2 ? 22 : 18
        case (.heading, _): return 8
        case (.rule, _), (_, .rule): return 16
        default: return 12
        }
    }

    // MARK: Parsing

    enum Block {
        case text(String), code(String, String), table(Table), quote(Callout?, String)
    }

    enum Element {
        case heading(Int, String), paragraph(String), list([ListItem]), rule, block(Block)
    }

    struct ListItem {
        var depth: Int
        var marker: String
        var text: String
        var ordered: Bool { marker.last == "." }
    }

    struct Table {
        var header: [String]
        var alignments: [HorizontalAlignment]
        var rows: [[String]]
    }

    enum Callout: String {
        case note, tip, important, warning, caution
        var title: String { rawValue.capitalized }
        var symbol: String {
            switch self {
            case .note: "info.circle.fill"
            case .tip: "lightbulb.fill"
            case .important: "exclamationmark.bubble.fill"
            case .warning: "exclamationmark.triangle.fill"
            case .caution: "octagon.fill"
            }
        }
        var color: Color {
            switch self {
            case .note: .blue
            case .tip: .green
            case .important: .purple
            case .warning: .orange
            case .caution: .red
            }
        }
    }

    static func blocks(_ md: String) -> [Block] {
        fencedBlocks(md).flatMap { block -> [Block] in
            if case .text(let t) = block { return structured(t) }
            return [block]
        }
    }

    /// Pulls tables and runs of `>` lines out of a text block; everything else stays text.
    static func structured(_ t: String) -> [Block] {
        let lines = t.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var out: [Block] = []
        var buf: [String] = []
        func flush() {
            if !buf.isEmpty { out.append(.text(buf.joined(separator: "\n"))) }
            buf.removeAll()
        }
        var i = 0
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix(">") {
                flush()
                var inner: [String] = []
                while i < lines.count, case let l = lines[i].trimmingCharacters(in: .whitespaces), l.hasPrefix(">") {
                    var rest = l.dropFirst()
                    if rest.first == " " { rest = rest.dropFirst() }
                    inner.append(String(rest))
                    i += 1
                }
                var callout: Callout?
                if let first = inner.first?.trimmingCharacters(in: .whitespaces),
                   let m = first.range(of: "^\\[!(note|tip|important|warning|caution)\\]", options: [.regularExpression, .caseInsensitive]) {
                    callout = Callout(rawValue: first[m].dropFirst(2).dropLast().lowercased())
                    let rest = first[m.upperBound...].trimmingCharacters(in: .whitespaces)
                    if rest.isEmpty { inner.removeFirst() } else { inner[0] = rest }
                }
                out.append(.quote(callout, inner.joined(separator: "\n")))
                continue
            }
            if line.contains("|"), i + 1 < lines.count, let alignments = delimiterRow(lines[i + 1]) {
                let header = cells(line)
                if header.count == alignments.count || (header.count > 1 && alignments.count > 1) {
                    flush()
                    var rows: [[String]] = []
                    i += 2
                    while i < lines.count, case let l = lines[i].trimmingCharacters(in: .whitespaces), !l.isEmpty, l.contains("|") {
                        rows.append(cells(l))
                        i += 1
                    }
                    let n = header.count
                    out.append(.table(Table(header: header,
                                            alignments: (0..<n).map { $0 < alignments.count ? alignments[$0] : .leading },
                                            rows: rows.map { r in (0..<n).map { $0 < r.count ? r[$0] : "" } })))
                    continue
                }
            }
            buf.append(lines[i])
            i += 1
        }
        flush()
        return out
    }

    /// `| :--- | :---: | ---: |` → the column alignments, or nil if the line isn't a table delimiter.
    static func delimiterRow(_ line: String) -> [HorizontalAlignment]? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-"), t.range(of: "^\\|?\\s*:?-+:?\\s*(\\|\\s*:?-+:?\\s*)*\\|?$", options: .regularExpression) != nil else { return nil }
        return cells(t).map { c in
            switch (c.hasPrefix(":"), c.hasSuffix(":")) {
            case (true, true): .center
            case (false, true): .trailing
            default: .leading
            }
        }
    }

    /// Splits a table row on `|`, leaving `\|` and pipes inside `code` alone.
    static func cells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") && !t.hasSuffix("\\|") { t.removeLast() }
        var out: [String] = []
        var cur = ""
        var inCode = false
        var escaped = false
        for ch in t {
            if escaped { cur.append(ch); escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            if ch == "`" { inCode.toggle() }
            if ch == "|" && !inCode { out.append(cur.trimmingCharacters(in: .whitespaces)); cur = ""; continue }
            cur.append(ch)
        }
        out.append(cur.trimmingCharacters(in: .whitespaces))
        return out
    }

    static func fencedBlocks(_ md: String) -> [Block] {
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

    /// Groups a text block's lines into headings, paragraphs, lists and rules.
    /// Lines within a paragraph keep their breaks; a blank line ends it. Indented lines (or ones
    /// directly under an item) continue the list item above them.
    static func elements(_ md: String) -> [Element] {
        var out: [Element] = []
        for block in blocks(md) {
            guard case .text(let t) = block else { out.append(.block(block)); continue }
            var para: [String] = []
            var items: [ListItem] = []
            var levels: [Int] = []
            var afterBlank = false
            func flushPara() {
                if !para.isEmpty { out.append(.paragraph(para.joined(separator: "\n"))) }
                para.removeAll()
            }
            func flushList() {
                if !items.isEmpty { out.append(.list(items)) }
                items.removeAll()
                levels.removeAll()
            }
            for raw in t.split(separator: "\n", omittingEmptySubsequences: false) {
                let s = raw.trimmingCharacters(in: .whitespaces)
                let indent = raw.prefix(while: { $0 == " " || $0 == "\t" }).reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
                defer { afterBlank = s.isEmpty }
                if s.isEmpty { flushPara(); continue }
                if let level = headingLevel(s) {
                    flushPara(); flushList()
                    out.append(.heading(level, String(s.dropFirst(level)).trimmingCharacters(in: .whitespaces)))
                } else if isRule(s) {
                    flushPara(); flushList()
                    out.append(.rule)
                } else if let b = bullet(s) {
                    flushPara()
                    while let last = levels.last, indent < last { levels.removeLast() }
                    if levels.last.map({ indent > $0 }) ?? true { levels.append(indent) }
                    items.append(ListItem(depth: levels.count - 1, marker: b.marker, text: b.text))
                } else if !items.isEmpty, indent > 0 || !afterBlank {
                    items[items.count - 1].text += "\n" + s
                } else {
                    flushList()
                    para.append(s)
                }
            }
            flushPara(); flushList()
        }
        return out
    }

    static func isRule(_ s: String) -> Bool {
        let compact = s.filter { $0 != " " }
        return compact.count >= 3 && ["-", "*", "_"].contains { c in compact.allSatisfy { String($0) == c } }
    }

    static func headingLevel(_ s: String) -> Int? {
        let hashes = s.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes), s.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    static func bullet(_ s: String) -> (marker: String, text: String)? {
        for m in ["- ", "* ", "+ "] where s.hasPrefix(m) {
            let rest = String(s.dropFirst(2))
            if rest.hasPrefix("[ ] ") { return ("☐", String(rest.dropFirst(4))) }
            if rest.lowercased().hasPrefix("[x] ") { return ("☑︎", String(rest.dropFirst(4))) }
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
            a[run.range].font = .app(13, design: .monospaced)
            a[run.range].backgroundColor = Color.primary.opacity(0.08)
        }
        return a
    }
}

/// Items with hanging indents: wrapped lines align under the text, not the marker,
/// and numbers right-align so 9. and 10. line up.
struct ListBlock: View {
    let items: [MarkdownView.ListItem]

    private var scale: CGFloat { Preferences.shared.textScale }

    var body: some View {
        let numberWidth = CGFloat(items.filter(\.ordered).map(\.marker.count).max() ?? 0) * 8.5
        VStack(alignment: .leading, spacing: 7 * scale) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 7 * scale) {
                    Text(marker(item))
                        .font(.app(14, weight: item.ordered ? .medium : .bold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: max(item.ordered ? numberWidth : 0, 12) * scale, alignment: .trailing)
                    Text(MarkdownView.inline(item.text))
                        .font(.app(14))
                        .lineSpacing(4.5 * scale)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, CGFloat(item.depth) * 19 * scale)
            }
        }
    }

    private func marker(_ item: MarkdownView.ListItem) -> String {
        guard item.marker == "•" else { return item.marker }
        return ["•", "◦", "▪︎"][min(item.depth, 2)]
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
                    .font(.app(10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    withAnimation(.snappy) { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { withAnimation { copied = false } }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.app(10.5, weight: .medium))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(SyntaxHighlighter.highlight(code, language: language))
                    .font(.app(12.5, design: .monospaced))
                    .lineSpacing(3)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                    .fixedSize()
            }
        }
        .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.06)))
    }
}

struct TableBlock: View {
    let table: MarkdownView.Table

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(table.header.enumerated()), id: \.offset) { i, cell in
                        self.cell(cell, column: i).fontWeight(.semibold)
                    }
                }
                .background(.primary.opacity(0.06))
                ForEach(Array(table.rows.enumerated()), id: \.offset) { r, row in
                    Divider().gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { i, cell in self.cell(cell, column: i) }
                    }
                    .background(r % 2 == 1 ? Color.primary.opacity(0.025) : .clear)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.primary.opacity(0.1)))
            .padding(.vertical, 1)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }

    private func cell(_ text: String, column: Int) -> some View {
        let alignment = table.alignments[column]
        return Text(MarkdownView.inline(text))
            .font(.app(13))
            .multilineTextAlignment(alignment == .trailing ? .trailing : alignment == .center ? .center : .leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 280, alignment: Alignment(horizontal: alignment, vertical: .center))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .gridColumnAlignment(alignment)
    }
}

struct QuoteBlock: View {
    let callout: MarkdownView.Callout?
    let markdown: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Capsule()
                .fill((callout?.color ?? .secondary).opacity(callout == nil ? 0.45 : 0.9))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 6) {
                if let callout {
                    Label(callout.title, systemImage: callout.symbol)
                        .font(.app(13, weight: .semibold))
                        .foregroundStyle(callout.color)
                }
                if !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    MarkdownView(markdown: markdown)
                        .foregroundStyle(callout == nil ? .secondary : .primary)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 2)
    }
}

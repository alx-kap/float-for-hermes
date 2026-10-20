import SwiftUI

/// Lightweight markdown: fenced code blocks (highlighted), tables, block quotes and callouts,
/// headings, lists and inline styling.
/// Parsing is cheap enough to redo on every streamed delta.
struct MarkdownView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.blocks(markdown).enumerated()), id: \.offset) { _, block in
                switch block {
                case .code(let lang, let code): CodeBlock(language: lang, code: code)
                case .text(let t): textBlock(t)
                case .table(let table): TableBlock(table: table)
                case .quote(let callout, let body): QuoteBlock(callout: callout, markdown: body)
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
        } else if trimmed == "---" || trimmed == "***" {
            Divider().padding(.vertical, 2)
        } else {
            Text(Self.inline(line)).font(.system(size: 14)).lineSpacing(2)
        }
    }

    // MARK: Parsing

    enum Block {
        case text(String), code(String, String), table(Table), quote(Callout?, String)
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
                Text(SyntaxHighlighter.highlight(code, language: language))
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
            .font(.system(size: 13))
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
            VStack(alignment: .leading, spacing: 4) {
                if let callout {
                    Label(callout.title, systemImage: callout.symbol)
                        .font(.system(size: 13, weight: .semibold))
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

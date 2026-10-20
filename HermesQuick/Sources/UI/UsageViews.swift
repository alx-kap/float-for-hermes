import SwiftUI

/// Header ring showing how full the context window is. Click for the token breakdown.
struct ContextGauge: View {
    @Environment(ChatStore.self) private var store
    let usage: UsageInfo
    @State private var showing = false
    @State private var hovering = false

    var body: some View {
        let fraction = usage.contextFraction ?? 0
        Button { showing.toggle() } label: {
            HStack(spacing: 5) {
                ZStack {
                    Circle().stroke(.primary.opacity(0.14), lineWidth: 2.5)
                    Circle()
                        .trim(from: 0, to: max(0.02, fraction))
                        .stroke(Self.tint(fraction), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 14, height: 14)
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(fraction >= 0.75 ? Self.tint(fraction) : .secondary)
            }
            .padding(.horizontal, 7)
            .frame(height: 28)
            .background(.primary.opacity(hovering || showing ? 0.08 : 0), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
        .help("Context: \(UsageInfo.compact(usage.contextUsed ?? 0)) of \(UsageInfo.compact(usage.contextMax ?? 0)) tokens")
        .animation(.snappy, value: fraction)
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            UsagePopover()
                .environment(store)
        }
    }

    /// Calm until it's getting full: accent, then orange from 75%, red from 90%.
    static func tint(_ fraction: Double) -> Color {
        fraction >= 0.9 ? .red : fraction >= 0.75 ? .orange : .accentColor
    }
}

struct UsagePopover: View {
    @Environment(ChatStore.self) private var store

    var body: some View {
        let usage = store.usage
        VStack(alignment: .leading, spacing: 14) {
            if let usage, let fraction = usage.contextFraction {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Context Window").font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Text("\(Int((fraction * 100).rounded()))% full")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(ContextGauge.tint(fraction))
                            .monospacedDigit()
                    }
                    ContextBar(fraction: fraction, slices: store.contextSlices, max: usage.contextMax ?? 0)
                    Text(verbatim: "\((usage.contextUsed ?? 0).formatted()) of \((usage.contextMax ?? 0).formatted()) tokens"
                         + (usage.contextEstimated ? " (estimated)" : ""))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    if !store.contextSlices.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(store.contextSlices) { slice in
                                HStack(spacing: 7) {
                                    Circle().fill(ContextBar.color(slice.id)).frame(width: 7, height: 7)
                                    Text(slice.label).font(.system(size: 12))
                                    Spacer(minLength: 12)
                                    Text(UsageInfo.compact(slice.tokens))
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                            }
                        }
                        .transition(.opacity)
                    }
                    if usage.compressions > 0 {
                        Label("Compacted \(usage.compressions) time\(usage.compressions == 1 ? "" : "s") to make room",
                              systemImage: "arrow.down.right.and.arrow.up.left")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let usage {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Tokens in This Chat").font(.system(size: 13, weight: .semibold))
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                        row("Input", usage.input)
                        row("Output", usage.output)
                        if usage.reasoning > 0 { row("Reasoning", usage.reasoning) }
                        if usage.total > 0 { row("Total", usage.total, bold: true) }
                    }
                    let extras = [usage.cacheHitPercent.map { "\($0)% from cache" },
                                  usage.calls > 0 ? "\(usage.calls) model call\(usage.calls == 1 ? "" : "s")" : nil]
                        .compactMap { $0 }
                    if !extras.isEmpty {
                        Text(extras.joined(separator: " · "))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 280)
        .animation(.snappy, value: store.contextSlices)
        .task { await store.refreshContextBreakdown() }
    }

    private func row(_ label: String, _ value: Int, bold: Bool = false) -> some View {
        GridRow {
            Text(label).font(.system(size: 12, weight: bold ? .semibold : .regular))
            Text(value, format: .number)
                .font(.system(size: 12, weight: bold ? .semibold : .regular))
                .monospacedDigit()
                .gridColumnAlignment(.trailing)
        }
    }
}

/// The context window as a bar: coloured segments per category when the breakdown is in, else one fill.
struct ContextBar: View {
    let fraction: Double
    let slices: [ContextSlice]
    let max: Int

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 1) {
                if slices.isEmpty || max == 0 {
                    Rectangle().fill(ContextGauge.tint(fraction)).frame(width: geo.size.width * fraction)
                } else {
                    // Category estimates can overshoot what the provider reports; scale them to the real fill.
                    let total = Double(slices.reduce(0) { $0 + $1.tokens })
                    let scale = total > 0 ? fraction / (total / Double(max)) : 1
                    ForEach(slices) { s in
                        Rectangle().fill(Self.color(s.id))
                            .frame(width: Swift.max(1, geo.size.width * Double(s.tokens) / Double(max) * Swift.min(1, scale)))
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 8)
        .background(.primary.opacity(0.1))
        .clipShape(Capsule())
    }

    static func color(_ id: String) -> Color {
        switch id {
        case "system_prompt": .gray
        case "tool_definitions": .blue
        case "rules": .teal
        case "skills": .purple
        case "mcp": .indigo
        case "subagent_definitions": .pink
        case "memory": .orange
        case "conversation": .green
        default: .secondary
        }
    }
}

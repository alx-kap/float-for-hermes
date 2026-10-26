import SwiftUI

/// Hands-free voice mode. The orb starts in the middle; tapping it (or pulling it down) docks it
/// small above the bar and brings in the chat, and tapping it again sends the chat away. It can
/// be dragged a little, against a rubbery pull, and springs back to its place; pulled far enough
/// toward the other spot, it lets go and jumps there.
struct VoiceStage: View {
    @Environment(ChatStore.self) private var store
    @State private var drag: CGSize = .zero
    @State private var dragging = false
    /// Where the pointer was, in this drag, when the orb last jumped spots; the pull counts from there.
    @State private var dragBase: CGSize = .zero
    @State private var appeared = false

    private static let orbSize: CGFloat = 128
    private static let dockedScale: CGFloat = 0.42
    /// The furthest the orb follows a drag, however far the pointer goes.
    private static let reach: CGFloat = 70
    /// How far to pull toward the other spot before the orb jumps there.
    private static let snapDistance: CGFloat = 100

    var body: some View {
        let voice = store.voice
        GeometryReader { geo in
            let docked = voice.showsChat
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2 - 26)
            let dock = CGPoint(x: geo.size.width / 2, y: geo.size.height - Self.orbSize * Self.dockedScale / 2 - 10)
            ZStack {
                if docked {
                    MessageList(bottomInset: Self.orbSize * Self.dockedScale + 26)
                        // The latest messages fade out behind the orb.
                        .mask(LinearGradient(stops: [.init(color: .black, location: 1 - 64 / geo.size.height),
                                                     .init(color: .clear, location: 1)],
                                             startPoint: .top, endPoint: .bottom))
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: -28)),
                                                removal: .opacity.combined(with: .offset(y: -14))))
                } else {
                    subtitle
                        .font(.system(size: 17))
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .padding(.horizontal, 40)
                        .frame(width: geo.size.width, height: 80, alignment: .top)
                        .position(x: center.x, y: center.y + Self.orbSize / 2 + 22 + 40)
                        .animation(.smooth(duration: 0.3), value: voice.phase)
                        .transition(.opacity)
                }
                orb(docked: docked)
                    .scaleEffect(appeared ? 1 : 0.55)
                    .opacity(appeared ? 1 : 0)
                    .position(docked ? dock : center)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.72).delay(0.1)) { appeared = true }
        }
    }

    private func orb(docked: Bool) -> some View {
        let voice = store.voice
        // Squash and stretch along the pull.
        let dx = abs(drag.width) / Self.reach, dy = abs(drag.height) / Self.reach
        return VoiceOrb(phase: voice.phase, level: voice.level, busy: store.isBusy)
            .frame(width: Self.orbSize, height: Self.orbSize)
            .scaleEffect(x: 1 + 0.12 * dx - 0.06 * dy, y: 1 + 0.12 * dy - 0.06 * dx)
            .offset(drag)
            .scaleEffect(docked ? Self.dockedScale : 1)
            .contentShape(Circle().scale(docked ? Self.dockedScale : 1))
            .onTapGesture { setDocked(!docked) }
            .gesture(
                // Measured in window space: the orb itself moves when it snaps, which would
                // otherwise jump the pull past the threshold the other way.
                DragGesture(minimumDistance: 3, coordinateSpace: .global)
                    .onChanged { g in
                        dragging = true
                        let pull = CGSize(width: g.translation.width - dragBase.width, height: g.translation.height - dragBase.height)
                        if docked ? pull.height < -Self.snapDistance : pull.height > Self.snapDistance {
                            dragBase = g.translation
                            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
                            setDocked(!docked)
                            return
                        }
                        drag = CGSize(width: Self.rubber(pull.width), height: Self.rubber(pull.height))
                    }
                    .onEnded { g in
                        dragging = false
                        // A flick toward the other spot carries it there too.
                        let flick = (g.predictedEndTranslation.height - g.translation.height) * 0.6
                        dragBase = .zero
                        withAnimation(.spring(response: 0.5, dampingFraction: 0.55)) { drag = .zero }
                        if !docked, flick > Self.snapDistance { setDocked(true) }
                        if docked, flick < -Self.snapDistance { setDocked(false) }
                    }
            )
            .pointerStyle(dragging ? .grabActive : .grabIdle)
            .help(docked ? "Hide the chat" : "Show the chat")
    }

    private func setDocked(_ on: Bool) {
        withAnimation(.spring(response: 0.55, dampingFraction: 0.75)) {
            store.voice.showsChat = on
            drag = .zero
        }
    }

    /// Follows the pointer less and less the further it goes, never past `reach`.
    private static func rubber(_ v: CGFloat) -> CGFloat {
        (v < 0 ? -1 : 1) * reach * (1 - exp(-abs(v) / (reach * 1.6)))
    }

    @ViewBuilder
    private var subtitle: some View {
        let voice = store.voice
        switch voice.phase {
        case .listening, .preparing:
            Text(voice.transcript)
                .contentTransition(.opacity)
                .animation(.easeOut(duration: 0.15), value: voice.transcript)
        case .waiting:
            // What you asked, quietly, while Hermes works on it.
            Text(store.messages.last { $0.role == .user }?.text ?? "")
                .foregroundStyle(.tertiary)
        default:
            EmptyView()
        }
    }
}

/// The composer's pill in voice mode: what's happening on the left, and the controls on the right.
struct VoiceBar: View {
    @Environment(ChatStore.self) private var store
    let rowHeight: CGFloat
    let morph: Namespace.ID

    var body: some View {
        let voice = store.voice
        HStack(spacing: 8) {
            indicator
                .frame(width: 28, height: rowHeight)
            Text(status)
                .font(.app(15, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .contentTransition(.opacity)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.easeOut(duration: 0.2), value: status)
            if voice.phase == .speaking {
                circleButton("stop.fill", size: 11, help: "Stop speaking") { voice.bargeIn() }
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
            circleButton(voice.isMuted ? "mic.slash.fill" : "mic.fill", size: 14,
                         tint: voice.isMuted ? .red : nil, help: voice.isMuted ? "Unmute" : "Mute") { voice.toggleMute() }
            circleButton("xmark", size: 13, help: "End voice mode (⇧⌘D)") { voice.stopConversation() }
                .matchedGeometryEffect(id: "voiceToggle", in: morph)
        }
        .frame(height: rowHeight)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: voice.phase)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: voice.isMuted)
    }

    @ViewBuilder
    private var indicator: some View {
        let voice = store.voice
        Group {
            if voice.phase == .listening {
                LevelBars(level: voice.level).scaleEffect(0.8)
            } else if voice.phase == .speaking {
                Image(systemName: "waveform")
                    .symbolEffect(.variableColor.iterative.dimInactiveLayers, options: .repeat(.continuous))
                    .foregroundStyle(.tint)
            } else if voice.phase == .waiting || store.isBusy {
                ProgressView().controlSize(.small)
            } else if voice.isMuted {
                Image(systemName: "mic.slash").foregroundStyle(.secondary)
            }
        }
        .font(.app(15, weight: .semibold))
        .transition(.opacity.combined(with: .scale(scale: 0.8)))
    }

    private var status: String {
        let voice = store.voice
        switch voice.phase {
        case .preparing: return "Getting ready…"
        case .listening: return "Listening…"
        case .waiting: return store.status.isEmpty ? "Thinking…" : store.status
        case .speaking: return "Speaking"
        case .idle:
            if store.isBusy { return "Thinking…" }
            return voice.isMuted ? "Microphone off" : "Getting ready…"
        }
    }

    private func circleButton(_ symbol: String, size: CGFloat, tint: Color? = nil, help: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.app(size, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: ComposerView.buttonSize, height: ComposerView.buttonSize)
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint ?? .primary)
        .glassEffect(tint.map { .regular.tint($0.opacity(0.25)).interactive() } ?? .regular.interactive(), in: Circle())
        .help(help)
    }
}

/// A soft orb whose mood follows the conversation. Listening follows your voice, speaking
/// flutters like talking, and thinking breathes and swirls. Changes of mood blend rather than jump.
struct VoiceOrb: View {
    let phase: VoiceEngine.Phase
    let level: Float
    let busy: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Mood { case resting, listening, thinking, speaking }

    private var mood: Mood {
        switch phase {
        case .listening, .preparing: .listening
        case .speaking: .speaking
        case .waiting: .thinking
        case .idle: busy ? .thinking : .resting
        }
    }

    private var energy: Double {
        switch mood {
        case .listening: 0.15 + 0.85 * min(1, Double(level) * 1.6)
        case .speaking: 0.4
        case .thinking: 0.3
        case .resting: 0.12
        }
    }

    private var tint: OrbTint {
        switch mood {
        case .listening: .listening
        case .speaking: .speaking
        case .thinking: .thinking
        case .resting: .resting
        }
    }

    var body: some View {
        OrbLayers(energy: energy, breathing: mood == .thinking ? 1 : mood == .resting ? 0.4 : 0,
                  talking: mood == .speaking ? 1 : 0, tint: tint, still: reduceMotion)
            .animation(.smooth(duration: 0.9), value: mood)
            .animation(.smooth(duration: 0.15), value: level)
            .glassEffect(.clear, in: Circle())
    }
}

/// The orb's drawing. Energy, breathing and color are animatable so mood changes glide.
/// Speeds stay fixed and only amplitudes change, so a change of mood never jolts the motion.
private struct OrbLayers: View, Animatable {
    var energy: Double
    var breathing: Double
    var talking: Double
    var tint: OrbTint
    let still: Bool

    var animatableData: AnimatablePair<AnimatablePair<Double, AnimatablePair<Double, Double>>, OrbTint> {
        get { AnimatablePair(AnimatablePair(energy, AnimatablePair(breathing, talking)), tint) }
        set {
            energy = newValue.first.first
            breathing = newValue.first.second.first
            talking = newValue.first.second.second
            tint = newValue.second
        }
    }

    var body: some View {
        TimelineView(.animation(paused: still)) { ctx in
            let t = still ? 0 : ctx.date.timeIntervalSinceReferenceDate
            let colors = tint.colors
            // A breath every 3 seconds; each layer follows a moment after the one inside it,
            // so it swells outward like a ripple.
            let breath = { (delay: Double) in sin((t - delay) * 2 * .pi / 3) }
            // While speaking, an uneven flutter made of a few slow waves, like the rise and fall of speech.
            let speech = talking * (0.5 + 0.25 * sin(t * 4.1) + 0.15 * sin(t * 6.7 + 1.3) + 0.1 * sin(t * 1.7))
            ZStack {
                ForEach(0..<3) { i in
                    let d = Double(i)
                    Circle()
                        .fill(AngularGradient(colors: colors + [colors[0]], center: .center,
                                              angle: .radians(t * (0.3 + d * 0.1) * (i == 1 ? -1 : 1) + d * 2.1)))
                        .scaleEffect(0.68 + 0.1 * d
                                     + energy * 0.12 * (0.5 + 0.5 * sin(t * (0.9 + d * 0.3) + d))
                                     + speech * 0.05 * (1 - d * 0.3)
                                     + breathing * 0.06 * breath(d * 0.35))
                        .opacity(0.62 - d * 0.12)
                        .blur(radius: 12 + d * 7)
                        .offset(x: (3 + 5 * breathing) * cos(t * (0.55 + d * 0.15) + d),
                                y: (3 + 5 * breathing) * sin(t * (0.5 + d * 0.2) + d))
                }
                Circle()
                    .fill(.white.opacity(0.55 + 0.35 * energy + 0.15 * breathing * breath(0)))
                    .scaleEffect(0.3 + energy * 0.18 + breathing * 0.04 * breath(0) + speech * 0.06)
                    .blur(radius: 16)
                    .blendMode(.plusLighter)
            }
            .scaleEffect(1 + breathing * 0.05 * breath(0.2) + energy * 0.07)
        }
    }
}

/// Three sRGB colors as one animatable value, so the orb's palette can blend between moods.
nonisolated struct OrbTint: VectorArithmetic {
    var rgb = SIMD16<Double>()

    init(rgb: SIMD16<Double> = .init()) { self.rgb = rgb }

    init(_ a: (Double, Double, Double), _ b: (Double, Double, Double), _ c: (Double, Double, Double)) {
        rgb = SIMD16(a.0, a.1, a.2, b.0, b.1, b.2, c.0, c.1, c.2, 0, 0, 0, 0, 0, 0, 0)
    }

    static let listening = OrbTint((1.0, 0.27, 0.23), (1.0, 0.58, 0.0), (1.0, 0.22, 0.45))
    static let speaking = OrbTint((0.2, 0.78, 0.95), (0.04, 0.52, 1.0), (0.62, 0.35, 0.95))
    static let thinking = OrbTint((0.37, 0.36, 0.9), (0.62, 0.35, 0.95), (0.04, 0.52, 1.0))
    static let resting = OrbTint((0.04, 0.52, 1.0), (0.19, 0.69, 0.78), (0.37, 0.36, 0.9))

    var colors: [Color] {
        (0..<3).map { Color(.sRGB, red: rgb[$0 * 3], green: rgb[$0 * 3 + 1], blue: rgb[$0 * 3 + 2]) }
    }

    static var zero: OrbTint { OrbTint() }
    static func + (a: OrbTint, b: OrbTint) -> OrbTint { OrbTint(rgb: a.rgb + b.rgb) }
    static func - (a: OrbTint, b: OrbTint) -> OrbTint { OrbTint(rgb: a.rgb - b.rgb) }
    mutating func scale(by rhs: Double) { rgb *= rhs }
    var magnitudeSquared: Double { (rgb * rgb).sum() }
}

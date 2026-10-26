import SwiftUI

/// Hands-free voice mode: a living orb that reacts to your voice and to Hermes speaking.
struct VoiceStage: View {
    @Environment(ChatStore.self) private var store

    var body: some View {
        let voice = store.voice
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VoiceOrb(phase: voice.phase, level: voice.level, busy: store.isBusy)
                .frame(width: 128, height: 128)
                .contentShape(Circle())
                .onTapGesture {
                    if voice.phase == .speaking { voice.bargeIn() }
                }
                .help(voice.phase == .speaking ? "Interrupt" : "")
            Text(caption)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.25), value: caption)
                .padding(.top, 18)
            subtitle
                .font(.system(size: 17))
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .minimumScaleFactor(0.85)
                .padding(.horizontal, 40)
                .frame(maxWidth: .infinity)
                .frame(height: 92, alignment: .top)
                .padding(.top, 10)
                .animation(.smooth(duration: 0.3), value: voice.phase)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    private var caption: String {
        let voice = store.voice
        switch voice.phase {
        case .preparing: return "Getting ready…"
        case .listening: return "Listening"
        case .waiting: return store.status.isEmpty ? "Thinking" : store.status
        case .speaking: return "Speaking · tap to interrupt"
        case .idle: return store.isBusy ? "Thinking" : "Voice mode"
        }
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
                .transition(.opacity)
        default:
            EmptyView()
        }
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

import SwiftUI

/// Hands-free voice mode: a living orb that reacts to your voice and to Hermes speaking.
struct VoiceStage: View {
    @Environment(ChatStore.self) private var store

    var body: some View {
        let voice = store.voice
        VStack(spacing: 18) {
            Spacer(minLength: 0)
            VoiceOrb(phase: voice.phase, level: voice.level, busy: store.isBusy)
                .frame(width: 150, height: 150)
                .onTapGesture {
                    if voice.phase == .speaking { voice.bargeIn() }
                }
            Text(caption)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.2), value: caption)
            Text(subtitle)
                .font(.system(size: 17))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.horizontal, 40)
                .frame(minHeight: 44, alignment: .top)
                .contentTransition(.opacity)
                .animation(.easeOut(duration: 0.15), value: subtitle)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    private var caption: String {
        switch store.voice.phase {
        case .preparing: "Getting ready…"
        case .listening: "Listening"
        case .waiting: store.status.isEmpty ? "Thinking" : store.status
        case .speaking: "Speaking · tap to interrupt"
        case .idle: store.isBusy ? "Thinking" : "Voice mode"
        }
    }

    private var subtitle: String {
        switch store.voice.phase {
        case .listening, .preparing: return store.voice.transcript
        case .speaking, .waiting, .idle:
            let last = store.messages.last { $0.role == .assistant }?.text ?? ""
            return VoiceEngine.speakable(last).components(separatedBy: CharacterSet(charactersIn: ".!?\n")).last { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        }
    }
}

struct VoiceOrb: View {
    let phase: VoiceEngine.Phase
    let level: Float
    let busy: Bool

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let energy: Double = switch phase {
            case .listening: 0.25 + Double(level) * 1.4
            case .speaking: 0.55 + 0.25 * sin(t * 7)
            case .waiting: 0.3
            default: busy ? 0.3 : 0.15
            }
            ZStack {
                ForEach(0..<4) { i in
                    let d = Double(i)
                    Circle()
                        .fill(
                            AngularGradient(colors: palette + [palette[0]], center: .center,
                                            angle: .radians(t * (0.6 + d * 0.25) * (i.isMultiple(of: 2) ? 1 : -1))))
                        .scaleEffect(0.62 + 0.1 * d + energy * 0.12 * sin(t * (2.1 + d) + d))
                        .opacity(0.55 - d * 0.1)
                        .blur(radius: 10 + d * 6)
                        .offset(x: 6 * cos(t * (1.3 + d * 0.4)), y: 6 * sin(t * (1.1 + d * 0.5)))
                }
                Circle()
                    .fill(.white.opacity(0.85))
                    .scaleEffect(0.32 + energy * 0.16)
                    .blur(radius: 14)
                    .blendMode(.plusLighter)
            }
            .scaleEffect(1 + energy * 0.08)
            .rotationEffect(.degrees(phase == .waiting ? t * 90 : 0))
        }
        .glassEffect(.clear, in: Circle())
        .animation(.spring(response: 0.5, dampingFraction: 0.7), value: phase)
    }

    private var palette: [Color] {
        switch phase {
        case .listening: [.red, .orange, .pink]
        case .speaking: [.cyan, .blue, .purple]
        case .waiting: [.indigo, .purple, .blue]
        default: [.blue, .teal, .indigo]
        }
    }
}

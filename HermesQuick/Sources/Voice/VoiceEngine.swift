import AVFoundation
import Foundation
import Observation
import Speech

/// Voice I/O built on Apple's on-device models:
/// `SpeechAnalyzer` + `SpeechTranscriber` for listening, and the macOS system voice for replies.
@Observable
final class VoiceEngine {
    enum Phase: Equatable { case idle, preparing, listening, waiting, speaking }

    private(set) var phase: Phase = .idle
    private(set) var transcript = ""
    private(set) var level: Float = 0
    /// Continuous hands-free mode: listen → send → speak reply → listen again.
    private(set) var isConversing = false
    private(set) var lastTurnWasVoice = false
    var errorMessage: String?

    @ObservationIgnored var onUtterance: ((String) -> Void)?

    @ObservationIgnored private let prefs = Preferences.shared
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var analyzer: SpeechAnalyzer?
    @ObservationIgnored private var tap: AudioTap?
    @ObservationIgnored private var resultsTask: Task<Void, Never>?
    @ObservationIgnored private var silenceTask: Task<Void, Never>?
    @ObservationIgnored private var finalized = ""
    @ObservationIgnored private var volatile = ""
    @ObservationIgnored private var lastSpeechAt = Date()
    @ObservationIgnored private let speaker = SystemVoiceSpeaker()

    init() {
        speaker.onFinish = { [weak self] in self?.didFinishSpeaking() }
    }

    var isListening: Bool { phase == .listening || phase == .preparing }

    // MARK: Public controls

    /// Push-to-talk: one utterance, then send.
    func toggleDictation() {
        if isListening { Task { await finishListening(send: true) } }
        else { lastTurnWasVoice = true; Task { await startListening() } }
    }

    func toggleConversation() {
        if isConversing { stopConversation() } else { startConversation() }
    }

    func startConversation() {
        isConversing = true
        lastTurnWasVoice = true
        stopSpeaking()
        Task { await startListening() }
    }

    func stopConversation() {
        isConversing = false
        stopSpeaking()
        Task { await finishListening(send: false) }
        phase = .idle
    }

    /// The reply arrived (or the turn ended); speak it.
    func speak(_ markdown: String) {
        let text = Self.speakable(markdown)
        guard !text.isEmpty else { didFinishSpeaking(); return }
        phase = .speaking
        speaker.speak(text, wordsPerMinute: Int(prefs.speechRate * 360))
    }

    func stopSpeaking() {
        speaker.stop()
        if phase == .speaking { phase = .idle }
    }

    /// Barge-in: interrupt speech and start listening immediately.
    func bargeIn() {
        stopSpeaking()
        Task { await startListening() }
    }

    func markTypedTurn() { lastTurnWasVoice = false }

    // MARK: Listening

    private func startListening() async {
        guard !isListening else { return }
        errorMessage = nil
        phase = .preparing
        transcript = ""
        finalized = ""
        volatile = ""

        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            fail("Microphone access is off. Enable it in System Settings › Privacy & Security › Microphone.")
            return
        }

        do {
            let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) ?? Locale(identifier: "en-US")
            let transcriber = SpeechTranscriber(locale: locale,
                                                transcriptionOptions: [],
                                                reportingOptions: [.volatileResults, .fastResults],
                                                attributeOptions: [])
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                errorMessage = "Downloading Apple's speech model…"
                try await request.downloadAndInstall()
                errorMessage = nil
            }

            let analyzer = SpeechAnalyzer(modules: [transcriber])
            self.analyzer = analyzer
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                fail("No compatible audio format for speech recognition.")
                return
            }
            try await analyzer.prepareToAnalyze(in: format)

            let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
            let input = engine.inputNode
            let inputFormat = input.outputFormat(forBus: 0)
            let tap = AudioTap(from: inputFormat, to: format, continuation: continuation) { [weak self] level in
                Task { @MainActor in self?.updateLevel(level) }
            }
            self.tap = tap
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat, block: tap.block)
            engine.prepare()
            try engine.start()

            resultsTask = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        self?.receive(String(result.text.characters), isFinal: result.isFinal)
                    }
                } catch {}
            }
            try await analyzer.start(inputSequence: stream)

            lastSpeechAt = Date()
            phase = .listening
            startSilenceWatch()
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func receive(_ text: String, isFinal: Bool) {
        if isFinal {
            finalized += text
            volatile = ""
        } else {
            volatile = text
        }
        transcript = (finalized + volatile).trimmingCharacters(in: .whitespaces)
        lastSpeechAt = Date()
    }

    private func updateLevel(_ value: Float) {
        level = level * 0.6 + value * 0.4
        if value > 0.08 { lastSpeechAt = Date() }
    }

    private func startSilenceWatch() {
        silenceTask?.cancel()
        silenceTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, self.phase == .listening else { return }
                let quiet = Date().timeIntervalSince(self.lastSpeechAt)
                let autoSend = self.prefs.autoSendOnPause || self.isConversing
                if autoSend, !self.transcript.isEmpty, quiet > 1.5 {
                    await self.finishListening(send: true)
                    return
                }
            }
        }
    }

    private func finishListening(send: Bool) async {
        guard isListening else { return }
        silenceTask?.cancel()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        tap?.finish()
        tap = nil
        if let analyzer {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        _ = await resultsTask?.value
        resultsTask = nil
        analyzer = nil
        level = 0

        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        phase = (send && !text.isEmpty) ? .waiting : .idle
        if send, !text.isEmpty {
            onUtterance?(text)
        } else if isConversing, send {
            Task { await startListening() }
        }
    }

    private func didFinishSpeaking() {
        guard phase == .speaking else { return }
        phase = .idle
        if isConversing { Task { await startListening() } }
    }

    /// The agent answered without voice (e.g. an error); resume the loop.
    func turnEndedWithoutSpeech() {
        if phase == .waiting { phase = .idle }
        if isConversing { Task { await startListening() } }
    }

    private func fail(_ message: String) {
        errorMessage = message
        phase = .idle
        isConversing = false
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
    }

    // MARK: Voices

    /// Strip markdown so the synthesizer doesn't read punctuation aloud.
    static func speakable(_ md: String) -> String {
        var s = md
        s = s.replacingOccurrences(of: "```[\\s\\S]*?```", with: " (code omitted) ", options: .regularExpression)
        s = s.replacingOccurrences(of: "`([^`]*)`", with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "!?\\[([^\\]]*)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?m)^#{1,6}\\s*", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?m)^\\s*[-*+]\\s+", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "[*_~]{1,3}", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "https?://\\S+", with: "link", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Runs on the realtime audio thread: converts mic buffers into the analyzer's format.
nonisolated final class AudioTap: @unchecked Sendable {
    private let converter: AVAudioConverter?
    private let outFormat: AVAudioFormat
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let onLevel: @Sendable (Float) -> Void

    init(from: AVAudioFormat, to: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation,
         onLevel: @escaping @Sendable (Float) -> Void) {
        converter = from == to ? nil : AVAudioConverter(from: from, to: to)
        outFormat = to
        self.continuation = continuation
        self.onLevel = onLevel
    }

    var block: AVAudioNodeTapBlock {
        { [self] buffer, _ in self.process(buffer) }
    }

    func finish() { continuation.finish() }

    private func process(_ buffer: AVAudioPCMBuffer) {
        onLevel(Self.rms(buffer))
        guard let converter else {
            continuation.yield(AnalyzerInput(buffer: buffer))
            return
        }
        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if error == nil, out.frameLength > 0 { continuation.yield(AnalyzerInput(buffer: out)) }
    }

    private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        for i in stride(from: 0, to: n, by: 4) { sum += data[i] * data[i] }
        let rms = sqrt(sum / Float(n / 4 + 1))
        return min(1, rms * 8)
    }
}

/// Speaks with the macOS *system voice* via /usr/bin/say.
///
/// macOS hides Siri voices from third-party apps' `AVSpeechSynthesizer` / `NSSpeechSynthesizer`
/// voice lists, but Apple's own `say` tool can use them. With System Settings › Accessibility ›
/// Read & Speak › System voice set to a Siri voice, replies come out in that Siri voice.
final class SystemVoiceSpeaker {
    var onFinish: (() -> Void)?
    private var process: Process?

    func speak(_ text: String, wordsPerMinute: Int) {
        stop()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-r", String(max(120, min(260, wordsPerMinute))), "-f", "-"]
        let input = Pipe()
        p.standardInput = input
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self, self.process === proc else { return }
                self.process = nil
                self.onFinish?()
            }
        }
        do {
            try p.run()
        } catch {
            onFinish?()
            return
        }
        process = p
        input.fileHandleForWriting.write(Data(text.utf8))
        try? input.fileHandleForWriting.close()
    }

    /// Stops speech immediately; does not fire `onFinish`.
    func stop() {
        guard let p = process else { return }
        process = nil
        if p.isRunning { p.terminate() }
    }
}

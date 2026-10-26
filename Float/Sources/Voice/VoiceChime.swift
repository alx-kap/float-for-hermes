import AppKit

/// The soft chimes for entering and leaving voice mode: two glassy notes, rising on the way in
/// and falling, a touch quieter, on the way out. Made here rather than shipped as files.
enum VoiceChime {
    static func playEnter() { enter?.stop(); enter?.play() }
    static func playExit() { exit?.stop(); exit?.play() }

    // E5 → B5 in, B5 → E5 out.
    private static let enter = NSSound(data: wav(notes: [659.25, 987.77], peak: 0.2))
    private static let exit = NSSound(data: wav(notes: [987.77, 659.25], peak: 0.16))

    private static func wav(notes: [Double], peak: Double) -> Data {
        let rate = 44_100.0
        let gap = 0.085, decay = 0.13, attack = 0.006
        let length = Int(rate * (gap * Double(notes.count - 1) + 0.55))
        var samples = [Double](repeating: 0, count: length)
        for (k, freq) in notes.enumerated() {
            let start = Int(rate * gap * Double(k))
            for i in start..<length {
                let t = Double(i - start) / rate
                let envelope = min(1, t / attack) * exp(-t / decay)
                // A pure tone with a faint octave and a slightly detuned twin, for a glassy ring.
                let tone = sin(2 * .pi * freq * t) + 0.16 * sin(4 * .pi * freq * t) + 0.3 * sin(2 * .pi * freq * 1.003 * t)
                samples[i] += tone * envelope * (k == 0 ? 0.85 : 1)
            }
        }
        let loudest = samples.map(abs).max() ?? 1
        var data = Data()
        func append<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + length * 2))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(rate)); append(UInt32(rate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(length * 2))
        for s in samples { append(Int16(s / loudest * peak * Double(Int16.max))) }
        return data
    }
}

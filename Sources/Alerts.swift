import Cocoa

/// Moments worth a sound: an agent starts needing help, or finishes its work.
enum AlertKind: Equatable {
    case needsHelp
    case finished
}

/// Plays a short chiptune jingle for each alert. Preferences live in
/// UserDefaults so muting survives relaunches; the menu bar and the widget's
/// speaker button both edit the same values.
final class SoundAlerts: ObservableObject {
    private let defaults: UserDefaults
    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: "sound.enabled") } }
    @Published var onNeedsHelp: Bool { didSet { defaults.set(onNeedsHelp, forKey: "sound.needsHelp") } }
    @Published var onFinished: Bool { didSet { defaults.set(onFinished, forKey: "sound.finished") } }

    private lazy var sounds: [AlertKind: NSSound] = [
        // Two urgent high blips, like a dungeon alarm.
        .needsHelp: SoundAlerts.jingle([(1319, 0.07), (0, 0.04), (1319, 0.07), (0, 0.04), (1760, 0.16)]),
        // Rising arpeggio: quest complete.
        .finished: SoundAlerts.jingle([(523, 0.07), (659, 0.07), (784, 0.07), (1047, 0.2)])
    ].compactMapValues { $0 }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: ["sound.enabled": true, "sound.needsHelp": true, "sound.finished": true])
        enabled = defaults.bool(forKey: "sound.enabled")
        onNeedsHelp = defaults.bool(forKey: "sound.needsHelp")
        onFinished = defaults.bool(forKey: "sound.finished")
    }

    func wants(_ kind: AlertKind) -> Bool {
        enabled && (kind == .needsHelp ? onNeedsHelp : onFinished)
    }

    func play(_ kind: AlertKind) {
        guard wants(kind), let sound = sounds[kind] else { return }
        sound.stop()
        sound.play()
    }

    /// Square-wave notes (frequency Hz, seconds; 0 Hz is a rest) rendered to
    /// an in-memory 16-bit mono WAV, with a quick fade so notes do not click.
    static func jingle(_ notes: [(Double, Double)], rate: Double = 22050, volume: Double = 0.18) -> NSSound? {
        var samples: [Int16] = []
        for (frequency, duration) in notes {
            let count = Int(duration * rate), fade = min(count / 4, Int(0.01 * rate))
            for i in 0..<count {
                guard frequency > 0 else { samples.append(0); continue }
                let phase = (Double(i) * frequency / rate).truncatingRemainder(dividingBy: 1)
                let edge = Double(min(i, count - 1 - i, fade)) / Double(max(fade, 1))
                samples.append(Int16((phase < 0.5 ? 1.0 : -1.0) * volume * min(1, edge) * Double(Int16.max)))
            }
        }
        var wav = Data()
        func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        wav.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36) + bytes)
        wav.append(contentsOf: Array("WAVEfmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
        put(UInt32(rate)); put(UInt32(rate) * 2); put(UInt16(2)); put(UInt16(16))
        wav.append(contentsOf: Array("data".utf8)); put(bytes)
        samples.forEach { put($0) }
        return NSSound(data: wav)
    }
}

/// Which alerts a snapshot change deserves. Needing help wins over finishing
/// so a busy refresh never plays two jingles on top of each other.
func alertFor(previous: [String: Agent], next: [Agent]) -> AlertKind? {
    var kinds: [AlertKind] = []
    for agent in next {
        guard let old = previous[agent.id], old.status != agent.status else { continue }
        if agent.status == "blocked" { kinds.append(.needsHelp) }
        else if agent.status == "done" || (old.status == "working" && agent.status == "idle") { kinds.append(.finished) }
    }
    return kinds.contains(.needsHelp) ? .needsHelp : kinds.first
}

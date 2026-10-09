import Cocoa
import UserNotifications

/// Moments worth a sound: an agent starts needing help, or finishes its work.
enum AlertKind: Equatable {
    case needsHelp
    case finished
}

/// Plays a short, soft chime for each alert. Preferences live in
/// UserDefaults so muting survives relaunches; the menu bar and the widget's
/// speaker button both edit the same values.
final class SoundAlerts: ObservableObject {
    private let defaults: UserDefaults
    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: "sound.enabled") } }
    @Published var onNeedsHelp: Bool { didSet { defaults.set(onNeedsHelp, forKey: "sound.needsHelp") } }
    @Published var onFinished: Bool { didSet { defaults.set(onFinished, forKey: "sound.finished") } }

    private lazy var sounds: [AlertKind: NSSound] = [
        // A soft two-note chime, falling a third: "ding-dong", someone is at the door.
        .needsHelp: SoundAlerts.jingle([(784, 0.22), (659, 0.5)]),
        // A gentle rising arpeggio that rings out: quest complete.
        .finished: SoundAlerts.jingle([(523, 0.12), (659, 0.12), (784, 0.12), (1047, 0.6)], volume: 0.1)
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

    /// Play both chimes, whatever the preferences: the menu's sound check.
    func preview() {
        sounds[.needsHelp]?.stop(); sounds[.needsHelp]?.play()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { self.sounds[.finished]?.stop(); self.sounds[.finished]?.play() }
    }

    func play(_ kind: AlertKind) {
        guard wants(kind), let sound = sounds[kind] else { return }
        sound.stop()
        sound.play()
    }

    /// Bell-like notes (frequency Hz, seconds until the next one; 0 Hz is a
    /// rest) rendered to an in-memory 16-bit mono WAV. Each note is a sine
    /// with soft overtones, a gentle attack and a natural exponential decay
    /// that keeps ringing under the next note, so it chimes instead of beeping.
    static func jingle(_ notes: [(Double, Double)], rate: Double = 44100, volume: Double = 0.12) -> NSSound? {
        let ring = 0.45   // how long a note keeps sounding after the next one starts
        let length = notes.reduce(0) { $0 + $1.1 } + ring
        var mix = [Double](repeating: 0, count: Int(length * rate))
        var start = 0.0
        for (frequency, step) in notes {
            defer { start += step }
            guard frequency > 0 else { continue }
            let first = Int(start * rate), count = min(Int((step + ring) * rate), mix.count - first)
            for i in 0..<max(count, 0) {
                let t = Double(i) / rate
                let attack = min(1, t / 0.012)
                let decay = exp(-t * 5.5)
                let tone = sin(2 * .pi * frequency * t) + 0.22 * sin(4 * .pi * frequency * t) + 0.06 * sin(6 * .pi * frequency * t)
                mix[first + i] += tone * attack * decay
            }
        }
        // Fade the very end so the last sample is silent, then scale.
        let tail = Int(0.03 * rate)
        for i in 0..<min(tail, mix.count) { mix[mix.count - 1 - i] *= Double(i) / Double(tail) }
        let samples = mix.map { Int16(max(-1, min(1, $0 * volume)) * Double(Int16.max)) }
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

/// One agent whose change deserves an alert.
struct AgentAlert: Equatable {
    let kind: AlertKind
    let agent: Agent
}

/// The agents whose change deserves an alert, those needing help first.
func alertsFor(previous: [String: Agent], next: [Agent]) -> [AgentAlert] {
    var alerts: [AgentAlert] = []
    for agent in next {
        guard let old = previous[agent.id], old.status != agent.status else { continue }
        if agent.status == "blocked" { alerts.append(AgentAlert(kind: .needsHelp, agent: agent)) }
        else if agent.status == "done" || (old.status == "working" && agent.status == "idle") { alerts.append(AgentAlert(kind: .finished, agent: agent)) }
    }
    return alerts.filter { $0.kind == .needsHelp } + alerts.filter { $0.kind == .finished }
}

/// Which jingle a snapshot change deserves. Needing help wins over finishing
/// so a busy refresh never plays two jingles on top of each other.
func alertFor(previous: [String: Agent], next: [Agent]) -> AlertKind? {
    alertsFor(previous: previous, next: next).first?.kind
}

/// macOS Notification Center banners for the same moments as the jingles:
/// on by default when an agent needs help, opt-in when one finishes.
/// Clicking a banner shows the dungeon with that agent's chat open.
final class Notifier: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    private let defaults: UserDefaults
    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: "notify.enabled"); if enabled { authorize() } } }
    @Published var onNeedsHelp: Bool { didSet { defaults.set(onNeedsHelp, forKey: "notify.needsHelp") } }
    @Published var onFinished: Bool { didSet { defaults.set(onFinished, forKey: "notify.finished") } }
    /// Called with the agent's pane id when its banner is clicked.
    var onOpen: ((String) -> Void)?
    private var authorized = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: ["notify.enabled": true, "notify.needsHelp": true, "notify.finished": false])
        enabled = defaults.bool(forKey: "notify.enabled")
        onNeedsHelp = defaults.bool(forKey: "notify.needsHelp")
        onFinished = defaults.bool(forKey: "notify.finished")
    }

    func wants(_ kind: AlertKind) -> Bool {
        enabled && (kind == .needsHelp ? onNeedsHelp : onFinished)
    }

    /// Become the delegate (so clicks reach us) and ask for permission once.
    func start() {
        UNUserNotificationCenter.current().delegate = self
        if enabled { authorize() }
    }

    private func authorize() {
        guard !authorized else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, _ in self.authorized = granted }
    }

    func post(_ alerts: [AgentAlert]) {
        for alert in alerts where wants(alert.kind) {
            let agent = alert.agent
            let content = UNMutableNotificationContent()
            content.title = alert.kind == .needsHelp ? tr("%@ necesita atención", agent.name) : tr("%@ terminó", agent.name)
            content.subtitle = agent.project
            content.body = agent.question ?? agent.activity
            content.userInfo = ["agent": agent.id]
            content.threadIdentifier = agent.id
            // One banner per agent: a newer one replaces the last.
            let request = UNNotificationRequest(identifier: "agent:" + agent.id, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }
    }

    /// Show banners even while the widget is in front: it may be covered.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let id = response.notification.request.content.userInfo["agent"] as? String {
            DispatchQueue.main.async { self.onOpen?(id) }
        }
        completionHandler()
    }
}

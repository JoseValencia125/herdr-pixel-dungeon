import Cocoa
import UserNotifications

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

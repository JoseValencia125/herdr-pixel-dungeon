import Foundation
import Darwin

/// Herdr's live event stream: one connection to its socket holding an
/// `events.subscribe` request open, so status changes arrive the moment they
/// happen instead of with the next `herdr api snapshot`. Herdr serves one
/// request per connection, so changing the subscribed panes means opening a
/// new stream. Callbacks run on the main queue.
final class HerdrStream {
    private let socketPath: String
    private let subscriptions: [[String: Any]]
    private var fd: Int32 = -1
    private let lock = NSLock()
    private var stopped = false
    var onOpen: (() -> Void)?
    var onEvent: (([String: Any]) -> Void)?
    var onClose: (() -> Void)?

    init(socketPath: String, panes: [String]) {
        self.socketPath = socketPath
        self.subscriptions = herdrSubscriptions(panes: panes)
    }

    func start() {
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "herdr-events"
        thread.start()
    }

    func stop() {
        lock.lock()
        stopped = true
        if fd >= 0 { shutdown(fd, SHUT_RDWR) }
        lock.unlock()
    }

    private func run() {
        defer { finish() }
        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else { return }
        lock.lock()
        fd = socket
        let cancelled = stopped
        lock.unlock()
        guard !cancelled, connect(socket, path: socketPath) else { return }
        let request: [String: Any] = ["id": "hpd-events", "method": "events.subscribe", "params": ["subscriptions": subscriptions]]
        guard var line = try? JSONSerialization.data(withJSONObject: request) else { return }
        line.append(0x0A)
        let written = line.withUnsafeBytes { write(socket, $0.baseAddress, $0.count) }
        guard written == line.count else { return }

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 16_384)
        var opened = false
        while true {
            let count = read(socket, &chunk, chunk.count)
            guard count > 0 else { return }
            buffer.append(chunk, count: count)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let row = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let object = try? JSONSerialization.jsonObject(with: row) as? [String: Any] else { continue }
                if !opened {
                    // The first reply confirms the subscription; an error ends the stream.
                    guard (object["result"] as? [String: Any])?["type"] as? String == "subscription_started" else { return }
                    opened = true
                    DispatchQueue.main.async { self.onOpen?() }
                } else {
                    DispatchQueue.main.async { self.onEvent?(object) }
                }
            }
        }
    }

    private func finish() {
        lock.lock()
        if fd >= 0 { close(fd); fd = -1 }
        let quiet = stopped
        lock.unlock()
        if !quiet { DispatchQueue.main.async { self.onClose?() } }
    }

    private func connect(_ socket: Int32, path: String) -> Bool {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return false }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
    }
}

/// What the dungeon listens to: panes appearing, changing, closing or
/// gaining an agent, workspaces being renamed or closed, and each agent
/// pane's status (Herdr subscribes to those one pane at a time).
func herdrSubscriptions(panes: [String]) -> [[String: Any]] {
    let global = ["pane.created", "pane.updated", "pane.closed", "pane.exited", "pane.agent_detected",
                  "workspace.created", "workspace.renamed", "workspace.closed", "tab.closed"]
    return global.map { ["type": $0] } + panes.sorted().map { ["type": "pane.agent_status_changed", "pane_id": $0] }
}

/// The socket of a Herdr session, from `herdr session list --json`; for the
/// session this app was launched inside, HERDR_SOCKET_PATH.
func herdrSocket(session: String) -> String? {
    let env = ProcessInfo.processInfo.environment
    if let path = env["HERDR_SOCKET_PATH"], (env["HERDR_SESSION"] ?? "default") == session { return path }
    guard let data = try? runHerdr(["session", "list", "--json"], session: "default", timeout: 3),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let rows = root["sessions"] as? [[String: Any]] else { return nil }
    return rows.first { $0["name"] as? String == session }?["socket_path"] as? String
}

/// How an event changes Herdr's view of the agents.
enum EventEffect: Equatable {
    case none       // nothing the dungeon shows
    case changed    // applied in place
    case resync     // a structural change best read from a fresh snapshot
}

/// Apply one event from the stream to the agents as Herdr reports them
/// (before local enrichment). Status changes and pane updates are applied
/// in place; a new agent or a workspace change asks for a snapshot.
func applyHerdrEvent(_ envelope: [String: Any], to agents: inout [Agent], names: [String: String]) -> EventEffect {
    let data = envelope["data"] as? [String: Any] ?? [:]
    let kind = ((envelope["event"] as? String) ?? (data["type"] as? String) ?? "").replacingOccurrences(of: ".", with: "_")
    switch kind {
    case "pane_agent_status_changed":
        guard let id = data["pane_id"] as? String else { return .none }
        guard let index = agents.firstIndex(where: { $0.id == id }) else { return .resync }
        let status = agentStatus(data["agent_status"])
        guard agents[index].status != status else { return .none }
        agents[index].status = status
        agents = sortAgents(agents)
        return .changed
    case "pane_created", "pane_updated":
        guard let pane = data["pane"] as? [String: Any], let id = pane["pane_id"] as? String else { return .none }
        let known = agents.firstIndex { $0.id == id }
        guard let agent = agentFromRow(pane, names: names) else {
            // The agent left the pane (the shell remains).
            guard let index = known else { return .none }
            agents.remove(at: index)
            return .changed
        }
        // A pane that just gained an agent needs its status subscription: resync.
        guard let index = known else { return .resync }
        guard agents[index] != agent else { return .none }
        agents[index] = agent
        agents = sortAgents(agents)
        return .changed
    case "pane_closed", "pane_exited":
        guard let id = data["pane_id"] as? String, let index = agents.firstIndex(where: { $0.id == id }) else { return .none }
        agents.remove(at: index)
        return .changed
    case "pane_agent_detected", "workspace_created", "workspace_renamed", "workspace_closed", "tab_closed":
        return .resync
    default:
        return .none
    }
}

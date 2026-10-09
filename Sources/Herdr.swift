import Foundation
import SwiftUI
import Darwin

struct Agent: Identifiable, Equatable {
    let id: String
    let name: String
    var status: String
    let project: String
    let activity: String
    let cwd: String
    var session: String? = nil    // agent_session id (Claude Code session UUID)
    var subagents = 0             // subagents with recent transcript activity
    var subagentActions: [String] = []   // what each of them is doing (read, forge, brew…), from its own transcript
    var branch: String? = nil     // git branch of cwd, if it is a repository
    var action: String? = nil     // what a working Claude Code agent is doing: read, forge, brew, summon, plan, type
    var question: String? = nil   // what a blocked background job is asking (its first line)
    var questionTranscript: String? = nil  // that job's transcript, to show the whole question
    var folder: String { (cwd as NSString).lastPathComponent }
    var label: String { tr(["working":"Trabajando", "blocked":"Necesita atención", "idle":"En espera", "done":"Listo"][status] ?? "Sin estado") }
    var color: Color { switch status { case "working": return .orange; case "blocked": return .red; case "done": return .green; case "idle": return .gray; default: return .gray } }
    static func rank(_ status: String) -> Int { ["blocked":0,"working":1,"idle":2,"done":3][status] ?? 4 }
    var rank: Int { Agent.rank(status) }
}

enum MonitorError: LocalizedError {
    case message(String)
    /// Herdr answered with an error (its JSON on stderr): a code such as
    /// agent_not_ready or agent_blocked, and its own message.
    case herdr(code: String, message: String)
    var errorDescription: String? {
        switch self {
        case .message(let value): return value
        case .herdr(_, let message): return message
        }
    }
    var herdrCode: String? { if case .herdr(let code, _) = self { return code }; return nil }
}

/// The error Herdr printed on stderr (`{"error":{"code":…,"message":…}}`), if any.
func herdrError(_ data: Data) -> MonitorError? {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let error = root["error"] as? [String: Any], let code = error["code"] as? String else { return nil }
    return .herdr(code: code, message: error["message"] as? String ?? code)
}

func decodeSnapshot(_ data: Data) throws -> [Agent] { try decodeSnapshotParts(data).agents }

/// A snapshot's agents (sorted, attention first) and its workspace labels.
func decodeSnapshotParts(_ data: Data) throws -> (agents: [Agent], names: [String: String]) {
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String:Any],
          let result = root["result"] as? [String:Any],
          let snapshot = result["snapshot"] as? [String:Any],
          let agents = snapshot["agents"] as? [[String:Any]] else {
        throw MonitorError.message(tr("Herdr no entregó un snapshot válido."))
    }
    var names: [String:String] = [:]
    for space in snapshot["workspaces"] as? [[String:Any]] ?? [] {
        if let id = space["workspace_id"] as? String { names[id] = space["label"] as? String }
    }
    var unique: [String:Agent] = [:]
    for row in agents {
        if let agent = agentFromRow(row, names: names) { unique[agent.id] = agent }
    }
    return (sortAgents(Array(unique.values)), names)
}

/// An agent from a Herdr pane row (a snapshot's agent or an event's pane),
/// or nil when no agent runs in the pane.
func agentFromRow(_ row: [String:Any], names: [String:String]) -> Agent? {
    guard let id = row["pane_id"] as? String, let name = row["agent"] as? String else { return nil }
    let cwd = row["foreground_cwd"] as? String ?? row["cwd"] as? String ?? ""
    return Agent(id: id, name: name, status: agentStatus(row["agent_status"]),
                 project: names[row["workspace_id"] as? String ?? ""] ?? URL(fileURLWithPath: cwd).lastPathComponent,
                 activity: row["terminal_title_stripped"] as? String ?? row["terminal_title"] as? String ?? tr("Sin título de actividad"),
                 cwd: (cwd as NSString).abbreviatingWithTildeInPath,
                 session: (row["agent_session"] as? [String:Any])?["value"] as? String)
}

func agentStatus(_ raw: Any?) -> String {
    let raw = raw as? String ?? "unknown"
    return ["working", "blocked", "idle", "done"].contains(raw) ? raw : "unknown"
}

/// Attention first, then working, waiting, done; ties by pane id.
func sortAgents(_ agents: [Agent]) -> [Agent] {
    agents.sorted { $0.rank == $1.rank ? $0.id.localizedStandardCompare($1.id) == .orderedAscending : $0.rank < $1.rank }
}

/// Locate the herdr binary: HERDR_BIN, the usual install spots, then PATH.
func herdrBinary() throws -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let pathCandidates = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/herdr" }
    let candidates = [ProcessInfo.processInfo.environment["HERDR_BIN"], home + "/.local/bin/herdr", "/opt/homebrew/bin/herdr", "/usr/local/bin/herdr"].compactMap { $0 } + pathCandidates
    guard let binary = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
        throw MonitorError.message(tr("No se encontró Herdr. Instálalo o define HERDR_BIN."))
    }
    return binary
}

/// Run `herdr [--session s] <arguments>` and return its stdout. The process
/// is killed after `timeout` seconds so a stuck server never hangs the UI.
@discardableResult
func runHerdr(_ arguments: [String], session: String, timeout seconds: TimeInterval = 4) throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: try herdrBinary())
    process.arguments = (session == "default" ? [] : ["--session", session]) + arguments
    let output = Pipe(), errors = Pipe()
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    let timeout = DispatchWorkItem { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
    DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: timeout)
    var complaint = Data()
    let drained = DispatchSemaphore(value: 0)
    DispatchQueue.global().async { complaint = errors.fileHandleForReading.readDataToEndOfFile(); drained.signal() }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    drained.wait()
    process.waitUntilExit()
    timeout.cancel()
    guard process.terminationStatus == 0 else {
        throw herdrError(complaint) ?? MonitorError.message(tr("Sin conexión con Herdr. Abre tu sesión; reintentamos automáticamente."))
    }
    return data
}

func fetchSnapshot(session: String) throws -> [Agent] {
    enrich(try decodeSnapshot(runHerdr(["api", "snapshot"], session: session)))
}

/// Add what Herdr does not know, from local files only (no processes): git
/// branch, Claude background jobs and subagents, and each harness's last
/// tool from its own session log.
func enrich(_ agents: [Agent]) -> [Agent] {
    let jobs = backgroundJobs()
    return agents.map { agent in
        var agent = agent
        let path = (agent.cwd as NSString).expandingTildeInPath
        agent.branch = gitBranch(at: path)
        if agent.name == "claude" { agent = agent.with(jobs: jobs[path] ?? []) }
        guard let session = agent.session else { return agent }
        switch Hero.harness(for: agent.name) {
        case "claude":
            agent.action = currentAction(session: session)
            let helpers = subagentActions(session: session)
            agent.subagentActions = helpers
            return agent.with(subagents: helpers.count)
        case "codex": agent.action = recentAction(in: codexTranscript(session: session), parse: codexAction)
        case "kiro": agent.action = recentAction(in: kiroTranscript(session: session), parse: kiroAction)
        default: break   // no readable activity: the hero makes the rounds
        }
        return agent
    }
}

/// Claude Code background sessions run as jobs, not in the pane: the pane
/// only shows the job list waiting for input, so Herdr reports it idle while
/// its jobs work. Each job keeps ~/.claude/jobs/<id>/state.json with its
/// state and cwd. Returns the states of recently updated jobs by cwd.
struct BackgroundJob {
    let state: String
    let needs: String?        // first line of the question a blocked job is asking
    let transcript: String?   // its transcript (.jsonl)
    let updated: Date
}

func backgroundJobs(within seconds: TimeInterval = 3600) -> [String:[BackgroundJob]] {
    let fm = FileManager.default
    let root = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/jobs")
    guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [:] }
    let dates = ISO8601DateFormatter()
    dates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let cutoff = Date().addingTimeInterval(-seconds)
    var byCwd: [String:[BackgroundJob]] = [:]
    for dir in dirs {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("state.json")),
              let job = try? JSONSerialization.jsonObject(with: data) as? [String:Any],
              let state = job["state"] as? String,
              let cwd = job["originCwd"] as? String ?? job["cwd"] as? String,
              let updated = (job["updatedAt"] as? String).flatMap(dates.date(from:)), updated > cutoff else { continue }
        byCwd[cwd, default: []].append(BackgroundJob(state: state, needs: job["needs"] as? String,
                                                      transcript: job["linkScanPath"] as? String, updated: updated))
    }
    return byCwd
}

/// Current git branch for a directory, read straight from .git/HEAD (no
/// process launch). Handles worktrees, where .git is a file pointing at the
/// real git dir. Detached HEADs show the short commit.
func gitBranch(at path: String) -> String? {
    let fm = FileManager.default
    var dir = URL(fileURLWithPath: path)
    while dir.path != "/" {
        let dotGit = dir.appendingPathComponent(".git")
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: dotGit.path, isDirectory: &isDir) {
            var gitDir = dotGit
            if !isDir.boolValue {
                guard let text = try? String(contentsOf: dotGit, encoding: .utf8),
                      let line = text.split(separator: "\n").first, line.hasPrefix("gitdir:") else { return nil }
                let target = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                gitDir = URL(fileURLWithPath: target, relativeTo: dir)
            }
            guard let head = try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
            if head.hasPrefix("ref: refs/heads/") { return String(head.dropFirst("ref: refs/heads/".count)) }
            return head.isEmpty ? nil : String(head.prefix(7))
        }
        dir.deleteLastPathComponent()
    }
    return nil
}

extension Agent {
    /// A pane takes the most urgent state among itself and its background
    /// jobs: a job needing input outranks one working, which outranks idle.
    func with(jobs: [BackgroundJob]) -> Agent {
        var agent = self
        let states = jobs.map(\.state)
        if let urgent = ["blocked", "working"].first(where: states.contains), Agent.rank(urgent) < rank { agent.status = urgent }
        if agent.status == "blocked", let asking = jobs.filter({ $0.state == "blocked" }).max(by: { $0.updated < $1.updated }) {
            agent.question = asking.needs
            agent.questionTranscript = asking.transcript
        }
        return agent
    }

    /// An agent whose subagents are still running is busy, even if its own
    /// pane reports idle.
    func with(subagents count: Int) -> Agent {
        var agent = self
        agent.subagents = count
        if count > 0 && agent.status == "idle" { agent.status = "working" }
        return agent
    }
}

/// Herdr does not report subagents, but Claude Code writes one transcript per
/// subagent under ~/.claude/projects/<project>/<session>/subagents/. A
/// subagent counts as active while its transcript was written recently.
/// For each active subagent this returns what it is doing: the last tool in
/// its own transcript (or typing when it only wrote text), in a stable
/// order. Tails are cached by modification date, so a quiet transcript is
/// read once.
func subagentActions(session: String, within seconds: TimeInterval = 30) -> [String] {
    activeSubagentFiles(session: session, within: seconds).map { file, modified in
        transcriptActions.lock()
        defer { transcriptActions.unlock() }
        if let cached = transcriptActions.cache[file.path], cached.modified == modified { return cached.action }
        let action = fileTail(file.path, bytes: 65_536).flatMap { lastAction(transcriptTail: $0) } ?? "type"
        transcriptActions.cache[file.path] = (modified, action)
        return action
    }
}

private final class ActionCache: NSLock {
    var cache: [String: (modified: Date, action: String)] = [:]
}
private let transcriptActions = ActionCache()

private func activeSubagentFiles(session: String, within seconds: TimeInterval) -> [(URL, Date)] {
    let fm = FileManager.default
    let projects = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    guard let dirs = try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil) else { return [] }
    let cutoff = Date().addingTimeInterval(-seconds)
    for dir in dirs {
        let folder = dir.appendingPathComponent(session).appendingPathComponent("subagents")
        guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
        return files.compactMap { file -> (URL, Date)? in
            guard file.pathExtension == "jsonl",
                  let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  modified > cutoff else { return nil }
            return (file, modified)
        }.sorted { $0.0.lastPathComponent < $1.0.lastPathComponent }
    }
    return []
}

/// What the dungeon should say about its link to Herdr, if anything: lost
/// (an error, red) or stale (no fresh data for a while, amber), with how
/// long ago the last good update was. Nil while all is well.
func connectionNote(error: String?, updated: Date?, now: Date = Date(), staleAfter: TimeInterval = 5) -> (text: String, lost: Bool)? {
    let age = updated.map { now.timeIntervalSince($0) }
    let ago = age.map { $0 < 90 ? tr("hace %ld s", Int($0)) : tr("hace %ld min", Int($0 / 60)) }
    if error != nil {
        return (tr("Herdr desconectado") + (ago.map { " · " + tr("última actualización %@", $0) } ?? ""), true)
    }
    guard let age = age, let ago = ago, age >= staleAfter else { return nil }
    return (tr("Datos sin actualizar · última actualización %@", ago), false)
}

/// Harnesses offered when creating an agent (all are `herdr agent start --kind` values).
let creatableKinds = ["claude", "codex", "gemini", "kiro", "opencode", "cursor", "copilot", "amp"]

/// A unique, readable Herdr agent name: kind, folder and a short suffix.
func agentName(kind: String, folder: String) -> String {
    let slug = folder.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.reduce("") { $0 + String($1) }
        .split(separator: "-").joined(separator: "-")
    return "\(kind)-\(slug.isEmpty ? "agent" : String(slug.prefix(24)))-\(String(UUID().uuidString.prefix(4)).lowercased())"
}

/// The new pane's id in `herdr workspace create` output (`.result.root_pane`).
func rootPane(_ data: Data) -> String? {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let result = root["result"] as? [String: Any] else { return nil }
    if let pane = result["root_pane"] as? [String: Any] { return pane["pane_id"] as? String }
    return result["root_pane"] as? String
}

/// A Herdr session, from `herdr session list --json`.
struct HerdrSession: Equatable {
    let name: String
    let running: Bool
}

func decodeSessions(_ data: Data) -> [HerdrSession] {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let rows = root["sessions"] as? [[String: Any]] else { return [] }
    return rows.compactMap { row in
        (row["name"] as? String).map { HerdrSession(name: $0, running: row["running"] as? Bool ?? false) }
    }
}

/// The sessions Herdr knows about; empty when Herdr cannot be reached.
func listSessions() -> [HerdrSession] {
    (try? runHerdr(["session", "list", "--json"], session: "default", timeout: 2)).map(decodeSessions) ?? []
}

/// Which rooms the HUD's state chips let through.
enum StatusFilter: String, CaseIterable {
    case all, blocked, working, idle, done

    func admits(_ agent: Agent) -> Bool { self == .all || agent.status == rawValue }
}

/// Agents that pass the state filter and whose project, harness, branch,
/// folder or activity contain every word of the query (ignoring case and
/// accents). Order is kept, so attention stays first.
func filterAgents(_ agents: [Agent], status: StatusFilter, query: String) -> [Agent] {
    let fold = { (text: String) in text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
    let words = fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
    return agents.filter { agent in
        guard status.admits(agent) else { return false }
        let haystack = fold([agent.project, agent.name, agent.branch ?? "", agent.folder, agent.cwd, agent.activity].joined(separator: "\n"))
        return words.allSatisfy(haystack.contains)
    }
}

/// One line of the activity log. `tone` picks its marker: an agent state
/// (working, blocked, idle, done), "joined", "left", "subagents", "message"
/// or "info".
struct GuildEvent: Identifiable {
    let id = UUID()
    let at = Date()
    let text: String
    var tone = "info"
}

final class Monitor: ObservableObject {
    @Published var agents: [Agent] = []
    @Published var error: String?
    @Published var updated: Date?
    @Published var events: [GuildEvent] = []
    @Published var demo = false
    /// HUD state chip and search box; the chip survives relaunches.
    @Published var filter: StatusFilter { didSet { UserDefaults.standard.set(filter.rawValue, forKey: "filter.status"); onChange?() } }
    @Published var query = "" { didSet { if query != oldValue { onChange?() } } }
    var visibleAgents: [Agent] { filterAgents(agents, status: filter, query: query) }
    var isFiltering: Bool { filter != .all || !query.trimmingCharacters(in: .whitespaces).isEmpty }
    /// The HUD shows once there are enough rooms to sift, or while a filter hides some.
    var showsHUD: Bool { agents.count >= 3 || isFiltering }

    init() {
        filter = StatusFilter(rawValue: UserDefaults.standard.string(forKey: "filter.status") ?? "") ?? .all
    }
    /// The room the user clicked; its chat panel is open while set.
    @Published var selected: String? { didSet { if selected != oldValue { if selected != nil { composing = false }; onChange?() } } }
    /// The "new agent" panel is open.
    @Published var composing = false { didSet { if composing != oldValue { if composing { selected = nil }; onChange?() } } }
    /// The Herdr session watched: HERDR_SESSION when set, else the one picked
    /// last time from the menu bar, else "default".
    @Published private(set) var session = ProcessInfo.processInfo.environment["HERDR_SESSION"]
        ?? UserDefaults.standard.string(forKey: "session") ?? "default"
    private var busy = false
    private var again = false          // a refresh was asked for while one ran
    private var timer: Timer?
    // Herdr's view of the agents before local enrichment: from a snapshot,
    // then kept current by the event stream.
    private var base: [Agent] = []
    private var names: [String: String] = [:]
    private var lastSnapshot: Date?
    private var needsSnapshot = true
    private var stream: HerdrStream?
    private var streamPanes: [String] = []
    private(set) var streamUp = false
    private var nextStreamTry = Date.distantPast
    private var socketPath: String?    // the session's socket, looked up once per connection
    private var connecting = false
    /// Snapshots double as a reconciliation while the stream is live.
    static let reconcileEvery: TimeInterval = 60
    private var tick = 0
    private var generation = 0
    var onChange: (() -> Void)?
    var onAlerts: (([AgentAlert]) -> Void)?
    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }
    func setDemo(_ enabled: Bool) {
        generation += 1; demo = enabled; reset()
    }
    /// Drop the event stream and Herdr's cached view: the next refresh
    /// starts over with a snapshot.
    private func dropStream() {
        stream?.stop(); stream = nil; streamPanes = []; streamUp = false; connecting = false
        base = []; names = [:]; lastSnapshot = nil; needsSnapshot = true; nextStreamTry = .distantPast; socketPath = nil
    }
    /// Watch another Herdr session, starting over with its agents.
    func setSession(_ name: String) {
        guard name != session else { return }
        generation += 1; session = name; UserDefaults.standard.set(name, forKey: "session"); reset()
    }
    private func reset() {
        dropStream()
        agents = []; events = []; updated = nil; error = nil; selected = nil
        onChange?(); refresh()
    }
    func apply(_ next: [Agent]) {
        // Sort last: background jobs and subagents can change a status after
        // Herdr's, and whoever needs attention must lead the grid.
        let next = sortAgents(next)
        let previous = Dictionary(uniqueKeysWithValues: agents.map { ($0.id, $0) })
        let ids = Set(next.map(\.id))
        if updated != nil { let alerts = alertsFor(previous: previous, next: next); if !alerts.isEmpty { onAlerts?(alerts) } }
        if updated == nil { events.insert(GuildEvent(text: tr("Guild conectada · %ld agentes", next.count)), at: 0) }
        else {
            for agent in next {
                if let old = previous[agent.id] {
                    if old.status != agent.status { events.insert(GuildEvent(text: "\(agent.project) · \(agent.label)", tone: agent.status), at: 0) }
                    if agent.subagents > old.subagents { events.insert(GuildEvent(text: tr("%@ · %ld subagentes activos", agent.project, agent.subagents), tone: "subagents"), at: 0) }
                } else { events.insert(GuildEvent(text: tr("%@ entró a la guild", agent.project), tone: "joined"), at: 0) }
            }
            for agent in agents where !ids.contains(agent.id) { events.insert(GuildEvent(text: tr("%@ salió de la guild", agent.project), tone: "left"), at: 0) }
        }
        events = Array(events.prefix(40)); agents = next; updated = Date(); error = nil
        if let selected = selected, !ids.contains(selected) { self.selected = nil }
    }
    /// Every second: enrich Herdr's view from local files and show it.
    /// Herdr itself is read with a snapshot only to bootstrap, after a
    /// structural event, once a minute to reconcile, or every time while the
    /// event stream is down (the old polling, as a fallback).
    func refresh() {
        guard !busy else { again = true; return }
        busy = true
        let currentGeneration = generation, demoMode = demo, currentTick = tick, selectedSession = session
        let snapshot = !demoMode && (needsSnapshot || !streamUp || Date().timeIntervalSince(lastSnapshot ?? .distantPast) > Monitor.reconcileEvery)
        let known = base
        tick += 1
        DispatchQueue.global(qos: .utility).async {
            let result = Result { () -> (fresh: (agents: [Agent], names: [String: String])?, shown: [Agent]) in
                if demoMode { return (nil, demoAgents(tick: currentTick)) }
                if snapshot {
                    let fresh = try decodeSnapshotParts(runHerdr(["api", "snapshot"], session: selectedSession))
                    return (fresh, enrich(fresh.agents))
                }
                return (nil, enrich(known))
            }
            DispatchQueue.main.async {
                self.busy = false
                guard currentGeneration == self.generation else { self.refresh(); return }
                switch result {
                case .success(let read):
                    if let fresh = read.fresh {
                        self.base = fresh.agents; self.names = fresh.names
                        self.lastSnapshot = Date(); self.needsSnapshot = false
                    }
                    self.apply(read.shown)
                    if !demoMode { self.keepStream() }
                case .failure(let error):
                    self.error = error.localizedDescription
                    self.needsSnapshot = true
                }
                self.onChange?()
                if self.again { self.again = false; self.refresh() }
            }
        }
    }

    /// Keep one event stream open on the current agent panes, reopening it
    /// when they change and retrying a few seconds after it drops.
    private func keepStream() {
        let panes = base.map(\.id).sorted()
        guard !connecting, stream == nil || panes != streamPanes, Date() >= nextStreamTry else { return }
        connecting = true
        stream?.stop()
        streamPanes = panes
        let selectedSession = session, currentGeneration = generation
        let wasUp = streamUp, cached = socketPath
        stream = nil
        DispatchQueue.global(qos: .utility).async {
            let path = cached ?? herdrSocket(session: selectedSession)
            DispatchQueue.main.async {
                self.connecting = false
                self.socketPath = path
                guard currentGeneration == self.generation, self.stream == nil else { return }
                guard let path = path else { self.streamUp = false; self.nextStreamTry = Date().addingTimeInterval(5); return }
                let next = HerdrStream(socketPath: path, panes: panes)
                next.onOpen = { [weak self, weak next] in
                    guard let self = self, self.stream === next else { return }
                    self.streamUp = true
                    // Anything that changed while (re)subscribing is caught by a snapshot.
                    if !wasUp { self.needsSnapshot = true }
                }
                next.onEvent = { [weak self, weak next] event in
                    guard let self = self, self.stream === next else { return }
                    self.handle(event)
                }
                next.onClose = { [weak self, weak next] in
                    guard let self = self, self.stream === next else { return }
                    self.stream = nil; self.streamPanes = []; self.streamUp = false; self.needsSnapshot = true
                    self.socketPath = nil   // look it up again: the server may have moved
                    self.nextStreamTry = Date().addingTimeInterval(3)
                }
                self.stream = next
                next.start()
            }
        }
    }

    /// An event from Herdr: apply it and show it right away, or ask for a snapshot.
    private func handle(_ event: [String: Any]) {
        switch applyHerdrEvent(event, to: &base, names: names) {
        case .none: return
        case .changed: refresh()
        case .resync: needsSnapshot = true; refresh()
        }
    }
}

// MARK: Actions on an agent's pane

extension Monitor {
    /// Run a herdr command off the main thread; `done` gets nil or an error message.
    private func act(_ arguments: [String]..., done: ((String?) -> Void)? = nil) {
        let selectedSession = session, demoMode = demo
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: String?
            if !demoMode {
                do { for args in arguments { try runHerdr(args, session: selectedSession, timeout: 6) } }
                catch { failure = tr("Herdr rechazó la acción. Revisa el panel del agente.") }
            }
            DispatchQueue.main.async { done?(failure) }
        }
    }

    /// Type a message into the agent's chat and press Enter. Herdr refuses
    /// `agent prompt` while a permission prompt is open, so a blocked agent
    /// gets the raw keystrokes instead (e.g. an answer to its question).
    func send(_ text: String, to agent: Agent, done: @escaping (String?) -> Void) {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return done(nil) }
        let log = { (failure: String?) in
            if failure == nil { self.events.insert(GuildEvent(text: tr("Tú → %@: %@", agent.project, message), tone: "message"), at: 0) }
            done(failure)
        }
        if agent.status == "blocked" {
            act(["pane", "send-text", agent.id, message], ["pane", "send-keys", agent.id, "enter"], done: log)
        } else {
            prompt(agent.id, message, done: log)
        }
    }

    /// Press keys in the agent's pane: "enter" accepts a permission prompt's
    /// highlighted option, "esc" rejects it or interrupts the agent.
    func press(_ keys: [String], on agent: Agent, done: @escaping (String?) -> Void) {
        act(["agent", "send-keys", agent.id] + keys, done: done)
    }

    /// End the agent's session by typing /exit in its chat. A working or
    /// asking agent first gets esc, and a pause so the terminal does not read
    /// esc + "/" as Alt+/.
    func finish(_ agent: Agent, done: @escaping (String?) -> Void) {
        let exit = { self.act(["pane", "send-text", agent.id, "/exit"], ["pane", "send-keys", agent.id, "enter"], done: done) }
        guard agent.status == "working" || agent.status == "blocked" else { return exit() }
        act(["agent", "send-keys", agent.id, "esc"]) { failure in
            if let failure = failure { return done(failure) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: exit)
        }
    }

    /// Start a new agent: a Herdr workspace in `folder` (its root pane is a
    /// fresh shell), `herdr agent start` of `kind` in it, then the first
    /// prompt if there is one. It shows up in the dungeon with the next
    /// snapshot. `done` gets nil or an error message.
    func create(kind: String, folder: String, prompt: String, done: @escaping (String?) -> Void) {
        let selectedSession = session, demoMode = demo
        let path = (folder as NSString).expandingTildeInPath
        let label = (path as NSString).lastPathComponent
        let name = agentName(kind: kind, folder: label)
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: String?
            var waitingPane: String?   // started, but stopped at a startup question
            if !demoMode {
                do {
                    var isDir: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
                        throw MonitorError.message(tr("La carpeta no existe."))
                    }
                    let created = try runHerdr(["workspace", "create", "--cwd", path, "--label", label, "--no-focus"], session: selectedSession, timeout: 8)
                    guard let pane = rootPane(created) else { throw MonitorError.message(tr("Herdr no devolvió el panel nuevo.")) }
                    do { try runHerdr(["agent", "start", name, "--kind", kind, "--pane", pane, "--timeout", "60000"], session: selectedSession, timeout: 65) }
                    catch let error as MonitorError where error.herdrCode == "agent_not_ready" { waitingPane = pane }
                    catch { throw MonitorError.message(tr("%@ no arrancó. Revisa que esté instalado.", kind)) }
                    if waitingPane == nil && !text.isEmpty {
                        do { try runHerdr(["agent", "prompt", name, text], session: selectedSession, timeout: 10) }
                        catch let error as MonitorError where ["agent_prompt_stalled", "agent_prompt_unverifiable"].contains(error.herdrCode ?? "") {}
                        catch let error as MonitorError where error.herdrCode == "agent_blocked" { waitingPane = pane }
                        catch { throw MonitorError.message(tr("El agente arrancó, pero no recibió el prompt.")) }
                    }
                } catch { failure = error.localizedDescription }
            }
            DispatchQueue.main.async {
                if failure == nil { self.events.insert(GuildEvent(text: tr("Invocaste a %@ en %@", kind, label), tone: "joined"), at: 0) }
                if let pane = waitingPane {
                    self.events.insert(GuildEvent(text: tr("%@ espera tu respuesta; su prompt se enviará cuando esté listo.", label), tone: "blocked"), at: 0)
                    if !text.isEmpty { self.promptWhenReady(pane: pane, name: name, project: label, text: text) } else { self.selected = pane }
                }
                done(failure)
                self.refresh()
            }
        }
    }

    /// Submit a prompt with `herdr agent prompt`. Herdr only reports
    /// "stalled" or "unverifiable" when it cannot see the agent react within
    /// five seconds; that is not proof the text was lost, so it counts as sent.
    private func prompt(_ target: String, _ text: String, done: @escaping (String?) -> Void) {
        let selectedSession = session, demoMode = demo
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: String?
            if !demoMode {
                do { try runHerdr(["agent", "prompt", target, text], session: selectedSession, timeout: 10) }
                catch let error as MonitorError where ["agent_prompt_stalled", "agent_prompt_unverifiable"].contains(error.herdrCode ?? "") {}
                catch let error as MonitorError where error.herdrCode == "agent_blocked" { failure = tr("El agente está esperando una respuesta; contéstale primero.") }
                catch { failure = tr("Herdr rechazó la acción. Revisa el panel del agente.") }
            }
            DispatchQueue.main.async { done(failure) }
        }
    }

    /// A new agent stopped at a startup question (trusting the folder, a
    /// login…): open its chat so it can be answered, and send the first
    /// prompt once it is idle. Gives up after three minutes.
    private func promptWhenReady(pane: String, name: String, project: String, text: String) {
        var seen = false
        func check(_ tries: Int) {
            guard tries > 0 else { return events.insert(GuildEvent(text: tr("%@ no quedó listo; su prompt no se envió.", project), tone: "left"), at: 0) }
            let status = agents.first { $0.id == pane }?.status
            if status != nil && !seen { seen = true; selected = pane }
            if status == "idle" || status == "done" {
                return prompt(name, text) { failure in
                    self.events.insert(GuildEvent(text: failure == nil ? tr("Tú → %@: %@", project, text) : tr("%@ no recibió su prompt.", project),
                                                  tone: failure == nil ? "message" : "left"), at: 0)
                }
            }
            if seen && status == nil { return }   // the pane went away
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { check(tries - 1) }
        }
        check(180)
    }

    /// Bring the agent's pane to the front inside Herdr.
    func focus(_ agent: Agent, done: @escaping (String?) -> Void) {
        act(["agent", "focus", agent.id], done: done)
    }

    /// The last non-blank lines of the agent's terminal, so a question can be
    /// answered without switching windows.
    func tail(of agent: Agent, lines: Int = 30, done: @escaping ([String]) -> Void) {
        let selectedSession = session, demoMode = demo
        DispatchQueue.global(qos: .userInitiated).async {
            // A background job asking something: its whole question, options included.
            if !demoMode, agent.status == "blocked", let path = agent.questionTranscript,
               let message = fileTail(path).flatMap({ lastAssistantText(transcriptTail: $0) }) {
                let rows = questionLines(in: message, needs: agent.question)
                if !rows.isEmpty { return DispatchQueue.main.async { done(rows) } }
            }
            let text: String
            if demoMode {
                text = agent.status == "blocked"
                    ? "● Bash(rm -rf build && make)\n  Do you want to proceed?\n❯ 1. Yes\n  2. Yes, and don't ask again\n  3. No, and tell Claude what to do"
                    : "● \(agent.activity)\n  ⎿ Leyendo archivos del proyecto…"
            } else {
                let data = try? runHerdr(["agent", "read", agent.id, "--source", "recent", "--lines", "60", "--format", "text"], session: selectedSession)
                text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            }
            let rows = meaningfulLines(text)
            DispatchQueue.main.async { done(Array(rows.suffix(agent.status == "blocked" ? 12 : lines))) }
        }
    }
}

func demoAgents(tick: Int) -> [Agent] {
    let specs = [("claude", "Website", "working", "Construyendo la página de ajustes"),
                 ("codex", "API service", ["working","blocked","done","idle"][(tick / 10) % 4], "Revisando las pruebas"),
                 ("kiro", "Mobile app", "blocked", "Esperando tu respuesta"),
                 ("claude", "Design system", "idle", "Listo para la próxima tarea"),
                 ("gemini", "Documentation", "done", "Documentación actualizada"),
                 ("codex", "Game engine", "working", "Ajustando el movimiento")]
    let subagents = [2, 0, 0, 0, 0, 5]
    let helpers = [["read", "brew"], [], [], [], [], ["forge", "read", "brew", "gems", "type"]]
    let branches: [String?] = ["main", "feature/tests", nil, "main", "docs", "physics"]
    return specs.enumerated().map { i, s in
        var agent = Agent(id: "demo:\(i)", name: s.0, status: s.2, project: s.1, activity: tr(s.3), cwd: "~/demo/\(s.1.lowercased().replacingOccurrences(of: " ", with: "-"))")
        agent.branch = branches[i]
        if i == 0 { agent.action = ["read", "forge", "brew", "summon", "plan", "type"][(tick / 8) % 6] }   // claude shows each action
        agent.subagentActions = helpers[i]
        return agent.with(subagents: subagents[i])
    }
}

/// The station a tool sends the hero to: reading (also web search and
/// fetch), forging (editing files), brewing (shell commands), summoning
/// (subagents), planning (todo lists and plans) or typing (anything else,
/// and thinking or writing a reply).
func toolAction(_ tool: String) -> String {
    switch tool {
    case "Read", "Grep", "Glob", "LS", "WebSearch", "WebFetch", "NotebookRead": return "read"
    case "Edit", "Write", "MultiEdit", "NotebookEdit": return "forge"
    case "Bash", "BashOutput", "KillShell", "KillBash", "Monitor": return "brew"
    case "Task", "Agent": return "summon"
    case "TodoWrite", "TaskCreate", "TaskUpdate", "TaskList", "ExitPlanMode", "EnterPlanMode": return "plan"
    default: return "type"
    }
}

/// The action of the latest assistant message in the tail of a Claude Code
/// transcript: the last tool it called, or typing when it only wrote text.
/// Only message types and tool names are looked at, never their contents.
func lastAction(transcriptTail text: String) -> String? {
    for line in text.split(separator: "\n").reversed() {
        guard line.contains("\"assistant\""),
              let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              row["type"] as? String == "assistant",
              let content = (row["message"] as? [String: Any])?["content"] as? [[String: Any]] else { continue }
        if let tool = content.last(where: { $0["type"] as? String == "tool_use" })?["name"] as? String { return toolAction(tool) }
        return "type"
    }
    return nil
}

// MARK: Other harnesses

/// The action in a transcript written in the last two minutes, from its
/// tail. Parsed again only when the file changes.
func recentAction(in file: URL?, parse: (String) -> String?) -> String? {
    guard let file = file,
          let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
          modified > Date().addingTimeInterval(-120) else { return nil }
    transcriptActions.lock()
    defer { transcriptActions.unlock() }
    if let cached = transcriptActions.cache[file.path], cached.modified == modified { return cached.action }
    guard let action = fileTail(file.path).flatMap(parse) else { return nil }
    transcriptActions.cache[file.path] = (modified, action)
    return action
}

/// A shell command that only looks at files (the way Codex reads them)
/// counts as reading; anything else is brewing.
func shellAction(_ command: String) -> String {
    let readers: Set<String> = ["cat", "rg", "grep", "sed", "ls", "find", "head", "tail", "nl", "wc", "less", "tree", "fd", "bat", "awk"]
    let first = command.split(whereSeparator: { " ;|&\n".contains($0) }).first.map(String.init) ?? ""
    return readers.contains((first as NSString).lastPathComponent) ? "read" : "brew"
}

/// The action of the latest Codex step in the tail of its rollout
/// (~/.codex/sessions/…/rollout-…-<session>.jsonl): its last tool call, or
/// typing while it reasons or writes.
func codexAction(transcriptTail text: String) -> String? {
    for line in text.split(separator: "\n").reversed() {
        guard line.contains("\"response_item\""),
              let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let item = row["payload"] as? [String: Any], let kind = item["type"] as? String else { continue }
        switch kind {
        case "function_call", "custom_tool_call", "local_shell_call":
            let name = item["name"] as? String ?? "shell"
            switch name {
            case "exec_command", "shell", "local_shell", "container.exec":
                let arguments = (item["arguments"] as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
                let command = arguments?["cmd"] as? String ?? (arguments?["command"] as? [String])?.joined(separator: " ") ?? ""
                return shellAction(command)
            case "apply_patch": return "forge"
            case "update_plan": return "plan"
            case "web_search", "view_image": return "read"
            default: return "type"
            }
        case "web_search_call": return "read"
        case "message", "reasoning": return item["role"] as? String == "user" ? nil : "type"
        default: continue
        }
    }
    return nil
}

/// The action of the latest Kiro reply in the tail of its session
/// (~/.kiro/sessions/cli/<session>.jsonl): its last tool, or typing.
func kiroAction(transcriptTail text: String) -> String? {
    for line in text.split(separator: "\n").reversed() {
        guard line.contains("\"AssistantMessage\""),
              let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let content = (row["data"] as? [String: Any])?["content"] as? [[String: Any]] else { continue }
        guard let tool = content.last(where: { $0["kind"] as? String == "toolUse" })?["data"] as? [String: Any],
              let name = (tool["name"] as? String)?.lowercased() else { return "type" }
        if ["read", "grep", "glob", "ls", "fs_read", "web_search", "web_fetch", "code"].contains(name) { return "read" }
        if ["write", "edit", "fs_write", "str_replace", "create"].contains(name) { return "forge" }
        if ["shell", "execute_bash", "bash"].contains(name) { return "brew" }
        if name.contains("todo") || name.contains("plan") { return "plan" }
        if name.contains("agent") || name.contains("delegate") { return "summon" }
        return "type"
    }
    return nil
}

private final class PathCache: NSLock { var paths: [String: URL] = [:] }
private let transcriptPaths = PathCache()

/// Codex's rollout for a session: an absolute path as given, else the
/// newest `rollout-*-<session>.jsonl` in the last two weeks of day folders.
func codexTranscript(session: String) -> URL? {
    if session.hasPrefix("/") { return URL(fileURLWithPath: session) }
    transcriptPaths.lock()
    defer { transcriptPaths.unlock() }
    if let known = transcriptPaths.paths[session] { return known }
    let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
    let days = DateFormatter()
    days.dateFormat = "yyyy/MM/dd"
    for back in 0..<14 {
        let folder = root.appendingPathComponent(days.string(from: Date().addingTimeInterval(-86_400 * Double(back))))
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { continue }
        if let name = files.filter({ $0.hasSuffix("-\(session).jsonl") }).max() {
            let url = folder.appendingPathComponent(name)
            transcriptPaths.paths[session] = url
            return url
        }
    }
    return nil
}

/// Kiro's session file: an absolute path as given, else ~/.kiro/sessions/cli/<session>.jsonl.
func kiroTranscript(session: String) -> URL? {
    if session.hasPrefix("/") { return URL(fileURLWithPath: session) }
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kiro/sessions/cli/\(session).jsonl")
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
}

/// The last 128 KB of a file, as text.
func fileTail(_ path: String, bytes: UInt64 = 131_072) -> String? {
    guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? handle.close() }
    let size = (try? handle.seekToEnd()) ?? 0
    try? handle.seek(toOffset: size > bytes ? size - bytes : 0)
    return (try? handle.readToEnd()).map { String(decoding: $0, as: UTF8.self) }
}

/// The text of the latest assistant message that has any, in the tail of a
/// Claude Code transcript.
func lastAssistantText(transcriptTail text: String) -> String? {
    for line in text.split(separator: "\n").reversed() {
        guard line.contains("\"assistant\""),
              let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              row["type"] as? String == "assistant",
              let content = (row["message"] as? [String: Any])?["content"] as? [[String: Any]] else { continue }
        let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
        if !text.isEmpty { return text }
    }
    return nil
}

/// The question in an assistant message: from the line that asks it (the
/// job's `needs`, or a "needs input:" line) to the end, so its options come
/// along. Markdown emphasis is dropped; the panel is plain text.
func questionLines(in message: String, needs: String?) -> [String] {
    var lines = message.components(separatedBy: "\n").map { $0.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "") }
    let needle = needs?.trimmingCharacters(in: .whitespaces)
    if let start = lines.lastIndex(where: { line in (needle.map { !$0.isEmpty && line.contains($0) } ?? false) || line.hasPrefix("needs input:") }) {
        lines = Array(lines[start...])
        lines[0] = lines[0].replacingOccurrences(of: "needs input:", with: "").trimmingCharacters(in: .whitespaces)
    } else {
        lines = Array(lines.suffix(8))
    }
    return lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
}

/// The numbered options of the question an agent is asking (the last run of
/// "1. …", "2. …" lines), and which one its terminal highlights with ❯, if
/// any. A highlighted option means the agent shows a menu driven by arrow
/// keys; without one the options are plain text to answer with.
struct MenuOptions: Equatable {
    struct Option: Equatable { let number: Int; let text: String; let line: Int }
    var options: [Option] = []
    var highlighted: Int?    // index into options
    var isMenu: Bool { highlighted != nil }

    init(_ lines: [String]) {
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let match = trimmed.range(of: "^(❯\\s*)?\\d+[.)]\\s+", options: .regularExpression) else { continue }
            let marked = trimmed.hasPrefix("❯")
            let digits = trimmed[match].filter(\.isNumber)
            guard let number = Int(digits) else { continue }
            // A "1." after other options starts a newer question.
            if number == 1 || options.last.map({ number != $0.number + 1 }) == true { options = []; highlighted = nil }
            if marked { highlighted = options.count }
            options.append(Option(number: number, text: String(trimmed[match.upperBound...]), line: i))
        }
    }

    /// The keys that move the terminal's highlight to option `index` and pick it.
    func keys(choosing index: Int) -> [String] {
        let delta = index - (highlighted ?? 0)
        return Array(repeating: delta > 0 ? "down" : "up", count: abs(delta)) + ["enter"]
    }
}

/// The lines of an agent's terminal that say something, without Claude
/// Code's own UI around its input box: status lines (✻ Worked…, ※ recap and
/// their wrapped continuation), the input line and the mode footer. Numbered
/// options stay, even the highlighted one (❯ 1. Yes).
func meaningfulLines(_ text: String) -> [String] {
    var out: [String] = [], skipping = false
    for raw in text.components(separatedBy: "\n") {
        let line = raw.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.range(of: "^[─━═╌┄-]+$", options: .regularExpression) != nil { skipping = false; continue }
        if skipping && line.first?.isWhitespace == true { continue }
        skipping = false
        let option = trimmed.range(of: "^❯?\\s*\\d+\\.\\s", options: .regularExpression) != nil
        let status = ["✻", "✳", "✢", "✽", "✶", "※"].contains { trimmed.hasPrefix($0) }
        let footer = ["⏵", "▶▶", "►", "⏸"].contains { trimmed.hasPrefix($0) }
            || ["? for shortcuts", "shift+tab to cycle", "esc to interrupt"].contains { trimmed.contains($0) }
        if status { skipping = true; continue }
        if footer || (trimmed.hasPrefix("❯") && !option) { continue }
        out.append(line)
    }
    return out
}

/// What a Claude Code session is doing right now, from the last 128 KB of
/// its transcript (~/.claude/projects/<project>/<session>.jsonl), if it was
/// written in the last two minutes.
func currentAction(session: String) -> String? {
    let fm = FileManager.default
    let projects = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    guard let dirs = try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil) else { return nil }
    for dir in dirs {
        let file = dir.appendingPathComponent(session + ".jsonl")
        guard let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { continue }
        guard modified > Date().addingTimeInterval(-120), let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 131_072 ? size - 131_072 : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        return lastAction(transcriptTail: String(decoding: data, as: UTF8.self))
    }
    return nil
}

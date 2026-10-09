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
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

func decodeSnapshot(_ data: Data) throws -> [Agent] {
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
        guard let id = row["pane_id"] as? String, let name = row["agent"] as? String else { continue }
        let cwd = row["foreground_cwd"] as? String ?? row["cwd"] as? String ?? ""
        let raw = row["agent_status"] as? String ?? "unknown"
        let status = ["working", "blocked", "idle", "done"].contains(raw) ? raw : "unknown"
        unique[id] = Agent(id: id, name: name, status: status,
                          project: names[row["workspace_id"] as? String ?? ""] ?? URL(fileURLWithPath: cwd).lastPathComponent,
                          activity: row["terminal_title_stripped"] as? String ?? row["terminal_title"] as? String ?? tr("Sin título de actividad"),
                          cwd: (cwd as NSString).abbreviatingWithTildeInPath,
                          session: (row["agent_session"] as? [String:Any])?["value"] as? String)
    }
    return unique.values.sorted { $0.rank == $1.rank ? $0.id.localizedStandardCompare($1.id) == .orderedAscending : $0.rank < $1.rank }
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
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    let timeout = DispatchWorkItem { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
    DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: timeout)
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    timeout.cancel()
    guard process.terminationStatus == 0 else { throw MonitorError.message(tr("Sin conexión con Herdr. Abre tu sesión; reintentamos automáticamente.")) }
    return data
}

func fetchSnapshot(session: String) throws -> [Agent] {
    let data = try runHerdr(["api", "snapshot"], session: session)
    let jobs = backgroundJobs()
    return try decodeSnapshot(data).map { agent in
        var agent = agent
        let path = (agent.cwd as NSString).expandingTildeInPath
        agent.branch = gitBranch(at: path)
        if agent.name == "claude" { agent = agent.with(jobs: jobs[path] ?? []) }
        guard let session = agent.session else { return agent }
        agent.action = currentAction(session: session)
        let helpers = subagentActions(session: session)
        agent.subagentActions = helpers
        return agent.with(subagents: helpers.count)
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
    @Published var selected: String? { didSet { if selected != oldValue { onChange?() } } }
    let session = ProcessInfo.processInfo.environment["HERDR_SESSION"] ?? "default"
    private var busy = false
    private var timer: Timer?
    private var tick = 0
    private var generation = 0
    var onChange: (() -> Void)?
    var onAlerts: (([AgentAlert]) -> Void)?
    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }
    func setDemo(_ enabled: Bool) {
        generation += 1; demo = enabled; agents = []; events = []; updated = nil; error = nil
        onChange?(); refresh()
    }
    func apply(_ next: [Agent]) {
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
    func refresh() {
        guard !busy else { return }
        busy = true
        let currentGeneration = generation, demoMode = demo, currentTick = tick, selectedSession = session
        tick += 1
        DispatchQueue.global(qos: .utility).async {
            let result = Result { demoMode ? demoAgents(tick: currentTick) : try fetchSnapshot(session: selectedSession) }
            DispatchQueue.main.async {
                self.busy = false
                guard currentGeneration == self.generation else { self.refresh(); return }
                switch result {
                case .success(let agents): self.apply(agents)
                case .failure(let error): self.error = error.localizedDescription
                }
                self.onChange?()
            }
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
            act(["agent", "prompt", agent.id, message, "--timeout", "4000"], done: log)
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

    /// Bring the agent's pane to the front inside Herdr.
    func focus(_ agent: Agent, done: @escaping (String?) -> Void) {
        act(["agent", "focus", agent.id], done: done)
    }

    /// The last non-blank lines of the agent's terminal, so a question can be
    /// answered without switching windows.
    func tail(of agent: Agent, lines: Int = 6, done: @escaping ([String]) -> Void) {
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

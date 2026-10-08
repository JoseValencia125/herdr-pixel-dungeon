import Foundation
import SwiftUI
import Darwin

struct Agent: Identifiable, Equatable {
    let id: String
    let name: String
    let status: String
    let project: String
    let activity: String
    let cwd: String
    var label: String { ["working":"Trabajando", "blocked":"Necesita atención", "idle":"En espera", "done":"Terminó"][status] ?? "Sin estado" }
    var color: Color { switch status { case "working": return Color(red: 0.7, green: 0.85, blue: 0.55); case "blocked": return .orange; case "done": return .cyan; case "idle": return .purple; default: return .gray } }
    var rank: Int { ["blocked":0,"working":1,"idle":2,"done":3][status] ?? 4 }
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
        throw MonitorError.message("Herdr no entregó un snapshot válido.")
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
                          activity: row["terminal_title_stripped"] as? String ?? row["terminal_title"] as? String ?? "Sin título de actividad",
                          cwd: (cwd as NSString).abbreviatingWithTildeInPath)
    }
    return unique.values.sorted { $0.rank == $1.rank ? $0.id.localizedStandardCompare($1.id) == .orderedAscending : $0.rank < $1.rank }
}

func fetchSnapshot(session: String) throws -> [Agent] {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let pathCandidates = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/herdr" }
    let candidates = [ProcessInfo.processInfo.environment["HERDR_BIN"], home + "/.local/bin/herdr", "/opt/homebrew/bin/herdr", "/usr/local/bin/herdr"].compactMap { $0 } + pathCandidates
    guard let binary = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
        throw MonitorError.message("No se encontró Herdr. Instálalo o define HERDR_BIN.")
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = (session == "default" ? [] : ["--session", session]) + ["api", "snapshot"]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    let timeout = DispatchWorkItem { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
    DispatchQueue.global().asyncAfter(deadline: .now() + 4, execute: timeout)
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    timeout.cancel()
    guard process.terminationStatus == 0 else { throw MonitorError.message("Sin conexión con Herdr. Abre tu sesión; reintentamos automáticamente.") }
    return try decodeSnapshot(data)
}

struct GuildEvent: Identifiable {
    let id = UUID()
    let at = Date()
    let text: String
}

final class Monitor: ObservableObject {
    @Published var agents: [Agent] = []
    @Published var error: String?
    @Published var updated: Date?
    @Published var events: [GuildEvent] = []
    @Published var demo = false
    let session = ProcessInfo.processInfo.environment["HERDR_SESSION"] ?? "default"
    private var busy = false
    private var timer: Timer?
    private var tick = 0
    private var generation = 0
    var onChange: (() -> Void)?
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
        if updated == nil { events.insert(GuildEvent(text: "Guild conectada · \(next.count) agentes"), at: 0) }
        else {
            for agent in next {
                if let old = previous[agent.id] {
                    if old.status != agent.status { events.insert(GuildEvent(text: "\(agent.project) · \(agent.label)"), at: 0) }
                } else { events.insert(GuildEvent(text: "\(agent.project) entró a la guild"), at: 0) }
            }
            for agent in agents where !ids.contains(agent.id) { events.insert(GuildEvent(text: "\(agent.project) salió de la guild"), at: 0) }
        }
        events = Array(events.prefix(40)); agents = next; updated = Date(); error = nil
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

func demoAgents(tick: Int) -> [Agent] {
    let specs = [("claude", "Website", "working", "Construyendo la página de ajustes"),
                 ("codex", "API service", ["working","blocked","done","idle"][(tick / 10) % 4], "Revisando las pruebas"),
                 ("kiro", "Mobile app", "blocked", "Esperando tu respuesta"),
                 ("claude", "Design system", "idle", "Listo para la próxima tarea"),
                 ("gemini", "Documentation", "done", "Documentación actualizada"),
                 ("codex", "Game engine", "working", "Ajustando el movimiento")]
    return specs.enumerated().map { i, s in Agent(id: "demo:\(i)", name: s.0, status: s.2, project: s.1, activity: s.3, cwd: "~/demo/\(s.1)") }
}

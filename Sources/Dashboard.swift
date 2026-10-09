import Cocoa
import SwiftUI
import SpriteKit

final class SceneStore: ObservableObject {
    let scene = DungeonScene(size: CGSize(width: 1000, height: 620))
}

struct Dashboard: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject var sounds: SoundAlerts
    @StateObject private var world = SceneStore()
    @State private var paused = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    @State private var hovering = false
    @State private var showLog = false
    var onMinimize: () -> Void = {}
    var onClose: () -> Void = {}
    var body: some View {
        ZStack(alignment:.topTrailing) {
            VStack(spacing:0) {
                TimelineView(.periodic(from:.now,by:1)) { clock in
                    let note = connectionNote(error:monitor.error,updated:monitor.updated,now:clock.date)
                    SpriteView(scene:world.scene,preferredFramesPerSecond:30,options:[.ignoresSiblingOrder])
                        .frame(maxWidth:.infinity,maxHeight:.infinity)
                        .background(Color(red:0.05,green:0.06,blue:0.065))
                        // The last known rooms stay, faded, while the data is not live.
                        .saturation(note == nil ? 1 : 0.35)
                        .opacity(note == nil ? 1 : 0.75)
                        .overlay(alignment:.top) { if let note = note { ConnectionBanner(text:note.text,lost:note.lost) } }
                }
                if monitor.showsHUD { HUD(monitor:monitor,onLog:{showLog.toggle()}) }
                if monitor.composing {
                    NewAgentPanel(monitor:monitor)
                        .transition(.move(edge:.bottom).combined(with:.opacity))
                } else if let agent = monitor.agents.first(where:{$0.id == monitor.selected}) {
                    ChatPanel(monitor:monitor,agent:agent,onClose:{monitor.selected=nil})
                        .id(agent.id)
                        .transition(.move(edge:.bottom).combined(with:.opacity))
                }
            }
            controls
                .padding(6)
                .opacity(hovering || showLog ? 1 : 0)
            if showLog {
                ActivityLog(events:monitor.events,onClose:{showLog=false})
                    .padding(.top,38).padding(.trailing,8)
                    .transition(.opacity)
            }
            DragHandle()
                .frame(maxWidth:.infinity,alignment:.top)
            ResizeGrip()
                .frame(width:14,height:14)
                .opacity(hovering ? 1 : 0)
                .frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.bottomTrailing)
        }
        .preferredColorScheme(.dark)
        .onHover { hovering = $0 }
        .onAppear {
            // Clicking a room opens its chat panel; clicking it again closes it.
            world.scene.onSelect={id in monitor.selected = monitor.selected == id ? nil : id}
            world.scene.onFinish={id in
                guard let agent = monitor.agents.first(where: { $0.id == id }) else { return }
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = tr("¿Finalizar %@?", agent.project)
                alert.informativeText = tr("Se escribirá /exit en su chat de Herdr.")
                alert.alertStyle = .warning
                // Return cancels: ending an agent needs an explicit click.
                let finish = alert.addButton(withTitle: tr("Finalizar"))
                finish.keyEquivalent = ""
                finish.hasDestructiveAction = true
                alert.addButton(withTitle: tr("Cancelar")).keyEquivalent = "\r"
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                monitor.finish(agent) { failure in if failure != nil { NSSound.beep() } }
            }
            sync();world.scene.reducedMotion=paused;world.scene.selected=monitor.selected
        }
        .onChange(of:monitor.agents) { _ in sync() }
        .onChange(of:monitor.filter) { _ in sync() }
        .onChange(of:monitor.query) { _ in sync() }
        .onChange(of:monitor.error) { _ in sync() }
        .onChange(of:monitor.selected) { world.scene.selected=$0 }
        .onChange(of:paused) { world.scene.reducedMotion=$0 }
    }
    /// Show the rooms that pass the HUD's filter. The column count follows
    /// every agent, so filtering never makes the widget jump in width.
    private func sync() {
        world.scene.emptyText = !monitor.agents.isEmpty ? tr("Ningún agente coincide")
            : monitor.error != nil ? tr("Esperando a Herdr…") : tr("Sin agentes en la sesión")
        world.scene.sync(monitor.visibleAgents)
    }

    private var controls: some View {
        HStack(spacing:7) {
            Button { monitor.composing.toggle() } label: {
                Image(systemName:"plus.circle.fill").font(.system(size:14))
                    .foregroundStyle(Color(red:0.55,green:0.85,blue:0.45))
                    .frame(width:17,height:15)
            }
            .buttonStyle(.plain)
            .help(tr("Invocar un agente nuevo"))
            Button { showLog.toggle() } label: {
                Image(systemName:"scroll.fill").font(.system(size:13))
                    .foregroundStyle(Color(red:0.93,green:0.84,blue:0.62).opacity(showLog ? 1 : 0.85))
                    .frame(width:17,height:15)
            }
            .buttonStyle(.plain)
            .help(tr("Registro de actividad"))
            Button { sounds.enabled.toggle() } label: {
                Image(systemName:sounds.enabled ? "speaker.wave.2.fill" : "speaker.slash.fill").font(.system(size:13))
                    .foregroundStyle(sounds.enabled ? Color.white.opacity(0.85) : Color.white.opacity(0.45))
                    .frame(width:17,height:15)
            }
            .buttonStyle(.plain)
            .help(sounds.enabled ? tr("Silenciar sonidos") : tr("Activar sonidos"))
            Button(action:onMinimize) {
                Image(systemName:"minus.circle.fill").font(.system(size:15))
                    .foregroundStyle(Color(red:0.98,green:0.74,blue:0.18))
            }
            .buttonStyle(.plain)
            .help(tr("Minimizar (ocultar)"))
            Button(action:onClose) {
                Image(systemName:"xmark.circle.fill").font(.system(size:15))
                    .foregroundStyle(Color(red:0.95,green:0.33,blue:0.30))
            }
            .buttonStyle(.plain)
            .help(tr("Cerrar"))
        }
        .padding(5)
        .background(.black.opacity(0.35),in:Capsule())
    }
}

/// The guild's activity log on a parchment: who joined or left, state
/// changes, subagents and messages you sent, newest first, with the time.
/// Kept in memory only (the last 40 lines).
struct ActivityLog: View {
    let events: [GuildEvent]
    var onClose: () -> Void
    private static let ink = Color(red:0.24,green:0.15,blue:0.08)
    private static let clock: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()

    var body: some View {
        VStack(alignment:.leading,spacing:6) {
            HStack {
                Text(tr("Registro de la guild")).font(.system(size:12,weight:.heavy,design:.monospaced))
                Spacer()
                Button(action:onClose) { Image(systemName:"xmark").font(.system(size:10,weight:.bold)) }
                    .buttonStyle(.plain).help(tr("Cerrar"))
            }
            Rectangle().fill(ActivityLog.ink.opacity(0.35)).frame(height:1)
            if events.isEmpty {
                Text(tr("Aún no pasa nada.")).font(.system(size:10,design:.monospaced)).opacity(0.7)
            } else {
                ScrollView {
                    VStack(alignment:.leading,spacing:4) {
                        ForEach(events) { event in
                            HStack(alignment:.firstTextBaseline,spacing:5) {
                                Text(ActivityLog.clock.string(from:event.at)).opacity(0.6)
                                Rectangle().fill(ActivityLog.tint(event.tone)).frame(width:6,height:6)
                                Text(event.text).fixedSize(horizontal:false,vertical:true)
                            }
                        }
                    }
                    .frame(maxWidth:.infinity,alignment:.leading)
                }
            }
        }
        .font(.system(size:10,design:.monospaced))
        .foregroundStyle(ActivityLog.ink)
        .padding(10)
        .frame(width:280)
        .frame(maxHeight:260)
        .fixedSize(horizontal:false,vertical:true)
        .background(Color(red:0.93,green:0.85,blue:0.66),in:RoundedRectangle(cornerRadius:4))
        .overlay(RoundedRectangle(cornerRadius:4).stroke(Color(red:0.45,green:0.29,blue:0.14),lineWidth:2))
        .shadow(color:.black.opacity(0.5),radius:6,y:2)
    }

    static func tint(_ tone: String) -> Color {
        switch tone {
        case "blocked": return .red
        case "working": return .orange
        case "done", "joined": return Color(red:0.15,green:0.6,blue:0.25)
        case "left", "idle": return .gray
        case "subagents": return .purple
        case "message": return .blue
        default: return Color(red:0.45,green:0.29,blue:0.14)
        }
    }
}

/// A pixel banner over the rooms while Herdr is unreachable or the data is
/// stale; reconnection keeps being retried in the background.
struct ConnectionBanner: View {
    let text: String
    let lost: Bool
    var body: some View {
        HStack(spacing:6) {
            Image(systemName:lost ? "bolt.horizontal.circle.fill" : "hourglass").font(.system(size:11,weight:.bold))
            Text(text).font(.system(size:10,weight:.bold,design:.monospaced)).lineLimit(1).minimumScaleFactor(0.7)
        }
        .foregroundStyle(Color.white)
        .padding(.horizontal,8).frame(height:22)
        .background((lost ? Color(red:0.6,green:0.12,blue:0.14) : Color(red:0.55,green:0.36,blue:0.08)).opacity(0.95),in:RoundedRectangle(cornerRadius:3))
        .overlay(RoundedRectangle(cornerRadius:3).stroke(Color.black.opacity(0.6),lineWidth:2))
        .padding(.top,16).padding(.horizontal,10)
        .help(lost ? tr("Reintentando la conexión automáticamente.") : tr("Herdr no ha entregado datos nuevos."))
    }
}

/// Bar under the rooms: one chip per state (with its count) to filter the
/// rooms, and a search box over project, harness, branch, folder and activity.
struct HUD: View {
    static let height: CGFloat = 28
    @ObservedObject var monitor: Monitor
    var onLog: () -> Void = {}
    @State private var searching = false
    @FocusState private var typing: Bool

    var body: some View {
        HStack(spacing:4) {
            ForEach(StatusFilter.allCases,id:\.self) { chip($0) }
            Spacer(minLength:2)
            if searching || !monitor.query.isEmpty {
                TextField(tr("Buscar…"),text:$monitor.query)
                    .textFieldStyle(.plain)
                    .font(.system(size:11,design:.monospaced))
                    .focused($typing)
                    .onExitCommand { monitor.query = ""; searching = false }
                    .padding(.horizontal,5).frame(height:19)
                    .background(Color.black.opacity(0.5),in:RoundedRectangle(cornerRadius:3))
                    .overlay(RoundedRectangle(cornerRadius:3).stroke(Color.white.opacity(0.25),lineWidth:1))
                    .frame(maxWidth:140)
                    .onAppear {
                        // Typing needs the widget to be the key window.
                        NSApp.windows.first { $0 is WidgetPanel }?.makeKey()
                        typing = true
                    }
            }
            Button(action:onLog) {
                Image(systemName:"scroll.fill").font(.system(size:11))
                    .foregroundStyle(Color(red:0.93,green:0.84,blue:0.62).opacity(0.85)).frame(width:16,height:16)
            }
            .buttonStyle(.plain)
            .help(tr("Registro de actividad"))
            Button { if searching || !monitor.query.isEmpty { monitor.query = ""; searching = false } else { searching = true } } label: {
                Image(systemName:searching || !monitor.query.isEmpty ? "xmark.circle.fill" : "magnifyingglass")
                    .font(.system(size:11,weight:.bold)).foregroundStyle(Color.white.opacity(0.75)).frame(width:16,height:16)
            }
            .buttonStyle(.plain)
            .help(searching ? tr("Cerrar búsqueda (esc)") : tr("Buscar por proyecto, agente, rama, carpeta o actividad"))
        }
        .padding(.horizontal,8)
        .frame(height:HUD.height)
        .background(Color(red:0.075,green:0.065,blue:0.09))
        .overlay(Rectangle().fill(Color.white.opacity(0.08)).frame(height:1),alignment:.top)
    }

    private func chip(_ filter: StatusFilter) -> some View {
        let count = filter == .all ? monitor.agents.count : monitor.agents.filter(filter.admits).count
        let on = monitor.filter == filter
        // Agents asking for help keep the chip lit red whatever the filter.
        let alarm = filter == .blocked && count > 0
        let tint = HUD.tint(filter)
        let fill: Color = alarm ? Color.red.opacity(on ? 0.75 : 0.45) : on ? tint.opacity(filter == .all ? 0.2 : 0.4) : Color.black.opacity(0.35)
        let edge: Color = on ? Color.white.opacity(0.7) : alarm ? Color.red : Color.white.opacity(0.15)
        let ink: Color = alarm || on ? Color.white : Color.white.opacity(0.6)
        return Button { monitor.filter = on && filter != .all ? .all : filter } label: {
            HStack(spacing:3) {
                chipIcon(filter,tint:tint)
                Text("\(count)")
            }
            .font(.system(size:10,weight:.bold,design:.monospaced))
            .foregroundStyle(ink)
            .padding(.horizontal,5).frame(height:18)
            .background(fill,in:RoundedRectangle(cornerRadius:3))
            .overlay(RoundedRectangle(cornerRadius:3).stroke(edge,lineWidth:1))
        }
        .buttonStyle(.plain)
        .help(HUD.name(filter))
    }

    @ViewBuilder private func chipIcon(_ filter: StatusFilter, tint: Color) -> some View {
        switch filter {
        case .all: Text(tr("Todos"))
        case .blocked: Text("!").fontWeight(.heavy)
        default: Rectangle().fill(tint).frame(width:6,height:6)
        }
    }

    static func tint(_ filter: StatusFilter) -> Color {
        switch filter {
        case .blocked: return .red
        case .working: return .orange
        case .idle: return .gray
        case .done: return .green
        case .all: return .white
        }
    }

    static func name(_ filter: StatusFilter) -> String {
        switch filter {
        case .all: return tr("Todos")
        case .blocked: return tr("Necesita atención")
        case .working: return tr("Trabajando")
        case .idle: return tr("En espera")
        case .done: return tr("Listo")
        }
    }
}

/// Opens under the rooms when one is clicked: the tail of the agent's
/// terminal, quick answers for a permission prompt, and a box to type to it.
struct ChatPanel: View {
    static let height: CGFloat = 220
    @ObservedObject var monitor: Monitor
    let agent: Agent
    var onClose: () -> Void
    @State private var draft = ""
    @State private var lines: [String] = []
    @State private var note: String?
    @State private var sending = false
    @State private var keys: Any?
    @State private var choice: Int?   // option picked with ↑/↓ or a click, into `menu.options`
    @StateObject private var route = KeyRoute()
    @FocusState private var typing: Bool

    var body: some View {
        VStack(alignment:.leading,spacing:7) {
            HStack(spacing:6) {
                Circle().fill(agent.color).frame(width:8,height:8)
                Text(agent.name).font(.system(size:12,weight:.bold,design:.monospaced))
                Text("\(agent.project) · \(agent.label)").font(.system(size:11,design:.monospaced))
                    .foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button { run { monitor.focus(agent,done:$0) } } label: { Image(systemName:"macwindow.and.cursorarrow") }
                    .buttonStyle(.plain).help(tr("Enfocar este agente en Herdr"))
                Button(action:onClose) { Image(systemName:"xmark") }
                    .buttonStyle(.plain).keyboardShortcut(.cancelAction).help("Cerrar (esc)")
            }
            Group {
                if agent.status == "blocked" && !lines.isEmpty {
                    // A question: show all of it, wrapped and scrollable, asked line first.
                    ScrollView {
                        VStack(alignment:.leading,spacing:2) {
                            ForEach(Array(lines.enumerated()),id:\.offset) { i,line in
                                let option = menu.options.firstIndex { $0.line == i }
                                let picked = option != nil && option == choice
                                Text(line).fontWeight(picked || (i == 0 && agent.question != nil) ? .bold : .regular)
                                    .foregroundStyle(picked || (i == 0 && agent.question != nil) ? Color.white : Color(white:0.85))
                                    .fixedSize(horizontal:false,vertical:true)
                                    .frame(maxWidth:.infinity,alignment:.leading)
                                    .background(picked ? agent.color.opacity(0.35) : Color.clear,in:RoundedRectangle(cornerRadius:3))
                                    .contentShape(Rectangle())
                                    .onTapGesture { if let option = option { pick(option) } }
                            }
                        }
                        .frame(maxWidth:.infinity,alignment:.leading)
                    }
                } else {
                    VStack(alignment:.leading,spacing:1) {
                        ForEach(Array(lines.enumerated()),id:\.offset) { _,line in
                            Text(line).lineLimit(1).truncationMode(.tail)
                        }
                        if lines.isEmpty { Text(tr("Leyendo la terminal…")).foregroundStyle(.secondary) }
                    }
                }
            }
            .font(.system(size:10,design:.monospaced))
            .foregroundStyle(Color(white:0.85))
            .frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.bottomLeading)
            .padding(6)
            .background(Color.black.opacity(0.45),in:RoundedRectangle(cornerRadius:5))
            HStack(spacing:6) {
                TextField(agent.status == "blocked" ? tr("↑↓ y ⏎ eligen · o responde a %@…", agent.name) : tr("Escribir a %@…", agent.name),text:$draft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size:12))
                    .focused($typing)
                    .onSubmit(submit)
                    .disabled(sending)
                Button(action:submit) { Image(systemName:"paperplane.fill") }
                    .buttonStyle(.borderless).disabled(sending || draft.trimmingCharacters(in:.whitespaces).isEmpty)
                    .help(tr("Enviar (⏎)"))
                if agent.status == "blocked" {
                    Button(tr("Aceptar")) { if let choice = choice { answer(choice) } else { run { monitor.press(["enter"],on:agent,done:$0) } } }
                        .help(tr("Elegir la opción marcada del agente (⏎ en su terminal)"))
                    Button(tr("Rechazar")) { run { monitor.press(["esc"],on:agent,done:$0) } }
                        .help(tr("Cancelar la petición del agente (esc en su terminal)"))
                } else if agent.status == "working" {
                    Button(tr("Detener")) { run { monitor.press(["esc"],on:agent,done:$0) } }
                        .help(tr("Interrumpir al agente (esc en su terminal)"))
                }
            }
            .controlSize(.small)
            if let note = note {
                Text(note).font(.system(size:10)).foregroundStyle(.orange).lineLimit(1)
            }
        }
        .padding(.horizontal,10).padding(.vertical,8)
        .frame(height:ChatPanel.height)
        .background(Color(red:0.09,green:0.08,blue:0.11))
        .overlay(Rectangle().fill(agent.color.opacity(0.7)).frame(height:1),alignment:.top)
        .onAppear { typing = true; route.agent = agent; installKeys() }
        .onDisappear { if let keys = keys { NSEvent.removeMonitor(keys) }; keys = nil }
        .onChange(of:agent) { route.agent = $0 }
        .onChange(of:draft) { route.draftEmpty = $0.trimmingCharacters(in:.whitespaces).isEmpty }
        .onChange(of:lines) { _ in if let c = choice, c >= menu.options.count { choice = nil } }
        // Keep the terminal tail fresh while the panel is open.
        .task(id:agent.status) {
            while !Task.isCancelled {
                monitor.tail(of:agent) { lines = $0 }
                try? await Task.sleep(nanoseconds:2_000_000_000)
            }
        }
    }

    /// While the agent is asking something, ↑/↓ move its highlighted option
    /// and ⏎ (with nothing typed) picks it, as in its own terminal.
    private func installKeys() {
        guard keys == nil else { return }
        let route = route, monitor = monitor
        keys = NSEvent.addLocalMonitorForEvents(matching:.keyDown) { event in
            guard let agent = route.agent, agent.status == "blocked",
                  event.modifierFlags.intersection([.command,.option,.control]).isEmpty else { return event }
            let key: String
            switch event.keyCode {
            case 126 where route.move?(-1) == true, 125 where route.move?(1) == true: return nil
            case 126: key = "up"
            case 125: key = "down"
            case 36 where route.draftEmpty, 76 where route.draftEmpty: key = "enter"
            default: return event
            }
            monitor.press([key],on:agent) { _ in monitor.tail(of:agent) { route.lines?($0) } }
            return nil
        }
        route.lines = { lines = $0 }
        route.move = { delta in
            let options = menu.options
            guard !options.isEmpty else { return false }
            let start = choice ?? menu.highlighted ?? (delta > 0 ? -1 : options.count)
            pick(min(max(start + delta, 0), options.count - 1))
            return true
        }
    }

    /// The options of the question the agent is asking, if it is asking one.
    private var menu: MenuOptions { agent.status == "blocked" ? MenuOptions(lines) : MenuOptions([]) }

    /// Highlight an option and put its text in the box, ready to send with ⏎.
    private func pick(_ index: Int) {
        choice = index
        draft = menu.options[index].text
        typing = true
    }

    /// Answer with an option: a terminal menu gets the arrows that reach it
    /// and ⏎; a question asked in plain text gets the option's text.
    private func answer(_ index: Int) {
        let options = menu
        guard options.options.indices.contains(index) else { return }
        choice = nil
        if options.isMenu {
            run { done in monitor.press(options.keys(choosing:index),on:agent) { failure in if failure == nil { draft = "" }; done(failure) } }
        } else {
            draft = options.options[index].text
            submitText()
        }
    }

    private func submit() {
        if let choice = choice, menu.options.indices.contains(choice), draft == menu.options[choice].text { return answer(choice) }
        choice = nil
        submitText()
    }

    private func submitText() {
        let text = draft
        guard !sending, !text.trimmingCharacters(in:.whitespaces).isEmpty else { return }
        run { done in monitor.send(text,to:agent) { failure in if failure == nil { draft = "" }; done(failure) } }
    }

    /// Run an action, lock the controls meanwhile, then refresh the tail.
    private func run(_ action: (@escaping (String?) -> Void) -> Void) {
        sending = true; note = nil
        action { failure in
            sending = false; note = failure; typing = true
            DispatchQueue.main.asyncAfter(deadline:.now() + 0.6) { monitor.tail(of:agent) { lines = $0 } }
        }
    }
}

/// Grab bar centred at the top of the widget. The SpriteKit scene takes every
/// click, so the window would otherwise be hard to move; this hands the drag
/// to AppKit's native window drag.
struct DragHandle: View {
    @State private var hovering = false
    var body: some View {
        ZStack {
            Capsule()
                .fill(Color.white.opacity(hovering ? 0.75 : 0.35))
                .frame(width:hovering ? 64 : 48,height:5)
                .shadow(color:.black.opacity(0.6),radius:1)
            WindowDragArea()
        }
        .frame(width:160,height:14)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration:0.12),value:hovering)
        .help(tr("Arrastrar para mover"))
    }
}

private struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Opens under the rooms from the + button: pick a harness, a folder (one
/// of the agents' or any other) and an optional first prompt, and Herdr
/// starts the agent in a new workspace there.
struct NewAgentPanel: View {
    @ObservedObject var monitor: Monitor
    @AppStorage("create.kind") private var kind = "claude"
    @AppStorage("create.folder") private var folder = ""
    @State private var prompt = ""
    @State private var busy = false
    @State private var note: String?

    var body: some View {
        VStack(alignment:.leading,spacing:7) {
            HStack(spacing:6) {
                Image(systemName:"plus.circle.fill").foregroundStyle(Color(red:0.55,green:0.85,blue:0.45))
                Text(tr("Invocar un agente")).font(.system(size:12,weight:.bold,design:.monospaced))
                Spacer()
                Button { monitor.composing = false } label: { Image(systemName:"xmark") }
                    .buttonStyle(.plain).keyboardShortcut(.cancelAction).help(tr("Cerrar"))
            }
            HStack(spacing:6) {
                Picker("",selection:$kind) { ForEach(creatableKinds,id:\.self) { Text($0).tag($0) } }
                    .labelsHidden().frame(width:96)
                Menu {
                    ForEach(knownFolders,id:\.self) { path in Button(path) { folder = path } }
                    if !knownFolders.isEmpty { Divider() }
                    Button(tr("Elegir carpeta…"),action:chooseFolder)
                } label: {
                    Text(folder.isEmpty ? tr("Carpeta…") : (folder as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.head)
                }
                .help(folder)
            }
            ZStack(alignment:.topLeading) {
                TextEditor(text:$prompt)
                    .font(.system(size:11,design:.monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(3)
                if prompt.isEmpty {
                    Text(tr("Primer prompt (opcional)")).font(.system(size:11,design:.monospaced)).foregroundStyle(.secondary)
                        .padding(.horizontal,8).padding(.vertical,3).allowsHitTesting(false)
                }
            }
            .background(Color.black.opacity(0.45),in:RoundedRectangle(cornerRadius:5))
            HStack(spacing:6) {
                if busy { ProgressView().controlSize(.small); Text(tr("Invocando…")).font(.system(size:10)).foregroundStyle(.secondary) }
                else if let note = note { Text(note).font(.system(size:10)).foregroundStyle(.orange).lineLimit(2) }
                Spacer()
                Button(tr("Invocar"),action:create)
                    .keyboardShortcut(.return,modifiers:.command)
                    .disabled(busy || folder.isEmpty)
                    .help(tr("Crear el agente (⌘⏎)"))
            }
            .controlSize(.small)
        }
        .padding(.horizontal,10).padding(.vertical,8)
        .frame(height:ChatPanel.height)
        .background(Color(red:0.09,green:0.08,blue:0.11))
        .overlay(Rectangle().fill(Color(red:0.55,green:0.85,blue:0.45).opacity(0.7)).frame(height:1),alignment:.top)
        .onAppear { if folder.isEmpty { folder = knownFolders.first ?? "" } }
    }

    /// Folders the current agents work in, most common first.
    private var knownFolders: [String] {
        let paths = monitor.agents.map { ($0.cwd as NSString).expandingTildeInPath }
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    private func chooseFolder() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if !folder.isEmpty { panel.directoryURL = URL(fileURLWithPath: folder) }
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
    }

    private func create() {
        busy = true; note = nil
        monitor.create(kind:kind,folder:folder,prompt:prompt) { failure in
            busy = false
            if let failure = failure { note = failure } else { prompt = ""; monitor.composing = false }
        }
    }
}

/// Pixel grip in the bottom-right corner: drag it to resize the widget
/// (the edges work too). The app delegate snaps the result to whole rooms.
struct ResizeGrip: NSViewRepresentable {
    static let began = Notification.Name("ResizeGrip.began")
    static let ended = Notification.Name("ResizeGrip.ended")

    final class GripView: NSView {
        private var start: (frame: NSRect, mouse: NSPoint)?
        override var mouseDownCanMoveWindow: Bool { false }
        override func mouseDown(with event: NSEvent) {
            guard let window = window else { return }
            start = (window.frame, NSEvent.mouseLocation)
            NotificationCenter.default.post(name: ResizeGrip.began, object: nil)
        }
        override func mouseDragged(with event: NSEvent) {
            guard let window = window, let start = start else { return }
            let mouse = NSEvent.mouseLocation
            let width = max(window.minSize.width, start.frame.width + mouse.x - start.mouse.x)
            let height = max(window.minSize.height, start.frame.height - (mouse.y - start.mouse.y))
            window.setFrame(NSRect(x: start.frame.minX, y: start.frame.maxY - height, width: width, height: height), display: true)
        }
        override func mouseUp(with event: NSEvent) {
            start = nil
            NotificationCenter.default.post(name: ResizeGrip.ended, object: nil)
        }
        override func draw(_ dirtyRect: NSRect) {
            // Three steps of pixels down the diagonal.
            NSColor(white: 1, alpha: 0.55).setFill()
            for (x, y) in [(10, 2), (6, 2), (10, 6), (2, 2), (6, 6), (10, 10)] { NSRect(x: x, y: y, width: 2, height: 2).fill() }
        }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    }
    func makeNSView(context: Context) -> NSView { GripView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Shared state the panel's key monitor reads: the closure outlives the view
/// value, so it cannot read the view's @State directly.
final class KeyRoute: ObservableObject {
    var agent: Agent?
    var draftEmpty = true
    var move: ((Int) -> Bool)?   // ↑/↓ over a question's options; false when it has none
    var lines: (([String]) -> Void)?
}

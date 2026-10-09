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
    var onMinimize: () -> Void = {}
    var onClose: () -> Void = {}
    var body: some View {
        ZStack(alignment:.topTrailing) {
            VStack(spacing:0) {
                SpriteView(scene:world.scene,preferredFramesPerSecond:30,options:[.ignoresSiblingOrder])
                    .frame(maxWidth:.infinity,maxHeight:.infinity)
                    .background(Color(red:0.05,green:0.06,blue:0.065))
                if let agent = monitor.agents.first(where:{$0.id == monitor.selected}) {
                    ChatPanel(monitor:monitor,agent:agent,onClose:{monitor.selected=nil})
                        .id(agent.id)
                        .transition(.move(edge:.bottom).combined(with:.opacity))
                }
            }
            controls
                .padding(6)
                .opacity(hovering ? 1 : 0)
            DragHandle()
                .frame(maxWidth:.infinity,alignment:.top)
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
            world.scene.sync(monitor.agents);world.scene.reducedMotion=paused;world.scene.selected=monitor.selected
        }
        .onChange(of:monitor.agents) { world.scene.sync($0) }
        .onChange(of:monitor.selected) { world.scene.selected=$0 }
        .onChange(of:paused) { world.scene.reducedMotion=$0 }
    }
    private var controls: some View {
        HStack(spacing:7) {
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

/// Shared state the panel's key monitor reads: the closure outlives the view
/// value, so it cannot read the view's @State directly.
final class KeyRoute: ObservableObject {
    var agent: Agent?
    var draftEmpty = true
    var move: ((Int) -> Bool)?   // ↑/↓ over a question's options; false when it has none
    var lines: (([String]) -> Void)?
}

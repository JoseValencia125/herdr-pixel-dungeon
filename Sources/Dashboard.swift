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
    static let height: CGFloat = 178
    @ObservedObject var monitor: Monitor
    let agent: Agent
    var onClose: () -> Void
    @State private var draft = ""
    @State private var lines: [String] = []
    @State private var note: String?
    @State private var sending = false
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
            VStack(alignment:.leading,spacing:1) {
                ForEach(Array(lines.enumerated()),id:\.offset) { _,line in
                    Text(line).lineLimit(1).truncationMode(.tail)
                }
                if lines.isEmpty && agent.foreground { Text(tr("Leyendo la terminal…")).foregroundStyle(.secondary) }
                if !agent.foreground {
                    Text(tr("Este chat no está abierto en su panel. Ábrelo en Claude para responderle.")).foregroundStyle(.secondary)
                }
            }
            .font(.system(size:10,design:.monospaced))
            .foregroundStyle(Color(white:0.85))
            .frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.bottomLeading)
            .padding(6)
            .background(Color.black.opacity(0.45),in:RoundedRectangle(cornerRadius:5))
            HStack(spacing:6) {
                TextField(agent.status == "blocked" ? tr("Responder a %@…", agent.name) : tr("Escribir a %@…", agent.name),text:$draft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size:12))
                    .focused($typing)
                    .onSubmit(submit)
                    .disabled(sending)
                Button(action:submit) { Image(systemName:"paperplane.fill") }
                    .buttonStyle(.borderless).disabled(sending || draft.trimmingCharacters(in:.whitespaces).isEmpty)
                    .help(tr("Enviar (⏎)"))
                if agent.status == "blocked" {
                    Button(tr("Aceptar")) { run { monitor.press(["enter"],on:agent,done:$0) } }
                        .help(tr("Elegir la opción marcada del agente (⏎ en su terminal)"))
                    Button(tr("Rechazar")) { run { monitor.press(["esc"],on:agent,done:$0) } }
                        .help(tr("Cancelar la petición del agente (esc en su terminal)"))
                } else if agent.status == "working" {
                    Button(tr("Detener")) { run { monitor.press(["esc"],on:agent,done:$0) } }
                        .help(tr("Interrumpir al agente (esc en su terminal)"))
                }
            }
            .controlSize(.small)
            // Keys and text would reach whichever chat the pane shows instead.
            .disabled(!agent.foreground)
            if let note = note {
                Text(note).font(.system(size:10)).foregroundStyle(.orange).lineLimit(1)
            }
        }
        .padding(.horizontal,10).padding(.vertical,8)
        .frame(height:ChatPanel.height)
        .background(Color(red:0.09,green:0.08,blue:0.11))
        .overlay(Rectangle().fill(agent.color.opacity(0.7)).frame(height:1),alignment:.top)
        .onAppear { typing = true }
        // Keep the terminal tail fresh while the panel is open.
        .task(id:agent.status) {
            while !Task.isCancelled {
                monitor.tail(of:agent) { lines = $0 }
                try? await Task.sleep(nanoseconds:2_000_000_000)
            }
        }
    }

    private func submit() {
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

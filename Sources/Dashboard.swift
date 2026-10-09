import Cocoa
import SwiftUI
import SpriteKit

final class SceneStore: ObservableObject {
    let scene = DungeonScene(size: CGSize(width: 1000, height: 620))
}

struct Dashboard: View {
    @ObservedObject var monitor: Monitor
    @StateObject private var world = SceneStore()
    @State private var selected: String?
    @State private var paused = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    @State private var hovering = false
    var onMinimize: () -> Void = {}
    var onClose: () -> Void = {}
    var body: some View {
        ZStack(alignment:.topTrailing) {
            SpriteView(scene:world.scene,preferredFramesPerSecond:30,options:[.ignoresSiblingOrder])
                .frame(maxWidth:.infinity,maxHeight:.infinity)
                .background(Color(red:0.05,green:0.06,blue:0.065))
            controls
                .padding(6)
                .opacity(hovering ? 1 : 0)
            DragHandle()
                .frame(maxWidth:.infinity,alignment:.top)
        }
        .preferredColorScheme(.dark)
        .onHover { hovering = $0 }
        .onAppear { world.scene.onSelect={selected=$0};world.scene.sync(monitor.agents);world.scene.reducedMotion=paused }
        .onChange(of:monitor.agents) { agents in
            world.scene.sync(agents)
            if !agents.contains(where:{$0.id == selected}) {selected=nil}
        }
        .onChange(of:selected) { world.scene.selected=$0 }
        .onChange(of:paused) { world.scene.reducedMotion=$0 }
    }
    private var controls: some View {
        HStack(spacing:7) {
            Button(action:onMinimize) {
                Image(systemName:"minus.circle.fill").font(.system(size:15))
                    .foregroundStyle(Color(red:0.98,green:0.74,blue:0.18))
            }
            .buttonStyle(.plain)
            .help("Minimizar (ocultar)")
            Button(action:onClose) {
                Image(systemName:"xmark.circle.fill").font(.system(size:15))
                    .foregroundStyle(Color(red:0.95,green:0.33,blue:0.30))
            }
            .buttonStyle(.plain)
            .help("Cerrar")
        }
        .padding(5)
        .background(.black.opacity(0.35),in:Capsule())
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
        .help("Arrastrar para mover")
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

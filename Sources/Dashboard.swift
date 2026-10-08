import Cocoa
import SwiftUI
import SpriteKit

private let panel = Color(red:0.095,green:0.115,blue:0.10)
private let accent = Color(red:0.70,green:0.86,blue:0.58)

final class SceneStore: ObservableObject {
    let scene = DungeonScene(size: DungeonScene.worldSize)
}

struct Dashboard: View {
    @ObservedObject var monitor: Monitor
    @StateObject private var world = SceneStore()
    @State private var selected: String?
    @State private var search = ""
    @State private var filter = "all"
    @State private var credits = false
    @State private var paused = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    var visible: [Agent] {
        monitor.agents.filter { (filter == "all" || $0.status == filter) && (search.isEmpty || "\($0.name) \($0.project) \($0.activity)".localizedCaseInsensitiveContains(search)) }
    }
    var body: some View {
        VStack(spacing:0) {
            header
            ScrollView {
            VStack(alignment:.leading,spacing:16) {
                HStack(alignment:.bottom) {
                    VStack(alignment:.leading,spacing:5) {
                        Text("TU GUILD ESTÁ ABIERTA").font(.system(size:9,design:.monospaced)).tracking(2).foregroundStyle(accent)
                        Text("Un mundo para tus agentes.").font(.system(size:27,weight:.semibold,design:.rounded))
                        Text("Cada héroe es un agente. Cada sala, su estado en Herdr.").font(.system(size:12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment:.trailing,spacing:5) {
                        Text(monitor.demo ? "DEMO · DATOS FICTICIOS" : "SESIÓN \(monitor.session == "default" ? "PRINCIPAL" : monitor.session.uppercased())").font(.system(size:9,design:.monospaced)).foregroundStyle(accent)
                        if let updated=monitor.updated { Text(updated,style:.time).font(.system(size:11,design:.monospaced)).foregroundStyle(.secondary) }
                    }
                }
                if let error=monitor.error {
                    Label(error + (monitor.updated == nil ? "" : " Se muestran los últimos datos recibidos."),systemImage:"wifi.exclamationmark").font(.callout).foregroundStyle(.orange).padding(10).frame(maxWidth:.infinity,alignment:.leading).background(Color.orange.opacity(0.1),in:RoundedRectangle(cornerRadius:8))
                }
                HStack(spacing:12) {
                    metric("Agentes abiertos",monitor.agents.count,"person.3",.secondary)
                    metric("Trabajando",monitor.agents.filter{$0.status == "working"}.count,"bolt",accent)
                    metric("Necesitan atención",monitor.agents.filter{$0.status == "blocked"}.count,"exclamationmark.bubble",.orange)
                    metric("Terminaron",monitor.agents.filter{$0.status == "done"}.count,"checkmark",.cyan)
                }.opacity(monitor.error == nil ? 1 : 0.45)
                HStack(alignment:.top,spacing:14) {
                    VStack(spacing:0) {
                        HStack { Text("La mazmorra").fontWeight(.semibold);Text("/ en vivo").foregroundStyle(.secondary);Spacer();Text("Selecciona un héroe").font(.system(size:10)).foregroundStyle(.secondary) }.font(.system(size:12)).padding(13)
                        SpriteView(scene:world.scene,preferredFramesPerSecond:30,options:[.ignoresSiblingOrder])
                            .aspectRatio(DungeonScene.worldSize.width/DungeonScene.worldSize.height,contentMode:.fit)
                            .opacity(monitor.error == nil ? 1 : 0.4)
                            .accessibilityLabel("Mazmorra animada. La lista Tu equipo ofrece controles accesibles para los mismos agentes.")
                        HStack(spacing:13) { legend("Arena",accent);legend("Portal",.orange);legend("Biblioteca",.purple);legend("Taberna",.cyan);Spacer() }.padding(12)
                        details
                    }.background(panel).clipShape(RoundedRectangle(cornerRadius:10)).overlay(RoundedRectangle(cornerRadius:10).stroke(.white.opacity(0.08)))
                    roster.frame(width:270)
                }
                HStack(spacing:12) {
                    Text("ACTIVIDAD").font(.system(size:9,design:.monospaced)).foregroundStyle(accent)
                    if let event=monitor.events.first { Text(event.at,style:.time).foregroundStyle(.secondary);Text(event.text).lineLimit(1) }
                    else { Text("Esperando a los agentes…").foregroundStyle(.secondary) }
                    Spacer()
                }.font(.system(size:11)).padding(12).background(panel,in:RoundedRectangle(cornerRadius:7))
            }.padding(22)
            }
            Spacer(minLength:0)
            HStack {
                Text("Swift + SpriteKit · local · cada 1 s").foregroundStyle(.secondary)
                Spacer()
                Link("Pixel art: o_lobster ↗",destination:URL(string:"https://o-lobster.itch.io/")!).foregroundStyle(accent)
                Text("·").foregroundStyle(.secondary)
                Button("Créditos") { credits=true }.buttonStyle(.plain)
            }.font(.system(size:10)).padding(.horizontal,24).padding(.bottom,14)
        }
        .frame(minWidth:1030,minHeight:760)
        .background(Color(red:0.06,green:0.075,blue:0.065))
        .preferredColorScheme(.dark)
        .onAppear { world.scene.onSelect={selected=$0};world.scene.sync(monitor.agents);world.scene.reducedMotion=paused }
        .onChange(of:monitor.agents) { agents in
            world.scene.sync(agents)
            if !agents.contains(where:{$0.id == selected}) {selected=nil}
        }
        .onChange(of:selected) { world.scene.selected=$0 }
        .onChange(of:paused) { world.scene.reducedMotion=$0 }
        .sheet(isPresented:$credits) { CreditsView() }
    }
    private var header: some View {
        HStack(spacing:12) {
            Image(systemName:"square.stack.3d.up.fill").font(.system(size:22)).foregroundStyle(accent)
            Text("herdr").font(.system(size:21,weight:.bold,design:.rounded)) + Text(" pixel agents").font(.system(size:21,weight:.light,design:.rounded))
            Spacer()
            Circle().fill(monitor.error == nil && monitor.updated != nil ? accent : .orange).frame(width:6,height:6)
            Text(monitor.demo ? "DEMO" : monitor.error == nil && monitor.updated != nil ? "EN VIVO" : "CONECTANDO").font(.system(size:10,design:.monospaced)).foregroundStyle(accent)
            Button { paused.toggle() } label:{ Image(systemName:paused ? "play.fill" : "pause.fill") }.help("Pausar o reanudar animaciones").buttonStyle(.borderless)
            Toggle("Demo",isOn:Binding(get:{monitor.demo},set:{monitor.setDemo($0)})).toggleStyle(.switch).controlSize(.mini).font(.system(size:11)).padding(.leading,8)
        }.padding(.horizontal,24).padding(.vertical,18).background(panel)
    }
    private var roster: some View {
        VStack(alignment:.leading,spacing:10) {
            HStack {Text("Tu equipo").fontWeight(.semibold);Spacer();Text("\(visible.count)").foregroundStyle(accent)}.font(.system(size:12))
            TextField("Buscar agente o proyecto",text:$search).textFieldStyle(.roundedBorder).controlSize(.small)
            Picker("Estado",selection:$filter) {
                Text("Todos").tag("all");Text("Trabajando").tag("working");Text("Atención").tag("blocked");Text("En espera").tag("idle");Text("Terminó").tag("done");Text("Sin estado").tag("unknown")
            }.labelsHidden().controlSize(.small)
            ScrollView {
                LazyVStack(spacing:7) {
                    if visible.isEmpty {Text(monitor.updated == nil ? "Conectando con Herdr…" : "No hay agentes para mostrar").font(.callout).foregroundStyle(.secondary).padding(.vertical,30)}
                    ForEach(visible) { agent in
                        Button { selected=agent.id } label: {
                            VStack(alignment:.leading,spacing:7) {
                                HStack(spacing:9) {
                                    Text(String(agent.name.prefix(1)).uppercased()).font(.system(size:15,weight:.bold,design:.monospaced)).foregroundStyle(agent.color).frame(width:29,height:32).background(agent.color.opacity(0.14),in:RoundedRectangle(cornerRadius:5))
                                    VStack(alignment:.leading,spacing:3) {Text(agent.project).font(.system(size:12,weight:.semibold)).lineLimit(1);Text("\(agent.name) · \(agent.label)").font(.system(size:9)).foregroundStyle(.secondary)}
                                    Spacer(minLength:0)
                                    Circle().fill(agent.color).frame(width:5,height:5)
                                }
                                Text(agent.activity).font(.system(size:10)).foregroundStyle(.secondary).lineLimit(2)
                            }.padding(10).frame(maxWidth:.infinity,alignment:.leading).background(selected == agent.id ? accent.opacity(0.1) : Color.white.opacity(0.025),in:RoundedRectangle(cornerRadius:7)).overlay(RoundedRectangle(cornerRadius:7).stroke(selected == agent.id ? accent.opacity(0.5) : Color.clear))
                        }.buttonStyle(.plain).accessibilityLabel("\(agent.project), \(agent.name), \(agent.label)")
                    }
                }
            }.frame(minHeight:380,maxHeight:520)
            Text("Estados reportados por Herdr").font(.system(size:9,design:.monospaced)).foregroundStyle(.secondary)
        }.padding(14).background(panel,in:RoundedRectangle(cornerRadius:10)).overlay(RoundedRectangle(cornerRadius:10).stroke(.white.opacity(0.08)))
    }
    private var details: some View {
        VStack(alignment:.leading,spacing:5) {
            if let agent=monitor.agents.first(where:{$0.id == selected}) {
                HStack {Text(agent.project).fontWeight(.semibold);Text("· \(agent.name)").foregroundStyle(.secondary);Spacer();Text(agent.label).foregroundStyle(agent.color)}.font(.system(size:12))
                Text(agent.activity).font(.system(size:11)).lineLimit(2).textSelection(.enabled)
                Text("\(agent.id) · \(agent.cwd)").font(.system(size:9,design:.monospaced)).foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled)
            } else {Text("Selecciona un héroe para ver su proyecto y actividad.").font(.system(size:11)).foregroundStyle(.secondary)}
        }.frame(maxWidth:.infinity,minHeight:55,alignment:.leading).padding(14).background(.white.opacity(0.02))
    }
    func metric(_ title: String,_ count: Int,_ icon: String,_ color: Color) -> some View {
        HStack(spacing:12) {Image(systemName:icon).font(.system(size:22)).foregroundStyle(color);VStack(alignment:.leading,spacing:3){Text("\(count)").font(.system(size:25,weight:.medium,design:.rounded));Text(title).font(.system(size:10)).foregroundStyle(.secondary)};Spacer(minLength:0)}.padding(14).frame(maxWidth:.infinity,alignment:.leading).background(panel,in:RoundedRectangle(cornerRadius:8)).overlay(RoundedRectangle(cornerRadius:8).stroke(.white.opacity(0.08)))
    }
    func legend(_ text: String,_ color: Color) -> some View { HStack(spacing:4){Rectangle().fill(color).frame(width:5,height:5);Text(text).foregroundStyle(.secondary)}.font(.system(size:9)) }
}

struct CreditsView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment:.leading,spacing:15) {
            Text("Créditos").font(.title.bold())
            Text("Pixel art · o_lobster").font(.headline)
            Link("https://o-lobster.itch.io/",destination:URL(string:"https://o-lobster.itch.io/")!)
            Text("Another Metroidvania Asset Pack Vol. 1, versión 1.7. Sprites y fondos originales, usados según la licencia CC BY 4.0 incluida en el pack. La app recorta fotogramas, escala con píxeles nítidos y compone las salas en tiempo de ejecución.")
            Link("Creative Commons Attribution 4.0",destination:URL(string:"https://creativecommons.org/licenses/by/4.0/")!)
            Divider()
            Text("Base e inspiración · Claude Dungeon").font(.headline)
            Link("thousandsky2024 / claude-pixel-agent-web",destination:URL(string:"https://github.com/thousandsky2024/claude-pixel-agent-web")!)
            Text("Concepto de agentes como héroes y navegación BFS adaptada a Swift. Copyright © 2026 Claude Dungeon Contributors. MIT.")
            Text("Adaptación nativa: Herdr Pixel Agents contributors. Estados en vivo provistos por Herdr. Proyecto independiente; no implica respaldo de los autores.").foregroundStyle(.secondary)
            HStack {Button("Ver licencias incluidas") { if let url=Bundle.main.resourceURL?.appendingPathComponent("Licenses") {NSWorkspace.shared.open(url)} };Spacer();Button("Listo") {dismiss()}.keyboardShortcut(.defaultAction)}
        }.font(.system(size:12)).padding(28).frame(width:520)
    }
}

import Cocoa
import SwiftUI

/// Menu bar icon: a pixel sword, drawn one square per pixel as a template
/// image so macOS tints it for light and dark bars.
func menuBarIcon() -> NSImage {
    let rows = [
        "..............##",
        ".............###",
        "............###.",
        "...........###..",
        "..........###...",
        ".........###....",
        "........###.....",
        "..##...###......",
        "..###.###.......",
        "...#####........",
        "....###.........",
        "...#####........",
        "..###.###.......",
        ".###...##.......",
        "###.............",
        "##..............",
    ]
    let image = NSImage(size: NSSize(width: 16, height: rows.count), flipped: true) { _ in
        NSColor.black.setFill()
        for (y, row) in rows.enumerated() {
            for (x, pixel) in row.enumerated() where pixel == "#" { NSRect(x: x, y: y, width: 1, height: 1).fill() }
        }
        return true
    }
    image.isTemplate = true
    image.accessibilityDescription = "Herdr Pixel Dungeon"
    return image
}

/// Borderless square panel that can still host SwiftUI/SpriteKit and accept clicks.
final class WidgetPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let monitor = Monitor()
    let sounds = SoundAlerts()
    var window: WidgetPanel!
    var status: NSStatusItem!

    /// Width of the widget, in points. Its height follows the number of agents.
    let side: CGFloat = 460
    /// Room above the first row (drag handle) and below the last one.
    let topInset: CGFloat = 14
    let bottomInset: CGFloat = 6
    /// Margin from the screen edges.
    let margin: CGFloat = 12

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar only: no Dock icon, no app menu bar.
        NSApp.setActivationPolicy(.accessory)

        // Status bar item. Left click toggles the widget; right click shows a menu.
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.image = menuBarIcon()
        status.button?.imagePosition = .imageLeading
        status.button?.target = self
        status.button?.action = #selector(statusClicked(_:))
        status.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        monitor.onChange = { [weak self] in
            guard let self = self else { return }
            let count = self.monitor.agents.filter { $0.status == "blocked" }.count
            self.status.button?.title = self.monitor.error == nil ? " \(self.monitor.agents.count)" + (count > 0 ? " · \(count)!" : "") : " —"
            self.status.button?.toolTip = tr("Herdr Pixel Dungeon · %ld necesitan atención", count)
            self.fitHeight()
            // Typing in the chat panel needs the widget to be the key window.
            if self.monitor.selected != nil { self.window.makeKey() }
        }
        monitor.onAlert = { [weak self] in self?.sounds.play($0) }

        // Square, borderless, floating widget window.
        window = WidgetPanel(contentRect: NSRect(x: 0, y: 0, width: side, height: side),
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.hasShadow = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = NSHostingView(rootView: Dashboard(monitor: monitor, sounds: sounds,
                                                               onMinimize: { [weak self] in self?.window.orderOut(nil) },
                                                               onClose: { NSApp.terminate(nil) }))
        window.delegate = self
        if let content = window.contentView {
            content.wantsLayer = true
            content.layer?.cornerRadius = 14
            content.layer?.masksToBounds = true
            content.layer?.backgroundColor = NSColor(red: 0.05, green: 0.06, blue: 0.065, alpha: 1).cgColor
        }

        if CommandLine.arguments.contains("--demo") { monitor.demo = true }
        anchorToCorner()
        window.orderFrontRegardless()
        monitor.start()
    }

    /// Height that shows every agent row (at least one), capped to the screen.
    func targetHeight() -> CGFloat {
        let rows = CGFloat(max(1, (monitor.agents.count + DungeonScene.columns - 1) / DungeonScene.columns))
        let panel = monitor.selected == nil ? 0 : ChatPanel.height
        let wanted = topInset + rows * AgentRow.height + (rows - 1) * DungeonScene.gap + bottomInset + panel
        let limit = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? wanted
        return min(wanted, limit - 2 * margin)
    }

    /// Grow or shrink the window vertically with the agent count, keeping its
    /// top edge where the user put it.
    func fitHeight() {
        let height = targetHeight()
        var frame = window.frame
        guard abs(frame.height - height) > 0.5 else { return }
        frame.origin.y = frame.maxY - height
        frame.size.height = height
        window.setFrame(frame, display: true, animate: window.isVisible)
        window.invalidateShadow()
    }

    /// Place the widget in the top-right corner, just under the menu bar.
    func anchorToCorner() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let height = targetHeight()
        let x = visible.maxX - side - margin
        let y = visible.maxY - height - margin
        window.setFrame(NSRect(x: x, y: y, width: side, height: height), display: true)
    }

    @objc func statusClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            showMenu()
        } else {
            toggle()
        }
    }

    func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: tr("Mostrar / ocultar"), action: #selector(toggle), keyEquivalent: "").target = self
        menu.addItem(withTitle: tr("Reposicionar en la esquina"), action: #selector(reanchor), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let soundMenu = NSMenu()
        for (title, action, on) in [(tr("Sonidos activados"), #selector(toggleSound), sounds.enabled),
                                    (tr("Al necesitar ayuda"), #selector(toggleNeedsHelpSound), sounds.onNeedsHelp),
                                    (tr("Al terminar"), #selector(toggleFinishedSound), sounds.onFinished)] {
            let item = soundMenu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.state = on ? .on : .off
            if action != #selector(toggleSound) { item.indentationLevel = 1; item.isEnabled = sounds.enabled }
        }
        soundMenu.autoenablesItems = false
        let soundItem = menu.addItem(withTitle: tr("Sonidos"), action: nil, keyEquivalent: "")
        soundItem.submenu = soundMenu
        menu.addItem(.separator())
        menu.addItem(withTitle: tr("Acerca de Herdr Pixel Dungeon"), action: #selector(about), keyEquivalent: "").target = self
        menu.addItem(withTitle: tr("Salir"), action: #selector(quit), keyEquivalent: "q").target = self
        status.menu = menu
        status.button?.performClick(nil)
        status.menu = nil // detach so left-click keeps toggling
    }

    @objc func toggle() {
        if window.isVisible {
            window.orderOut(nil)
        } else {
            window.orderFrontRegardless()
        }
    }

    @objc func toggleSound() { sounds.enabled.toggle() }
    @objc func toggleNeedsHelpSound() { sounds.onNeedsHelp.toggle(); sounds.play(.needsHelp) }
    @objc func toggleFinishedSound() { sounds.onFinished.toggle(); sounds.play(.finished) }

    @objc func reanchor() { anchorToCorner(); window.orderFrontRegardless() }
    @objc func show() { window.orderFrontRegardless() }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func about() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Herdr Pixel Dungeon", .credits: NSAttributedString(string: tr("Creado por Nacho Valencia.\nCódigo y pixel art originales · MIT."))])
    }
}

func selfTest() throws {
    let sample = #"{"result":{"snapshot":{"agents":[{"pane_id":"a","agent":"claude","agent_status":"idle","workspace_id":"w"},{"pane_id":"b","agent":"codex","agent_status":"blocked"},{"pane_id":"shell"}],"workspaces":[{"workspace_id":"w","label":"Example"}]}}}"#
    let agents=try decodeSnapshot(Data(sample.utf8))
    precondition(agents.count==2 && agents[0].status=="blocked" && agents[1].project=="Example")
    do {_ = try decodeSnapshot(Data("{}".utf8));fatalError("Invalid snapshot accepted")}catch{}
    let empty=try decodeSnapshot(Data(#"{"result":{"snapshot":{"agents":[]}}}"#.utf8));precondition(empty.isEmpty)
    let monitor=Monitor();monitor.apply(demoAgents(tick:0));monitor.apply(demoAgents(tick:10));precondition(monitor.events.contains{$0.text.contains(tr("Necesita atención"))});monitor.apply([]);precondition(monitor.agents.isEmpty)
    let resource=Bundle.main.resourceURL!.appendingPathComponent("Sprites")
    let files=FileManager.default.enumerator(at:resource,includingPropertiesForKeys:nil)!.allObjects.compactMap{$0 as? URL}.filter{$0.pathExtension=="png"}
    precondition(files.count>=6);for file in files{precondition(NSImage(contentsOf:file) != nil,"Unreadable asset: \(file.lastPathComponent)")}
    let busy=Agent(id:"x",name:"claude",status:"idle",project:"p",activity:"a",cwd:"~").with(subagents:2);precondition(busy.status=="working" && busy.subagents==2)
    precondition(Agent(id:"x",name:"claude",status:"blocked",project:"p",activity:"a",cwd:"~").with(subagents:1).status=="blocked")
    let repo=FileManager.default.temporaryDirectory.appendingPathComponent("hpd-selftest-\(ProcessInfo.processInfo.processIdentifier)")
    try FileManager.default.createDirectory(at:repo.appendingPathComponent(".git"),withIntermediateDirectories:true)
    try FileManager.default.createDirectory(at:repo.appendingPathComponent("src"),withIntermediateDirectories:true)
    try "ref: refs/heads/feature/x\n".write(to:repo.appendingPathComponent(".git/HEAD"),atomically:true,encoding:.utf8)
    precondition(gitBranch(at:repo.appendingPathComponent("src").path)=="feature/x");try? FileManager.default.removeItem(at:repo)
    precondition(Hero.harness(for:"claude")=="claude" && Hero.harness(for:"Codex CLI")=="codex" && Hero.harness(for:"opencode")=="hero")
    let withSession=try decodeSnapshot(Data(#"{"result":{"snapshot":{"agents":[{"pane_id":"a","agent":"claude","agent_session":{"kind":"id","value":"s-1"}}]}}}"#.utf8));precondition(withSession[0].session=="s-1" && withSession[0].subagents==0)
    precondition(NSImage(contentsOf:resource.appendingPathComponent("heroes/heroes.png"))?.size==NSSize(width:48,height:CGFloat(Hero.order.count*32)),"Hero sheet layout mismatch")
    for style in RoomStyle.all{precondition(NSImage(contentsOf:resource.appendingPathComponent("rooms/\(style.background).png")) != nil,"Missing room art: \(style.background)")}
    precondition(toolAction("WebSearch")=="read" && toolAction("Edit")=="forge" && toolAction("Bash")=="brew" && toolAction("Task")=="summon" && toolAction("TodoWrite")=="plan" && toolAction("mcp__x")=="type")
    let tail=#"{"type":"assistant","message":{"content":[{"type":"text","text":"hi"},{"type":"tool_use","name":"Grep","input":{}}]}}"#+"\n"+#"{"type":"user","message":{"content":[{"type":"tool_result"}]}}"#
    precondition(lastAction(transcriptTail:tail)=="read" && lastAction(transcriptTail:#"{"type":"assistant","message":{"content":[{"type":"text","text":"done"}]}}"#)=="type" && lastAction(transcriptTail:"")==nil)
    for (spanish, row) in L10n.table { precondition(row.count==4 && row.allSatisfy{!$0.isEmpty}, "Missing translation: \(spanish)")
        for language in L10n.languages { let t=L10n.text(spanish,language:language); precondition(t.components(separatedBy:"%").count==spanish.components(separatedBy:"%").count, "Format mismatch: \(spanish) [\(language)]") } }
    precondition(L10n.text("LISTO",language:"fr")=="TERMINÉ" && L10n.text("LISTO",language:"es")=="LISTO")
    var before=Dictionary(uniqueKeysWithValues:[Agent(id:"a",name:"claude",status:"working",project:"p",activity:"a",cwd:"~")].map{($0.id,$0)})
    precondition(alertFor(previous:before,next:[Agent(id:"a",name:"claude",status:"idle",project:"p",activity:"a",cwd:"~")]) == .finished)
    precondition(alertFor(previous:before,next:[Agent(id:"a",name:"claude",status:"blocked",project:"p",activity:"a",cwd:"~"),Agent(id:"b",name:"x",status:"done",project:"p",activity:"a",cwd:"~")]) == .needsHelp)
    before["a"]=Agent(id:"a",name:"claude",status:"idle",project:"p",activity:"a",cwd:"~");precondition(alertFor(previous:before,next:[Agent(id:"a",name:"claude",status:"idle",project:"p",activity:"a",cwd:"~")]) == nil)
    var alerts:[AlertKind]=[];let watcher=Monitor();watcher.onAlert={alerts.append($0)};watcher.apply(demoAgents(tick:0));watcher.apply(demoAgents(tick:10));precondition(alerts == [.needsHelp])
    watcher.selected="demo:1";watcher.apply([]);precondition(watcher.selected == nil)
    let prefs=UserDefaults(suiteName:"hpd-selftest")!;prefs.removePersistentDomain(forName:"hpd-selftest")
    let sounds=SoundAlerts(defaults:prefs);precondition(sounds.wants(.needsHelp) && sounds.wants(.finished))
    sounds.onFinished=false;precondition(SoundAlerts(defaults:prefs).wants(.needsHelp) && !SoundAlerts(defaults:prefs).wants(.finished))
    sounds.enabled=false;precondition(!SoundAlerts(defaults:prefs).wants(.needsHelp));prefs.removePersistentDomain(forName:"hpd-selftest")
    precondition(SoundAlerts.jingle([(440,0.1)]) != nil,"Jingle did not decode")
    print("PASS: snapshot states, filtering, empty/error handling, monitor transitions, room art, heroes, subagent sessions, subagents keep agents busy, tool actions, translations, git branch, sound alerts + prefs, chat selection, \(files.count) bundled sprites")
}

if CommandLine.arguments.contains("--self-test") {
    do{try selfTest()}catch{fputs("\(error)\n",stderr);exit(1)}
} else if CommandLine.arguments.contains("--diagnose") {
    do{let agents=try fetchSnapshot(session:ProcessInfo.processInfo.environment["HERDR_SESSION"] ?? "default");print("OK: \(agents.count) agentes");for a in agents{print("\(a.id) | \(a.name) | \(a.status) | \(a.project)")}}catch{fputs("\(error.localizedDescription)\n",stderr);exit(1)}
} else {
    let app=NSApplication.shared;let delegate=AppDelegate();app.delegate=delegate;app.run()
}

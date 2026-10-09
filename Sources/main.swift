import Cocoa
import SwiftUI
import ServiceManagement

/// Menu bar icon: a pixel knight's great helm (T visor, breathing holes,
/// gorget), drawn one square per pixel as a template image so macOS tints
/// it for light and dark bars.
func menuBarIcon() -> NSImage {
    let rows = [
        "......####......",
        "....########....",
        "...##########...",
        "..############..",
        "..##........##..",
        "..##........##..",
        "..#####..#####..",
        "..#####..#####..",
        "..#####..#####..",
        "..############..",
        "..##.#.##.#.##..",
        "...##########...",
        "..############..",
        ".##############.",
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
    let notifier = Notifier()
    var window: WidgetPanel!
    var status: NSStatusItem!

    /// Columns and rows of rooms the user sized the widget to; resizing it
    /// (edges or the corner grip) snaps to whole rooms. With fewer agents
    /// than columns it narrows (one agent is one square); past `rows` rows
    /// the rooms scroll.
    var columns = max(1, UserDefaults.standard.object(forKey: "layout.columns") as? Int ?? 2) {
        didSet { UserDefaults.standard.set(columns, forKey: "layout.columns") }
    }
    var rows = max(1, UserDefaults.standard.object(forKey: "layout.rows") as? Int ?? 4) {
        didSet { UserDefaults.standard.set(rows, forKey: "layout.rows") }
    }
    private var resizeStart: NSRect?
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
        status.button?.imagePosition = .imageOnly
        status.button?.target = self
        status.button?.action = #selector(statusClicked(_:))
        status.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        monitor.onChange = { [weak self] in
            guard let self = self else { return }
            let count = self.monitor.agents.filter { $0.status == "blocked" }.count
            self.status.button?.toolTip = tr("Herdr Pixel Dungeon · %ld necesitan atención", count)
            self.fitSize()
            // Typing in the chat or new-agent panel needs the widget to be the key window.
            if self.monitor.selected != nil || self.monitor.composing { self.window.makeKey() }
        }
        monitor.onAlerts = { [weak self] alerts in
            guard let self = self, let first = alerts.first else { return }
            self.sounds.play(first.kind)
            self.notifier.post(alerts)
        }
        notifier.onOpen = { [weak self] id in self?.open(agent: id) }
        notifier.start()

        // Square, borderless, floating widget window.
        window = WidgetPanel(contentRect: NSRect(x: 0, y: 0, width: DungeonScene.width(columns: 2), height: 400),
                             styleMask: [.borderless, .nonactivatingPanel, .resizable],
                             backing: .buffered, defer: false)
        window.level = alwaysOnTop ? .floating : .normal
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

        NotificationCenter.default.addObserver(self, selector: #selector(gripBegan), name: ResizeGrip.began, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(gripEnded), name: ResizeGrip.ended, object: nil)
        if CommandLine.arguments.contains("--demo") { monitor.demo = true }
        restorePosition()
        window.orderFrontRegardless()
        monitor.start()
    }

    /// Columns shown: the user's, but never more than there are agents.
    var shownColumns: Int { min(columns, max(1, monitor.agents.count)) }

    /// Height of everything that is not rooms: insets, HUD and chat panel.
    var chrome: CGFloat {
        topInset + bottomInset + (monitor.selected == nil && !monitor.composing ? 0 : ChatPanel.height) + (monitor.showsHUD ? HUD.height : 0)
    }

    /// Height that shows the agents' rows, up to the user's row count (at
    /// least one), capped to the screen.
    func targetHeight() -> CGFloat {
        let needed = max(1, (monitor.visibleAgents.count + shownColumns - 1) / shownColumns)
        let shown = CGFloat(min(needed, rows))
        let wanted = chrome + shown * AgentRow.height + (shown - 1) * DungeonScene.gap
        let limit = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? wanted
        return min(wanted, limit - 2 * margin)
    }

    func targetWidth() -> CGFloat { DungeonScene.width(columns: shownColumns) }

    /// Resize the window to whole rooms. Changes in the agent count keep the
    /// top-right corner where the user put it; a resize by the user keeps
    /// the corner opposite the one dragged (the top-left for the grip).
    func fitSize(anchorLeft: Bool = false) {
        window.minSize = NSSize(width: DungeonScene.width(columns: 1), height: chrome + AgentRow.height)
        guard resizeStart == nil, !window.inLiveResize else { return }
        let height = targetHeight(), width = targetWidth()
        var frame = window.frame
        guard abs(frame.height - height) > 0.5 || abs(frame.width - width) > 0.5 else { return }
        frame.origin.y = frame.maxY - height
        if !anchorLeft { frame.origin.x = frame.maxX - width }
        frame.size = NSSize(width: width, height: height)
        window.setFrame(frame, display: true, animate: window.isVisible)
        window.invalidateShadow()
    }

    // MARK: Resizing by the user

    func windowWillStartLiveResize(_ notification: Notification) { resizeStart = window.frame }
    func windowDidEndLiveResize(_ notification: Notification) { endResize(anchorLeft: false) }
    @objc func gripBegan() { resizeStart = window.frame }
    @objc func gripEnded() { endResize(anchorLeft: true) }

    /// Snap a resize to whole rooms: the new width picks the columns, the
    /// new height the rows to show before scrolling. A side left alone keeps
    /// its setting (fewer agents than rows would otherwise shrink it).
    private func endResize(anchorLeft: Bool) {
        guard let start = resizeStart else { return }
        resizeStart = nil
        let frame = window.frame
        if abs(frame.width - start.width) > 1 {
            columns = min(8, max(1, Int(((frame.width - DungeonScene.gap) / (AgentRow.width + DungeonScene.gap)).rounded())))
        }
        if abs(frame.height - start.height) > 1 {
            rows = max(1, Int(((frame.height - chrome + DungeonScene.gap) / (AgentRow.height + DungeonScene.gap)).rounded()))
        }
        fitSize(anchorLeft: anchorLeft || frame.minX == start.minX)
    }

    /// Place the widget in the top-right corner, just under the menu bar.
    /// Keep the widget above other windows (the default) or let them cover it.
    var alwaysOnTop = UserDefaults.standard.object(forKey: "window.onTop") as? Bool ?? true {
        didSet { UserDefaults.standard.set(alwaysOnTop, forKey: "window.onTop"); window.level = alwaysOnTop ? .floating : .normal }
    }

    /// Remember where the user left the widget: its top-right corner, since
    /// that is the corner that stays put as it grows.
    func windowDidMove(_ notification: Notification) {
        guard resizeStart == nil, !window.inLiveResize else { return }
        UserDefaults.standard.set([window.frame.maxX, window.frame.maxY], forKey: "window.topRight")
    }

    /// Put the widget back where it was, if that spot is still on a screen;
    /// otherwise in the top-right corner.
    func restorePosition() {
        guard let saved = UserDefaults.standard.array(forKey: "window.topRight") as? [CGFloat], saved.count == 2,
              let screen = NSScreen.screens.first(where: { $0.visibleFrame.insetBy(dx: -1, dy: -1).contains(NSPoint(x: saved[0] - 20, y: saved[1] - 20)) })
        else { return anchorToCorner() }
        let height = targetHeight(), width = targetWidth()
        let x = min(max(saved[0] - width, screen.visibleFrame.minX), screen.visibleFrame.maxX - width)
        window.setFrame(NSRect(x: x, y: saved[1] - height, width: width, height: height), display: true)
    }

    func anchorToCorner() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let height = targetHeight(), width = targetWidth()
        let x = visible.maxX - width - margin
        let y = visible.maxY - height - margin
        window.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
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
        let top = menu.addItem(withTitle: tr("Siempre visible"), action: #selector(toggleOnTop), keyEquivalent: "")
        top.target = self
        top.state = alwaysOnTop ? .on : .off
        let login = menu.addItem(withTitle: tr("Abrir al iniciar sesión"), action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
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
        let notifyMenu = NSMenu()
        for (title, action, on) in [(tr("Notificaciones activadas"), #selector(toggleNotify), notifier.enabled),
                                    (tr("Al necesitar ayuda"), #selector(toggleNeedsHelpNotify), notifier.onNeedsHelp),
                                    (tr("Al terminar"), #selector(toggleFinishedNotify), notifier.onFinished)] {
            let item = notifyMenu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.state = on ? .on : .off
            if action != #selector(toggleNotify) { item.indentationLevel = 1; item.isEnabled = notifier.enabled }
        }
        notifyMenu.autoenablesItems = false
        menu.addItem(withTitle: tr("Notificaciones"), action: nil, keyEquivalent: "").submenu = notifyMenu
        menu.addItem(.separator())
        // Sessions: the running ones (and the watched one, even if stopped).
        let sessionMenu = NSMenu()
        var sessions = listSessions()
        if !sessions.contains(where: { $0.name == monitor.session }) { sessions.insert(HerdrSession(name: monitor.session, running: false), at: 0) }
        for session in sessions {
            let item = sessionMenu.addItem(withTitle: session.running ? session.name : tr("%@ (detenida)", session.name), action: #selector(pickSession(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = session.name
            item.state = session.name == monitor.session && !monitor.demo ? .on : .off
        }
        sessionMenu.addItem(.separator())
        let demo = sessionMenu.addItem(withTitle: tr("Demo (agentes ficticios)"), action: #selector(toggleDemo), keyEquivalent: "")
        demo.target = self
        demo.state = monitor.demo ? .on : .off
        menu.addItem(withTitle: tr("Sesión de Herdr"), action: nil, keyEquivalent: "").submenu = sessionMenu
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
    @objc func pickSession(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        if monitor.demo { monitor.setDemo(false) }
        monitor.setSession(name)
    }
    @objc func toggleOnTop() { alwaysOnTop.toggle() }
    /// Launch at login through SMAppService. A locally built, ad-hoc signed
    /// app may be refused; then say so instead of pretending.
    @objc func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = tr("macOS no permitió abrir la app al iniciar sesión.")
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
    @objc func toggleDemo() { monitor.setDemo(!monitor.demo) }
    @objc func toggleNotify() { notifier.enabled.toggle() }
    @objc func toggleNeedsHelpNotify() { notifier.onNeedsHelp.toggle() }
    @objc func toggleFinishedNotify() { notifier.onFinished.toggle() }

    /// Show the dungeon with an agent's chat open, clearing a filter that hides it.
    func open(agent id: String) {
        guard monitor.agents.contains(where: { $0.id == id }) else { return show() }
        if !monitor.visibleAgents.contains(where: { $0.id == id }) { monitor.filter = .all; monitor.query = "" }
        monitor.selected = id
        show()
        window.makeKey()
    }

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
    var alerts:[AlertKind]=[];let watcher=Monitor();watcher.onAlerts={alerts+=$0.map(\.kind)};watcher.apply(demoAgents(tick:0));watcher.apply(demoAgents(tick:10));precondition(alerts == [.needsHelp])
    watcher.selected="demo:1";watcher.apply([]);precondition(watcher.selected == nil)
    let prefs=UserDefaults(suiteName:"hpd-selftest")!;prefs.removePersistentDomain(forName:"hpd-selftest")
    let sounds=SoundAlerts(defaults:prefs);precondition(sounds.wants(.needsHelp) && sounds.wants(.finished))
    sounds.onFinished=false;precondition(SoundAlerts(defaults:prefs).wants(.needsHelp) && !SoundAlerts(defaults:prefs).wants(.finished))
    sounds.enabled=false;precondition(!SoundAlerts(defaults:prefs).wants(.needsHelp));prefs.removePersistentDomain(forName:"hpd-selftest")
    let notes=Notifier(defaults:prefs);precondition(notes.wants(.needsHelp) && !notes.wants(.finished))
    notes.onFinished=true;notes.onNeedsHelp=false;let reread=Notifier(defaults:prefs);precondition(reread.wants(.finished) && !reread.wants(.needsHelp))
    notes.enabled=false;precondition(!Notifier(defaults:prefs).wants(.finished));prefs.removePersistentDomain(forName:"hpd-selftest")
    let both=alertsFor(previous:["a":Agent(id:"a",name:"x",status:"working",project:"p",activity:"",cwd:"~"),"b":Agent(id:"b",name:"y",status:"working",project:"p",activity:"",cwd:"~")],
                       next:[Agent(id:"a",name:"x",status:"done",project:"p",activity:"",cwd:"~"),Agent(id:"b",name:"y",status:"blocked",project:"p",activity:"",cwd:"~")])
    precondition(both.map(\.kind)==[.needsHelp,.finished] && both.map(\.agent.id)==["b","a"])
    precondition(SoundAlerts.jingle([(440,0.1)]) != nil,"Jingle did not decode")
    let screen="✻ Worked for 17s · done 12:00 AM\n※ recap: Estamos mejorando el dungeon y ya sale un cuadro\n  nueva: subir tus commits de main en un PR\n────────\n❯ la 1, con PR borrador\n────────\n  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents"
    precondition(meaningfulLines(screen).isEmpty,"Chrome left in terminal tail: \(meaningfulLines(screen))")
    precondition(meaningfulLines(" Do you want to proceed?\n❯ 1. Yes\n  2. No\n❯ hola").count==3,"Permission options were dropped")
    let ask="Lo que veo:\n- algo\n\nneeds input: ¿para qué es la rama nueva? Opciones:\n\n1. **Rama de PR** desde `main`\n2. Renombrar"
    precondition(questionLines(in:ask,needs:"¿para qué es la rama nueva? Opciones:")==["¿para qué es la rama nueva? Opciones:","1. Rama de PR desde main","2. Renombrar"],"Question not cut at the ask")
    let job=BackgroundJob(state:"blocked",needs:"¿Sí?",transcript:"/t.jsonl",updated:Date())
    let asked=Agent(id:"q",name:"claude",status:"idle",project:"p",activity:"a",cwd:"~").with(jobs:[job])
    precondition(asked.status=="blocked" && asked.question=="¿Sí?" && asked.questionTranscript=="/t.jsonl")
    let menu=MenuOptions(["Bash(rm -rf build)"," Do you want to proceed?","❯ 1. Yes","  2. Yes, and don't ask again","  3. No, and tell Claude what to do"])
    precondition(menu.options.map(\.number)==[1,2,3] && menu.highlighted==0 && menu.isMenu && menu.options[1].text=="Yes, and don't ask again" && menu.options[2].line==4)
    precondition(menu.keys(choosing:2)==["down","down","enter"] && menu.keys(choosing:0)==["enter"])
    let plain=MenuOptions(["¿Qué rama?","1. Rama de PR","2) Renombrar","texto","1. Otra pregunta","2. Sí"])
    precondition(!plain.isMenu && plain.options.map(\.text)==["Otra pregunta","Sí"] && MenuOptions(["hola"]).options.isEmpty)
    let pool=[Agent(id:"1",name:"claude",status:"blocked",project:"Web Shop",activity:"Arreglando el carrito",cwd:"~/code/shop"),Agent(id:"2",name:"codex",status:"working",project:"API",activity:"Tests",cwd:"~/code/api")]
    var branched=pool[1];branched.branch="feature/pagos"
    precondition(filterAgents(pool,status:.all,query:"").count==2 && filterAgents(pool,status:.blocked,query:"").map(\.id)==["1"] && filterAgents(pool,status:.idle,query:"").isEmpty)
    precondition(filterAgents(pool,status:.all,query:"CARRITO").map(\.id)==["1"] && filterAgents(pool,status:.all,query:"codex").map(\.id)==["2"] && filterAgents(pool,status:.all,query:"web shop").map(\.id)==["1"])
    precondition(filterAgents([pool[0],branched],status:.all,query:"pagos").map(\.id)==["2"] && filterAgents(pool,status:.all,query:"cárrito shop").map(\.id)==["1"] && filterAgents(pool,status:.working,query:"shop").isEmpty)
    let now=Date();precondition(connectionNote(error:nil,updated:now,now:now)==nil && connectionNote(error:nil,updated:nil,now:now)==nil)
    let stale=connectionNote(error:nil,updated:now.addingTimeInterval(-14),now:now);precondition(stale?.lost==false && stale!.text.contains("14"))
    let lost=connectionNote(error:"x",updated:now.addingTimeInterval(-200),now:now);precondition(lost?.lost==true && lost!.text.contains("3"))
    precondition(connectionNote(error:"x",updated:nil,now:now)?.text==tr("Herdr desconectado"))
    for n in 1...6 { precondition(DungeonScene.columns(fitting:DungeonScene.width(columns:n))==n && DungeonScene.columns(fitting:DungeonScene.width(columns:n)+100)==n, "Flex wrap columns: \(n)") }
    precondition(DungeonScene.columns(fitting:10)==1 && DungeonScene.width(columns:2)==458)
    let listed=decodeSessions(Data(#"{"sessions":[{"default":true,"name":"default","running":true},{"name":"work","running":false}]}"#.utf8))
    precondition(listed==[HerdrSession(name:"default",running:true),HerdrSession(name:"work",running:false)] && decodeSessions(Data("nope".utf8)).isEmpty)
    let named=agentName(kind:"codex",folder:"Mi Proyecto_2");precondition(named.hasPrefix("codex-mi-proyecto-2-") && named.count==24,"Agent name: \(named)")
    precondition(rootPane(Data(#"{"result":{"root_pane":{"pane_id":"w3:p1"},"tab":{}}}"#.utf8))=="w3:p1" && rootPane(Data("{}".utf8))==nil)
    let codex=[#"{"type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\"cmd\":\"rg --files app\"}"}}"#,
               #"{"type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\"cmd\":\"npm test\"}"}}"#,
               #"{"type":"response_item","payload":{"type":"custom_tool_call","name":"apply_patch","input":"*** Begin"}}"#,
               #"{"type":"response_item","payload":{"type":"reasoning","summary":[]}}"#]
    precondition(codexAction(transcriptTail:codex[0])=="read" && codexAction(transcriptTail:codex[1])=="brew" && codexAction(transcriptTail:codex[0...2].joined(separator:"\n"))=="forge")
    precondition(codexAction(transcriptTail:codex.joined(separator:"\n"))=="type" && codexAction(transcriptTail:#"{"type":"event_msg","payload":{"type":"token_count"}}"#)==nil)
    let kiro=#"{"version":"v1","kind":"AssistantMessage","data":{"content":[{"kind":"text","data":"x"},{"kind":"toolUse","data":{"name":"shell","input":{}}}]}}"#
    precondition(kiroAction(transcriptTail:kiro)=="brew" && kiroAction(transcriptTail:#"{"kind":"AssistantMessage","data":{"content":[{"kind":"text","data":"hola"}]}}"#)=="type" && kiroAction(transcriptTail:#"{"kind":"Prompt","data":{}}"#)==nil)
    precondition(shellAction("/usr/bin/sed -n 1,5p x")=="read" && shellAction("swift build")=="brew" && shellAction("")=="brew")
    var live=[Agent(id:"a",name:"claude",status:"working",project:"p",activity:"x",cwd:"~"),Agent(id:"b",name:"codex",status:"idle",project:"p",activity:"y",cwd:"~")]
    precondition(applyHerdrEvent(["event":"pane.agent_status_changed","data":["pane_id":"b","workspace_id":"w","agent_status":"blocked"]],to:&live,names:[:]) == .changed && live.map(\.id)==["b","a"] && live[0].status=="blocked")
    precondition(applyHerdrEvent(["event":"pane_agent_status_changed","data":["pane_id":"b","agent_status":"blocked"]],to:&live,names:[:]) == .none)
    precondition(applyHerdrEvent(["event":"pane.agent_status_changed","data":["pane_id":"zz","agent_status":"idle"]],to:&live,names:[:]) == .resync)
    precondition(applyHerdrEvent(["event":"pane_updated","data":["pane":["pane_id":"a","agent":"claude","agent_status":"done","workspace_id":"w","terminal_title_stripped":"Nuevo"]]],to:&live,names:["w":"Web"]) == .changed && live.first{$0.id=="a"}?.activity=="Nuevo" && live.first{$0.id=="a"}?.project=="Web")
    precondition(applyHerdrEvent(["event":"pane_updated","data":["pane":["pane_id":"a","agent_status":"idle"]]],to:&live,names:[:]) == .changed && live.map(\.id)==["b"])
    precondition(applyHerdrEvent(["event":"pane_created","data":["pane":["pane_id":"n","agent":"kiro"]]],to:&live,names:[:]) == .resync)
    precondition(applyHerdrEvent(["event":"pane_closed","data":["pane_id":"b"]],to:&live,names:[:]) == .changed && live.isEmpty)
    precondition(applyHerdrEvent(["event":"pane_agent_detected","data":["pane_id":"q"]],to:&live,names:[:]) == .resync && applyHerdrEvent(["event":"pane_focused","data":[:]],to:&live,names:[:]) == .none)
    let subs=herdrSubscriptions(panes:["w2:p1","w1:p1"]);precondition(subs.last?["pane_id"] as? String=="w2:p1" && subs.contains{$0["type"] as? String=="pane.closed"})
    precondition(herdrError(Data(#"{"error":{"code":"agent_blocked","message":"blocked"},"id":"x"}"#.utf8))?.herdrCode=="agent_blocked" && herdrError(Data("oops".utf8))==nil)
    let ordering=Monitor();ordering.apply([Agent(id:"a",name:"claude",status:"idle",project:"p",activity:"",cwd:"~"),Agent(id:"b",name:"claude",status:"working",project:"p",activity:"",cwd:"~").with(jobs:[BackgroundJob(state:"blocked",needs:nil,transcript:nil,updated:Date())])])
    precondition(ordering.agents.map(\.id)==["b","a"],"Attention must lead the grid")
    var fired=false;let item=ClosureMenuItem(title:"x"){fired=true};_=(item.target as AnyObject).perform(item.action,with:item);precondition(fired,"Context menu item did not fire")
    print("PASS: snapshot states, filtering, empty/error handling, monitor transitions, room art, heroes, subagent sessions, subagents keep agents busy, tool actions, translations, git branch, sound alerts + prefs, notifications + prefs, chat selection, question options, filters and search, connection notes, flex-wrap columns, sessions, agent creation, codex + kiro actions, herdr events, context menu, question extraction, Herdr error codes, \(files.count) bundled sprites")
}

if CommandLine.arguments.contains("--self-test") {
    do{try selfTest()}catch{fputs("\(error)\n",stderr);exit(1)}
} else if CommandLine.arguments.contains("--diagnose") {
    do{let agents=try fetchSnapshot(session:Monitor().session);print("OK: \(agents.count) agentes");for a in agents{print("\(a.id) | \(a.name) | \(a.status) | \(a.project)")}}catch{fputs("\(error.localizedDescription)\n",stderr);exit(1)}
} else {
    let app=NSApplication.shared;let delegate=AppDelegate();app.delegate=delegate;app.run()
}

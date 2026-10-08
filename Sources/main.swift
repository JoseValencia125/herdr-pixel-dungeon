import Cocoa
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let monitor=Monitor()
    var window: NSWindow!
    var status: NSStatusItem!
    func applicationDidFinishLaunching(_ notification: Notification) {
        let appMenu=NSMenu()
        let root=NSMenuItem();appMenu.addItem(root)
        let submenu=NSMenu();root.submenu=submenu
        submenu.addItem(withTitle:"Acerca de Herdr Pixel Agents",action:#selector(about),keyEquivalent:"").target=self
        submenu.addItem(.separator())
        submenu.addItem(withTitle:"Salir de Herdr Pixel Agents",action:#selector(quit),keyEquivalent:"q").target=self
        let editRoot=NSMenuItem(title:"Edición",action:nil,keyEquivalent:"");appMenu.addItem(editRoot)
        let edit=NSMenu(title:"Edición");editRoot.submenu=edit
        edit.addItem(withTitle:"Copiar",action:#selector(NSText.copy(_:)),keyEquivalent:"c")
        edit.addItem(withTitle:"Pegar",action:#selector(NSText.paste(_:)),keyEquivalent:"v")
        edit.addItem(withTitle:"Seleccionar todo",action:#selector(NSText.selectAll(_:)),keyEquivalent:"a")
        NSApp.mainMenu=appMenu
        let menu=NSMenu()
        menu.addItem(withTitle:"Mostrar Herdr Pixel Agents",action:#selector(show),keyEquivalent:"m").target=self
        menu.addItem(.separator())
        menu.addItem(withTitle:"Salir",action:#selector(quit),keyEquivalent:"q").target=self
        status=NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength);status.menu=menu
        status.button?.image=NSImage(systemSymbolName:"square.stack.3d.up",accessibilityDescription:"Herdr Pixel Agents")
        status.button?.imagePosition = .imageLeading
        monitor.onChange={ [weak self] in
            guard let self=self else{return}
            let count=self.monitor.agents.filter{$0.status == "blocked"}.count
            self.status.button?.title=self.monitor.error == nil ? " \(self.monitor.agents.count)"+(count>0 ? " · \(count)!" : "") : " —"
            self.status.button?.toolTip="Herdr Pixel Agents · \(count) necesitan atención"
        }
        window=NSWindow(contentRect:NSRect(x:0,y:0,width:1180,height:840),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title="Herdr Pixel Agents";window.contentView=NSHostingView(rootView:Dashboard(monitor:monitor));window.isReleasedWhenClosed=false;window.delegate=self;window.center()
        if CommandLine.arguments.contains("--demo") {monitor.demo=true}
        show();monitor.start()
    }
    @objc func show(){NSApp.setActivationPolicy(.regular);window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)}
    @objc func quit(){NSApp.terminate(nil)}
    @objc func about(){NSApp.orderFrontStandardAboutPanel(options:[.applicationName:"Herdr Pixel Agents",.credits:NSAttributedString(string:"Pixel art: o_lobster · https://o-lobster.itch.io/\nCC BY 4.0 (license included with asset pack).\nBased on Claude Dungeon by thousandsky2024. MIT.")])}
    func windowWillClose(_ notification: Notification){NSApp.setActivationPolicy(.accessory)}
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool)->Bool{show();return true}
}

func selfTest() throws {
    let sample = #"{"result":{"snapshot":{"agents":[{"pane_id":"a","agent":"claude","agent_status":"idle","workspace_id":"w"},{"pane_id":"b","agent":"codex","agent_status":"blocked"},{"pane_id":"shell"}],"workspaces":[{"workspace_id":"w","label":"Example"}]}}}"#
    let agents=try decodeSnapshot(Data(sample.utf8))
    precondition(agents.count==2 && agents[0].status=="blocked" && agents[1].project=="Example")
    do {_ = try decodeSnapshot(Data("{}".utf8));fatalError("Invalid snapshot accepted")}catch{}
    let empty=try decodeSnapshot(Data(#"{"result":{"snapshot":{"agents":[]}}}"#.utf8));precondition(empty.isEmpty)
    let grid=[[true,false,true],[true,false,true],[true,true,true]]
    let path=bfsPath(grid:grid,from:Tile(x:0,y:0),to:Tile(x:2,y:0));precondition(path.count==6)
    var last=Tile(x:0,y:0);for p in path{precondition(grid[p.y][p.x]);precondition(abs(last.x-p.x)+abs(last.y-p.y)==1);last=p}
    precondition(bfsPath(grid:[[true,false,true]],from:Tile(x:0,y:0),to:Tile(x:2,y:0)).isEmpty)
    let monitor=Monitor();monitor.apply(demoAgents(tick:0));monitor.apply(demoAgents(tick:10));precondition(monitor.events.contains{$0.text.contains("Necesita atención")});monitor.apply([]);precondition(monitor.agents.isEmpty)
    let resource=Bundle.main.resourceURL!.appendingPathComponent("Sprites")
    let files=FileManager.default.enumerator(at:resource,includingPropertiesForKeys:nil)!.allObjects.compactMap{$0 as? URL}.filter{$0.pathExtension=="png"}
    precondition(files.count>20);for file in files{precondition(NSImage(contentsOf:file) != nil,"Unreadable asset: \(file.lastPathComponent)")}
    print("PASS: snapshot states, filtering, empty/error handling, BFS walls, monitor transitions, \(files.count) bundled sprites")
}

if CommandLine.arguments.contains("--self-test") {
    do{try selfTest()}catch{fputs("\(error)\n",stderr);exit(1)}
} else if CommandLine.arguments.contains("--diagnose") {
    do{let agents=try fetchSnapshot(session:ProcessInfo.processInfo.environment["HERDR_SESSION"] ?? "default");print("OK: \(agents.count) agentes");for a in agents{print("\(a.id) | \(a.name) | \(a.status) | \(a.project)")}}catch{fputs("\(error.localizedDescription)\n",stderr);exit(1)}
} else {
    let app=NSApplication.shared;let delegate=AppDelegate();app.delegate=delegate;app.run()
}

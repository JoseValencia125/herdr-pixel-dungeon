import Cocoa
import SpriteKit

struct Room {
    let status: String
    let title: String
    let rect: CGRect
    let background: String
    let color: NSColor
}

final class HeroNode: SKNode {
    let sprite = SKSpriteNode()
    let label = SKLabelNode(fontNamed: "Menlo-Bold")
    let marker = SKLabelNode(fontNamed: "Menlo-Bold")
    let selection = SKShapeNode(rectOf: CGSize(width: 42, height: 48), cornerRadius: 3)
    var agent: Agent
    var route: [Tile] = []
    var destination: Tile?
    var animation = ""
    var lastX: CGFloat = 0
    var facingLeft = false
    init(agent: Agent) {
        self.agent = agent
        super.init()
        name = agent.id
        sprite.size = CGSize(width: 48, height: 48); sprite.position.y = 8
        label.fontSize = 9; label.position.y = -23
        marker.fontSize = 18; marker.position.y = 40
        selection.strokeColor = NSColor(red: 0.85, green: 0.95, blue: 0.65, alpha: 1)
        selection.lineWidth = 1; selection.position.y = 7; selection.isHidden = true
        addChild(selection); addChild(sprite); addChild(label); addChild(marker)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

final class DungeonScene: SKScene {
    static let worldSize = CGSize(width: 1000, height: 620)
    let rooms = [
        Room(status: "idle", title: "BIBLIOTECA · EN ESPERA", rect: CGRect(x:20,y:340,width:280,height:240), background:"bg_00_library",color:.systemPurple),
        Room(status: "unknown", title: "SANTUARIO · SIN ESTADO", rect: CGRect(x:330,y:340,width:260,height:240),background:"bg_00_dungeon",color:.systemGray),
        Room(status: "working", title: "ARENA · TRABAJANDO", rect: CGRect(x:620,y:30,width:360,height:550),background:"bg_00_boss_room",color:.systemGreen),
        Room(status: "blocked", title: "PORTAL · ATENCIÓN", rect: CGRect(x:20,y:30,width:280,height:270),background:"bg_00_witch_shop",color:.systemOrange),
        Room(status: "done", title: "TABERNA · TERMINÓ", rect: CGRect(x:330,y:30,width:260,height:270),background:"bg_00_dungeon",color:.systemCyan)
    ]
    var heroes: [String:HeroNode] = [:]
    var onSelect: ((String) -> Void)?
    var selected: String? { didSet { for (id,node) in heroes { node.selection.isHidden = id != selected } } }
    var reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
        didSet { for node in children where !(node is HeroNode) { node.speed = reducedMotion ? 0 : 1 } }
    }
    private var lastTime: TimeInterval = 0
    private var sheets: [String:[SKTexture]] = [:]
    private(set) var grid = Array(repeating: Array(repeating: false, count: 100), count: 62)
    private var initialized = false

    override init(size: CGSize) { super.init(size: size); scaleMode = .aspectFit; backgroundColor = NSColor(red:0.06,green:0.08,blue:0.075,alpha:1); buildWorld() }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func resource(_ relative: String) -> URL? { Bundle.main.resourceURL?.appendingPathComponent("Sprites/" + relative + ".png") }
    func frames(_ file: String, width: Int = 16, height: Int = 16) -> [SKTexture] {
        if let cached = sheets[file] { return cached }
        guard let url = resource(file), let image = NSImage(contentsOf: url) else { return [] }
        let texture = SKTexture(image: image); texture.filteringMode = .nearest
        let count = max(1,Int(texture.size().width)/width)
        let result = (0..<count).map { i -> SKTexture in
            let frame = SKTexture(rect: CGRect(x:CGFloat(i)/CGFloat(count),y:0,width:1/CGFloat(count),height:1), in: texture)
            frame.filteringMode = .nearest; return frame
        }
        sheets[file] = result; return result
    }
    @discardableResult func sprite(_ file: String, at point: CGPoint, scale: CGFloat = 3, frameWidth: Int = 16, frameHeight: Int = 16, animated: Bool = false) -> SKSpriteNode {
        let textures = frames(file,width:frameWidth,height:frameHeight)
        let node = SKSpriteNode(texture:textures.first)
        node.size = CGSize(width:CGFloat(frameWidth)*scale,height:CGFloat(frameHeight)*scale)
        node.position = point; node.zPosition = 2; addChild(node)
        if animated && textures.count > 1 { node.run(.repeatForever(.animate(with:textures,timePerFrame:0.16))) }
        return node
    }
    func label(_ text: String, at point: CGPoint, size: CGFloat = 10, color: NSColor = .white) {
        let node = SKLabelNode(fontNamed:"Menlo-Bold"); node.text=text;node.fontSize=size;node.fontColor=color;node.position=point;node.zPosition=5;addChild(node)
    }
    func fill(_ rect: CGRect, color: NSColor, z: CGFloat = 0) {
        let node=SKSpriteNode(color:color,size:rect.size);node.position=CGPoint(x:rect.midX,y:rect.midY);node.zPosition=z;addChild(node)
    }
    func openGrid(_ r: CGRect) {
        for y in max(0,Int(r.minY)/10)..<min(62,Int(r.maxY)/10) { for x in max(0,Int(r.minX)/10)..<min(100,Int(r.maxX)/10) { grid[y][x]=true } }
    }
    func buildWorld() {
        guard !initialized else { return }; initialized=true
        for room in rooms {
            let r=room.rect
            fill(r.insetBy(dx:-5,dy:-5),color:NSColor(calibratedWhite:0.04,alpha:1))
            fill(r,color:NSColor(red:0.25,green:0.29,blue:0.25,alpha:1))
            if let url=resource("tilesets/"+room.background),let image=NSImage(contentsOf:url){
                let texture=SKTexture(image:image);texture.filteringMode = .nearest
                let bg=SKSpriteNode(texture:texture);bg.size=CGSize(width:r.width-20,height:r.height-20);bg.position=CGPoint(x:r.midX,y:r.midY);bg.color=room.color;bg.colorBlendFactor=0.10;addChild(bg)
            }
            // Masonry frames complement the original background textures.
            for x in stride(from:r.minX,to:r.maxX,by:20){
                fill(CGRect(x:x+1,y:r.maxY-10,width:18,height:8),color:NSColor(red:0.38,green:0.40,blue:0.34,alpha:1),z:1)
                fill(CGRect(x:x+1,y:r.minY,width:18,height:8),color:NSColor(red:0.24,green:0.28,blue:0.24,alpha:1),z:1)
            }
            fill(CGRect(x:r.minX+14,y:r.maxY-40,width:r.width-28,height:22),color:NSColor(calibratedWhite:0.04,alpha:0.8),z:3)
            label(room.title,at:CGPoint(x:r.midX,y:r.maxY-33),size:9,color:room.color.blended(withFraction:0.5,of:.white) ?? .white)
            openGrid(r.insetBy(dx:20,dy:20))
            for x in [r.minX+27,r.maxX-27] { sprite("props/light_source_03_anim",at:CGPoint(x:x,y:r.maxY-85),scale:1.4,frameWidth:16,frameHeight:48,animated:true) }
        }
        let corridors = [CGRect(x:280,y:440,width:70,height:30),CGRect(x:570,y:440,width:70,height:30),CGRect(x:280,y:140,width:70,height:30),CGRect(x:570,y:140,width:70,height:30),CGRect(x:140,y:280,width:30,height:80),CGRect(x:440,y:280,width:30,height:80)]
        for r in corridors { fill(r,color:NSColor(red:0.21,green:0.24,blue:0.20,alpha:1),z:1);openGrid(r) }
        sprite("boss/lord_wizard_idle_anim",at:CGPoint(x:805,y:405),scale:3,frameWidth:48,frameHeight:48,animated:true)
        sprite("props/wall_red_tapestry_static",at:CGPoint(x:700,y:485),scale:2,frameWidth:16,frameHeight:32)
        sprite("props/wall_red_tapestry_static",at:CGPoint(x:900,y:485),scale:2,frameWidth:16,frameHeight:32)
        sprite("npcs/witch_merchant_idle",at:CGPoint(x:158,y:215),scale:2.4,frameWidth:32,frameHeight:32,animated:true)
        sprite("npcs/item_sell_orb",at:CGPoint(x:220,y:215),scale:1.4,frameWidth:16,frameHeight:32)
        sprite("enemies/guardian_idle_right_anim",at:CGPoint(x:150,y:483),scale:3,animated:true)
        sprite("savepoint/goddess_bench_static",at:CGPoint(x:460,y:475),scale:2,frameWidth:32,frameHeight:32)
        for x in [390.0,515.0] { sprite("props/table_and_chair_static",at:CGPoint(x:x,y:223),scale:2,frameWidth:32,frameHeight:8) }
        for x in [77.0,240.0] { sprite("props/wall_painting_00_static",at:CGPoint(x:x,y:506),scale:2) }
        label("HERDR GUILD  /  PIXEL ART BY O_LOBSTER",at:CGPoint(x:500,y:6),size:8,color:.gray)
    }
    func target(_ agent: Agent, index: Int) -> Tile {
        let r=(rooms.first { $0.status == agent.status } ?? rooms[1]).rect
        let columns = max(2,Int((r.width-60)/70))
        let startY: CGFloat = agent.status == "working" ? 260 : 55
        let rows = max(1, Int((r.height - startY - 55)/55))
        return Tile(x:Int(r.minX+45+CGFloat(index%columns)*70)/10,y:Int(r.minY+startY+CGFloat((index/columns)%rows)*55)/10)
    }
    func sync(_ agents: [Agent]) {
        let ids=Set(agents.map(\.id));for id in Array(heroes.keys) where !ids.contains(id) { heroes[id]?.removeFromParent();heroes.removeValue(forKey:id) }
        var count: [String:Int]=[:]
        for agent in agents.sorted(by: { $0.id < $1.id }) {
            let index=count[agent.status,default:0];count[agent.status]=index+1;let dest=target(agent,index:index)
            let hero: HeroNode
            if let existing=heroes[agent.id] { hero=existing } else { hero=HeroNode(agent:agent);hero.position=CGPoint(x:455,y:395);hero.zPosition=10;addChild(hero);heroes[agent.id]=hero }
            hero.agent=agent;hero.label.text=String(agent.project.prefix(11));hero.label.fontColor=NSColor(agent.color)
            hero.marker.text=agent.status == "blocked" ? "!" : agent.status == "done" ? "z z" : nil
            hero.marker.fontColor=NSColor(agent.color)
            if hero.destination != dest {
                let from=hero.route.first ?? Tile(x:Int(hero.position.x)/10,y:Int(hero.position.y)/10)
                hero.route=(hero.route.isEmpty ? [] : [from])+bfsPath(grid:grid,from:from,to:dest);hero.destination=dest
            }
            hero.selection.isHidden=agent.id != selected
            if reducedMotion { hero.position=CGPoint(x:dest.x*10+5,y:dest.y*10+5);hero.route=[] }
            animate(hero)
        }
    }
    func animate(_ hero: HeroNode) {
        let direction=hero.facingLeft ? "left" : "right"
        let kind = !hero.route.isEmpty ? "run" : hero.agent.status == "working" ? "attack_00" : "idle"
        let file="player/char_\(kind)_\(direction)_anim"
        guard hero.animation != file else { return };hero.animation=file
        hero.sprite.removeAllActions();let textures=frames(file)
        hero.sprite.xScale=1;hero.sprite.texture=textures.first
        if !textures.isEmpty { hero.sprite.run(.repeatForever(.animate(with:textures,timePerFrame:kind == "run" ? 0.10 : 0.17))) }
    }
    override func update(_ currentTime: TimeInterval) {
        let dt=lastTime == 0 ? 0 : min(0.05,currentTime-lastTime);lastTime=currentTime
        for hero in heroes.values {
            if reducedMotion, let destination=hero.destination { hero.position=CGPoint(x:destination.x*10+5,y:destination.y*10+5);hero.route=[] }
            if let tile=hero.route.first, !reducedMotion {
                let point=CGPoint(x:tile.x*10+5,y:tile.y*10+5),dx=point.x-hero.position.x,dy=point.y-hero.position.y,d=hypot(dx,dy),step=dt*75
                if abs(dx)>0.1 {hero.facingLeft=dx<0}
                if d<=step {hero.position=point;hero.route.removeFirst()} else {hero.position.x+=dx/d*step;hero.position.y+=dy/d*step}
            }
            hero.zPosition=20-hero.position.y/1000
            animate(hero)
            hero.sprite.speed=reducedMotion ? 0 : 1
        }
    }
    override func mouseDown(with event: NSEvent) {
        let point=event.location(in:self)
        if let match=heroes.values.min(by:{hypot($0.position.x-point.x,$0.position.y-point.y)<hypot($1.position.x-point.x,$1.position.y-point.y)}),hypot(match.position.x-point.x,match.position.y-point.y)<35 {onSelect?(match.agent.id)}
    }
}

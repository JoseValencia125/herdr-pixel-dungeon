import Cocoa
import SpriteKit

/// Visual recipe for a room. Each agent's row renders the room matching its
/// current Herdr status; when the status changes, the row swaps rooms and the
/// hero moves to that room's spot.
struct RoomStyle {
    let status: String
    let title: String
    let background: String        // room art under Sprites/rooms (art/dungeon_rooms.aseprite)
    let color: NSColor
    let playerKind: String        // hero animation row: idle | work
    let bubble: String?           // speech bubble over the hero
    let spot: CGPoint             // hero position in room-art pixels (144x100, origin top-left)
    let roam: CGFloat             // how far the hero wanders left/right of its spot
    let lying: Bool               // asleep in bed
    var route: [CGPoint] = []     // waypoints from the door to the spot, around furniture

    static let all: [RoomStyle] = [
        RoomStyle(status: "blocked", title: tr("ATENCIÓN"),  background: "room_blocked", color: .systemRed,    playerKind: "idle", bubble: nil, spot: CGPoint(x: 72, y: 64), roam: 8,  lying: false),
        RoomStyle(status: "working", title: tr("TRABAJANDO"),background: "room_working", color: .systemOrange, playerKind: "work", bubble: nil, spot: CGPoint(x: 72, y: 34), roam: 0,  lying: false,
                  route: [CGPoint(x: 72, y: 80), CGPoint(x: 36, y: 74), CGPoint(x: 36, y: 36)]),
        RoomStyle(status: "idle",    title: tr("EN ESPERA"), background: "room_idle",    color: .systemGray,   playerKind: "idle", bubble: "z", spot: CGPoint(x: 63, y: 57), roam: 0,  lying: true,
                  route: [CGPoint(x: 72, y: 80), CGPoint(x: 52, y: 72)]),
        RoomStyle(status: "done",    title: tr("LISTO"),     background: "room_done",    color: .systemGreen,  playerKind: "work", bubble: nil, spot: CGPoint(x: 72, y: 66), roam: 0,  lying: false),
        RoomStyle(status: "unknown", title: tr("SIN ESTADO"),background: "room_unknown", color: .systemGray,   playerKind: "idle", bubble: "…", spot: CGPoint(x: 72, y: 62), roam: 24, lying: false)
    ]

    /// The doorway in the bottom wall that every room shares, and a point
    /// just outside it (clipped away) where the hero leaves and arrives.
    static let door = CGPoint(x: 72, y: 88)
    static let outside = CGPoint(x: 72, y: 112)

    static func forStatus(_ status: String) -> RoomStyle { all.first { $0.status == status } ?? all[4] }
}

/// One classic RPG hero per harness, styled after each tool's logo colours.
/// heroes.png (art/heroes.aseprite) stacks two 16 px rows per harness: idle
/// (2 frames) and work (3 frames).
enum Hero {
    static let order = ["claude", "codex", "kiro", "gemini", "hero"]
    static let fallback = "hero"

    static func harness(for agent: String) -> String {
        let name = agent.lowercased()
        return order.first { $0 != fallback && name.contains($0) } ?? fallback
    }
}

/// One horizontal row = one agent living in a room that reflects its state.
/// The room art fills the row; the hero lives in the middle of it.
final class AgentRow: SKNode {
    static let art = CGSize(width: 144, height: 100)
    static let footer: CGFloat = 36         // caption band under the room: chat title + folder · branch
    static let height: CGFloat = 158 + footer  // room art 100 px at 1.5 pt/px + 8 pt frame, plus the footer
    static let width: CGFloat = 220         // room art 144 px at 1.5 pt/px + 4 pt frame
    static let heroSize: CGFloat = 32        // 16 px sprite at 2 pt/px

    let agentId: String
    private var layoutWidth: CGFloat = AgentRow.width
    private var laidOut = false
    private let frameNode = SKShapeNode()
    private let backdrop = SKSpriteNode()
    private let roomCrop = SKCropNode()   // clips the room and its actors to the rounded frame
    private let roomMask = SKShapeNode()
    private let actors = SKNode()         // hero + subagents, clipped with the room
    private let player = SKSpriteNode()
    private let bubble = SKNode()
    private let bubbleLabel = SKLabelNode(fontNamed: "Menlo-Bold")
    private let party = SKNode()          // one mini hero per active subagent
    private let nameLabel = SKLabelNode(fontNamed: "Menlo-Bold")
    private let namePill = SKShapeNode()
    private let roomLabel = SKLabelNode(fontNamed: "Menlo-Bold")
    private let roomPill = SKShapeNode()
    private let activityLabel = SKLabelNode(fontNamed: "Menlo")
    private let activityPill = SKShapeNode()
    private let placeLabel = SKLabelNode(fontNamed: "Menlo")
    private let placePill = SKShapeNode()
    private let footerNode = SKShapeNode()   // solid caption band under the room
    private let blanket = SKSpriteNode()    // the bed's own blanket, drawn over the sleeper
    private let front = SKSpriteNode()      // the room's "front" layer (the desk), drawn over the hero
    private let confetti = SKNode()         // celebration bits in the done room
    private let alarm = SKNode()            // the big "!" and waving arms, riding on the hero
    private let fx = SKNode()               // each room's sparks, sparkles, lights and z's
    private let selectionGlow = SKShapeNode()

    private unowned let host: DungeonScene
    private(set) var currentStatus = ""
    private var style = RoomStyle.forStatus("unknown")
    private var roomTexture: SKTexture?
    private var frontTexture: SKTexture?
    private var playerAnimation = ""
    private var harness = Hero.fallback
    private var subagents = -1
    private var subagentActions: [String] = []
    private var activity = ""
    private var place = ""
    private var nameText = ""
    private var action: String?           // Claude Code tool action while working, nil = cycle through stations
    private var inTransition = false

    init(agent: Agent, scene: DungeonScene) {
        self.agentId = agent.id
        self.host = scene
        super.init()
        name = agent.id

        roomMask.fillColor = .white
        roomMask.lineWidth = 0
        roomCrop.maskNode = roomMask
        roomCrop.zPosition = 0
        roomCrop.addChild(backdrop)
        actors.zPosition = 1
        roomCrop.addChild(actors)
        addChild(roomCrop)

        footerNode.fillColor = NSColor(red: 0.07, green: 0.06, blue: 0.09, alpha: 1)
        footerNode.lineWidth = 0
        footerNode.zPosition = 1
        addChild(footerNode)

        frameNode.lineWidth = 1
        frameNode.fillColor = .clear
        frameNode.zPosition = 2
        addChild(frameNode)

        player.size = CGSize(width: AgentRow.heroSize, height: AgentRow.heroSize)
        player.zPosition = 2
        actors.addChild(party)
        actors.addChild(player)
        blanket.zPosition = 2.5
        actors.addChild(blanket)
        front.zPosition = 2.5   // over the hero (2) and the helpers behind it, under the helpers in front (3)
        actors.addChild(front)
        confetti.zPosition = 4
        actors.addChild(confetti)
        fx.zPosition = 4
        actors.addChild(fx)

        let bubbleBox = SKShapeNode(rect: CGRect(x: -9, y: -8, width: 18, height: 16), cornerRadius: 5)
        bubbleBox.fillColor = .white
        bubbleBox.strokeColor = NSColor(calibratedWhite: 0.1, alpha: 1)
        bubbleBox.lineWidth = 1
        bubble.addChild(bubbleBox)
        bubbleLabel.fontSize = 13
        bubbleLabel.fontColor = .black
        bubbleLabel.verticalAlignmentMode = .center
        bubbleLabel.horizontalAlignmentMode = .center
        bubble.addChild(bubbleLabel)
        bubble.zPosition = 3
        actors.addChild(bubble)

        for (label, pill, size, align) in [(nameLabel, namePill, CGFloat(17), SKLabelHorizontalAlignmentMode.left),
                                           (roomLabel, roomPill, 13, .right),
                                           (activityLabel, activityPill, 11, .left),
                                           (placeLabel, placePill, 11, .right)] {
            label.fontSize = size
            label.horizontalAlignmentMode = align
            label.verticalAlignmentMode = .center
            label.zPosition = 6
            pill.fillColor = NSColor(calibratedWhite: 0, alpha: 0.72)
            pill.lineWidth = 0
            pill.zPosition = 5
            addChild(pill)
            addChild(label)
        }
        activityLabel.fontColor = .white
        placeLabel.fontColor = NSColor(calibratedWhite: 0.82, alpha: 1)

        selectionGlow.strokeColor = NSColor(red: 0.85, green: 0.95, blue: 0.65, alpha: 1)
        selectionGlow.lineWidth = 2
        selectionGlow.fillColor = .clear
        selectionGlow.zPosition = 7
        selectionGlow.isHidden = true
        addChild(selectionGlow)

        resize(width: layoutWidth)
        update(agent: agent, animated: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var isSelected: Bool = false { didSet { selectionGlow.isHidden = !isSelected } }

    /// The room frame inside the row, in row coordinates.
    private var roomFrame: CGRect {
        let h = AgentRow.height
        return CGRect(x: -layoutWidth / 2 + 2, y: -h / 2 + 4 + AgentRow.footer, width: layoutWidth - 4, height: h - 8 - AgentRow.footer)
    }

    /// Room-art pixel (origin top-left) to row coordinates, matching how the
    /// backdrop is aspect-filled and anchored right.
    private func roomPoint(_ p: CGPoint) -> CGPoint {
        let f = roomFrame
        let scale = max(f.width / AgentRow.art.width, f.height / AgentRow.art.height)
        return CGPoint(x: f.maxX - (AgentRow.art.width - p.x) * scale,
                       y: f.midY + (AgentRow.art.height / 2 - p.y) * scale)
    }

    /// Lay the row out for a given width. Positions are relative to the row center.
    func resize(width: CGFloat) {
        // Called on every sync; only lay out again when the width really
        // changes, or the hero's routine and transitions would restart.
        guard width != layoutWidth || !laidOut else { return }
        laidOut = true
        layoutWidth = width
        let f = roomFrame
        let cell = CGRect(x: f.minX, y: f.minY - AgentRow.footer, width: f.width, height: f.height + AgentRow.footer)
        frameNode.path = CGPath(roundedRect: cell, cornerWidth: 6, cornerHeight: 6, transform: nil)
        footerNode.path = CGPath(roundedRect: CGRect(x: cell.minX, y: cell.minY, width: cell.width, height: AgentRow.footer), cornerWidth: 6, cornerHeight: 6, transform: nil)
        selectionGlow.path = CGPath(roundedRect: cell.insetBy(dx: -2, dy: -2), cornerWidth: 7, cornerHeight: 7, transform: nil)
        nameLabel.position = CGPoint(x: f.minX + 12, y: f.maxY - 14)
        roomLabel.position = CGPoint(x: f.maxX - 12, y: f.maxY - 14)
        // Two-line footer: chat title across the cell, folder · branch below it.
        activityLabel.position = CGPoint(x: f.minX + 10, y: f.minY - 11)
        placeLabel.position = CGPoint(x: f.maxX - 10, y: f.minY - AgentRow.footer + 10)
        layoutText()
        layoutBackdrop()
        placeActors()
    }

    /// Apply the agent's latest data. If the status changed, swap the room.
    func update(agent: Agent, animated: Bool) {
        nameText = agent.name
        nameLabel.fontColor = NSColor(agent.color)
        activity = agent.activity
        place = agent.folder + (agent.branch.map { " · " + $0 } ?? "")
        harness = Hero.harness(for: agent.name)
        if agent.action != action {
            action = agent.action
            if style.status == "working" && agent.status == "working" && !inTransition { restartWorking() }
        }
        if agent.status != currentStatus {
            currentStatus = agent.status
            applyRoom(RoomStyle.forStatus(agent.status), animated: animated)
        } else {
            setPlayer()
        }
        if agent.subagents != subagents || agent.subagentActions != subagentActions {
            subagents = agent.subagents
            subagentActions = agent.subagentActions
            setParty()
        }
        layoutText()
    }

    private func layoutText() {
        roomLabel.text = style.title + (subagents > 0 ? " +\(subagents)" : "")
        nameLabel.text = clip(nameText, chars: max(4, Int((roomFrame.width - roomLabel.frame.width - 40) / 10.2)))
        let charW: CGFloat = 6.65, usable = roomFrame.width - 28
        placeLabel.text = clip(place, chars: Int(usable / charW))
        activityLabel.text = clip(activity, chars: Int(usable / charW))
        activityPill.isHidden = true   // the footer band is their backing
        placePill.isHidden = true
        for (label, pill) in [(nameLabel, namePill), (roomLabel, roomPill)] {
            pill.path = CGPath(roundedRect: label.frame.insetBy(dx: -4, dy: -2), cornerWidth: 3, cornerHeight: 3, transform: nil)
        }
    }

    private func clip(_ text: String, chars: Int) -> String {
        text.count > chars ? String(text.prefix(max(1, chars - 1))) + "…" : text
    }

    /// A status change: the hero gets up if asleep, walks out through the
    /// door, the room changes behind it, and it walks back in to its new
    /// spot (around the desk, to the bed) before starting that room's routine.
    private func applyRoom(_ next: RoomStyle, animated: Bool) {
        guard animated, actors.speed > 0, roomTexture != nil else { inTransition = false; return swapRoom(next, animated: animated) }
        inTransition = true
        for key in ["move", "hop", "breathe", "pose", "frames"] { player.removeAction(forKey: key) }
        fx.removeAllActions(); fx.removeAllChildren()
        alarm.removeAllChildren(); alarm.removeFromParent()
        player.childNode(withName: "book")?.removeFromParent()
        confetti.removeAllActions()
        blanket.removeAllActions(); blanket.isHidden = true
        bubble.isHidden = true
        party.run(.fadeOut(withDuration: 0.25))
        walker = artPoint(player.position)
        if style.lying {   // get out of bed first
            player.zRotation = 0
            player.size = CGSize(width: AgentRow.heroSize, height: AgentRow.heroSize)
            walker = CGPoint(x: 52, y: 70)
            player.position = roomPoint(walker)
        }
        player.yScale = 1
        var steps: [SKAction] = []
        for p in style.route.reversed() where style.lying == false || p.y > 71 { steps.append(walkSeq(p, speed: 44)) }
        steps.append(walkSeq(RoomStyle.door, speed: 44))
        steps.append(walkSeq(RoomStyle.outside, speed: 44))
        steps.append(.run { [weak self] in
            guard let self = self else { return }
            self.swapRoom(next, animated: true, routine: false)
            self.player.position = self.roomPoint(RoomStyle.outside)
        })
        walker = RoomStyle.outside
        steps.append(walkSeq(RoomStyle.door, speed: 44))
        for p in next.route { steps.append(walkSeq(p, speed: 44)) }
        if !next.lying { steps.append(walkSeq(next.spot, speed: 44)) }
        steps.append(.run { [weak self] in
            guard let self = self else { return }
            self.inTransition = false
            self.placeActors()
            self.party.removeAllActions(); self.party.alpha = 1
        })
        player.run(.sequence(steps), withKey: "move")
    }

    /// Room-art pixel of a row-coordinate point (inverse of roomPoint).
    private func artPoint(_ p: CGPoint) -> CGPoint {
        let f = roomFrame
        let scale = max(f.width / AgentRow.art.width, f.height / AgentRow.art.height)
        return CGPoint(x: AgentRow.art.width - (f.maxX - p.x) / scale, y: AgentRow.art.height / 2 - (p.y - f.midY) / scale)
    }

    private func swapRoom(_ next: RoomStyle, animated: Bool, routine: Bool = true) {
        style = next
        roomLabel.fontColor = next.color.blended(withFraction: 0.45, of: .white) ?? next.color
        frameNode.strokeColor = next.color.withAlphaComponent(0.85)
        frameNode.removeAction(forKey: "blink")
        frameNode.lineWidth = 1
        if next.status == "blocked" {
            // Border blinks bright red / dark red.
            frameNode.lineWidth = 3
            let bright = NSColor(red: 1, green: 0.2, blue: 0.22, alpha: 1), dim = NSColor(red: 0.35, green: 0.05, blue: 0.08, alpha: 1)
            frameNode.run(.repeatForever(.sequence([.run { [weak self] in self?.frameNode.strokeColor = bright }, .wait(forDuration: 0.35),
                                                    .run { [weak self] in self?.frameNode.strokeColor = dim }, .wait(forDuration: 0.35)])), withKey: "blink")
        }
        roomTexture = host.roomTexture(next.background)
        frontTexture = host.roomTexture(next.background + "_front")
        layoutBackdrop()
        layoutText()
        if routine {
            playerAnimation = ""
            setPlayer()
            placeActors()
        }
        setParty()
        if !routine { party.alpha = 0 }
        if animated {
            for node in [backdrop, front] { node.alpha = 0; node.run(.fadeIn(withDuration: 0.35)) }
        }
    }

    /// Fill the whole row frame with the room art (aspect-fill, anchored right).
    private func layoutBackdrop() {
        let f = roomFrame
        roomMask.path = CGPath(roundedRect: f, cornerWidth: 6, cornerHeight: 6, transform: nil)
        for (node, texture) in [(backdrop, roomTexture), (front, frontTexture)] {
            node.size = f.size
            node.position = CGPoint(x: f.midX, y: f.midY)
            node.isHidden = texture == nil
            guard let art = texture else { node.texture = nil; continue }
            let size = art.size()
            let scale = max(f.width / size.width, f.height / size.height)
            let w = f.width / scale / size.width
            let ch = f.height / scale / size.height
            node.texture = SKTexture(rect: CGRect(x: 1 - w, y: (1 - ch) / 2, width: w, height: ch), in: art)
            node.texture?.filteringMode = .nearest
        }
    }

    private func setPlayer() {
        let key = harness + "/" + style.playerKind
        guard playerAnimation != key else { return }
        playerAnimation = key
        player.removeAction(forKey: "frames")
        if style.lying {
            // Asleep: one still frame with the eyes shut, no fidgeting.
            player.texture = host.sleeperFrame(harness)
            return
        }
        if style.status == "blocked" {
            // Needs attention: one still frame, so only the jump moves.
            player.texture = host.heroFrames(harness, kind: "idle").first
            return
        }
        let textures = host.heroFrames(harness, kind: style.playerKind)
        player.texture = textures.first
        if textures.count > 1 {
            player.run(.repeatForever(.animate(with: textures, timePerFrame: style.playerKind == "work" ? 0.14 : 0.5)), withKey: "frames")
        }
    }

    /// Put the hero on its spot and start that room's motion: wander, hop,
    /// work at the desk, or sleep in bed.
    private func placeActors() {
        let spot = roomPoint(style.spot)
        for key in ["move", "hop", "breathe", "pose"] { player.removeAction(forKey: key) }
        bubble.removeAllActions()
        player.position = spot
        player.zRotation = style.lying ? .pi / 2 : 0
        player.xScale = 1
        player.yScale = 1
        blanket.removeAllActions()
        blanket.yScale = 1
        fx.removeAllActions()
        fx.removeAllChildren()
        alarm.removeAllChildren(); alarm.removeFromParent()
        player.childNode(withName: "book")?.removeFromParent()
        confetti.removeAllActions()
        confetti.removeAllChildren()
        let side = AgentRow.heroSize
        player.size = style.lying ? CGSize(width: DungeonScene.headCrop.width * 2, height: DungeonScene.headCrop.height * 2)
                                  : CGSize(width: side, height: side)
        layoutBlanket()
        playerAnimation = ""
        setPlayer()
        walker = style.spot
        switch style.status {
        case "working": startWorking()
        case "blocked": startBlocked()
        case "done":    startDone()
        case "idle":    startSleeping(head: spot)
        default:        startWandering()
        }
        bubble.isHidden = style.bubble == nil || style.lying
        bubbleLabel.text = style.bubble
        // The bubble rides over the hero's head wherever it goes, bobbing.
        var clock: CGFloat = 0
        bubble.run(.repeatForever(.customAction(withDuration: 1) { [weak self] node, t in
            guard let self = self else { return }
            clock = t
            node.position = CGPoint(x: self.player.position.x, y: self.player.position.y + side / 2 + 10 + 2 * sin(clock * .pi * 2))
        }), withKey: "follow")
    }

    // MARK: Routines

    /// Show the hero's idle or work frames at a given pace.
    private func pose(_ kind: String, pace: TimeInterval) -> SKAction {
        .run { [weak self] in
            guard let self = self else { return }
            self.player.removeAction(forKey: "frames")
            let textures = self.host.heroFrames(self.harness, kind: kind)
            self.player.texture = textures.first
            if textures.count > 1 {
                self.player.run(.repeatForever(.animate(with: textures, timePerFrame: pace)), withKey: "frames")
            }
        }
    }

    /// Walk from where the routine left the hero to a room-art pixel: face
    /// the way and step quickly with a little bob. Routines are built ahead
    /// of time, so `walker` tracks where each walk ends.
    private var walker = CGPoint.zero

    private func walkSeq(_ art: CGPoint, speed: CGFloat = 34) -> SKAction {
        let from = roomPoint(walker), target = roomPoint(art)
        walker = art
        let dx = target.x - from.x
        let time = TimeInterval(max(0.05, hypot(dx, target.y - from.y) / speed))
        let steps = max(1, Int(time / 0.24))
        let bob = SKAction.repeat(.sequence([.moveBy(x: 0, y: 2, duration: 0.12), .moveBy(x: 0, y: -2, duration: 0.12)]), count: steps)
        return .sequence([pose("idle", pace: 0.12), abs(dx) > 1 ? face(dx < 0 ? -1 : 1) : .wait(forDuration: 0),
                          .group([.move(to: target, duration: time), bob])])
    }

    private func face(_ direction: CGFloat) -> SKAction { .run { [weak self] in self?.player.xScale = direction } }

    private func say(_ text: String?) -> SKAction {
        .run { [weak self] in self?.bubble.isHidden = text == nil; self?.bubbleLabel.text = text }
    }

    /// Run `body` every `every` seconds on the effects layer.
    private func emit(every: TimeInterval, range: TimeInterval = 0, _ body: @escaping (AgentRow) -> Void) {
        fx.run(.repeatForever(.sequence([.run { [weak self] in if let self = self { body(self) } },
                                         .wait(forDuration: every, withRange: range)])))
    }

    /// A pixel sparkle that grows, turns and shrinks at a room-art point.
    private func sparkle(at art: CGPoint, color: NSColor = .white, size: CGFloat = 10, jitter: CGFloat = 3) {
        let star = SKSpriteNode(texture: host.sparkleTexture())
        star.size = CGSize(width: size, height: size)
        let p = roomPoint(art)
        star.position = CGPoint(x: p.x + .random(in: -jitter...jitter), y: p.y + .random(in: -jitter...jitter))
        star.color = color
        star.colorBlendFactor = color == .white ? 0 : 0.6
        star.setScale(0)
        star.zPosition = 2
        fx.addChild(star)
        star.run(.sequence([.group([.sequence([.scale(to: 1, duration: 0.18), .wait(forDuration: 0.12), .scale(to: 0, duration: 0.3)]),
                                    .rotate(byAngle: .pi / 4, duration: 0.6)]), .removeFromParent()]))
    }

    /// Small square bits that fly from a point (sparks, code, coins, motes).
    private func bits(at p: CGPoint, colors: [NSColor], count: Int, spread: CGFloat, rise: ClosedRange<CGFloat>,
                      size: CGFloat = 2, life: TimeInterval = 0.7) {
        for _ in 0..<count {
            let bit = SKSpriteNode(color: colors.randomElement()!, size: CGSize(width: size, height: size))
            bit.position = p
            bit.zPosition = 3
            fx.addChild(bit)
            bit.run(.sequence([.group([.moveBy(x: .random(in: -spread...spread), y: .random(in: rise), duration: life),
                                       .sequence([.wait(forDuration: life * 0.5), .fadeOut(withDuration: life * 0.5)])]),
                               .removeFromParent()]))
        }
    }

    /// A soft additive light that flickers or pulses over part of the room.
    private func light(at art: CGPoint, radius: CGFloat, color: NSColor, low: CGFloat, high: CGFloat, pulse: TimeInterval? = nil) {
        let glow = SKSpriteNode(texture: host.glowTexture())
        glow.size = CGSize(width: radius * 2.6, height: radius * 2.6)
        glow.color = color
        glow.colorBlendFactor = 1
        glow.blendMode = .add
        glow.position = roomPoint(art)
        glow.alpha = low
        glow.zPosition = -1
        fx.addChild(glow)
        if let pulse = pulse {
            glow.run(.repeatForever(.sequence([.fadeAlpha(to: high, duration: pulse), .fadeAlpha(to: low, duration: pulse)])))
        } else {
            glow.run(.repeatForever(.sequence([.run { glow.run(.fadeAlpha(to: .random(in: low...high), duration: .random(in: 0.1...0.3))) },
                                               .wait(forDuration: 0.25, withRange: 0.2)])))
        }
    }

    private static let gold = NSColor(red: 0.996, green: 0.906, blue: 0.38, alpha: 1)
    private static let orange = NSColor(red: 0.969, green: 0.463, blue: 0.133, alpha: 1)
    private static let cyan = NSColor(red: 0.173, green: 0.91, blue: 0.961, alpha: 1)
    private static let red = NSColor(red: 0.894, green: 0.231, blue: 0.267, alpha: 1)
    private static let green = NSColor(red: 0.39, green: 0.78, blue: 0.3, alpha: 1)
    private static let violet = NSColor(red: 0.71, green: 0.31, blue: 0.53, alpha: 1)

    /// Take a book (it pops into the hero's hands), open it and read,
    /// flipping pages, then put it back. Works for every hero.
    private func readBook(for seconds: TimeInterval, scroll: Bool = false) -> SKAction {
        let closed = scroll ? host.scrollTexture(open: false) : host.bookTexture(open: false)
        let pages = scroll ? [host.scrollTexture(open: true), host.scrollTexture(open: true, flipped: true)]
                           : [host.bookTexture(open: true), host.bookTexture(open: true, flipped: true)]
        return .sequence([pose("idle", pace: 0.6),
                          .moveBy(x: 0, y: 3, duration: 0.15), .moveBy(x: 0, y: -3, duration: 0.15),   // reach for the shelf
                          .run { [weak self] in
                              guard let self = self else { return }
                              self.player.childNode(withName: "book")?.removeFromParent()
                              let book = SKSpriteNode(texture: closed)
                              book.name = "book"
                              book.size = CGSize(width: 10, height: 10)
                              book.position = CGPoint(x: 0, y: -5)
                              book.zPosition = 0.2
                              self.player.addChild(book)
                              self.sparkle(at: self.artPoint(CGPoint(x: self.player.position.x, y: self.player.position.y + 26)), color: .white, size: 10)
                          },
                          .wait(forDuration: 0.4),
                          .run { [weak self] in
                              guard let book = self?.player.childNode(withName: "book") as? SKSpriteNode else { return }
                              book.size = CGSize(width: 18, height: 12)
                              book.run(.repeatForever(.animate(with: pages, timePerFrame: 0.9)))
                          },
                          .wait(forDuration: seconds),
                          .moveBy(x: 0, y: 3, duration: 0.15), .moveBy(x: 0, y: -3, duration: 0.15),   // put it back
                          .run { [weak self] in self?.player.childNode(withName: "book")?.removeFromParent() }])
    }

    /// Walk to a station, around the desk: going between the top half of
    /// the room and the bottom half uses the free lane on the left or right.
    private func go(_ to: CGPoint) -> SKAction {
        let from = walker
        guard (from.y < 50) != (to.y < 50) else { return walkSeq(to) }
        let lane: CGFloat = (from.x + to.x) / 2 < 72 ? 36 : 106
        return .sequence([walkSeq(CGPoint(x: lane, y: from.y)), walkSeq(CGPoint(x: lane, y: to.y)), walkSeq(to)])
    }

    /// The working agent's action changed: walk from wherever the hero is
    /// to the new station.
    private func restartWorking() {
        for key in ["move", "pose"] { player.removeAction(forKey: key) }
        player.childNode(withName: "book")?.removeFromParent()
        fx.removeAllActions(); fx.removeAllChildren()
        walker = artPoint(player.position)
        startWorking()
    }

    /// Workshop. With a Claude Code action the hero goes to its station and
    /// keeps at it: reading a book (Read, Grep, web search), forging at the
    /// anvil (edits), brewing at the alchemy table (shell), summoning in a
    /// magic circle (subagents), studying a scroll (plans and todos) or
    /// typing at the laptop (thinking, writing). Without one it makes the
    /// rounds of every station.
    private func startWorking() {
        var stations = AgentRow.stations.mapValues(\.spot)
        stations["type"] = style.spot; stations["plan"] = style.spot
        var station = "type"
        func at(_ name: String) -> SKAction { .run { station = name } }
        func activity(_ name: String) -> SKAction {
            switch name {
            case "read":   return .sequence([at("read"), face(1), readBook(for: 3.6)])
            case "plan":   return .sequence([at("plan"), face(1), readBook(for: 3.6, scroll: true)])
            case "forge":  return .sequence([at("forge"), face(-1), pose("work", pace: 0.16), .wait(forDuration: 3)])
            case "brew":   return .sequence([at("brew"), face(1), pose("work", pace: 0.2), .wait(forDuration: 3.4)])
            case "gems":   return .sequence([at("gems"), face(1), pose("work", pace: 0.22), .wait(forDuration: 2)])
            case "summon": return .sequence([at("summon"), face(1), pose("work", pace: 0.09), .wait(forDuration: 3)])
            default:       return .sequence([at("type"), face(1), pose("work", pace: 0.12), .wait(forDuration: 4)])
            }
        }
        if let action = action, let target = stations[action] {
            player.run(.sequence([at("walk"), go(target), .repeatForever(activity(action))]), withKey: "move")
        } else {
            var steps: [SKAction] = [at("walk"), go(style.spot), activity("type")]
            for name in ["read", "forge", "brew", "gems"] { steps += [at("walk"), go(stations[name]!), activity(name)] }
            steps += [at("walk"), go(style.spot)]
            // The first lap starts from wherever the hero stands; later laps loop from the desk.
            var loop: [SKAction] = [activity("type")]
            walker = style.spot
            for name in ["read", "forge", "brew", "gems"] { loop += [at("walk"), go(stations[name]!), activity(name)] }
            loop += [at("walk"), go(style.spot)]
            player.run(.sequence([.sequence(steps), .repeatForever(.sequence(loop))]), withKey: "move")
        }

        light(at: CGPoint(x: 26, y: 18), radius: 26, color: AgentRow.orange, low: 0.08, high: 0.2)
        light(at: CGPoint(x: 72, y: 47), radius: 16, color: AgentRow.cyan, low: 0.06, high: 0.16)
        light(at: CGPoint(x: 124, y: 40), radius: 14, color: AgentRow.cyan, low: 0.05, high: 0.18, pulse: 1.1)
        light(at: CGPoint(x: 93, y: 72), radius: 12, color: AgentRow.green, low: 0.06, high: 0.2, pulse: 0.8)
        let laptop = roomPoint(CGPoint(x: 72, y: 46)), anvilTop = roomPoint(CGPoint(x: 20, y: 41))
        let potions: [NSColor] = [AgentRow.red, AgentRow.green, AgentRow.cyan, AgentRow.violet]
        var angle: CGFloat = 0
        emit(every: 0.14) { row in
            switch station {
            case "type":
                row.bits(at: CGPoint(x: laptop.x + .random(in: -8...8), y: laptop.y + 4), colors: [AgentRow.cyan, .white, AgentRow.green],
                         count: 1, spread: 6, rise: 14...24, size: 2, life: 0.9)
            case "read", "plan":
                if Int.random(in: 0..<3) == 0 {
                    row.bits(at: row.player.position, colors: [.white, AgentRow.gold], count: 1, spread: 8, rise: 8...16, life: 0.8)
                }
            case "forge":
                row.bits(at: anvilTop, colors: [AgentRow.gold, AgentRow.orange, .white], count: 3, spread: 16, rise: 4...16, size: 2, life: 0.45)
            case "brew":
                let flask = row.roomPoint(CGPoint(x: [105, 110, 115, 121, 125][Int.random(in: 0..<5)], y: 68))
                row.bits(at: flask, colors: [potions.randomElement()!], count: 1, spread: 3, rise: 10...20, size: 3, life: 0.9)
                if Int.random(in: 0..<4) == 0 { row.sparkle(at: CGPoint(x: .random(in: 103...126), y: 66), color: potions.randomElement()!, size: 10) }
            case "gems":
                row.sparkle(at: CGPoint(x: .random(in: 116...130), y: .random(in: 34...44)), color: AgentRow.cyan, size: 12)
            case "summon":
                // A ring of violet light turning around the hero's feet, motes rising out of it.
                for k in 0..<3 {
                    let t = angle + CGFloat(k) * 2.1
                    row.sparkle(at: CGPoint(x: 72 + cos(t) * 16, y: 86 + sin(t) * 5), color: AgentRow.violet, size: 9, jitter: 0)
                }
                angle += 0.5
                row.bits(at: row.roomPoint(CGPoint(x: .random(in: 58...86), y: 86)), colors: [AgentRow.violet, .white], count: 1, spread: 2, rise: 14...26, life: 0.9)
            default: break
            }
        }
        // The cauldron bubbles all the time.
        let cauldron = roomPoint(CGPoint(x: 93, y: 71))
        emit(every: 0.3, range: 0.2) { row in
            row.bits(at: CGPoint(x: cauldron.x + .random(in: -5...5), y: cauldron.y), colors: [AgentRow.green, AgentRow.cyan],
                     count: 1, spread: 2, rise: 6...12, size: 2, life: 0.7)
        }
        let glints = [CGPoint(x: 52, y: 12), CGPoint(x: 88, y: 20), CGPoint(x: 119, y: 37), CGPoint(x: 129, y: 41),
                      CGPoint(x: 76, y: 46), CGPoint(x: 114, y: 71), CGPoint(x: 26, y: 16), CGPoint(x: 72, y: 8), CGPoint(x: 124, y: 12)]
        emit(every: 0.45, range: 0.3) { row in row.sparkle(at: glints.randomElement()!, color: .white, size: 9) }
        let furnace = roomPoint(CGPoint(x: 26, y: 16))
        emit(every: 0.2, range: 0.15) { row in
            row.bits(at: CGPoint(x: furnace.x + .random(in: -10...10), y: furnace.y), colors: [AgentRow.gold, AgentRow.orange], count: 1, spread: 4, rise: 8...14, life: 0.9)
        }
    }

    /// Needs attention: the hero keeps jumping on the rug under a huge
    /// pulsing red "!", the room throbs with red light and the cell's border
    /// blinks red.
    private func startBlocked() {
        alarm.removeAllChildren()
        player.addChild(alarm)
        let mark = SKSpriteNode(texture: host.alertTexture())
        mark.size = CGSize(width: 13.5, height: 25.5)
        mark.position = CGPoint(x: 0, y: AgentRow.heroSize / 2 + 16)
        alarm.addChild(mark)
        mark.run(.repeatForever(.sequence([.scale(to: 1.25, duration: 0.18), .scale(to: 1, duration: 0.22), .wait(forDuration: 0.15)])))
        mark.run(.repeatForever(.sequence([.rotate(toAngle: 0.12, duration: 0.12), .rotate(toAngle: -0.12, duration: 0.24), .rotate(toAngle: 0, duration: 0.12)])))
        let hop = SKAction.sequence([.moveBy(x: 0, y: 12, duration: 0.16), .moveBy(x: 0, y: -12, duration: 0.14), .wait(forDuration: 0.06)])
        let seal = SKSpriteNode(texture: host.glowTexture())
        seal.size = CGSize(width: 48, height: 48)
        seal.color = AgentRow.red
        seal.colorBlendFactor = 1
        seal.blendMode = .add
        seal.alpha = 0.2
        seal.position = roomPoint(CGPoint(x: 72, y: 15))
        seal.zPosition = -1
        fx.addChild(seal)
        seal.run(.repeatForever(.sequence([.fadeAlpha(to: 0.5, duration: 0.3), .fadeAlpha(to: 0.15, duration: 0.3)])))
        player.run(.sequence([face(1), .repeatForever(hop)]), withKey: "move")
        // The whole room throbs red.
        let wash = SKSpriteNode(color: AgentRow.red, size: roomFrame.size)
        wash.position = CGPoint(x: roomFrame.midX, y: roomFrame.midY)
        wash.blendMode = .add
        wash.alpha = 0
        wash.zPosition = -1
        fx.addChild(wash)
        wash.run(.repeatForever(.sequence([.fadeAlpha(to: 0.16, duration: 0.35), .fadeAlpha(to: 0.02, duration: 0.45)])))
        light(at: CGPoint(x: 33, y: 33), radius: 12, color: AgentRow.orange, low: 0.1, high: 0.28)
        light(at: CGPoint(x: 109, y: 33), radius: 12, color: AgentRow.orange, low: 0.1, high: 0.28)
        emit(every: 0.25, range: 0.15) { row in
            let brazier = Bool.random() ? CGPoint(x: 33, y: 31) : CGPoint(x: 109, y: 31)
            row.bits(at: row.roomPoint(brazier), colors: [AgentRow.gold, AgentRow.orange], count: 1, spread: 3, rise: 6...12, life: 0.8)
        }
    }

    /// Done: the hero jumps for joy in the middle of the treasure room,
    /// arms up, under a speech bubble with a green tick, while confetti
    /// flies and the gold glints.
    private func startDone() {
        alarm.removeAllChildren()
        player.addChild(alarm)
        let tick = SKSpriteNode(texture: host.tickBubbleTexture())
        tick.size = CGSize(width: 22, height: 24)
        tick.position = CGPoint(x: 0, y: AgentRow.heroSize / 2 + 15)
        alarm.addChild(tick)
        tick.run(.repeatForever(.sequence([.scale(to: 1.12, duration: 0.25), .scale(to: 1, duration: 0.25)])))
        // Arms thrown up, waving with each jump.
        let armTexture = host.armTexture(harness)
        for side: CGFloat in [-1, 1] {
            let arm = SKSpriteNode(texture: armTexture)
            arm.size = CGSize(width: 6, height: 14)
            arm.anchorPoint = CGPoint(x: 0.5, y: 0.08)
            arm.position = CGPoint(x: side * 11, y: -2)
            arm.zPosition = 0.1
            alarm.addChild(arm)
            arm.run(.repeatForever(.sequence([.rotate(toAngle: -side * 0.2, duration: 0.18), .rotate(toAngle: -side * 0.75, duration: 0.18)])))
        }
        let hop = SKAction.sequence([.moveBy(x: 0, y: 14, duration: 0.18), .moveBy(x: 0, y: -14, duration: 0.16), .wait(forDuration: 0.08)])
        let small = SKAction.sequence([.moveBy(x: 0, y: 6, duration: 0.1), .moveBy(x: 0, y: -6, duration: 0.1), .wait(forDuration: 0.1)])
        let party = SKAction.run { [weak self] in self?.burstConfetti() }
        // No turning around: the bubble rides on the hero and would show the tick mirrored.
        player.run(.sequence([face(1), pose("work", pace: 0.1), .repeatForever(.sequence([
            party, hop, party, hop, small, small, party, hop, .wait(forDuration: 0.35)]))]), withKey: "move")
        let coins = [CGPoint(x: 16, y: 41), CGPoint(x: 32, y: 66), CGPoint(x: 46, y: 75), CGPoint(x: 20, y: 81), CGPoint(x: 64, y: 86),
                     CGPoint(x: 86, y: 89), CGPoint(x: 116, y: 83), CGPoint(x: 126, y: 41), CGPoint(x: 127, y: 75), CGPoint(x: 107, y: 46),
                     CGPoint(x: 26, y: 32), CGPoint(x: 72, y: 8), CGPoint(x: 20, y: 8), CGPoint(x: 124, y: 8)]
        emit(every: 0.12, range: 0.08) { row in row.sparkle(at: coins.randomElement()!, color: .white, size: 10) }
        for x in [28.0, 72.0, 116.0] {
            light(at: CGPoint(x: x, y: 40), radius: 22, color: AgentRow.gold, low: 0.04, high: 0.14, pulse: .random(in: 1.2...1.8))
        }
    }

    /// Unknown: wander the ruins looking left and right; the portal swirls,
    /// the orb pulses and motes drift up from it.
    private func startWandering() {
        let c = style.spot, r = style.roam
        let look = SKAction.sequence([face(-1), .wait(forDuration: 0.5), face(1), .wait(forDuration: 0.5), face(-1), .wait(forDuration: 0.4)])
        player.run(.repeatForever(.sequence([
            walkSeq(CGPoint(x: c.x + r, y: c.y + 4), speed: 18), pose("idle", pace: 0.5), look,
            walkSeq(CGPoint(x: c.x - r, y: c.y - 6), speed: 18), pose("idle", pace: 0.5), say("?"), .wait(forDuration: 1), say("…"),
            walkSeq(CGPoint(x: c.x - 4, y: c.y + 12), speed: 18), pose("idle", pace: 0.5), look,
            walkSeq(c, speed: 18), .wait(forDuration: 0.8)])), withKey: "move")
        light(at: CGPoint(x: 72, y: 20), radius: 26, color: AgentRow.violet, low: 0.08, high: 0.24, pulse: 1.6)
        light(at: CGPoint(x: 72, y: 30), radius: 12, color: AgentRow.cyan, low: 0.1, high: 0.3, pulse: 0.9)
        var angle: CGFloat = 0
        let portal = roomPoint(CGPoint(x: 72, y: 20))
        emit(every: 0.09) { row in
            angle += 0.7
            let p = CGPoint(x: portal.x + cos(angle) * 18, y: portal.y + sin(angle) * 12)
            row.bits(at: p, colors: [AgentRow.violet, NSColor(red: 0.96, green: 0.6, blue: 0.8, alpha: 1), .white], count: 1, spread: 2, rise: -2...2, life: 0.6)
        }
        emit(every: 0.35, range: 0.2) { row in
            row.bits(at: row.roomPoint(CGPoint(x: .random(in: 66...78), y: 28)), colors: [AgentRow.cyan, .white], count: 1, spread: 6, rise: 10...20, life: 1.2)
        }
        let glints = [CGPoint(x: 21, y: 9), CGPoint(x: 124, y: 9), CGPoint(x: 112, y: 79), CGPoint(x: 70, y: 28), CGPoint(x: 14, y: 34)]
        emit(every: 0.5, range: 0.3) { row in row.sparkle(at: glints.randomElement()!, color: AgentRow.cyan, size: 9) }
    }

    /// Sleeping in the inn: the blanket rises and falls with each breath,
    /// pixel z's drift up from the pillow, the sleeper turns over now and
    /// then, and the fireplace throws a flickering warm light with embers.
    private func startSleeping(head: CGPoint) {
        // Breathing: in for 1.6 s, out for 2 s.
        let inhale = SKAction.customAction(withDuration: 1.6) { node, t in node.yScale = 1 + 0.12 * sin(.pi / 2 * t / 1.6) }
        let exhale = SKAction.customAction(withDuration: 2.0) { node, t in node.yScale = 1.12 - 0.12 * sin(.pi / 2 * t / 2.0) }
        blanket.run(.repeatForever(.sequence([inhale, exhale])))
        // Turning over: a short shuffle every ~9 s.
        let flat = CGFloat.pi / 2
        let shuffle: [SKAction] = [.wait(forDuration: 9, withRange: 4),
                                   .rotate(toAngle: flat + 0.12, duration: 0.15),
                                   .rotate(toAngle: flat - 0.08, duration: 0.2),
                                   .rotate(toAngle: flat, duration: 0.25)]
        player.run(.repeatForever(.sequence(shuffle)), withKey: "move")

        // Z's: one per breath, small to big, wobbling up and to the right.
        let zTexture = host.zTexture()
        fx.run(.repeatForever(.sequence([.run { [weak self] in
            guard let self = self else { return }
            let z = SKSpriteNode(texture: zTexture)
            z.size = CGSize(width: 14, height: 14)
            z.position = CGPoint(x: head.x + 4, y: head.y + 10)
            z.setScale(0.5)
            z.alpha = 0
            self.fx.addChild(z)
            let rise = SKAction.customAction(withDuration: 2.8) { node, t in
                let k = t / 2.8
                node.position = CGPoint(x: head.x + 4 + 16 * k + 3 * sin(k * .pi * 3), y: head.y + 10 + 30 * k)
            }
            z.run(.sequence([.group([rise, .scale(to: 1.3, duration: 2.8),
                                     .sequence([.fadeIn(withDuration: 0.4), .wait(forDuration: 1.6), .fadeOut(withDuration: 0.8)])]),
                             .removeFromParent()]))
        }, .wait(forDuration: 1.2)])))

        // Night: the room sinks into the dark and only the fireplace lights
        // it, a warm pool that breathes slowly. Embers rise from the hearth.
        let hearth = roomPoint(CGPoint(x: 70, y: 22))
        let dark = SKSpriteNode(texture: host.darknessTexture())
        let reach = roomFrame.width * 2
        dark.size = CGSize(width: reach, height: reach)
        dark.position = hearth
        dark.zPosition = -0.5   // over the room, the hero and the blanket; under the z's
        fx.addChild(dark)
        dark.run(.repeatForever(.sequence([.scale(to: 1.05, duration: 1.8), .scale(to: 0.97, duration: 2.2)])))
        let fire = SKSpriteNode(texture: host.glowTexture())
        fire.size = CGSize(width: 90, height: 70)
        fire.color = NSColor(red: 1, green: 0.55, blue: 0.2, alpha: 1)
        fire.colorBlendFactor = 1
        fire.blendMode = .add
        fire.position = CGPoint(x: hearth.x, y: hearth.y - 6)
        fire.alpha = 0.14
        fire.zPosition = -0.4
        fx.addChild(fire)
        fire.run(.repeatForever(.sequence([.run {
            fire.run(.fadeAlpha(to: .random(in: 0.1...0.2), duration: .random(in: 0.9...1.6)))
        }, .wait(forDuration: 1.4, withRange: 0.6)])))
        let flameColors = [NSColor(red: 0.996, green: 0.906, blue: 0.38, alpha: 1), NSColor(red: 0.969, green: 0.463, blue: 0.133, alpha: 1)]
        fx.run(.repeatForever(.sequence([.run { [weak self] in
            guard let self = self else { return }
            let ember = SKSpriteNode(color: flameColors.randomElement()!, size: CGSize(width: 2, height: 2))
            ember.position = CGPoint(x: hearth.x + .random(in: -14...14), y: hearth.y)
            self.fx.addChild(ember)
            ember.run(.sequence([.group([.moveBy(x: .random(in: -4...4), y: .random(in: 8...14), duration: 0.9),
                                         .fadeOut(withDuration: 0.9)]), .removeFromParent()]))
        }, .wait(forDuration: 0.25, withRange: 0.2)])))
    }

    /// A few square bits of gold, white and red that pop over the hero and fall.
    private func burstConfetti() {
        let colors: [NSColor] = [NSColor(red: 0.996, green: 0.906, blue: 0.38, alpha: 1), .white,
                                 NSColor(red: 0.894, green: 0.231, blue: 0.267, alpha: 1), NSColor(red: 0.173, green: 0.91, blue: 0.961, alpha: 1)]
        for _ in 0..<3 {
            let bit = SKSpriteNode(color: colors.randomElement()!, size: CGSize(width: 3, height: 3))
            bit.position = CGPoint(x: player.position.x + .random(in: -14...14), y: player.position.y + AgentRow.heroSize / 2 + .random(in: 2...10))
            confetti.addChild(bit)
            let drift = CGFloat.random(in: -18...18)
            bit.run(.sequence([.group([.moveBy(x: drift, y: -34, duration: 1.1), .fadeOut(withDuration: 1.1),
                                       .rotate(byAngle: .pi * 2, duration: 1.1)]), .removeFromParent()]))
        }
    }

    /// In bed, the bed's own blanket (cut from the room art) covers the
    /// sleeper so only the head shows on the pillow.
    private func layoutBlanket() {
        guard style.lying, let art = roomTexture else { blanket.isHidden = true; return }
        let region = CGRect(x: 70, y: 53, width: 20, height: 9)   // blanket in room-art pixels
        let size = art.size()
        blanket.texture = SKTexture(rect: CGRect(x: region.minX / size.width, y: 1 - region.maxY / size.height,
                                                 width: region.width / size.width, height: region.height / size.height), in: art)
        blanket.texture?.filteringMode = .nearest
        let a = roomPoint(CGPoint(x: region.minX, y: region.minY)), b = roomPoint(CGPoint(x: region.maxX, y: region.maxY))
        blanket.size = CGSize(width: b.x - a.x, height: a.y - b.y)
        blanket.position = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        blanket.isHidden = false
    }

    /// Where each workshop station is in the room art, and which way a hero
    /// at it faces. Typing and planning happen at the desk (`style.spot`).
    static let stations: [String: (spot: CGPoint, facing: CGFloat)] = [
        "read": (CGPoint(x: 53, y: 33), 1), "forge": (CGPoint(x: 32, y: 40), -1), "brew": (CGPoint(x: 114, y: 63), 1),
        "gems": (CGPoint(x: 108, y: 38), 1), "summon": (CGPoint(x: 72, y: 76), 1)]

    /// Active subagents are small heroes of the same harness, each at the
    /// station of its own last tool (read at the shelf, brew at the alchemy
    /// table…), a step darker so the lead hero stays the clearest shape.
    /// Several at one station stand side by side; one with no known tool
    /// waits on the free floor in front of the desk. When a subagent changes
    /// tool it walks to the new station.
    private func setParty() {
        let count = min(max(subagents, 0), 4)
        while party.children.count > count { party.children.last?.removeFromParent() }
        guard count > 0 else { return }
        let textures = host.heroFrames(harness, kind: "work")
        // The lead hero already stands at its own station: start beside it.
        var taken: [String: Int] = action.map { [$0: 1] } ?? [:]
        for i in 0..<count {
            let action = i < subagentActions.count ? subagentActions[i] : "idle"
            let station = AgentRow.stations[action]
            // Typing and planning share the desk with the lead hero: stand beside it.
            let base = station?.spot ?? (action == "type" || action == "plan" ? CGPoint(x: style.spot.x, y: style.spot.y) : CGPoint(x: 72, y: 88))
            let k = taken[action, default: 0]
            taken[action] = k + 1
            let nudge: [CGFloat] = action == "type" || action == "plan" ? [-18, 18, -30, 30] : [0, 11, -11, 22]
            let art = CGPoint(x: base.x + nudge[k % nudge.count], y: base.y + (k > 0 ? 2 : 0))
            let home = roomPoint(art)
            let mini: SKSpriteNode
            if i < party.children.count, let existing = party.children[i] as? SKSpriteNode {
                mini = existing
                mini.removeAction(forKey: "walk")
                let distance = hypot(home.x - mini.position.x, home.y - mini.position.y)
                mini.run(.move(to: home, duration: TimeInterval(distance / 50)), withKey: "walk")
            } else {
                mini = SKSpriteNode(texture: textures.first)
                mini.size = CGSize(width: 24, height: 24)
                mini.position = home
                mini.color = .black
                mini.colorBlendFactor = 0.3
                if textures.count > 1 { mini.run(.repeatForever(.animate(with: textures, timePerFrame: 0.16))) }
                party.addChild(mini)
            }
            mini.zPosition = art.y > style.spot.y ? 3 : 1    // in front of the desk or behind it
            mini.xScale = (station?.facing ?? 1) * (action == "type" || action == "plan" ? (nudge[k % nudge.count] < 0 ? 1 : -1) : 1)
            // Readers and planners hold an open book or scroll.
            mini.childNode(withName: "book")?.removeFromParent()
            if action == "read" || action == "plan" {
                let book = SKSpriteNode(texture: action == "plan" ? host.scrollTexture(open: true) : host.bookTexture(open: true))
                book.name = "book"
                book.size = CGSize(width: 12, height: 8)
                book.position = CGPoint(x: 0, y: -4)
                book.zPosition = 0.2
                mini.addChild(book)
            }
        }
    }

    func setMotion(reduced: Bool) {
        actors.speed = reduced ? 0 : 1
    }
}


final class DungeonScene: SKScene {
    static let worldWidth: CGFloat = 1000

    private var rows: [String: AgentRow] = [:]
    private var order: [String] = []
    private let container = SKNode()
    private let emptyLabel = SKLabelNode(fontNamed: "Menlo-Bold")
    var emptyText = tr("Sin agentes en la sesión") { didSet { emptyLabel.text = emptyText } }
    /// How far the rooms are scrolled up, in points, when they do not fit.
    private var scroll: CGFloat = 0
    private var contentHeight: CGFloat = 0
    private let scrollBar = SKShapeNode()

    var onSelect: ((String) -> Void)?
    /// Right click → "end agent": the dashboard confirms and types /exit.
    var onFinish: ((String) -> Void)?
    var selected: String? {
        didSet {
            for (id, row) in rows { row.isSelected = (id == selected) }
            if let id = selected { reveal(id) }
        }
    }
    var reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
        didSet { for row in rows.values { row.setMotion(reduced: reducedMotion) } }
    }

    private var sheets: [String: [SKTexture]] = [:]
    private var rooms: [String: SKTexture] = [:]

    override init(size: CGSize) {
        super.init(size: size)
        scaleMode = .resizeFill
        backgroundColor = NSColor(red: 0.05, green: 0.06, blue: 0.065, alpha: 1)
        addChild(container)
        emptyLabel.text = tr("Sin agentes en la sesión")
        emptyLabel.fontSize = 16
        emptyLabel.fontColor = NSColor(calibratedWhite: 0.5, alpha: 1)
        emptyLabel.isHidden = true
        addChild(emptyLabel)
        scrollBar.fillColor = NSColor(calibratedWhite: 1, alpha: 0.35)
        scrollBar.strokeColor = .clear
        scrollBar.zPosition = 50
        scrollBar.isHidden = true
        addChild(scrollBar)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Asset helpers

    func resource(_ relative: String) -> URL? {
        Bundle.main.resourceURL?.appendingPathComponent("Sprites/" + relative + ".png")
    }

    func roomTexture(_ file: String) -> SKTexture? {
        if let cached = rooms[file] { return cached }
        guard let url = resource("rooms/" + file), let image = NSImage(contentsOf: url) else { return nil }
        let texture = SKTexture(image: image)
        texture.filteringMode = .nearest
        rooms[file] = texture
        return texture
    }

    func heroFrames(_ harness: String, kind: String) -> [SKTexture] {
        let key = "heroes/\(harness)/\(kind)"
        if let cached = sheets[key] { return cached }
        guard let url = resource("heroes/heroes"), let image = NSImage(contentsOf: url) else { return [] }
        let sheet = SKTexture(image: image)
        sheet.filteringMode = .nearest
        let rows = CGFloat(Hero.order.count * 2)
        let row = CGFloat((Hero.order.firstIndex(of: harness) ?? Hero.order.count - 1) * 2 + (kind == "work" ? 1 : 0))
        let count = kind == "work" ? 3 : 2
        let result = (0..<count).map { i -> SKTexture in
            // SpriteKit texture space starts at the bottom-left corner.
            let frame = SKTexture(rect: CGRect(x: CGFloat(i) / 3, y: 1 - (row + 1) / rows, width: 1 / 3, height: 1 / rows), in: sheet)
            frame.filteringMode = .nearest
            return frame
        }
        sheets[key] = result
        return result
    }

    /// The hero's first idle frame with its eyes shut: each lone dark pixel
    /// set in the face (same light colour left and right) becomes a darker
    /// shade of that face colour, which reads as a closed lid.
    /// The sleeper's head only (the body is under the blanket): the top of
    /// the hero's first idle frame, without staff or shield, eyes shut. Each
    /// lone dark pixel set in the face (same light colour left and right)
    /// becomes a darker shade of that face colour, which reads as a closed lid.
    static let headCrop = CGRect(x: 1, y: 0, width: 11, height: 10)   // sprite pixels, origin top-left

    func sleeperFrame(_ harness: String) -> SKTexture? {
        let key = "heroes/\(harness)/sleep"
        if let cached = sheets[key] { return cached.first }
        let w = Int(DungeonScene.headCrop.width), h = Int(DungeonScene.headCrop.height)
        guard let url = resource("heroes/heroes"), let image = NSImage(contentsOf: url),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return heroFrames(harness, kind: "idle").first }
        let row = (Hero.order.firstIndex(of: harness) ?? Hero.order.count - 1) * 2
        guard let cell = cg.cropping(to: DungeonScene.headCrop.offsetBy(dx: 0, dy: CGFloat(row * 32))),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return heroFrames(harness, kind: "idle").first }
        ctx.draw(cell, in: CGRect(x: 0, y: 0, width: w, height: h))
        func px(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
            let i = (y * w + x) * 4; return (data[i], data[i + 1], data[i + 2], data[i + 3])
        }
        func dark(_ p: (UInt8, UInt8, UInt8, UInt8)) -> Bool { p.3 > 0 && Int(p.0) + Int(p.1) + Int(p.2) < 160 }
        var lids: [(Int, Int, (UInt8, UInt8, UInt8, UInt8))] = []
        for y in 0..<h { for x in 1..<(w - 1) {   // memory row 0 is the top of the sprite
            let c = px(x, y), l = px(x - 1, y), r = px(x + 1, y)
            if dark(c), !dark(l), l.3 > 0, l == r, Int(l.0) + Int(l.1) + Int(l.2) > 380 { lids.append((x, y, l)) }
        } }
        for (x, y, face) in lids {
            let i = (y * w + x) * 4
            data[i] = UInt8(Double(face.0) * 0.72); data[i + 1] = UInt8(Double(face.1) * 0.62); data[i + 2] = UInt8(Double(face.2) * 0.62)
        }
        guard let out = ctx.makeImage() else { return heroFrames(harness, kind: "idle").first }
        let texture = SKTexture(cgImage: out)
        texture.filteringMode = .nearest
        sheets[key] = [texture]
        return texture
    }

    /// A 5x5 pixel four-point star, white with a gold rim, tinted per room.
    func sparkleTexture() -> SKTexture {
        if let cached = sheets["fx/sparkle"]?.first { return cached }
        let texture = pixelTexture(["..y..",
                                    "..w..",
                                    "ywWwy",
                                    "..w..",
                                    "..y.."], colors: ["y": CGColor(red: 1, green: 0.91, blue: 0.5, alpha: 1),
                                                       "w": CGColor(red: 1, green: 1, blue: 1, alpha: 0.9),
                                                       "W": CGColor(red: 1, green: 1, blue: 1, alpha: 1)])
        sheets["fx/sparkle"] = [texture]
        return texture
    }

    /// A small book: closed (red cover, gold clasp) or open (two cream
    /// pages with text lines; `flipped` moves the lines as a page turns).
    func bookTexture(open: Bool, flipped: Bool = false) -> SKTexture {
        let key = "fx/book/\(open)/\(flipped)"
        if let cached = sheets[key]?.first { return cached }
        let rows = !open ? ["kkkkk", "kRRRk", "kRYRk", "kRRRk", "kkkkk"]
                 : flipped ? ["kkkk.kkkk", "kWWWkWWWk", "kWWWkWlWk", "kWlWkWWWk", "kRRRkRRRk", ".kkkkkkk."]
                           : ["kkkk.kkkk", "kWWWkWWWk", "kWlWkWWWk", "kWWWkWlWk", "kRRRkRRRk", ".kkkkkkk."]
        let texture = pixelTexture(rows, colors: ["k": CGColor(red: 0.094, green: 0.078, blue: 0.145, alpha: 1),
                                                  "R": CGColor(red: 0.635, green: 0.149, blue: 0.2, alpha: 1),
                                                  "Y": CGColor(red: 0.996, green: 0.906, blue: 0.38, alpha: 1),
                                                  "W": CGColor(red: 0.918, green: 0.831, blue: 0.667, alpha: 1),
                                                  "l": CGColor(red: 0.353, green: 0.412, blue: 0.533, alpha: 1)])
        sheets[key] = [texture]
        return texture
    }

    /// A small parchment scroll: rolled up, or open between two wooden rods.
    func scrollTexture(open: Bool, flipped: Bool = false) -> SKTexture {
        let key = "fx/scroll/\(open)/\(flipped)"
        if let cached = sheets[key]?.first { return cached }
        let rows = !open ? ["kkkkk", "kDWDk", "kkkkk"]
                 : flipped ? ["kkkkkkkkk", "kDWWWWWDk", "kDWlWWlDk", "kDWWlWWDk", "kkkkkkkkk"]
                           : ["kkkkkkkkk", "kDWWWWWDk", "kDWlWlWDk", "kDWWWlWDk", "kkkkkkkkk"]
        let texture = pixelTexture(rows, colors: ["k": CGColor(red: 0.094, green: 0.078, blue: 0.145, alpha: 1),
                                                  "D": CGColor(red: 0.722, green: 0.435, blue: 0.314, alpha: 1),
                                                  "W": CGColor(red: 0.918, green: 0.831, blue: 0.667, alpha: 1),
                                                  "l": CGColor(red: 0.635, green: 0.149, blue: 0.2, alpha: 1)])
        sheets[key] = [texture]
        return texture
    }

    /// A white speech bubble with a green tick, for a finished agent.
    func tickBubbleTexture() -> SKTexture {
        if let cached = sheets["fx/tick"]?.first { return cached }
        let texture = pixelTexture([".kkkkkkkkk.",
                                    "kwwwwwwwwwk",
                                    "kwwwwwwwGwk",
                                    "kwwwwwwGgwk",
                                    "kwGwwwGgwwk",
                                    "kwgGwGgwwwk",
                                    "kwwgGgwwwwk",
                                    "kwwwgwwwwwk",
                                    "kwwwwwwwwwk",
                                    ".kkkkkkkkk.",
                                    "...kwk.....",
                                    "....k......"], colors: ["k": CGColor(red: 0.094, green: 0.078, blue: 0.145, alpha: 1),
                                                             "w": CGColor(red: 1, green: 1, blue: 1, alpha: 1),
                                                             "G": CGColor(red: 0.388, green: 0.78, blue: 0.302, alpha: 1),
                                                             "g": CGColor(red: 0.243, green: 0.537, blue: 0.282, alpha: 1)])
        sheets["fx/tick"] = [texture]
        return texture
    }

    /// A big red exclamation mark with a dark outline and a white glint.
    func alertTexture() -> SKTexture {
        if let cached = sheets["fx/alert"]?.first { return cached }
        let texture = pixelTexture(["..wwwww..",
                                    ".wkkkkkw.",
                                    "wkRWRRdkw",
                                    "wkRWRRdkw",
                                    "wkRRRRdkw",
                                    ".wkRRdkw.",
                                    ".wkRRdkw.",
                                    ".wkRRdkw.",
                                    ".wkRRdkw.",
                                    "..wkRkw..",
                                    "..wkRkw..",
                                    "..wkkkw..",
                                    ".wwkkkww.",
                                    ".wkRRdkw.",
                                    ".wkRRdkw.",
                                    ".wkkkkkw.",
                                    "..wwwww.."], colors: ["k": CGColor(red: 0.094, green: 0.078, blue: 0.145, alpha: 1),
                                                           "R": CGColor(red: 0.894, green: 0.231, blue: 0.267, alpha: 1),
                                                           "d": CGColor(red: 0.635, green: 0.149, blue: 0.2, alpha: 1),
                                                           "W": CGColor(red: 1, green: 1, blue: 1, alpha: 1),
                                                           "w": CGColor(red: 1, green: 1, blue: 1, alpha: 1)])
        sheets["fx/alert"] = [texture]
        return texture
    }

    /// A 3x7 raised arm in the hero's sleeve colour, hand at the top.
    func armTexture(_ harness: String) -> SKTexture {
        let key = "fx/arm/" + harness
        if let cached = sheets[key]?.first { return cached }
        let sleeves: [String: CGColor] = ["claude": CGColor(red: 0.843, green: 0.463, blue: 0.263, alpha: 1),
                                          "codex": CGColor(red: 0.227, green: 0.267, blue: 0.4, alpha: 1),
                                          "kiro": CGColor(red: 0.408, green: 0.22, blue: 0.424, alpha: 1),
                                          "gemini": CGColor(red: 0.071, green: 0.306, blue: 0.537, alpha: 1),
                                          "hero": CGColor(red: 0.243, green: 0.537, blue: 0.282, alpha: 1)]
        let hand = harness == "codex" ? CGColor(red: 0.753, green: 0.796, blue: 0.863, alpha: 1) : CGColor(red: 0.91, green: 0.718, blue: 0.588, alpha: 1)
        let texture = pixelTexture(["kHk", "kHk", "kSk", "kSk", "kSk", "kSk", ".k."],
                                   colors: ["k": CGColor(red: 0.094, green: 0.078, blue: 0.145, alpha: 1), "H": hand,
                                            "S": sleeves[harness] ?? sleeves["hero"]!])
        sheets[key] = [texture]
        return texture
    }

    /// A soft white radial falloff for additive lights.
    /// Night for the resting room: clear in the middle, darkening outward,
    /// so centred on the hearth it leaves only a pool of firelight.
    func darknessTexture() -> SKTexture {
        if let cached = sheets["fx/darkness"]?.first { return cached }
        let n = 128
        let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let night = CGColor(red: 0.02, green: 0.01, blue: 0.04, alpha: 1)
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: [night.copy(alpha: 0)!, night.copy(alpha: 0.12)!, night.copy(alpha: 0.6)!,
                                           night.copy(alpha: 0.82)!, night.copy(alpha: 0.86)!] as CFArray,
                                  locations: [0, 0.1, 0.28, 0.5, 1])!
        let c = CGPoint(x: n / 2, y: n / 2)
        ctx.drawRadialGradient(gradient, startCenter: c, startRadius: 0, endCenter: c, endRadius: CGFloat(n) / 2, options: [.drawsAfterEndLocation])
        let texture = SKTexture(cgImage: ctx.makeImage()!)
        sheets["fx/darkness"] = [texture]
        return texture
    }

    func glowTexture() -> SKTexture {
        if let cached = sheets["fx/glow"]?.first { return cached }
        let n = 64
        let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: [CGColor(red: 1, green: 1, blue: 1, alpha: 1), CGColor(red: 1, green: 1, blue: 1, alpha: 0.35),
                                           CGColor(red: 1, green: 1, blue: 1, alpha: 0)] as CFArray, locations: [0, 0.45, 1])!
        let c = CGPoint(x: n / 2, y: n / 2)
        ctx.drawRadialGradient(gradient, startCenter: c, startRadius: 0, endCenter: c, endRadius: CGFloat(n) / 2, options: [])
        let texture = SKTexture(cgImage: ctx.makeImage()!)
        sheets["fx/glow"] = [texture]
        return texture
    }

    private func pixelTexture(_ rows: [String], colors: [Character: CGColor]) -> SKTexture {
        let w = rows[0].count, h = rows.count
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for (y, line) in rows.enumerated() {
            for (x, ch) in line.enumerated() {
                guard let color = colors[ch] else { continue }
                ctx.setFillColor(color)
                ctx.fill(CGRect(x: x, y: h - 1 - y, width: 1, height: 1))   // CG origin is bottom-left
            }
        }
        let texture = SKTexture(cgImage: ctx.makeImage()!)
        texture.filteringMode = .nearest
        return texture
    }

    /// A 7x7 pixel "z" with a dark outline, for the sleeper.
    func zTexture() -> SKTexture {
        if let cached = sheets["fx/z"]?.first { return cached }
        let rows = ["kkkkkk.",
                    "kwwwwk.",
                    "kkkwkk.",
                    ".kwkk..",
                    "kwkkkk.",
                    "kwwwwk.",
                    "kkkkkk."]
        let ctx = CGContext(data: nil, width: 7, height: 7, bitsPerComponent: 8, bytesPerRow: 28,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for (y, line) in rows.enumerated() {
            for (x, ch) in line.enumerated() where ch != "." {
                ctx.setFillColor(ch == "w" ? CGColor(red: 0.92, green: 0.95, blue: 1, alpha: 1) : CGColor(red: 0.094, green: 0.078, blue: 0.145, alpha: 1))
                ctx.fill(CGRect(x: x, y: 6 - y, width: 1, height: 1))   // CG origin is bottom-left
            }
        }
        let texture = SKTexture(cgImage: ctx.makeImage()!)
        texture.filteringMode = .nearest
        sheets["fx/z"] = [texture]
        return texture
    }

    func frames(_ file: String, width: Int = 16, height: Int = 16) -> [SKTexture] {
        if let cached = sheets[file] { return cached }
        guard let url = resource(file), let image = NSImage(contentsOf: url) else { return [] }
        let texture = SKTexture(image: image)
        texture.filteringMode = .nearest
        let count = max(1, Int(texture.size().width) / width)
        let result = (0..<count).map { i -> SKTexture in
            let frame = SKTexture(rect: CGRect(x: CGFloat(i) / CGFloat(count), y: 0, width: 1 / CGFloat(count), height: 1), in: texture)
            frame.filteringMode = .nearest
            return frame
        }
        sheets[file] = result
        return result
    }

    // MARK: Sync

    func sync(_ agents: [Agent]) {
        let ids = Set(agents.map(\.id))
        for id in Array(rows.keys) where !ids.contains(id) {
            rows[id]?.removeFromParent()
            rows.removeValue(forKey: id)
        }
        // Agents arrive already sorted by rank (attention first); keep that order.
        order = agents.map(\.id)
        emptyLabel.isHidden = !agents.isEmpty

        for agent in agents {
            if let row = rows[agent.id] {
                row.update(agent: agent, animated: true)
            } else {
                let row = AgentRow(agent: agent, scene: self)
                row.isSelected = (agent.id == selected)
                row.setMotion(reduced: reducedMotion)
                rows[agent.id] = row
                container.addChild(row)
            }
        }
        layout()
    }

    /// Stack rows vertically, attention on top, filling the widget from the top.
    /// A lone agent gets a single room; otherwise two columns.
    /// Rooms wrap like a flex row: as many columns as fit the width.
    static func columns(fitting width: CGFloat) -> Int { max(1, Int((width - gap + 0.5) / (AgentRow.width + gap))) }
    static func width(columns: Int) -> CGFloat { CGFloat(columns) * AgentRow.width + CGFloat(columns + 1) * gap }
    static let gap: CGFloat = 6
    static let topPad: CGFloat = 14   // room for the drag handle

    /// Lay agents out as a two-column grid of rooms, attention first,
    /// filling from the top-left.
    private func layout() {
        let cellW = AgentRow.width, cellH = AgentRow.height
        let columns = DungeonScene.columns(fitting: size.width)
        let gap = max(DungeonScene.gap, (size.width - CGFloat(columns) * cellW) / CGFloat(columns + 1))
        emptyLabel.position = CGPoint(x: size.width / 2, y: size.height / 2)

        let lines = (order.count + columns - 1) / columns
        contentHeight = DungeonScene.topPad + CGFloat(lines) * cellH + CGFloat(max(lines - 1, 0)) * DungeonScene.gap + DungeonScene.bottomPad
        scrollTo(scroll, animated: false)

        for (index, id) in order.enumerated() {
            guard let row = rows[id] else { continue }
            row.resize(width: cellW)
            let col = index % columns, line = index / columns
            let x = gap + cellW / 2 + CGFloat(col) * (cellW + gap)
            let y = size.height - DungeonScene.topPad - cellH / 2 - CGFloat(line) * (cellH + DungeonScene.gap)
            let target = CGPoint(x: x, y: y)
            if row.parent != nil && row.position != .zero {
                row.run(.move(to: target, duration: reducedMotion ? 0 : 0.25))
            } else {
                row.position = target
            }
        }
    }

    override func didChangeSize(_ oldSize: CGSize) {
        super.didChangeSize(oldSize)
        layout()
        if let id = selected { reveal(id) }
    }

    // MARK: Scrolling

    static let bottomPad: CGFloat = 6
    private var maxScroll: CGFloat { max(0, contentHeight - size.height) }

    /// Scroll the rooms (clamped) and redraw the pixel scroll bar on the right.
    private func scrollTo(_ offset: CGFloat, animated: Bool) {
        scroll = min(max(offset, 0), maxScroll)
        let target = CGPoint(x: 0, y: scroll)
        container.removeAction(forKey: "scroll")
        if animated && !reducedMotion { container.run(.move(to: target, duration: 0.2), withKey: "scroll") } else { container.position = target }
        scrollBar.isHidden = maxScroll <= 0
        guard maxScroll > 0 else { return }
        let track = size.height - DungeonScene.topPad - 8
        let thumb = max(24, track * size.height / contentHeight)
        let y = size.height - DungeonScene.topPad - 4 - thumb - (track - thumb) * scroll / maxScroll
        scrollBar.path = CGPath(roundedRect: CGRect(x: size.width - 5, y: y, width: 3, height: thumb), cornerWidth: 1.5, cornerHeight: 1.5, transform: nil)
    }

    override func scrollWheel(with event: NSEvent) {
        guard maxScroll > 0 else { return }
        let step = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 12
        scrollTo(scroll - step, animated: false)
    }

    /// Scroll just enough to show an agent's room whole.
    func reveal(_ id: String) {
        guard let row = rows[id] else { return }
        let top = row.position.y + AgentRow.height / 2 + scroll, bottom = row.position.y - AgentRow.height / 2 + scroll
        // In scene coordinates the room spans [bottom, top] once scrolled; keep it inside the view.
        if top > size.height - DungeonScene.topPad { scrollTo(scroll - (top - (size.height - DungeonScene.topPad)), animated: true) }
        else if bottom < 0 { scrollTo(scroll - bottom + DungeonScene.bottomPad, animated: true) }
    }

    /// The agent whose room is under the pointer, if any.
    private func rowID(at event: NSEvent) -> String? {
        let point = event.location(in: container)
        return order.first { id in
            guard let row = rows[id] else { return false }
            return CGRect(x: row.position.x - AgentRow.width / 2, y: row.position.y - AgentRow.height / 2,
                          width: AgentRow.width, height: AgentRow.height).contains(point)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if let id = rowID(at: event) { onSelect?(id) }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let id = rowID(at: event), let view = view else { return }
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: tr("Finalizar agente (/exit)")) { [weak self] in self?.onFinish?(id) })
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }
}

/// A menu item that runs a closure, so a scene can build menus without a
/// dedicated target object.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func fire() { handler() }
}

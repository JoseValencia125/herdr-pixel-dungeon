import Foundation

// Port/adaptation of BFS in DungeonMapPhaser.tsx by Claude Dungeon Contributors.
// Source: thousandsky2024/claude-pixel-agent-web @ f174fe15. MIT; see LICENSE.
// Changes: Swift, cardinal movement, indexed queue, no teleport fallback.
struct Tile: Hashable { let x: Int; let y: Int }
func bfsPath(grid: [[Bool]], from: Tile, to: Tile) -> [Tile] {
    let height = grid.count, width = grid.first?.count ?? 0
    func valid(_ p: Tile) -> Bool { p.x >= 0 && p.y >= 0 && p.x < width && p.y < height && grid[p.y][p.x] }
    guard valid(from), valid(to), from != to else { return [] }
    var queue = [from], parents = [Tile:Tile](), seen: Set<Tile> = [from], head = 0
    while head < queue.count {
        let current = queue[head]; head += 1
        if current == to {
            var result = [Tile](), node = to
            while node != from { result.append(node); guard let p = parents[node] else { return [] }; node = p }
            return result.reversed()
        }
        for (dx, dy) in [(0,1),(0,-1),(1,0),(-1,0)] {
            let next = Tile(x: current.x + dx, y: current.y + dy)
            if valid(next) && seen.insert(next).inserted { parents[next] = current; queue.append(next) }
        }
    }
    return []
}

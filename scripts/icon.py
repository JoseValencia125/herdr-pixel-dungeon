#!/usr/bin/env python3
"""Draw the app icon: the guild's knight helm (the menu bar glyph, in steel
and gold) on a dark dungeon-stone tile, as pixel art scaled up with no
smoothing. Writes Resources/Icon/icon.png (1024 px) and the sizes an
.iconset needs. Pure Python, no PIL."""
import os, struct, zlib

HELM = [
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
# Endesga-32 colours, as in the sprites.
BG = (0x3a, 0x44, 0x66)
BG_EDGE = (0x26, 0x2b, 0x44)
BG_LIGHT = (0x5a, 0x69, 0x88)
STEEL = (0x8b, 0x9b, 0xb4)
STEEL_LIGHT = (0xc0, 0xcb, 0xdc)
STEEL_DARK = (0x5a, 0x69, 0x88)
INK = (0x18, 0x14, 0x25)
GOLD = (0xfe, 0xe7, 0x61)
RED = (0xe4, 0x3b, 0x44)

SIZE = 44  # canvas in art pixels

def pixels():
    px = {}
    r = 8  # corner radius of the tile
    for y in range(SIZE):
        for x in range(SIZE):
            # Rounded square tile.
            cx = min(max(x, r), SIZE - 1 - r)
            cy = min(max(y, r), SIZE - 1 - r)
            if (x - cx) ** 2 + (y - cy) ** 2 > r * r:
                continue
            edge = x < 2 or y < 2 or x >= SIZE - 2 or y >= SIZE - 2 or (x - cx) ** 2 + (y - cy) ** 2 > (r - 2) ** 2
            # Faint bricks.
            brick = ((y // 6) % 2 == 0 and x % 12 == 0) or ((y // 6) % 2 == 1 and (x + 6) % 12 == 0) or y % 6 == 0
            px[(x, y)] = BG_EDGE if edge else (BG_LIGHT if brick and (x + y) % 3 == 0 else BG)
    # The helm, 2x, centred, with a 1 px ink outline.
    scale = 2
    hw, hh = 16 * scale, len(HELM) * scale
    ox, oy = (SIZE - hw) // 2, (SIZE - hh) // 2 + 1
    cells = {}
    for y, row in enumerate(HELM):
        first = row.find("#")
        last = row.rfind("#")
        for x, ch in enumerate(row):
            if ch == "#":
                color = STEEL_LIGHT if y <= 2 or (x <= 3 and y <= 9) else STEEL
                if y >= 11:
                    color = STEEL_DARK
                cells[(x, y)] = color
            elif first != -1 and first < x < last:
                cells[(x, y)] = INK  # visor and breathing holes
    # Gold crest band and red plume.
    for x in range(6, 10):
        cells[(x, 3)] = GOLD
    for y in range(0, 3):
        cells[(7, y - 1)] = RED if y > 0 else RED
        cells[(8, y - 1)] = RED
    for (x, y), color in cells.items():
        for dy in range(scale):
            for dx in range(scale):
                px[(ox + x * scale + dx, oy + y * scale + dy)] = color
    # Outline: ink around any helm pixel that borders the tile.
    helm_set = set((ox + x * scale + dx, oy + y * scale + dy) for (x, y) in cells for dx in range(scale) for dy in range(scale))
    outline = set()
    for (x, y) in helm_set:
        for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
            if (nx, ny) not in helm_set and (nx, ny) in px:
                outline.add((nx, ny))
    for p in outline:
        px[p] = INK
    return px

def png(path, size, px):
    scale = size // SIZE
    pad = (size - SIZE * scale) // 2
    rows = []
    for y in range(size):
        row = bytearray([0])
        for x in range(size):
            p = px.get(((x - pad) // scale, (y - pad) // scale)) if pad <= x < pad + SIZE * scale and pad <= y < pad + SIZE * scale else None
            row += bytes(p) + b"\xff" if p else b"\x00\x00\x00\x00"
        rows.append(bytes(row))
    raw = b"".join(rows)
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
    data = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(data)

if __name__ == "__main__":
    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Resources", "Icon")
    os.makedirs(root, exist_ok=True)
    px = pixels()
    png(os.path.join(root, "icon.png"), 1024, px)
    png(os.path.join(root, "icon_256.png"), 256, px)
    iconset = os.path.join(root, "icon.iconset")
    os.makedirs(iconset, exist_ok=True)
    for size in (16, 32, 64, 128, 256, 512, 1024):
        png(os.path.join(iconset, f"icon_{size}x{size}.png"), size, px)
        if size >= 32:
            png(os.path.join(iconset, f"icon_{size // 2}x{size // 2}@2x.png"), size, px)
    print("icons written to", root)

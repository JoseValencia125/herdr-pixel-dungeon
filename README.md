<p align="center"><img src="Resources/Icon/icon_256.png" width="128" alt="Herdr Pixel Dungeon icon: a knight's helm on a dungeon tile"></p>

# Herdr Pixel Dungeon

**A native pixel-art guild for your live [Herdr](https://herdr.dev) agents, for macOS and Linux.**

Each coding agent is a hero in a dungeon room that changes with its real Herdr status: working at the forge, asking for your attention, resting, done. Click a room to answer the agent, accept or decline its permission prompts, or summon a new one. Rust, `egui`, a status item in the menu bar or tray, no browser or server.

<p align="center">
  <img src="docs/media/demo.gif" width="460" alt="The widget in demo mode: six agents working, asking for attention, waiting and done">
</p>

<p align="center"><a href="docs/media/demo.mp4">Watch the full demo video</a> · <a href="docs/media/widget.png">Full-size screenshot</a> · <a href="docs/GUIDE.md">Guide</a></p>

## Download

Binaries for macOS (`.app`) and Linux (x86_64) are on the [Releases](https://github.com/JoseValencia125/herdr-pixel-dungeon/releases) page. The macOS app is ad-hoc signed, not notarized: the first time, right-click it and choose Open.

## States and rooms

| Herdr state | | Room | Hero |
| --- | --- | --- | --- |
| `working` | <img src="docs/media/room_working.png" width="216" alt=""> | Workshop: desk, bookshelves, forge, alchemy table | Works at the station of its last tool: reads, forges, brews, summons, plans or types |
| `blocked` | <img src="docs/media/room_blocked.png" width="216" alt=""> | Sealed door, braziers, a rug | Jumps on the rug under a pulsing red "!" |
| `idle` | <img src="docs/media/room_idle.png" width="216" alt=""> | Inn room at night | Sleeps under the blanket, z's drifting up |
| `done` | <img src="docs/media/room_done.png" width="216" alt=""> | Treasure chamber | Jumps for joy under a green tick, confetti flying |
| unknown | <img src="docs/media/room_unknown.png" width="216" alt=""> | Ruins with a portal | Wanders, looking around |

When the state changes the hero walks out through the door, the room changes behind it, and it walks back in.

## Heroes

| Harness | Hero | |
| --- | :---: | --- |
| **claude** (Claude Code) | <img src="docs/media/hero_claude.png" width="64" alt="Coral wizard"> | Coral wizard with a staff |
| **codex** (OpenAI Codex) | <img src="docs/media/hero_codex.png" width="64" alt="Monochrome knight"> | Monochrome knight with sword and shield |
| **kiro** (Amazon Kiro) | <img src="docs/media/hero_kiro.png" width="64" alt="Purple-hooded rogue"> | Purple-hooded rogue with a ghost face |
| **gemini** (Google Gemini CLI) | <img src="docs/media/hero_gemini.png" width="64" alt="Blue star cleric"> | Blue star cleric |
| any other | <img src="docs/media/hero_hero.png" width="64" alt="Green adventurer"> | Green adventurer |

Original pixel art drawn in Aseprite (sources in `art/`), coloured after each tool's brand; no logos are reproduced.

## What it does

- **Chat with an agent**: its terminal's last lines, a box to reply, ↑/↓ to pick among a question's options, Accept / Decline / Stop buttons, `/exit` from the right-click menu.
- **Summon agents** in any folder with a first prompt, through Herdr.
- **Chimes and desktop notifications** when an agent needs help or finishes.
- **Subagents** as small heroes at the station of their own tool (Claude Code).
- **Filters, search and an activity log**; the window resizes to whole rooms, scrolls, and remembers where you left it.
- **Event-driven**: Herdr's socket events the moment they happen, snapshots only to reconcile.
- Spanish, English, French, Italian and Portuguese.

The [guide](docs/GUIDE.md) has the details: how states are read, background jobs, the menu, configuration, privacy and the optional viewer mode without Herdr.

## Build and open

Requires [Rust](https://rustup.rs) (stable) and [Herdr](https://herdr.dev). Tested with Herdr 0.9.x.

```sh
git clone https://github.com/JoseValencia125/herdr-pixel-dungeon.git
cd herdr-pixel-dungeon
./scripts/build.sh
```

- **macOS**: `open 'build/Herdr Pixel Dungeon.app'` (optionally copy it to `~/Applications`).
- **Linux** (X11 or Wayland): `./build/herdr-pixel-dungeon`. Needs GTK 3, libayatana-appindicator, xdo and ALSA — on Debian/Ubuntu `sudo apt install libgtk-3-dev libayatana-appindicator3-dev libxdo-dev libasound2-dev`. `build/` also has a `.desktop` entry and icon.

`cargo test` and `--self-test` run the checks; `--demo` shows fictional agents without Herdr.

## Credits and licenses

Created by **Nacho Valencia**: code and all pixel art. MIT, see [LICENSE](LICENSE) and [NOTICE.md](NOTICE.md).

Inspired by **[Claude Dungeon](https://github.com/thousandsky2024/claude-pixel-agent-web)** by [thousandsky2024](https://github.com/thousandsky2024), which first pictured coding agents as dungeon heroes. No code or artwork from it is included.

[Herdr](https://github.com/herdrdev/herdr) is by the Herdr contributors and is installed separately. Independent project; no endorsement or affiliation implied.

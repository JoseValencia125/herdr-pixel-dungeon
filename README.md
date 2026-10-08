# Herdr Pixel Agents

**A native macOS pixel-art guild for your live Herdr agents.**

Built in **Swift, SwiftUI, AppKit and SpriteKit**. Each agent is an animated hero that walks between rooms when its real Herdr status changes. Lives in a desktop window and your menu bar. No browser, WebView, Node.js, account or server required.

**Pixel art by [o_lobster](https://o-lobster.itch.io/)** — Another Metroidvania Asset Pack Vol. 1 v1.7, under the CC BY 4.0 license included with that version. See [asset attribution](Resources/Licenses/ASSETS.md).

Based on **[Claude Dungeon / claude-pixel-agent-web](https://github.com/thousandsky2024/claude-pixel-agent-web)** by **[thousandsky2024](https://github.com/thousandsky2024)** and Claude Dungeon Contributors. The concept and BFS navigation were adapted to native Swift. Original MIT notice preserved. See [NOTICE.md](NOTICE.md).

## Build and open

Requires macOS 13+, Xcode Command Line Tools (`xcode-select --install`) and [Herdr](https://herdr.dev) with `herdr api snapshot` support. Tested with Herdr 0.9.1.

```sh
git clone https://github.com/JoseValencia125/herdr-pixel-agents.git
cd herdr-pixel-agents
./scripts/build.sh
open 'build/Herdr Pixel Agents.app'
```

Optional installation:

```sh
mkdir -p ~/Applications
ditto 'build/Herdr Pixel Agents.app' "$HOME/Applications/Herdr Pixel Agents.app"
open "$HOME/Applications/Herdr Pixel Agents.app"
```

Uses only Apple frameworks; no third-party packages. The build produces a locally ad-hoc-signed app for your Mac's architecture. It is not Developer ID signed or notarized.

Close the window to keep monitoring in the menu bar. Choose **Mostrar Herdr Pixel Agents** to reopen it or **Salir** to quit. Enable **Demo** to try fictional agents without Herdr. Live mode never inserts fictional agents.

## States and rooms

| Herdr state | Room | Hero |
| --- | --- | --- |
| `working` | Arena | Attacking |
| `blocked` | Portal | Attention marker |
| `idle` | Library | Waiting |
| `done` | Tavern | Resting |
| unknown | Sanctuary | Unknown |

- Background Herdr queries every second, no overlapping reads, four-second timeout.
- Native SpriteKit animations, crisp nearest-neighbor sprites and wall-aware cardinal BFS paths.
- Search, state filters, agent selection, project, pane, directory and terminal title.
- Latest status change, counts and menu-bar attention indicator.
- Explicit stale-data indication and automatic reconnection.
- Animation pause and macOS Reduce Motion support.
- Artist credits and licenses accessible from the app.

Activity means **the title reported by the terminal**, not an inferred summary. Animation represents state, not tool calls or completion percentage. Agents outside the selected Herdr session are not included. Very large rosters may share visual positions; the list remains complete.

## Configuration

Monitors the principal local session by default. For a named session/custom executable, launch directly:

```sh
HERDR_SESSION=my-session HERDR_BIN=/absolute/path/to/herdr 'build/Herdr Pixel Agents.app/Contents/MacOS/HerdrPixelAgents'
```

Herdr discovery: `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, then inherited `PATH`. GUI launches may have a different PATH from your shell. One session per app instance.

## Privacy

Read-only `herdr api snapshot` calls. No network listener, telemetry, transcript scanning, terminal control or credential access. Agent data remains in memory. External links open only when clicked. Public source and demo data contain no live user sessions.

## Verify

```sh
./scripts/build.sh
'build/Herdr Pixel Agents.app/Contents/MacOS/HerdrPixelAgents' --self-test
'build/Herdr Pixel Agents.app/Contents/MacOS/HerdrPixelAgents' --diagnose
open 'build/Herdr Pixel Agents.app' --args --demo
```

Self-tests cover snapshot states, invalid/empty replies, BFS, monitor transitions and bundled PNG decoding. `--diagnose` prints live agent data; review it before sharing publicly.

## Credits and licenses

- **[o_lobster](https://o-lobster.itch.io/)**: all bundled PNG characters, NPCs, props and backgrounds. **Another Metroidvania Asset Pack Vol. 1 v1.7**. **[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/)** as stated in the [included original license](Resources/Licenses/o_lobster-original.txt). Frames are cropped, scaled and composed at runtime. [Source paths and hashes](Resources/Licenses/asset-manifest.json).
- **[thousandsky2024 / Claude Dungeon Contributors](https://github.com/thousandsky2024/claude-pixel-agent-web)**: original dungeon concept and BFS adapted to Swift. MIT notice retained in [LICENSE](LICENSE).
- **Herdr contributors**: [Herdr](https://github.com/herdrdev/herdr) and its local API. Herdr is installed separately.
- **Herdr Pixel Agents contributors**: native adapter, UI and SpriteKit composition, MIT.

**Code is MIT; o_lobster's assets remain CC BY 4.0.** This project does not claim ownership of the artwork. Independent adaptation; no endorsement or affiliation implied.

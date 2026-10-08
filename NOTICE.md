# Attribution and provenance

## Claude Dungeon — MIT

Based on [thousandsky2024/claude-pixel-agent-web](https://github.com/thousandsky2024/claude-pixel-agent-web), revision `f174fe15ef7f5ba121727c89d7b79d2db5e5cab4`.

Copyright (c) 2026 Claude Dungeon Contributors. The original MIT notice is preserved in LICENSE.

The agent-as-dungeon-hero concept comes from the reference project. Sources/Pathfinding.swift ports/adapts BFS from client/src/components/DungeonMapPhaser.tsx: Swift, cardinal moves, indexed queue, generic grid and no teleport fallback. Native adapter, UI and SpriteKit composition are new code, copyright (c) 2026 Herdr Pixel Agents contributors, MIT.

## Pixel art — o_lobster

**Author: o_lobster. Artist: https://o-lobster.itch.io/**

Title: **Another Metroidvania Asset Pack Vol. 1**, version **1.7**.

All PNGs in Resources/Sprites are copied from the reference project's client/public/sprites/mv directory at the revision above. They are attributed to o_lobster and used under **Creative Commons Attribution 4.0 International (CC BY 4.0)**, declared in that pack's accompanying `read me (or not).txt`, preserved verbatim in Resources/Licenses/o_lobster-original.txt.

License: https://creativecommons.org/licenses/by/4.0/

PNG bytes are unchanged. Frames are cropped in memory, scaled with nearest-neighbor filtering and composed in SpriteKit; backgrounds receive a slight runtime tint. The manifest records source paths and SHA-256 hashes. Synthetic dungeon_bg_* backgrounds from the reference are not included.

The included license is the basis for this specific version; no rights over later releases are asserted. The artwork remains CC BY 4.0, not MIT. No artist endorsement is implied.

## Herdr

[Herdr](https://github.com/herdrdev/herdr) provides the separately installed local runtime and CLI snapshot API. Herdr is not bundled. Vendor names only identify the agents Herdr reports.

Independent project; no affiliation with or endorsement by Herdr, Anthropic, OpenAI, thousandsky2024 or o_lobster.

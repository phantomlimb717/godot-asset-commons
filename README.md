# Asset Commons for Godot

Browse, download and prepare free **CC0** models, textures and HDRIs from
[Poly Haven](https://polyhaven.com) inside the Godot 4.7+ editor — and let AI
coding agents (Claude Code or any MCP client) do the same through
[Godot AI](https://github.com/hi-godot/godot-ai).

- **Main-screen tab** next to Asset Store: search, categories, thumbnail grid,
  details (polycount, real-world size, texture resolution, tags), 1K–8K downloads
  with a queue.
- **Ready resources**: models → glTF scene, textures → `StandardMaterial3D`,
  HDRIs → `Sky`. Downloads are MD5-verified and credited in a generated
  `CREDITS.md` + manifest.
- **Prep for [Terrain3D](https://github.com/TokisanGames/Terrain3D)**: splits
  asset sets into variants, merges meshes, bakes transforms, origin at base,
  builds LOD0–3 (foliage is thinned rather than simplified, so trees stay full at
  a distance) and registers them as Terrain3D mesh assets.
- **Agent tools** (optional, with Godot AI): `commons_search`,
  `commons_thumbnail`, `commons_download`, `commons_prep_terrain3d`,
  `commons_t3d_place`, … — see [`AGENTS.md`](addons/asset_commons/AGENTS.md).
- **Swappable sources**: Poly Haven today; add others (e.g. ambientCG) by
  extending one class.

## Install
1. Copy `addons/asset_commons/` into your project's `addons/` folder.
2. **Project → Project Settings → Plugins** → enable **Asset Commons**.
3. Open the **Asset Commons** tab in the top bar.

Terrain3D and Godot AI are optional; their features appear only when they are
installed.

## Docs
- [User guide](addons/asset_commons/README.md) — the tab, output files,
  Terrain3D prep, settings, adding sources.
- [Agent guide](addons/asset_commons/AGENTS.md) — every MCP tool, recipes,
  gotchas, and how to expose *your own* plugin's functions as agent tools.

## Credits & license
Code: MIT (see `LICENSE`). Assets are provided by Poly Haven under CC0; this
project is not affiliated with Poly Haven. Please keep the
"Powered by Poly Haven" credit and consider supporting them.

# Asset Commons — guide for AI agents (Claude Code and other MCP clients)

This file is for AI coding agents working in a Godot project that has Asset
Commons installed. Humans: see `README.md`.

## What it is
An editor plugin that browses and downloads CC0 assets from Poly Haven
(models, textures, HDRIs), turns them into ready Godot resources, and can
prepare models for Terrain3D's instancer. When the
[Godot AI](https://github.com/hi-godot/godot-ai) addon is also installed, the
plugin registers **MCP tools** so you can do all of it without the UI.

How that works: Godot AI runs an MCP server connected to the live editor.
Any editor plugin can register extra tools with it (`McpToolRegistry`).
Asset Commons does that in `plugin.gd`; the tool code is in
`mcp/commons_tools.gd`. The tools drive the same download queue as the tab,
so the user sees your downloads' progress in the editor.

## Calling the tools
Through Godot AI's generic custom-tool call:

```
custom_manage  op="invoke"  params={"tool_name": "commons_search", "params": {...}}
custom_manage  op="list"    # confirms which commons_* tools are registered
```

They may also appear as first-class tools named `custom_commons_*` if your
client has refreshed its tool list.

| Tool | Params | Returns |
|---|---|---|
| `commons_categories` | `type` (models/textures/hdris) | `[{id, label}]` with counts |
| `commons_search` | `type`, `category`=all, `query`, `sort` (popular/newest/name), `limit`≤100, `offset` | `{total, assets:[{id, name, polycount, max_resolution, size_wdh_m / tile_size_m, tags, installed_resolutions}]}` |
| `commons_info` | `id`, `type`? | everything above + description, authors, `download_sizes` per resolution, `installed_entry` |
| `commons_thumbnail` | `id`, `type`? | `png_path` — an absolute path to a 512 px preview; **read it as an image to look at the asset** |
| `commons_download` | `id`, `type`?, `resolution` (1k/2k/4k/8k, default 1k), `wait_seconds`≤110 | `{status: done, main_file, folder}` or `status: in_progress` |
| `commons_prep_terrain3d` | `id`, `budgets`? (max tris per LOD), `register`=true | variants with `scene`, `lod_tris`, `foliage_keep`; `registered.ids` = Terrain3D mesh asset ids |
| `commons_t3d_place` | `mesh_ids`, `x`, `z`, `spacing`=3 | placed positions (snapped to terrain height) |
| `commons_t3d_clear` | `mesh_ids` | removes all placed instances of those ids |
| `commons_installed` | — | assets already in the project (manifest) |
| `commons_status` | — | download queue |

`main_file` by type: model → `.gltf` scene, texture → `StandardMaterial3D`
`.tres`, HDRI → `Sky` `.tres`.

## Recipes

**Put a prop in the scene**
1. `commons_search` (e.g. `type=models, query="barrel"`). Filter by
   `polycount` and `size_wdh_m` (width × depth × height, metres).
2. `commons_thumbnail` for the 2–3 best candidates; look at the images.
3. `commons_download` with `resolution="4k"` for things the player walks up
   to, `2k` for background, `8k` only for hero pieces (≈4× the memory of 4K).
4. Instance `main_file` with Godot AI's `node_create(scene_path=…)`, then set
   its transform.

**Texture a surface** — download a texture; assign the returned `.tres` as the
mesh's material / `material_override`.

**Change the sky** — download an HDRI; set the returned `Sky` `.tres` on the
`WorldEnvironment`'s environment (skip if the scene uses Sky3D or another sky
system that owns the environment).

**Scatter vegetation/rocks on Terrain3D**
1. Download the model (4K for rocks the player stands near).
2. `commons_prep_terrain3d` with the target scene open → note `registered.ids`.
3. `commons_t3d_place` to drop test instances; check visually; then paint or
   place more (Terrain3D instancer API: `add_transforms`).
4. `commons_t3d_clear` to remove test instances.

## Things to know
- **Check before acting**: `commons_installed` tells you what's already there;
  `commons_info` shows download sizes (big trees are hundreds of MB).
- **Heavy models**: Poly Haven's big trees are 4–7 million triangles each —
  import and Terrain3D prep take minutes. Saplings/rocks take seconds.
- **LODs**: solid meshes use Godot's simplifier. Foliage is thinned instead
  (the simplifier deletes needles/leaves outright, leaving bare sticks).
  Re-running prep overwrites files and keeps the same mesh asset ids.
- **Look, don't assume**: screenshot results. With Godot AI, use
  `editor_screenshot source="cinematic"` through a Camera3D; the `viewport`
  source can return a stale frame when a main-screen plugin tab is showing.
  Keep `max_resolution` ≤ 640 — large images can drop in transport.
- **Shared UI**: the tab and the tools share state (queue, selected type and
  category). Tell the user before long tool-driven runs.
- **Unsaved changes**: Terrain3D registration and placement mark the open
  scene as modified; saving is the user's call.
- **Editing this plugin's scripts live**: after changes, run a filesystem scan;
  tools re-register automatically when Godot AI restarts
  (`editor_reload_plugin`). Don't hot-reload scripts mid-download.

## Adding your own tools (this plugin or others)
Any plugin can expose functions to agents the same way:
1. Describe the tool: `name`, `description` (≤600 chars), JSON `schema`
   (≤8 KB) — see `CommonsTools.specs()`.
2. Write the handler: `func my_tool(params: Dictionary, ctx) -> Dictionary`
   returning `{"data": …}` or `{"status": "error", "error": {"code", "message"}}`.
   For work longer than a frame, return `{"_deferred": true}` and later call
   `ctx.send_deferred(result)` (max 120 s per call).
3. Register it with Godot AI's registry, reached by path so the plugin still
   works without Godot AI — see `_check_registry()` / `_register_mcp_tools()`
   in `plugin.gd`, including the watcher that re-registers after a Godot AI
   restart.

To wrap a third-party plugin, write a small separate addon whose handlers call
that plugin's public API; the original plugin stays untouched.

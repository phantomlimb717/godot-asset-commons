# Asset Commons

Browse, download and prepare free CC0 assets (models, textures, HDRIs) from
[Poly Haven](https://polyhaven.com) without leaving the Godot editor.
Self-contained: copy `addons/asset_commons/` into any Godot 4.7+ project.

## Install
1. Copy this folder to `res://addons/asset_commons/`.
2. **Project → Project Settings → Plugins** → enable **Asset Commons**.
3. Click the **Asset Commons** tab in the top bar (next to Asset Store).

## Using the tab
- **Type** (Models / Textures / HDRIs), **category**, **search**, **sort**.
- Click an asset for details: polycount, max texture resolution, real-world
  size, tags, license, download size per resolution.
- **Download** (or double-click a grid item; right-click for 1K–8K).
  Downloads queue and run one at a time.

| Type | You get | Main file |
|---|---|---|
| Model | glTF + textures | `<id>_<res>.gltf` |
| Texture | colour, normal, AO/rough/metal, height maps | `<id>_<res>.tres` (StandardMaterial3D) |
| HDRI | `.hdr` | `<id>_<res>_sky.tres` (Sky with PanoramaSkyMaterial) |

Resolution guide for first-person scenes: **4K** for props you walk past,
**8K** only for things you stand right next to (≈4× the memory of 4K).

Files are verified against Poly Haven's MD5 checksums in a staging folder and
only copied into the project once complete.

## Where things go
- Downloads: `<download_root>/polyhaven/<asset_id>/` (default `res://assets`).
- `<download_root>/asset_manifest.json`: every downloaded asset (machine-readable).
- `<download_root>/CREDITS.md`: generated attribution table. CC0 needs no
  credit, but it's good practice and Poly Haven appreciates it.
- Cache (asset lists, thumbnails): the editor's cache folder
  (`EditorPaths.get_cache_dir()/asset_commons`), outside the project and
  shared between projects.

## Prep for Terrain3D (models only)
Shown when [Terrain3D](https://github.com/TokisanGames/Terrain3D) is installed
and the model is downloaded. For each variant in the file (Poly Haven "sets"
hold several, e.g. three trees):

1. Merges its meshes into one (one surface per material).
2. Bakes transforms (neutral transforms), moves the origin to the base, keeps
   real-world scale.
3. Builds LOD0–LOD3 within the triangle budgets
   (`asset_commons/terrain3d_lod_budgets`, default 150k / 40k / 12k / 4k):
   - solid parts (trunks, rocks) use Godot's mesh simplifier;
   - foliage (auto-detected as many small separate pieces, e.g. needles) is
     thinned instead: an even spread of pieces is kept and enlarged, so trees
     stay full at a distance.
4. Writes `<asset>/terrain3d/<variant>.tscn` with `<variant>LOD0..3` meshes
   (Terrain3D's LOD naming) and registers each as a `Terrain3DMeshAsset` on the
   open scene's Terrain3D node. Re-running updates the same mesh asset ids.

The original download is never modified.

## AI agent tools (optional)
If the [Godot AI](https://github.com/hi-godot/godot-ai) addon is installed,
Asset Commons registers MCP tools so an agent (e.g. Claude Code) can do all of
the above without clicking. They drive the same queue as the tab.

| Tool | Does |
|---|---|
| `commons_categories` | categories + counts for a type |
| `commons_search` | search by type/category/words; returns polycount, size, tags, installed resolutions |
| `commons_info` | full details + download size per resolution |
| `commons_thumbnail` | saves a 512 px preview PNG and returns its path |
| `commons_download` | download + import + credit; returns the main `res://` file |
| `commons_prep_terrain3d` | the Terrain3D prep above |
| `commons_t3d_place` | place Terrain3D instances of mesh asset ids, snapped to the ground |
| `commons_t3d_clear` | remove all placed instances of mesh asset ids |
| `commons_installed` | what's already in the project |
| `commons_status` | the download queue |

Tools re-register automatically if Godot AI restarts. Agents: read
[`AGENTS.md`](AGENTS.md) for parameters, step-by-step recipes and gotchas
(Claude Code loads it automatically via `CLAUDE.md`).

## Settings (Project Settings → `asset_commons/…`)
| Setting | Default |
|---|---|
| `download_root` | `res://assets` |
| `user_agent` | auto: `GodotAssetCommons/<version> (Godot <ver>; project <name>)` |
| `list_cache_hours` | 24 |
| `terrain3d_lod_budgets` | 150000, 40000, 12000, 4000 |

## Adding a source (e.g. ambientCG)
Extend `sources/asset_source.gd`, implement the "Provider API" methods
(`get_asset_types`, `fetch_categories`, `fetch_assets`,
`fetch_download_plan`, optionally `post_import`), and add the script to
`SOURCES` in `ui/browser_panel.gd`.

## Known limits
- Very heavy models (Poly Haven's big trees are 4–7 million triangles) take
  minutes to import and to prep.
- Foliage LODs are thinned, not re-authored; the farthest LOD is sparser than a
  hand-made impostor would be.

## License
MIT (see `LICENSE` in the repository). Assets you download are CC0 from
Poly Haven; this plugin is not affiliated with Poly Haven.

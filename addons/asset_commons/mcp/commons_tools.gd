@tool
extends RefCounted
## Optional MCP tools for AI agents, registered with the Godot AI addon
## (github.com/hi-godot/godot-ai) when it is installed. They drive the same
## panel, queue and downloader as the UI, so results are identical.
##
## Godot AI instantiates this script itself (no-arg new()) and calls
## handler(params, ctx). Every handler replies later via ctx.send_deferred().

const Credits = preload("../core/credits.gd")
const AssetSource = preload("../sources/asset_source.gd")
const Terrain3DPrep = preload("../core/terrain3d_prep.gd")

const SOURCE_PATH := "res://addons/asset_commons/plugin.cfg"
const DEFERRED := {"_deferred": true}
const TYPE_ENUM := ["models", "textures", "hdris"]
## Detail-pane stat labels -> JSON keys.
const STAT_KEYS := {"Size (W×D×H)": "size_wdh_m", "Real-world tile": "tile_size_m",
	"Dynamic range": "dynamic_range", "White balance": "white_balance"}

## Set by plugin.gd; the live browser panel (ui/browser_panel.gd).
static var panel: Control

var _active_calls := 0


## Tool definitions, turned into McpCustomToolSpec objects by plugin.gd.
static func specs() -> Array:
	var type_prop := {"type": "string", "enum": TYPE_ENUM, "description": "Asset type."}
	var id_props := {
		"id": {"type": "string", "description": "Asset id from commons_search, e.g. \"barrel_01\"."},
		"type": {"type": "string", "enum": TYPE_ENUM, "description": "Optional; speeds up the lookup."},
	}
	return [
		{
			"name": "commons_categories",
			"method": &"categories",
			"description": "Asset Commons: list the categories (with asset counts) for a CC0 asset type from Poly Haven.",
			"schema": {"type": "object", "properties": {"type": type_prop}, "required": ["type"]},
		},
		{
			"name": "commons_search",
			"method": &"search",
			"description": "Asset Commons: search CC0 models/textures/HDRIs (Poly Haven). Returns id, name, polycount, real-world size, max resolution, tags and which resolutions are already in the project. Use commons_thumbnail to look at candidates before downloading.",
			"schema": {"type": "object", "required": ["type"], "properties": {
				"type": type_prop,
				"category": {"type": "string", "description": "Category id from commons_categories (default \"all\")."},
				"query": {"type": "string", "description": "Words matched against name, id and tags."},
				"sort": {"type": "string", "enum": ["popular", "newest", "name"]},
				"limit": {"type": "integer", "minimum": 1, "maximum": 100, "description": "Default 20."},
				"offset": {"type": "integer", "minimum": 0},
			}},
		},
		{
			"name": "commons_info",
			"method": &"info",
			"description": "Asset Commons: full details for one asset: authors, description, all tags, stats, download size per resolution, and whether it is already in the project.",
			"schema": {"type": "object", "properties": id_props, "required": ["id"]},
		},
		{
			"name": "commons_thumbnail",
			"method": &"thumbnail",
			"description": "Asset Commons: save an asset's 512px preview image as PNG and return its absolute file path, so it can be viewed before downloading.",
			"schema": {"type": "object", "properties": id_props, "required": ["id"]},
		},
		{
			"name": "commons_download",
			"method": &"download",
			"description": "Asset Commons: download an asset into the project (checksummed, imported, credited). Models give a .gltf scene, textures a StandardMaterial3D .tres, HDRIs a Sky .tres; main_file is its res:// path. Waits up to wait_seconds, then reports in_progress (poll commons_status).",
			"schema": {"type": "object", "required": ["id"], "properties": {
				"id": id_props.id,
				"type": id_props.type,
				"resolution": {"type": "string", "enum": ["1k", "2k", "4k", "8k"], "description": "Default 1k. Texture size: 4k suits props seen up close; 8k is ~4x the memory."},
				"wait_seconds": {"type": "integer", "minimum": 0, "maximum": 110, "description": "Default 100."},
			}},
			"timeout_ms": 120000,
			"writable": true,
		},
		{
			"name": "commons_prep_terrain3d",
			"method": &"prep_terrain3d",
			"description": "Asset Commons: prepare a downloaded model for Terrain3D: split sets into variants, merge meshes (one surface per material), bake transforms, origin at base, build LOD0-LODn to triangle budgets (solid parts simplified; foliage thinned with survivors enlarged), save <asset>/terrain3d/<variant>.tscn, and add each as a Terrain3DMeshAsset on the open scene's Terrain3D node.",
			"schema": {"type": "object", "required": ["id"], "properties": {
				"id": id_props.id,
				"budgets": {"type": "array", "items": {"type": "integer", "minimum": 100}, "description": "Max triangles per LOD, near to far. Default: project setting (150000, 40000, 12000, 4000)."},
				"register": {"type": "boolean", "description": "Add to Terrain3D (default true)."},
			}},
			"timeout_ms": 120000,
			"writable": true,
		},
		{
			"name": "commons_t3d_place",
			"method": &"t3d_place",
			"description": "Asset Commons: place one Terrain3D instance of each mesh asset id in a row along +X starting at world (x, z), snapped to the terrain height. Returns the positions.",
			"schema": {"type": "object", "required": ["mesh_ids", "x", "z"], "properties": {
				"mesh_ids": {"type": "array", "items": {"type": "integer", "minimum": 0}},
				"x": {"type": "number"},
				"z": {"type": "number"},
				"spacing": {"type": "number", "description": "Metres between instances (default 3)."},
			}},
			"writable": true,
		},
		{
			"name": "commons_t3d_clear",
			"method": &"t3d_clear",
			"description": "Asset Commons: remove all placed Terrain3D instances of the given mesh asset ids (the mesh assets themselves stay registered).",
			"schema": {"type": "object", "required": ["mesh_ids"], "properties": {
				"mesh_ids": {"type": "array", "items": {"type": "integer", "minimum": 0}},
			}},
			"writable": true,
		},
		{
			"name": "commons_installed",
			"method": &"installed",
			"description": "Asset Commons: list assets already downloaded into the project (from asset_manifest.json): id, type, resolutions, folder and main res:// file.",
			"schema": {"type": "object", "properties": {}},
		},
		{
			"name": "commons_status",
			"method": &"status",
			"description": "Asset Commons: show the download queue (first entry is downloading now).",
			"schema": {"type": "object", "properties": {}},
		},
	]


## Godot AI asks this before hot-swapping scripts; refuse while calls are running.
func quiesce_for_script_swap() -> Dictionary:
	return {"ok": _active_calls == 0}


# --- Handlers (sync entry → deferred reply) ------------------------------------

func categories(params: Dictionary, ctx) -> Dictionary:
	return _start(_categories, params, ctx)


func search(params: Dictionary, ctx) -> Dictionary:
	return _start(_search, params, ctx)


func info(params: Dictionary, ctx) -> Dictionary:
	return _start(_info, params, ctx)


func thumbnail(params: Dictionary, ctx) -> Dictionary:
	return _start(_thumbnail, params, ctx)


func download(params: Dictionary, ctx) -> Dictionary:
	return _start(_download, params, ctx)


func prep_terrain3d(params: Dictionary, ctx) -> Dictionary:
	return _start(_prep_terrain3d, params, ctx)


func t3d_place(params: Dictionary, _ctx) -> Dictionary:
	var r := Terrain3DPrep.place(Array(params.get("mesh_ids", [])), float(params.get("x", 0)),
		float(params.get("z", 0)), float(params.get("spacing", 3.0)))
	return {"data": r} if r.ok else _error(r.error)


func t3d_clear(params: Dictionary, _ctx) -> Dictionary:
	var r := Terrain3DPrep.clear_instances(Array(params.get("mesh_ids", [])))
	return {"data": r} if r.ok else _error(r.error)


func installed(_params: Dictionary, _ctx) -> Dictionary:
	var out := []
	var manifest := Credits.load_manifest()
	for key in manifest.assets:
		var e: Dictionary = manifest.assets[key]
		out.append({"id": e.id, "name": e.name, "type": e.get("type", "models"), "resolutions": e.resolutions,
			"folder": e.folder, "main_file": e.main_file, "license": e.license, "terrain3d": e.get("terrain3d", {})})
	return {"data": {"count": out.size(), "assets": out}}


func status(_params: Dictionary, _ctx) -> Dictionary:
	if not is_instance_valid(panel):
		return _error("Asset Commons panel is not loaded")
	var queue: Array = panel.queue_state()
	return {"data": {"downloading": queue[0] if not queue.is_empty() else null, "queued": queue.slice(1)}}


# --- Implementations -----------------------------------------------------------

func _categories(params: Dictionary) -> Dictionary:
	var type_id := str(params.get("type", ""))
	if type_id not in TYPE_ENUM:
		return _error("type must be one of %s" % [TYPE_ENUM])
	var cats: Array = await panel.get_source().fetch_categories(type_id)
	var out := []
	for c in cats:
		if c.has("separator"):
			continue
		out.append({"id": c.id, "label": c.label})
	return {"data": {"type": type_id, "categories": out}}


func _search(params: Dictionary) -> Dictionary:
	var type_id := str(params.get("type", ""))
	if type_id not in TYPE_ENUM:
		return _error("type must be one of %s" % [TYPE_ENUM])
	var res: Dictionary = await panel.get_source().fetch_assets(type_id, str(params.get("category", "all")))
	if not res.ok:
		return _error("could not load assets: %s" % res.get("error", "?"))
	var words := Array(str(params.get("query", "")).to_lower().split(" ", false))
	var hits := []
	for a in res.assets:
		var hay: String = (a.name + " " + a.id + " " + " ".join(a.tags)).to_lower()
		if words.all(func(w): return hay.contains(w)):
			hits.append(a)
	match str(params.get("sort", "popular")):
		"newest": hits.sort_custom(func(a, b): return a.date_published > b.date_published)
		"name": hits.sort_custom(func(a, b): return a.name.naturalnocasecmp_to(b.name) < 0)
		_: hits.sort_custom(func(a, b): return a.download_count > b.download_count)
	var offset := maxi(int(params.get("offset", 0)), 0)
	var limit := clampi(int(params.get("limit", 20)), 1, 100)
	var page := []
	for a in hits.slice(offset, offset + limit):
		page.append(_summary(a))
	return {"data": {"type": type_id, "total": hits.size(), "offset": offset, "assets": page}}


func _info(params: Dictionary) -> Dictionary:
	var asset: Dictionary = await panel.find_asset(str(params.get("id", "")), str(params.get("type", "")))
	if asset.is_empty():
		return _error("asset '%s' not found" % params.get("id", ""))
	var sizes := {}
	for r in panel.get_source().get_resolutions():
		var plan: Dictionary = await panel.get_source().fetch_download_plan(asset, r)
		if plan.ok:
			sizes[r] = {"bytes": plan.total_size, "human": String.humanize_size(plan.total_size), "actual_resolution": plan.resolution}
	var out := _summary(asset)
	out.merge({
		"description": asset.description,
		"tags": asset.tags,
		"categories": asset.categories,
		"authors": asset.authors,
		"license": asset.license,
		"page_url": asset.page_url,
		"download_count": asset.download_count,
		"download_sizes": sizes,
		"installed_entry": Credits.find(asset.source, asset.id),
	}, true)
	return {"data": out}


func _thumbnail(params: Dictionary) -> Dictionary:
	var asset: Dictionary = await panel.find_asset(str(params.get("id", "")), str(params.get("type", "")))
	if asset.is_empty():
		return _error("asset '%s' not found" % params.get("id", ""))
	var source: RefCounted = panel.get_source()
	var path: String = source.cache.root.path_join("previews").path_join("%s_512.png" % asset.id)
	if not FileAccess.file_exists(path):
		var res: Dictionary = await source.http.fetch(str(asset.thumbnail_url).replace("width=256&height=256", "width=512&height=512"))
		if not res.ok:
			return _error("thumbnail download failed: %s" % res.error)
		var img := AssetSource.decode_image(res.body)
		if img == null:
			return _error("could not decode thumbnail")
		DirAccess.make_dir_recursive_absolute(path.get_base_dir())
		img.save_png(path)
	return {"data": {"id": asset.id, "name": asset.name, "png_path": path}}


func _download(params: Dictionary) -> Dictionary:
	var asset: Dictionary = await panel.find_asset(str(params.get("id", "")), str(params.get("type", "")))
	if asset.is_empty():
		return _error("asset '%s' not found" % params.get("id", ""))
	var resolution := str(params.get("resolution", "1k"))
	if resolution not in Array(panel.get_source().get_resolutions()):
		return _error("resolution must be one of %s" % [panel.get_source().get_resolutions()])
	var waiter := _Waiter.new(asset.id, resolution)
	panel.download_finished.connect(waiter.on_finished)
	panel.enqueue_download(asset, resolution)
	var deadline := Time.get_ticks_msec() + clampi(int(params.get("wait_seconds", 100)), 0, 110) * 1000
	var tree := Engine.get_main_loop() as SceneTree
	while waiter.result.is_empty() and Time.get_ticks_msec() < deadline:
		await tree.create_timer(0.25).timeout
	if is_instance_valid(panel) and panel.download_finished.is_connected(waiter.on_finished):
		panel.download_finished.disconnect(waiter.on_finished)
	if waiter.result.is_empty():
		return {"data": {"id": asset.id, "resolution": resolution, "status": "in_progress",
			"hint": "Still downloading; poll commons_status / commons_installed."}}
	if not waiter.result.ok:
		return _error("download failed: %s" % waiter.result.get("error", "?"))
	return {"data": {"id": asset.id, "type": asset.type, "resolution": waiter.result.resolution, "status": "done",
		"folder": waiter.result.folder, "main_file": waiter.result.main_file}}


func _prep_terrain3d(params: Dictionary) -> Dictionary:
	var asset: Dictionary = await panel.find_asset(str(params.get("id", "")), "models")
	if asset.is_empty():
		return _error("model '%s' not found" % params.get("id", ""))
	var result: Dictionary = await panel.prep_for_terrain3d(asset, Array(params.get("budgets", [])), bool(params.get("register", true)))
	if not result.ok:
		return _error(result.error)
	return {"data": {"id": asset.id, "out_dir": result.out_dir, "variants": result.variants, "registered": result.registered}}


# --- Helpers -------------------------------------------------------------------

## Runs `impl` as a coroutine and replies through ctx.send_deferred().
func _start(impl: Callable, params: Dictionary, ctx) -> Dictionary:
	if not is_instance_valid(panel):
		return _error("Asset Commons panel is not loaded")
	_run(impl, params, ctx)
	return DEFERRED


func _run(impl: Callable, params: Dictionary, ctx) -> void:
	_active_calls += 1
	# Yield once so the dispatcher registers the deferred request before we reply.
	await (Engine.get_main_loop() as SceneTree).create_timer(0.01).timeout
	var result: Dictionary = await impl.call(params)
	_active_calls -= 1
	ctx.send_deferred(result)


func _summary(a: Dictionary) -> Dictionary:
	var entry := Credits.find(a.source, a.id)
	var out := {
		"id": a.id,
		"name": a.name,
		"type": a.type,
		"max_resolution": "%dK" % (a.max_resolution.x / 1024) if a.max_resolution.x > 0 else "",
		"tags": a.tags.slice(0, 8),
		"installed_resolutions": entry.get("resolutions", []),
	}
	if a.polycount >= 0:
		out["polycount"] = a.polycount
	for row in a.get("extra_stats", []):
		out[STAT_KEYS.get(row[0], str(row[0]).to_lower().replace(" ", "_"))] = row[1]
	return out


static func _error(message: String) -> Dictionary:
	return {"status": "error", "error": {"code": "INVALID_PARAMS", "message": message}}


class _Waiter:
	var id: String
	var resolution: String
	var result := {}

	func _init(asset_id: String, res: String) -> void:
		id = asset_id
		resolution = res

	func on_finished(asset_id: String, res: String, r: Dictionary) -> void:
		if asset_id == id and res == resolution:
			result = r

@tool
extends "asset_source.gd"
## Poly Haven (https://polyhaven.com) — CC0 models, textures and HDRIs via the public API.
## API docs: https://api.polyhaven.com / https://redocly.github.io/redoc/?url=https://api.polyhaven.com/api-docs/swagger.json

const Settings = preload("../core/settings.gd")
const API := "https://api.polyhaven.com"

const TYPES := [
	{"id": "models", "label": "Models", "noun": "models"},
	{"id": "textures", "label": "Textures", "noun": "textures"},
	{"id": "hdris", "label": "HDRIs", "noun": "HDRIs"},
]

## Texture maps downloaded for a material: Poly Haven map name -> file format.
## arm = AO (R), roughness (G), metallic (B) packed into one image.
const TEXTURE_MAPS := {"Diffuse": "jpg", "nor_gl": "jpg", "arm": "jpg", "Displacement": "jpg"}


func get_id() -> String:
	return "polyhaven"


func get_display_name() -> String:
	return "Poly Haven"


func get_credit() -> Dictionary:
	return {"text": "Powered by Poly Haven", "url": "https://polyhaven.com"}


func get_asset_types() -> Array:
	return TYPES


func get_resolutions() -> PackedStringArray:
	return PackedStringArray(["1k", "2k", "4k", "8k"])


func fetch_categories(type_id: String, force_refresh := false) -> Array:
	var key := "categories_%s.json" % type_id
	var data: Variant = null
	if not force_refresh and cache.has(key, Settings.list_cache_seconds()):
		data = cache.read_json(key)
	else:
		var res: Dictionary = await http.fetch_json("%s/categories/%s" % [API, type_id])
		if res.ok and res.data is Dictionary:
			data = res.data
			cache.write_json(key, data)
		elif cache.has(key):
			data = cache.read_json(key)
	var noun := _type_noun(type_id)
	if not data is Dictionary:
		return [{"id": "all", "label": "All %s" % noun}]

	# Poly Haven returns {name: count}; "collection: x" entries are themed packs.
	var categories := []
	var collections := []
	for name: String in data:
		if name == "all":
			continue
		var entry := {"id": name, "count": int(data[name])}
		if name.begins_with("collection: "):
			entry.label = "%s (%d)" % [name.trim_prefix("collection: ").replace("_", " ").capitalize(), entry.count]
			collections.append(entry)
		else:
			entry.label = "%s (%d)" % [name.replace("-", " / ").capitalize(), entry.count]
			categories.append(entry)
	var by_count := func(a, b): return a.count > b.count
	categories.sort_custom(by_count)
	collections.sort_custom(by_count)
	var out: Array = [{"id": "all", "label": "All %s (%d)" % [noun, int(data.get("all", 0))]}]
	out.append({"separator": "Categories"})
	out.append_array(categories)
	if not collections.is_empty():
		out.append({"separator": "Collections"})
		out.append_array(collections)
	return out


func fetch_assets(type_id: String, category_id: String, force_refresh := false) -> Dictionary:
	var key := "list_%s_%s.json" % [type_id, category_id]
	if not force_refresh and cache.has(key, Settings.list_cache_seconds()):
		return {"ok": true, "assets": _normalize_list(type_id, cache.read_json(key)), "stale": false}

	var url := "%s/assets?type=%s" % [API, type_id]
	if category_id != "all":
		url += "&categories=" + category_id.uri_encode()
	var res: Dictionary = await http.fetch_json(url)
	if res.ok and res.data is Dictionary:
		cache.write_json(key, res.data)
		return {"ok": true, "assets": _normalize_list(type_id, res.data), "stale": false}
	# Offline: fall back to an expired cache rather than showing nothing.
	if cache.has(key):
		return {"ok": true, "assets": _normalize_list(type_id, cache.read_json(key)), "stale": true, "error": res.error}
	return {"ok": false, "assets": [], "error": res.error}


func fetch_download_plan(asset: Dictionary, resolution: String) -> Dictionary:
	var files := await _fetch_files(asset)
	if files.is_empty():
		return {"ok": false, "error": "could not fetch file list"}
	match asset.type:
		"models":
			return _plan_model(asset, files, resolution)
		"textures":
			return _plan_texture(asset, files, resolution)
		"hdris":
			return _plan_hdri(asset, files, resolution)
	return {"ok": false, "error": "unknown asset type %s" % asset.type}


func post_import(asset: Dictionary, plan: Dictionary, folder: String) -> Dictionary:
	match asset.type:
		"textures":
			return _build_material(asset, plan, folder)
		"hdris":
			return _build_sky(asset, plan, folder)
	return {"ok": true, "main_file": folder.path_join(plan.main_file)}


# --- Download plans -----------------------------------------------------------

func _plan_model(asset: Dictionary, files: Dictionary, resolution: String) -> Dictionary:
	var gltf: Dictionary = files.get("gltf", {})
	if gltf.is_empty():
		return {"ok": false, "error": "no glTF available for this asset"}
	var res := _pick_resolution(gltf.keys(), resolution)
	var entry: Dictionary = gltf[res]["gltf"]
	var main_file := "%s_%s.gltf" % [asset.id, res]
	var plan_files := [_file(entry, main_file)]
	var include: Dictionary = entry.get("include", {})
	for rel_path in include:
		plan_files.append(_file(include[rel_path], rel_path))
	return _plan(res, main_file, plan_files)


func _plan_texture(asset: Dictionary, files: Dictionary, resolution: String) -> Dictionary:
	if not files.has("Diffuse"):
		return {"ok": false, "error": "no diffuse map for this texture"}
	var res := _pick_resolution(files.Diffuse.keys(), resolution)
	var plan_files := []
	var maps := {}
	for map_name in TEXTURE_MAPS:
		var fmt: String = TEXTURE_MAPS[map_name]
		if not files.has(map_name) or not files[map_name].has(res) or not files[map_name][res].has(fmt):
			continue
		var entry: Dictionary = files[map_name][res][fmt]
		var rel: String = "textures/" + entry.url.get_file()
		plan_files.append(_file(entry, rel))
		maps[map_name] = rel
	var plan := _plan(res, "%s_%s.tres" % [asset.id, res], plan_files)
	plan.maps = maps
	return plan


func _plan_hdri(asset: Dictionary, files: Dictionary, resolution: String) -> Dictionary:
	var hdri: Dictionary = files.get("hdri", {})
	if hdri.is_empty():
		return {"ok": false, "error": "no HDRI files for this asset"}
	var res := _pick_resolution(hdri.keys(), resolution)
	var entry: Dictionary = hdri[res]["hdr"]
	var plan := _plan(res, "%s_%s_sky.tres" % [asset.id, res], [_file(entry, entry.url.get_file())])
	plan.hdr = entry.url.get_file()
	return plan


static func _file(entry: Dictionary, rel_path: String) -> Dictionary:
	return {"url": entry.url, "path": rel_path, "size": int(entry.size), "md5": entry.get("md5", "")}


static func _plan(res: String, main_file: String, files: Array) -> Dictionary:
	var total := 0
	for f in files:
		total += f.size
	return {"ok": true, "resolution": res, "main_file": main_file, "files": files, "total_size": total}


## The requested resolution, or the closest one below it (or the smallest available).
static func _pick_resolution(available: Array, wanted: String) -> String:
	if wanted in available:
		return wanted
	available.sort_custom(func(a, b): return a.to_int() < b.to_int())
	var res: String = available[0]
	for r in available:
		if r.to_int() <= wanted.to_int():
			res = r
	return res


# --- Post-import resources ------------------------------------------------------

func _build_material(asset: Dictionary, plan: Dictionary, folder: String) -> Dictionary:
	var maps: Dictionary = plan.maps
	var mat := StandardMaterial3D.new()
	mat.resource_name = asset.name
	if maps.has("Diffuse"):
		mat.albedo_texture = load(folder.path_join(maps.Diffuse))
	if maps.has("nor_gl"):
		mat.normal_enabled = true
		mat.normal_texture = load(folder.path_join(maps.nor_gl))
	if maps.has("arm"):
		var arm: Texture2D = load(folder.path_join(maps.arm))
		mat.ao_enabled = true
		mat.ao_texture = arm
		mat.ao_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
		mat.roughness_texture = arm
		mat.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_GREEN
		mat.metallic = 1.0
		mat.metallic_texture = arm
		mat.metallic_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_BLUE
	if maps.has("Displacement"):
		# Assigned but off: parallax is costly, enable per use.
		mat.heightmap_texture = load(folder.path_join(maps.Displacement))
		mat.heightmap_enabled = false
	if mat.albedo_texture == null:
		return {"ok": false, "error": "textures were not imported yet; material not created"}
	var path := folder.path_join(plan.main_file)
	var err := ResourceSaver.save(mat, path)
	if err != OK:
		return {"ok": false, "error": "could not save %s (%s)" % [path, error_string(err)]}
	return {"ok": true, "main_file": path}


func _build_sky(asset: Dictionary, plan: Dictionary, folder: String) -> Dictionary:
	var tex: Texture2D = load(folder.path_join(plan.hdr))
	if tex == null:
		return {"ok": false, "error": "HDRI was not imported yet; sky not created"}
	var sky_mat := PanoramaSkyMaterial.new()
	sky_mat.panorama = tex
	var sky := Sky.new()
	sky.resource_name = asset.name
	sky.sky_material = sky_mat
	var path := folder.path_join(plan.main_file)
	var err := ResourceSaver.save(sky, path)
	if err != OK:
		return {"ok": false, "error": "could not save %s (%s)" % [path, error_string(err)]}
	return {"ok": true, "main_file": path}


# --- API data -------------------------------------------------------------------

func _fetch_files(asset: Dictionary) -> Dictionary:
	# files_hash changes whenever Poly Haven updates the files, so the cache never goes stale.
	var key := "files_%s_%s.json" % [asset.id, asset.get("files_hash", "")]
	if cache.has(key):
		var cached: Variant = cache.read_json(key)
		if cached is Dictionary:
			return cached
	var res: Dictionary = await http.fetch_json("%s/files/%s" % [API, asset.id])
	if res.ok and res.data is Dictionary:
		cache.write_json(key, res.data)
		return res.data
	return {}


func _normalize_list(type_id: String, data: Variant) -> Array:
	var out := []
	if not data is Dictionary:
		return out
	for id in data:
		var a: Dictionary = data[id]
		var max_res: Array = a.get("max_resolution", [0, 0])
		var desc: Variant = a.get("description", a.get("info", ""))  # HDRIs use "info"
		out.append({
			"id": id,
			"name": a.get("name", id),
			"source": get_id(),
			"type": type_id,
			"description": desc if desc is String else "",
			"page_url": "https://polyhaven.com/a/%s" % id,
			"thumbnail_url": a.get("thumbnail_url", "https://cdn.polyhaven.com/asset_img/thumbs/%s.png?width=256&height=256" % id),
			"thumbnail_key": "%s_%s" % [id, a.get("img_version", "")],
			"categories": a.get("categories", []),
			"tags": a.get("tags", []),
			"authors": a.get("authors", {}),
			"polycount": int(a.get("polycount", -1)),
			"max_resolution": Vector2i(int(max_res[0]), int(max_res[1])),
			"extra_stats": _extra_stats(type_id, a),
			"download_count": int(a.get("download_count", 0)),
			"date_published": int(a.get("date_published", 0)),
			"files_hash": a.get("files_hash", ""),
			"license": "CC0 1.0",
		})
	return out


## Type-specific [label, value] rows for the detail pane.
static func _extra_stats(type_id: String, a: Dictionary) -> Array:
	var rows := []
	var dims: Array = a.get("dimensions", [])  # millimetres
	match type_id:
		"models":
			if dims.size() == 3:
				# Blender order (Z-up): width, depth, height.
				rows.append(["Size (W×D×H)", "%.2f × %.2f × %.2f m" % [dims[0] / 1000.0, dims[1] / 1000.0, dims[2] / 1000.0]])
		"textures":
			if dims.size() == 2:
				rows.append(["Real-world tile", "%.2f × %.2f m" % [dims[0] / 1000.0, dims[1] / 1000.0]])
		"hdris":
			if a.has("evs_cap"):
				rows.append(["Dynamic range", "%d EVs" % int(a.evs_cap)])
			if a.has("whitebalance") and a.whitebalance != null:
				rows.append(["White balance", "%d K" % int(a.whitebalance)])
	return rows


static func _type_noun(type_id: String) -> String:
	for t in TYPES:
		if t.id == type_id:
			return t.noun
	return type_id

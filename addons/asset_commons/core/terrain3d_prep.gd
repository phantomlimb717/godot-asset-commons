@tool
extends RefCounted
## Turns a downloaded model into Terrain3D-ready mesh assets.
##
## For each variant in the file (each top-level node; Poly Haven "sets" hold
## several, e.g. pine_tree_01 a/b/c) it:
##   1. merges all its meshes into one mesh, keeping one surface per material,
##   2. bakes node transforms into the vertices (neutral transforms),
##   3. moves the origin to the base (lowest point; pivot kept in X/Z),
##   4. keeps real-world scale (glTF is metres),
##   5. builds LOD0..LODn with Godot's mesh simplifier to fit triangle budgets,
## and writes <asset>/terrain3d/<variant>.tscn with sibling MeshInstance3Ds
## named "<variant>LOD0".. which Terrain3D's instancer picks up as LODs.
## The original download is left untouched.
##
## Terrain3D is optional: it is only touched through ClassDB/duck typing.

signal progress(fraction: float, message: String)

const Settings = preload("settings.gd")



static func terrain3d_available() -> bool:
	return ClassDB.class_exists("Terrain3D")


## Returns {ok, error, out_dir, variants: [{name, scene, lod_tris: [int]}]}.
## `budgets` = max triangles per LOD, near to far (default: project setting).
## The simplifier stops early on meshes it can't reduce further (e.g. foliage
## cards); later LODs are then dropped.
func prep(main_file: String, budgets: Array = []) -> Dictionary:
	if budgets.is_empty():
		budgets = Settings.terrain3d_budgets()
	var packed := load(main_file) as PackedScene
	if packed == null:
		return {"ok": false, "error": "could not load %s" % main_file}
	var root := packed.instantiate()
	var variants := _find_variants(root)
	if variants.is_empty():
		root.free()
		return {"ok": false, "error": "no meshes found in %s" % main_file}

	var out_dir := main_file.get_base_dir().path_join("terrain3d")
	for sub in ["", "meshes", "materials"]:
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out_dir.path_join(sub)))

	var saved_materials := {}  # original material -> saved external copy
	var results := []
	var tree := Engine.get_main_loop() as SceneTree
	for i in variants.size():
		var v: Node3D = variants[i]
		var vname := String(v.name).trim_suffix("_LOD0")
		progress.emit(float(i) / variants.size(), "Preparing %s (%d/%d): merging…" % [vname, i + 1, variants.size()])
		await tree.create_timer(0.05).timeout  # let the UI repaint before heavy work
		var surfaces := _merge_variant(v)
		if surfaces.is_empty():
			continue
		_move_origin_to_base(surfaces)

		progress.emit((i + 0.3) / variants.size(), "Preparing %s (%d/%d): simplifying…" % [vname, i + 1, variants.size()])
		await tree.create_timer(0.05).timeout
		var built := _build_lods(surfaces, budgets)
		var lods: Array = built.lods

		var scene_root := Node3D.new()
		scene_root.name = vname
		var lod_tris := []
		for k in lods.size():
			var mesh: ArrayMesh = lods[k].mesh
			for s in mesh.get_surface_count():
				mesh.surface_set_material(s, _external_material(mesh.surface_get_material(s), out_dir, saved_materials))
			var mesh_path := out_dir.path_join("meshes/%s_LOD%d.res" % [vname, k])
			ResourceSaver.save(mesh, mesh_path, ResourceSaver.FLAG_COMPRESS)
			mesh.take_over_path(mesh_path)
			_register_file(mesh_path)
			var mi := MeshInstance3D.new()
			mi.name = "%sLOD%d" % [vname, k]
			mi.mesh = mesh
			scene_root.add_child(mi)
			mi.owner = scene_root
			lod_tris.append(lods[k].tris)
		var scene := PackedScene.new()
		scene.pack(scene_root)
		var scene_path := out_dir.path_join("%s.tscn" % vname)
		ResourceSaver.save(scene, scene_path)
		scene_root.free()
		_register_file(scene_path)
		results.append({"name": vname, "scene": scene_path, "lod_tris": lod_tris,
			"solid_levels": built.levels, "foliage_keep": built.foliage_keep})
	root.free()

	EditorInterface.get_resource_filesystem().scan()
	progress.emit(1.0, "Prepared %d variant(s) for Terrain3D" % results.size())
	return {"ok": true, "out_dir": out_dir, "variants": results}


## Adds (or updates, matched by scene path) one Terrain3DMeshAsset per scene on
## the first Terrain3D node in the edited scene. Returns {ok, error, ids}.
static func register(scene_paths: Array) -> Dictionary:
	if not terrain3d_available():
		return {"ok": false, "error": "Terrain3D is not installed"}
	var terrain := _find_terrain(EditorInterface.get_edited_scene_root())
	if terrain == null:
		return {"ok": false, "error": "no Terrain3D node in the open scene"}
	var assets: Object = terrain.get("assets")
	if assets == null:
		assets = ClassDB.instantiate("Terrain3DAssets")
		terrain.set("assets", assets)
	var ids := []
	for path in scene_paths:
		var id: int = assets.get_mesh_count()
		for existing in assets.get_mesh_count():
			var ma: Object = assets.get_mesh_asset(existing)
			if ma and ma.scene_file and ma.scene_file.resource_path == path:
				id = existing
				break
		var asset: Object = ClassDB.instantiate("Terrain3DMeshAsset")
		asset.name = path.get_file().get_basename()
		asset.scene_file = load(path)
		assets.set_mesh_asset(id, asset)
		ids.append(id)
	EditorInterface.mark_scene_as_unsaved()
	return {"ok": true, "ids": ids, "terrain": String(terrain.get_path())}


## Places one instance per mesh id in a row along X starting at (x, z), each
## snapped to the terrain height. Returns {ok, error, placed: [{mesh_id, position}]}.
static func place(mesh_ids: Array, x: float, z: float, spacing := 3.0) -> Dictionary:
	var terrain := _find_terrain(EditorInterface.get_edited_scene_root())
	if terrain == null:
		return {"ok": false, "error": "no Terrain3D node in the open scene"}
	var data: Object = terrain.get("data")
	var instancer: Object = terrain.get("instancer")
	var assets: Object = terrain.get("assets")
	var placed := []
	for i in mesh_ids.size():
		var id := int(mesh_ids[i])
		if assets == null or id < 0 or id >= assets.get_mesh_count():
			return {"ok": false, "error": "mesh asset id %d does not exist" % id}
		var pos := Vector3(x + i * spacing, 0.0, z)
		var h: float = data.get_height(pos)
		if is_nan(h):
			return {"ok": false, "error": "no terrain at (%.1f, %.1f)" % [x + i * spacing, z]}
		pos.y = h
		var transforms: Array[Transform3D] = [Transform3D(Basis.IDENTITY, pos)]
		instancer.add_transforms(id, transforms, PackedColorArray(), true)
		placed.append({"mesh_id": id, "position": [pos.x, pos.y, pos.z]})
	EditorInterface.mark_scene_as_unsaved()
	return {"ok": true, "placed": placed}


## Removes every placed instance of the given mesh ids (the mesh assets stay).
static func clear_instances(mesh_ids: Array) -> Dictionary:
	var terrain := _find_terrain(EditorInterface.get_edited_scene_root())
	if terrain == null:
		return {"ok": false, "error": "no Terrain3D node in the open scene"}
	var instancer: Object = terrain.get("instancer")
	for id in mesh_ids:
		instancer.clear_by_mesh(int(id))
	EditorInterface.mark_scene_as_unsaved()
	return {"ok": true, "cleared": mesh_ids}


# --- Merging -------------------------------------------------------------------

## Variants are the top-level children that contain meshes. A single wrapper
## node (e.g. "Scene" → children) is looked through.
static func _find_variants(root: Node) -> Array:
	var level: Node = root
	var with_mesh := level.get_children().filter(func(c): return c is Node3D and _has_mesh(c))
	while with_mesh.size() == 1 and not with_mesh[0] is MeshInstance3D:
		level = with_mesh[0]
		with_mesh = level.get_children().filter(func(c): return c is Node3D and _has_mesh(c))
	if with_mesh.is_empty() and level is MeshInstance3D:
		return [level]
	return with_mesh


static func _has_mesh(n: Node) -> bool:
	if n is MeshInstance3D and n.mesh != null:
		return true
	return n.get_children().any(func(c): return _has_mesh(c))


## Returns [{material, arrays}] — one merged surface per (material, format).
static func _merge_variant(v: Node3D) -> Array:
	var parts := []
	_collect(v, Transform3D.IDENTITY, parts, true)
	var merged := {}  # key -> {material, arrays}
	for part in parts:
		var mi: MeshInstance3D = part.node
		var mesh: Mesh = mi.mesh
		for s in mesh.get_surface_count():
			if mesh.surface_get_primitive_type(s) != Mesh.PRIMITIVE_TRIANGLES:
				continue
			var arrays := mesh.surface_get_arrays(s)
			_transform_arrays(arrays, part.xform)
			var mat: Material = mi.get_active_material(s)
			var key := "%d|%s" % [mat.get_instance_id() if mat else 0, _format_key(arrays)]
			if merged.has(key):
				_append_arrays(merged[key].arrays, arrays)
			else:
				merged[key] = {"material": mat, "arrays": _with_indices(arrays)}
	return merged.values()


## `xform` maps node-local space into variant space; the variant's own
## transform is excluded so each variant's pivot becomes the origin.
static func _collect(n: Node, xform: Transform3D, out: Array, is_variant_root: bool) -> void:
	var local := xform
	if not is_variant_root and n is Node3D:
		local = xform * (n as Node3D).transform
	if n is MeshInstance3D and n.mesh != null and n.visible:
		out.append({"node": n, "xform": local})
	for c in n.get_children():
		_collect(c, local, out, false)


static func _transform_arrays(arrays: Array, xform: Transform3D) -> void:
	if xform == Transform3D.IDENTITY:
		return
	arrays[Mesh.ARRAY_VERTEX] = xform * (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array)
	if xform.basis == Basis.IDENTITY:
		return
	var nbasis := Transform3D(xform.basis.inverse().transposed(), Vector3.ZERO)
	if arrays[Mesh.ARRAY_NORMAL] != null:
		var normals: PackedVector3Array = nbasis * (arrays[Mesh.ARRAY_NORMAL] as PackedVector3Array)
		for i in normals.size():
			normals[i] = normals[i].normalized()
		arrays[Mesh.ARRAY_NORMAL] = normals
	if arrays[Mesh.ARRAY_TANGENT] != null:
		var t: PackedFloat32Array = arrays[Mesh.ARRAY_TANGENT]
		for i in range(0, t.size(), 4):
			var v := (xform.basis * Vector3(t[i], t[i + 1], t[i + 2])).normalized()
			t[i] = v.x; t[i + 1] = v.y; t[i + 2] = v.z
		arrays[Mesh.ARRAY_TANGENT] = t


static func _format_key(arrays: Array) -> String:
	var bits := ""
	for i in Mesh.ARRAY_MAX:
		if i != Mesh.ARRAY_INDEX:
			bits += "1" if arrays[i] != null else "0"
	return bits


static func _with_indices(arrays: Array) -> Array:
	if arrays[Mesh.ARRAY_INDEX] == null:
		var idx := PackedInt32Array()
		idx.resize((arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size())
		for i in idx.size():
			idx[i] = i
		arrays[Mesh.ARRAY_INDEX] = idx
	return arrays


static func _append_arrays(dst: Array, src: Array) -> void:
	src = _with_indices(src)
	var offset := (dst[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	var idx: PackedInt32Array = src[Mesh.ARRAY_INDEX]
	var shifted := PackedInt32Array()
	shifted.resize(idx.size())
	for i in idx.size():
		shifted[i] = idx[i] + offset
	for i in Mesh.ARRAY_MAX:
		if i == Mesh.ARRAY_INDEX:
			dst[i].append_array(shifted)
		elif dst[i] != null:
			dst[i].append_array(src[i])


static func _move_origin_to_base(surfaces: Array) -> void:
	var tmp := ArrayMesh.new()
	for s in surfaces:
		tmp.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, s.arrays)
	var aabb := tmp.get_aabb()
	# Keep the authored pivot in X/Z (trunk base) unless it lies outside the footprint.
	var shift := Vector3(0, -aabb.position.y, 0)
	if not Rect2(aabb.position.x, aabb.position.z, aabb.size.x, aabb.size.z).has_point(Vector2.ZERO):
		var c := aabb.get_center()
		shift.x = -c.x
		shift.z = -c.z
	if shift.is_zero_approx():
		return
	var xform := Transform3D(Basis.IDENTITY, shift)
	for s in surfaces:
		s.arrays[Mesh.ARRAY_VERTEX] = xform * (s.arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array)


# --- LODs ----------------------------------------------------------------------

## Returns {lods: [{mesh: ArrayMesh, tris: int}], levels: [int], foliage_keep: [float]}.
##
## Solid surfaces (trunks, rocks) use Godot's simplifier: it yields a few
## coarse detail levels, so each LOD takes the level closest to its share of
## the budget (on a ratio scale).
## Foliage surfaces (many small disconnected pieces, e.g. needles or leaf
## cards) are NOT simplified — the simplifier deletes them outright. Instead
## each LOD keeps an evenly spread subset of pieces and scales the survivors
## up around their own centre so the tree keeps its fullness and silhouette.
## A LOD must be clearly smaller than the previous one, or it is dropped.
static func _build_lods(surfaces: Array, budgets: Array) -> Dictionary:
	var solid := []
	var foliage := []
	var full_tris := 0
	for s in surfaces:
		full_tris += (s.arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
		var isl := _islands(s.arrays)
		if isl.count >= FOLIAGE_MIN_PIECES and isl.tris_per_piece <= FOLIAGE_MAX_PIECE_TRIS:
			# Foliage surfaces often also hold twig stems (fir_tree_01: 1k stems of
			# 30-140 tris among 90k four-tri needles). Stems are structure: thinning
			# or enlarging them leaves floating needles and long diagonal sticks, so
			# they go with the solid parts and only the small pieces get thinned.
			var split := _split_pieces(s.arrays, isl, FOLIAGE_STEM_MIN_TRIS)
			if not split.big.is_empty():
				solid.append({"arrays": split.big, "material": s.material})
			if split.small.is_empty():
				continue
			s.arrays = split.small
			s.islands = _islands(s.arrays)
			foliage.append(s)
		else:
			solid.append(s)

	# Solid surfaces: simplifier levels (level -1 = full mesh).
	var im := ImporterMesh.new()
	for s in solid:
		im.add_surface(Mesh.PRIMITIVE_TRIANGLES, s.arrays, [], {}, s.material)
	if not solid.is_empty():
		im.generate_lods(25.0, 60.0, [])
	var level_count := 0
	for i in im.get_surface_count():
		level_count = maxi(level_count, im.get_surface_lod_count(i))
	var levels := []  # solid tris per level, index 0 = full
	for level in range(-1, level_count):
		var tris := 0
		for i in im.get_surface_count():
			tris += _level_indices(im, i, level).size() / 3
		levels.append(tris)
	var solid_full: int = levels[0] if not levels.is_empty() else 0

	var foliage_full := full_tris - solid_full
	var lods := []
	var keeps := []
	var last_tris := -1
	for budget in budgets:
		var ratio := minf(1.0, float(budget) / maxi(full_tris, 1))
		var mesh := ArrayMesh.new()
		var tris := 0
		# Solid part: level closest to its share. With foliage present, trunk and
		# branches claim the budget first (up to SOLID_MAX_SHARE of it): they are a
		# small part of a tree, and simplifying them hard breaks branches into
		# floating sticks. Without foliage (rocks), a proportional share.
		if not solid.is_empty():
			var target := maxf(solid_full * ratio, 1.0)
			if not foliage.is_empty():
				target = maxf(minf(solid_full, budget * SOLID_MAX_SHARE), 1.0)
			var best := 0
			var best_score := INF
			for i in levels.size():
				var score := absf(log(float(maxi(levels[i], 1)) / target))
				if score < best_score:
					best_score = score
					best = i
			for i in im.get_surface_count():
				var arrays := _compact(im.get_surface_arrays(i), _level_indices(im, i, best - 1))
				mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
				mesh.surface_set_material(mesh.get_surface_count() - 1, im.get_surface_material(i))
			tris += levels[best]
		# Foliage part: thin out pieces to fill the rest of the budget, enlarge survivors.
		var keep := minf(1.0, float(budget - tris) / maxi(foliage_full, 1))
		keep = maxf(keep, FOLIAGE_MIN_KEEP)
		for s in foliage:
			var thinned := _thin_foliage(s.arrays, s.islands, keep)
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, thinned)
			mesh.surface_set_material(mesh.get_surface_count() - 1, s.material)
			tris += (thinned[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
		if last_tris >= 0 and tris >= last_tris * 0.9:
			continue  # not meaningfully smaller than the previous LOD
		lods.append({"mesh": mesh, "tris": tris})
		keeps.append(snappedf(keep, 0.001) if not foliage.is_empty() else 1.0)
		last_tris = tris
	return {"lods": lods, "levels": levels, "foliage_keep": keeps}


# --- Foliage thinning ------------------------------------------------------------

## A surface counts as foliage when it is many small disconnected pieces.
const FOLIAGE_MIN_PIECES := 200
## Most of a LOD's budget that trunk/branches/stems may take before foliage gets the rest.
const SOLID_MAX_SHARE := 0.7
const FOLIAGE_MAX_PIECE_TRIS := 64.0
## Pieces of a foliage surface with at least this many triangles are stems
## (structure), not leaves/needles.
const FOLIAGE_STEM_MIN_TRIS := 16
## Never thin below this fraction of pieces (keeps the far LOD readable).
const FOLIAGE_MIN_KEEP := 0.03
## Survivors grow by 1/sqrt(keep) to preserve covered area, capped here. Kept
## low: big enlargement turns needles into sticks that float off their twigs.
const FOLIAGE_MAX_SCALE := 1.4


## Splits a surface's triangles by piece size: {big: arrays, small: arrays}
## (either may be empty).
static func _split_pieces(arrays: Array, islands: Dictionary, min_tris: int) -> Dictionary:
	var tri_island: PackedInt32Array = islands.tri_island
	var sizes := PackedInt32Array()
	sizes.resize(islands.count)
	for isl in tri_island:
		sizes[isl] += 1
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var big := PackedInt32Array()
	var small := PackedInt32Array()
	# Packed arrays are values in GDScript, so append to each one by name.
	for t in tri_island.size():
		if sizes[tri_island[t]] >= min_tris:
			big.append_array(idx.slice(t * 3, t * 3 + 3))
		else:
			small.append_array(idx.slice(t * 3, t * 3 + 3))
	return {"big": _compact(arrays, big) if not big.is_empty() else [],
		"small": _compact(arrays, small) if not small.is_empty() else []}


## Connected pieces of a surface. Vertices at the same position are welded
## first, so UV seams don't split one needle into two pieces.
## Returns {count, tris_per_piece, tri_island: PackedInt32Array}.
static func _islands(arrays: Array) -> Dictionary:
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var weld := PackedInt32Array()
	weld.resize(verts.size())
	var seen := {}
	for i in verts.size():
		var key := verts[i].snappedf(0.0001)
		if seen.has(key):
			weld[i] = seen[key]
		else:
			seen[key] = i
			weld[i] = i
	var parent := PackedInt32Array()
	parent.resize(verts.size())
	for i in parent.size():
		parent[i] = i
	for t in range(0, idx.size(), 3):
		var a := _find(parent, weld[idx[t]])
		var b := _find(parent, weld[idx[t + 1]])
		var c := _find(parent, weld[idx[t + 2]])
		parent[b] = a
		parent[_find(parent, c)] = a
	var tri_island := PackedInt32Array()
	tri_island.resize(idx.size() / 3)
	var roots := {}
	for t in tri_island.size():
		var r := _find(parent, weld[idx[t * 3]])
		if not roots.has(r):
			roots[r] = roots.size()
		tri_island[t] = roots[r]
	return {"count": roots.size(), "tris_per_piece": float(tri_island.size()) / maxi(roots.size(), 1),
		"tri_island": tri_island}


static func _find(parent: PackedInt32Array, i: int) -> int:
	while parent[i] != i:
		parent[i] = parent[parent[i]]  # path halving
		i = parent[i]
	return i


## Keeps roughly `keep` of the pieces (deterministic, evenly spread) and scales
## each kept piece about its centre so total coverage stays similar.
static func _thin_foliage(arrays: Array, islands: Dictionary, keep: float) -> Array:
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	if keep >= 1.0:
		return _compact(arrays, idx)
	var tri_island: PackedInt32Array = islands.tri_island
	var kept := PackedByteArray()
	kept.resize(islands.count)
	for i in islands.count:
		# Golden-ratio sequence: spreads the kept pieces evenly, same result every run.
		kept[i] = 1 if fposmod(i * 0.6180339887, 1.0) < keep else 0
	var new_idx := PackedInt32Array()
	var sums := PackedVector3Array()
	sums.resize(islands.count)
	var counts := PackedInt32Array()
	counts.resize(islands.count)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	for t in tri_island.size():
		var isl := tri_island[t]
		if kept[isl] == 0:
			continue
		for k in 3:
			var v := idx[t * 3 + k]
			new_idx.append(v)
			sums[isl] += verts[v]
			counts[isl] += 1
	# Scale kept pieces about their centres (vertices belong to one piece each).
	var scale := minf(1.0 / sqrt(keep), FOLIAGE_MAX_SCALE)
	var scaled := verts.duplicate()
	var done := PackedByteArray()
	done.resize(verts.size())
	for t in tri_island.size():
		var isl := tri_island[t]
		if kept[isl] == 0:
			continue
		var centre := sums[isl] / counts[isl]
		for k in 3:
			var v := idx[t * 3 + k]
			if done[v] == 0:
				scaled[v] = centre + (verts[v] - centre) * scale
				done[v] = 1
	var out := arrays.duplicate()
	out[Mesh.ARRAY_VERTEX] = scaled
	return _compact(out, new_idx)


static func _level_indices(im: ImporterMesh, s: int, level: int) -> PackedInt32Array:
	if level < 0 or im.get_surface_lod_count(s) == 0:
		return im.get_surface_arrays(s)[Mesh.ARRAY_INDEX]
	return im.get_surface_lod_indices(s, mini(level, im.get_surface_lod_count(s) - 1))


## Keeps only the vertices referenced by `indices` (LODs reuse the full vertex
## buffer, which would otherwise make every LOD as heavy as LOD0).
static func _compact(arrays: Array, indices: PackedInt32Array) -> Array:
	var remap := {}
	var new_idx := PackedInt32Array()
	new_idx.resize(indices.size())
	var order := PackedInt32Array()
	for i in indices.size():
		var old := indices[i]
		if not remap.has(old):
			remap[old] = order.size()
			order.append(old)
		new_idx[i] = remap[old]
	var out := []
	out.resize(Mesh.ARRAY_MAX)
	for a in Mesh.ARRAY_MAX:
		var src = arrays[a]
		if src == null or a == Mesh.ARRAY_INDEX:
			continue
		var width := 1
		match a:
			Mesh.ARRAY_TANGENT, Mesh.ARRAY_BONES, Mesh.ARRAY_WEIGHTS:
				width = 4
		var dst = src.slice(0, 0)  # empty array of the same packed type
		dst.resize(order.size() * width)
		for i in order.size():
			for w in width:
				dst[i * width + w] = src[order[i] * width + w]
		out[a] = dst
	out[Mesh.ARRAY_INDEX] = new_idx
	return out


# --- Materials / lookup ----------------------------------------------------------

## Materials embedded in the imported glTF are saved once as .tres files so all
## LOD meshes share them instead of each embedding a copy. A material file that
## already exists is reused as-is, so hand-tuned materials (e.g. wind shaders)
## survive re-running prep; delete the file to regenerate it.
static func _external_material(mat: Material, out_dir: String, saved: Dictionary) -> Material:
	if mat == null:
		return null
	if saved.has(mat):
		return saved[mat]
	var result := mat
	if mat.resource_path.is_empty() or mat.resource_path.contains("::"):
		var mname := mat.resource_name if not mat.resource_name.is_empty() else "material_%d" % saved.size()
		var path := out_dir.path_join("materials/%s.tres" % mname.validate_filename())
		if ResourceLoader.exists(path):
			saved[mat] = load(path)
			return saved[mat]
		result = mat.duplicate()
		ResourceSaver.save(result, path)
		result.take_over_path(path)
		_register_file(path)
	saved[mat] = result
	return result


## Tells the editor about a newly written file so its UID is known right away
## (otherwise files referencing it log "invalid UID" warnings until a rescan).
static func _register_file(path: String) -> void:
	EditorInterface.get_resource_filesystem().update_file(path)


static func _find_terrain(n: Node) -> Node:
	if n == null:
		return null
	if n.is_class("Terrain3D"):
		return n
	for c in n.get_children():
		var t := _find_terrain(c)
		if t:
			return t
	return null

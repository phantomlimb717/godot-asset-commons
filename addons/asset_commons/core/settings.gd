@tool
extends RefCounted
## Project settings for the Asset Commons. Defaults are registered as initial
## values, so nothing is written to project.godot unless the user changes them.

const DOWNLOAD_ROOT := "asset_commons/download_root"
const USER_AGENT := "asset_commons/user_agent"
const LIST_CACHE_HOURS := "asset_commons/list_cache_hours"
const T3D_BUDGETS := "asset_commons/terrain3d_lod_budgets"

const VERSION := "0.2.0"


static func register() -> void:
	_add(DOWNLOAD_ROOT, "res://assets", TYPE_STRING, PROPERTY_HINT_DIR)
	_add(USER_AGENT, "", TYPE_STRING, PROPERTY_HINT_PLACEHOLDER_TEXT, "(auto)")
	_add(LIST_CACHE_HOURS, 24, TYPE_INT, PROPERTY_HINT_RANGE, "0,720,1")
	_add(T3D_BUDGETS, PackedInt32Array([150000, 40000, 12000, 4000]), TYPE_PACKED_INT32_ARRAY, PROPERTY_HINT_NONE)


static func download_root() -> String:
	return str(ProjectSettings.get_setting(DOWNLOAD_ROOT, "res://assets")).trim_suffix("/")


## Max triangles for LOD0..LODn when preparing models for Terrain3D.
static func terrain3d_budgets() -> Array:
	return Array(ProjectSettings.get_setting(T3D_BUDGETS, PackedInt32Array([150000, 40000, 12000, 4000])))


static func list_cache_seconds() -> int:
	return int(ProjectSettings.get_setting(LIST_CACHE_HOURS, 24)) * 3600


## Poly Haven asks API users to send a User-Agent unique to their tool.
static func user_agent() -> String:
	var custom := str(ProjectSettings.get_setting(USER_AGENT, ""))
	if not custom.is_empty():
		return custom
	var project := str(ProjectSettings.get_setting("application/config/name", "unnamed")).validate_filename()
	return "GodotAssetCommons/%s (Godot %s; project %s)" % [VERSION, Engine.get_version_info().string, project]


static func _add(name: String, default: Variant, type: int, hint: int, hint_string := "") -> void:
	if not ProjectSettings.has_setting(name):
		ProjectSettings.set_setting(name, default)
	ProjectSettings.set_initial_value(name, default)
	ProjectSettings.add_property_info({"name": name, "type": type, "hint": hint, "hint_string": hint_string})

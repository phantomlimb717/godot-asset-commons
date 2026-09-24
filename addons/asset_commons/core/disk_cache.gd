@tool
extends RefCounted
## Small on-disk cache in the editor's per-user cache folder (outside the
## project), so it is shared between projects and never ends up in git.

var root: String


func _init(folder_name: String) -> void:
	root = EditorInterface.get_editor_paths().get_cache_dir().path_join("asset_commons").path_join(folder_name)
	DirAccess.make_dir_recursive_absolute(root)


func path_for(key: String) -> String:
	return root.path_join(key.validate_filename())


## True if the entry exists and is younger than `max_age_sec` (<= 0: any age).
func has(key: String, max_age_sec := 0) -> bool:
	var p := path_for(key)
	if not FileAccess.file_exists(p):
		return false
	if max_age_sec <= 0:
		return true
	return Time.get_unix_time_from_system() - FileAccess.get_modified_time(p) < max_age_sec


func read_bytes(key: String) -> PackedByteArray:
	return FileAccess.get_file_as_bytes(path_for(key))


func write_bytes(key: String, data: PackedByteArray) -> void:
	var f := FileAccess.open(path_for(key), FileAccess.WRITE)
	if f:
		f.store_buffer(data)


func read_json(key: String) -> Variant:
	return JSON.parse_string(FileAccess.get_file_as_string(path_for(key)))


func write_json(key: String, data: Variant) -> void:
	var f := FileAccess.open(path_for(key), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(data))


## Deletes every cached file (used by the "clear cache" menu).
func clear() -> void:
	for file in DirAccess.get_files_at(root):
		DirAccess.remove_absolute(root.path_join(file))

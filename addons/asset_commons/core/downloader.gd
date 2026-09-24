@tool
extends RefCounted
## Downloads an asset into <download_root>/<source_id>/<asset_id>/.
## Files are staged in the editor cache first and only copied into the project
## once every file downloaded and passed its MD5 check, so a failed download
## never leaves a half-imported asset behind.

signal progress(fraction: float, message: String)

const Settings = preload("settings.gd")
const Credits = preload("credits.gd")

## Extensions Godot imports (and so gets a .import file); others (.bin) are raw.
const IMPORTABLE := ["jpg", "jpeg", "png", "webp", "hdr", "exr", "gltf", "glb", "fbx", "obj"]

var busy := false


## Returns {ok, error, folder, main_file, resolution}.
func download(source: RefCounted, asset: Dictionary, resolution: String) -> Dictionary:
	if busy:
		return {"ok": false, "error": "another download is running"}
	busy = true
	var result := await _download(source, asset, resolution)
	busy = false
	return result


func _download(source: RefCounted, asset: Dictionary, resolution: String) -> Dictionary:
	progress.emit(0.0, "Fetching file list…")
	var plan: Dictionary = await source.fetch_download_plan(asset, resolution)
	if not plan.ok:
		return plan

	var stage: String = source.cache.root.path_join("staging").path_join("%s_%s" % [asset.id, plan.resolution])
	var jobs := []
	for f in plan.files:
		var dest: String = stage.path_join(f.path)
		DirAccess.make_dir_recursive_absolute(dest.get_base_dir())
		jobs.append({"url": f.url, "file": dest, "size": f.size, "md5": f.md5, "path": f.path})

	var total := maxi(int(plan.total_size), 1)
	var done := {"bytes": 0, "files": 0}
	var on_done := func(job: Dictionary, _res: Dictionary) -> void:
		done.bytes += int(job.size)
		done.files += 1
		progress.emit(0.9 * done.bytes / total, "Downloading %s — %s / %s (%d/%d files)" % [
			asset.name, String.humanize_size(done.bytes), String.humanize_size(total), done.files, jobs.size()])
	var failures: Array = await source.http.fetch_all(jobs, on_done)
	if not failures.is_empty():
		return {"ok": false, "error": "%d file(s) failed: %s" % [failures.size(), failures[0].error]}

	for job in jobs:
		if not job.md5.is_empty() and FileAccess.get_md5(job.file) != job.md5:
			return {"ok": false, "error": "checksum mismatch for %s" % job.path}

	progress.emit(0.92, "Copying into project…")
	var folder := Settings.download_root().path_join(source.get_id()).path_join(asset.id)
	for job in jobs:
		var target := ProjectSettings.globalize_path(folder.path_join(job.path))
		DirAccess.make_dir_recursive_absolute(target.get_base_dir())
		var err := DirAccess.copy_absolute(job.file, target)
		if err != OK:
			return {"ok": false, "error": "could not write %s (%s)" % [target, error_string(err)]}
	_remove_tree(stage)

	progress.emit(0.96, "Importing…")
	var efs := EditorInterface.get_resource_filesystem()
	efs.scan()
	# The scan finds the files; importing happens after it. Wait until every
	# importable file has its .import sidecar (written when its import finishes)
	# so post_import can load them. Poll on a timer (process_frame can stall while
	# the editor is unfocused), and never wait more than ~2 minutes.
	var pending: Array = []
	for job in jobs:
		if job.path.get_extension().to_lower() in IMPORTABLE:
			pending.append(ProjectSettings.globalize_path(folder.path_join(job.path)) + ".import")
	var tree := Engine.get_main_loop() as SceneTree
	for i in 480:
		if not efs.is_scanning() and pending.all(func(p): return FileAccess.file_exists(p)):
			break
		await tree.create_timer(0.25).timeout
	await tree.create_timer(0.5).timeout

	progress.emit(0.98, "Creating resources…")
	var post: Dictionary = await source.post_import(asset, plan, folder)
	if not post.ok:
		return post
	Credits.record(asset, source.get_display_name(), plan.resolution, folder, post.main_file)
	progress.emit(1.0, "Downloaded %s (%s)" % [asset.name, plan.resolution.to_upper()])
	return {"ok": true, "folder": folder, "main_file": post.main_file, "resolution": plan.resolution}


static func _remove_tree(path: String) -> void:
	for dir in DirAccess.get_directories_at(path):
		_remove_tree(path.path_join(dir))
	for file in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(file))
	DirAccess.remove_absolute(path)

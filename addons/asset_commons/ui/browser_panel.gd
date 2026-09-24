@tool
extends VBoxContainer
## The Asset Commons main-screen panel: header + filters, thumbnail grid, detail pane.
## UI is built in code so the addon has no .tscn to keep in sync.

const Settings = preload("../core/settings.gd")
const HttpFetcher = preload("../core/http_fetcher.gd")
const Downloader = preload("../core/downloader.gd")
const Credits = preload("../core/credits.gd")
const Terrain3DPrep = preload("../core/terrain3d_prep.gd")

## Register new providers here (each extends sources/asset_source.gd).
const SOURCES := [
	preload("../sources/polyhaven_source.gd"),
]

## Emitted after each queued download finishes (ok or not). Used by the MCP tools.
signal download_finished(asset_id: String, resolution: String, result: Dictionary)

const SORTS := ["Most popular", "Newest", "Name"]
const THUMB_WORKERS := 6
const MENU_WEBSITE := 1000  # context-menu id; resolution entries use their index

var _http: Node
var _sources: Array = []
var _source: RefCounted
var _downloader := Downloader.new()
var _prep := Terrain3DPrep.new()
var _prepping := false
var _download_queue: Array = []  # [{asset, resolution}], processed one at a time

var _assets: Array = []          # all assets in the current category
var _thumbs := {}                # asset id -> Texture2D
var _selected: Dictionary = {}
var _load_generation := 0
var _thumb_queue: Array = []
var _menu_asset: Dictionary = {}  # asset the context menu was opened on

# Widgets
var _credit_link: LinkButton
var _source_pick: OptionButton
var _type_pick: OptionButton
var _category_pick: OptionButton
var _search: LineEdit
var _sort_pick: OptionButton
var _refresh_btn: Button
var _grid: ItemList
var _grid_menu: PopupMenu
var _count_label: Label
var _detail_root: Control
var _detail_empty: Label
var _d_thumb: TextureRect
var _d_name: Label
var _d_authors: Label
var _d_stats: GridContainer
var _d_tags: HFlowContainer
var _d_desc: Label
var _d_link: LinkButton
var _res_pick: OptionButton
var _size_label: Label
var _installed_label: Label
var _download_btn: Button
var _terrain_btn: Button
var _status: Label
var _progress: ProgressBar
var _dl_label: Label  # download messages; separate so list loads can't overwrite them


func _ready() -> void:
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	_http = HttpFetcher.new()
	_http.user_agent = Settings.user_agent()
	add_child(_http)
	for script in SOURCES:
		var src: RefCounted = script.new()
		src.setup(_http)
		_sources.append(src)
	_downloader.progress.connect(_on_download_progress)
	_prep.progress.connect(_on_download_progress)
	_build_ui()
	_select_source(0)


# --- UI construction --------------------------------------------------------

func _build_ui() -> void:
	var s := EditorInterface.get_editor_scale()

	# Header: source picker + credit
	var header := HBoxContainer.new()
	add_child(header)
	_source_pick = OptionButton.new()
	_source_pick.tooltip_text = "Asset source"
	_source_pick.item_selected.connect(_select_source)
	for src in _sources:
		_source_pick.add_item(src.get_display_name())
	header.add_child(_source_pick)
	header.add_child(_spacer())
	_credit_link = LinkButton.new()
	_credit_link.underline = LinkButton.UNDERLINE_MODE_ON_HOVER
	header.add_child(_credit_link)

	# Filter row
	var filters := HBoxContainer.new()
	add_child(filters)
	_type_pick = OptionButton.new()
	_type_pick.tooltip_text = "Asset type"
	_type_pick.item_selected.connect(_on_type_selected)
	filters.add_child(_type_pick)
	_category_pick = OptionButton.new()
	_category_pick.tooltip_text = "Category"
	_category_pick.item_selected.connect(func(_i): _load_assets(false))
	# Long category lists: cap the popup height and let it scroll.
	_category_pick.get_popup().max_size = Vector2i(int(4096 * s), int(260 * s))
	filters.add_child(_category_pick)
	_search = LineEdit.new()
	_search.placeholder_text = "Search name or tag…"
	_search.clear_button_enabled = true
	_search.right_icon = get_theme_icon("Search", "EditorIcons")
	_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search.text_changed.connect(func(_t): _apply_filter())
	filters.add_child(_search)
	_sort_pick = OptionButton.new()
	for label in SORTS:
		_sort_pick.add_item(label)
	_sort_pick.tooltip_text = "Sort"
	_sort_pick.item_selected.connect(func(_i): _apply_filter())
	filters.add_child(_sort_pick)
	_refresh_btn = Button.new()
	_refresh_btn.icon = get_theme_icon("Reload", "EditorIcons")
	_refresh_btn.flat = true
	_refresh_btn.tooltip_text = "Re-download the asset list (ignores the cache)"
	_refresh_btn.pressed.connect(func():
		await _load_categories(true)
		_load_assets(true))
	filters.add_child(_refresh_btn)

	# Body: grid | details
	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(split)

	var grid_box := VBoxContainer.new()
	grid_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid_box.size_flags_stretch_ratio = 2.5
	split.add_child(grid_box)
	_grid = ItemList.new()
	_grid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_grid.custom_minimum_size = Vector2(200, 150) * s
	_grid.icon_mode = ItemList.ICON_MODE_TOP
	_grid.max_columns = 0
	_grid.same_column_width = true
	_grid.fixed_icon_size = Vector2i(int(128 * s), int(128 * s))
	_grid.fixed_column_width = int(150 * s)
	_grid.max_text_lines = 2
	_grid.allow_rmb_select = true
	_grid.item_selected.connect(_on_item_selected)
	_grid.item_activated.connect(_on_item_activated)
	_grid.item_clicked.connect(_on_item_clicked)
	grid_box.add_child(_grid)
	_grid_menu = PopupMenu.new()
	_grid_menu.id_pressed.connect(_on_grid_menu)
	add_child(_grid_menu)
	_count_label = Label.new()
	_count_label.add_theme_color_override("font_color", get_theme_color("font_disabled_color", "Editor"))
	grid_box.add_child(_count_label)

	var detail_scroll := ScrollContainer.new()
	detail_scroll.custom_minimum_size.x = 380 * s
	detail_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	split.add_child(detail_scroll)
	var detail_holder := VBoxContainer.new()
	detail_holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail_scroll.add_child(detail_holder)
	_detail_empty = Label.new()
	_detail_empty.text = "Select an asset to see details.\nDouble-click to download; right-click for more options."
	_detail_empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_detail_empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	detail_holder.add_child(_detail_empty)
	_detail_root = VBoxContainer.new()
	_detail_root.visible = false
	detail_holder.add_child(_detail_root)
	_build_detail(s)

	# Status bar
	var status_row := HBoxContainer.new()
	add_child(status_row)
	_status = Label.new()
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	status_row.add_child(_status)
	_dl_label = Label.new()
	_dl_label.visible = false
	status_row.add_child(_dl_label)
	_progress = ProgressBar.new()
	_progress.custom_minimum_size.x = 200 * s
	_progress.max_value = 1.0
	_progress.visible = false
	status_row.add_child(_progress)


func _build_detail(s: float) -> void:
	_d_thumb = TextureRect.new()
	_d_thumb.custom_minimum_size = Vector2(0, 200) * s
	_d_thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_d_thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_detail_root.add_child(_d_thumb)

	_d_name = Label.new()
	_d_name.add_theme_font_override("font", get_theme_font("bold", "EditorFonts"))
	_d_name.add_theme_font_size_override("font_size", int(get_theme_font_size("main_size", "EditorFonts") * 1.3))
	_d_name.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_detail_root.add_child(_d_name)
	_d_authors = Label.new()
	_d_authors.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_d_authors.add_theme_color_override("font_color", get_theme_color("font_disabled_color", "Editor"))
	_detail_root.add_child(_d_authors)

	_d_stats = GridContainer.new()
	_d_stats.columns = 2
	_d_stats.add_theme_constant_override("h_separation", int(12 * s))
	_detail_root.add_child(_d_stats)

	_detail_root.add_child(HSeparator.new())
	var res_row := HBoxContainer.new()
	_detail_root.add_child(res_row)
	var res_label := Label.new()
	res_label.text = "Resolution"
	res_row.add_child(res_label)
	_res_pick = OptionButton.new()
	_res_pick.item_selected.connect(func(_i): _update_download_size())
	res_row.add_child(_res_pick)
	_size_label = Label.new()
	_size_label.add_theme_color_override("font_color", get_theme_color("font_disabled_color", "Editor"))
	res_row.add_child(_size_label)

	_installed_label = Label.new()
	_installed_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_installed_label.add_theme_color_override("font_color", get_theme_color("success_color", "Editor"))
	_detail_root.add_child(_installed_label)

	_download_btn = Button.new()
	_download_btn.text = "Download"
	_download_btn.icon = get_theme_icon("Load", "EditorIcons")
	_download_btn.pressed.connect(_on_download_pressed)
	_detail_root.add_child(_download_btn)
	_terrain_btn = Button.new()
	_terrain_btn.text = "Prep for Terrain3D"
	_terrain_btn.pressed.connect(func(): prep_for_terrain3d(_selected))
	_detail_root.add_child(_terrain_btn)

	_detail_root.add_child(HSeparator.new())
	var tags_title := Label.new()
	tags_title.text = "Tags"
	tags_title.add_theme_color_override("font_color", get_theme_color("font_disabled_color", "Editor"))
	_detail_root.add_child(tags_title)
	_d_tags = HFlowContainer.new()
	_detail_root.add_child(_d_tags)

	_d_desc = Label.new()
	_d_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_detail_root.add_child(_d_desc)
	_d_link = LinkButton.new()
	_d_link.text = "View on website"
	_detail_root.add_child(_d_link)


static func _spacer() -> Control:
	var c := Control.new()
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return c


# --- Data flow ----------------------------------------------------------------

func _select_source(index: int) -> void:
	_source = _sources[index]
	var credit: Dictionary = _source.get_credit()
	_credit_link.text = credit.text
	_credit_link.uri = credit.url
	_res_pick.clear()
	for r in _source.get_resolutions():
		_res_pick.add_item(r.to_upper())
		_res_pick.set_item_metadata(_res_pick.item_count - 1, r)
	_res_pick.select(mini(1, _res_pick.item_count - 1))  # default 2K
	_type_pick.clear()
	var remembered: String = _settings().get_project_metadata("asset_commons", "type_" + _source.get_id(), "")
	for t in _source.get_asset_types():
		_type_pick.add_item(t.label)
		_type_pick.set_item_metadata(_type_pick.item_count - 1, t.id)
		if t.id == remembered:
			_type_pick.select(_type_pick.item_count - 1)
	await _load_categories(false)
	_load_assets(false)


func _on_type_selected(_index: int) -> void:
	_settings().set_project_metadata("asset_commons", "type_" + _source.get_id(), _type_id())
	_selected = {}
	_detail_root.visible = false
	_detail_empty.visible = true
	await _load_categories(false)
	_load_assets(false)


func _type_id() -> String:
	return _type_pick.get_item_metadata(_type_pick.selected) if _type_pick.item_count > 0 else ""


func _category_key() -> String:
	return "category_%s_%s" % [_source.get_id(), _type_id()]


func _load_categories(force_refresh: bool) -> void:
	_category_pick.clear()
	_category_pick.disabled = true
	var categories: Array = await _source.fetch_categories(_type_id(), force_refresh)
	_category_pick.clear()
	var remembered: String = _settings().get_project_metadata("asset_commons", _category_key(), "all")
	for c in categories:
		if c.has("separator"):
			_category_pick.add_separator(c.separator)
			continue
		_category_pick.add_item(c.label)
		var i := _category_pick.item_count - 1
		_category_pick.set_item_metadata(i, c.id)
		if c.id == remembered:
			_category_pick.select(i)
	_category_pick.disabled = false


static func _settings() -> EditorSettings:
	return EditorInterface.get_editor_settings()


func _load_assets(force_refresh: bool) -> void:
	_load_generation += 1
	var gen := _load_generation
	var category: String = _category_pick.get_item_metadata(_category_pick.selected)
	# Remember the last category per project (stored in .godot/, not project.godot).
	_settings().set_project_metadata("asset_commons", _category_key(), category)
	_set_status("Loading %s…" % _category_pick.get_item_text(_category_pick.selected))
	_refresh_btn.disabled = true
	var res: Dictionary = await _source.fetch_assets(_type_id(), category, force_refresh)
	if gen != _load_generation:
		return
	_refresh_btn.disabled = false
	if not res.ok:
		_assets = []
		_set_status("Could not load assets: %s" % res.error)
	else:
		_assets = res.assets
		_set_status("Offline — showing cached list (%s)" % res.error if res.get("stale", false) else "")
	_apply_filter()
	_load_thumbnails(gen)


## Loads missing thumbnails in grid order with a few workers; they stop as soon
## as the list is reloaded (new category/type), so stale requests don't pile up.
func _load_thumbnails(gen: int) -> void:
	_thumb_queue.clear()
	for i in _grid.item_count:
		var asset: Dictionary = _grid.get_item_metadata(i)
		if not _thumbs.has(asset.id):
			_thumb_queue.append(asset)
	for w in THUMB_WORKERS:
		_thumb_worker(gen)


func _thumb_worker(gen: int) -> void:
	while gen == _load_generation and not _thumb_queue.is_empty():
		var asset: Dictionary = _thumb_queue.pop_front()
		if not _thumbs.has(asset.id):
			await _load_thumbnail(asset, gen)


func _load_thumbnail(asset: Dictionary, gen: int) -> void:
	var tex: Texture2D = await _source.fetch_thumbnail(asset)
	if tex == null or not is_instance_valid(_grid):
		return
	_thumbs[asset.id] = tex
	if gen != _load_generation:
		return
	for i in _grid.item_count:
		if _grid.get_item_metadata(i).id == asset.id:
			_grid.set_item_icon(i, tex)
			break
	if _selected.get("id") == asset.id:
		_d_thumb.texture = tex


func _apply_filter() -> void:
	var words := _search.text.to_lower().split(" ", false)
	var shown := []
	for asset in _assets:
		var haystack: String = (asset.name + " " + asset.id + " " + " ".join(asset.tags)).to_lower()
		var ok := true
		for w in words:
			if not haystack.contains(w):
				ok = false
				break
		if ok:
			shown.append(asset)
	match _sort_pick.selected:
		0: shown.sort_custom(func(a, b): return a.download_count > b.download_count)
		1: shown.sort_custom(func(a, b): return a.date_published > b.date_published)
		2: shown.sort_custom(func(a, b): return a.name.naturalnocasecmp_to(b.name) < 0)

	_grid.clear()
	var placeholder := get_theme_icon("MeshInstance3D", "EditorIcons")
	for asset in shown:
		var i := _grid.add_item(asset.name, _thumbs.get(asset.id, placeholder))
		_grid.set_item_metadata(i, asset)
		var tris := "%s tris · " % _fmt_int(asset.polycount) if asset.polycount >= 0 else ""
		_grid.set_item_tooltip(i, "%s\n%s%s" % [asset.name, tris, ", ".join(asset.tags.slice(0, 6))])
		if asset.id == _selected.get("id"):
			_grid.select(i)
	_count_label.text = "%d of %d assets · double-click to download, right-click for options" % [shown.size(), _assets.size()]


func _on_item_selected(index: int) -> void:
	_show_detail(_grid.get_item_metadata(index))


## Double-click: download at the resolution chosen in the detail pane.
func _on_item_activated(index: int) -> void:
	_enqueue_download(_grid.get_item_metadata(index), _res_pick.get_item_metadata(_res_pick.selected))


func _on_item_clicked(index: int, at_position: Vector2, mouse_button: int) -> void:
	if mouse_button != MOUSE_BUTTON_RIGHT:
		return
	_menu_asset = _grid.get_item_metadata(index)
	_show_detail(_menu_asset)
	_grid_menu.clear()
	for i in _res_pick.item_count:
		_grid_menu.add_item("Download %s" % _res_pick.get_item_text(i), i)
	_grid_menu.add_separator()
	_grid_menu.add_item("View on website", MENU_WEBSITE)
	_grid_menu.position = Vector2i(_grid.get_screen_position() + at_position)
	_grid_menu.reset_size()
	_grid_menu.popup()


func _on_grid_menu(id: int) -> void:
	if _menu_asset.is_empty():
		return
	if id == MENU_WEBSITE:
		OS.shell_open(_menu_asset.page_url)
	else:
		_enqueue_download(_menu_asset, _res_pick.get_item_metadata(id))


func _show_detail(asset: Dictionary) -> void:
	_selected = asset
	_detail_empty.visible = false
	_detail_root.visible = true
	_d_thumb.texture = _thumbs.get(asset.id)
	_d_name.text = asset.name
	var authors := PackedStringArray()
	for a in asset.authors:
		authors.append("%s (%s)" % [a, asset.authors[a]])
	_d_authors.text = "by " + ", ".join(authors) if not authors.is_empty() else ""

	for c in _d_stats.get_children():
		c.queue_free()
	var mr: Vector2i = asset.max_resolution
	if asset.polycount >= 0:
		_add_stat("Polycount", "%s tris" % _fmt_int(asset.polycount))
	_add_stat("Max resolution", "%d×%d (%dK)" % [mr.x, mr.y, mr.x / 1024] if mr.x > 0 else "—")
	for row in asset.get("extra_stats", []):
		_add_stat(row[0], row[1])
	_add_stat("License", asset.license)
	_add_stat("Downloads", _fmt_int(asset.download_count))

	for c in _d_tags.get_children():
		c.queue_free()
	for tag in asset.tags:
		var b := Button.new()
		b.text = tag
		b.focus_mode = Control.FOCUS_NONE
		b.add_theme_font_size_override("font_size", int(get_theme_font_size("main_size", "EditorFonts") * 0.85))
		b.tooltip_text = "Search for \"%s\"" % tag
		b.pressed.connect(func():
			_search.text = tag
			_apply_filter())
		_d_tags.add_child(b)

	_terrain_btn.visible = asset.type == "models" and Terrain3DPrep.terrain3d_available()
	_d_desc.text = asset.description
	_d_link.uri = asset.page_url
	_update_installed_label()
	_update_download_size()


func _add_stat(label: String, value: String) -> void:
	var l := Label.new()
	l.text = label
	l.add_theme_color_override("font_color", get_theme_color("font_disabled_color", "Editor"))
	_d_stats.add_child(l)
	var v := Label.new()
	v.text = value
	_d_stats.add_child(v)


func _update_installed_label() -> void:
	var entry := Credits.find(_selected.source, _selected.id)
	_terrain_btn.disabled = entry.is_empty() or _prepping
	_terrain_btn.tooltip_text = ("Download the model first." if entry.is_empty() else
		"Split into variants, merge meshes, bake transforms, origin at base, build LODs, and add them as Terrain3D mesh assets.")
	if entry.is_empty():
		_installed_label.text = ""
		_installed_label.visible = false
	else:
		var res := PackedStringArray()
		for r in entry.resolutions:
			res.append(str(r).to_upper())
		_installed_label.text = "✓ In project (%s): %s" % [", ".join(res), entry.folder]
		var t3d: Dictionary = entry.get("terrain3d", {})
		if not t3d.is_empty():
			_installed_label.text += "\n✓ Terrain3D: %d variant(s) in %s" % [t3d.variants.size(), t3d.out_dir]
		_installed_label.visible = true


func _update_download_size() -> void:
	if _selected.is_empty():
		return
	var asset := _selected
	var res: String = _res_pick.get_item_metadata(_res_pick.selected)
	_size_label.text = "…"
	var plan: Dictionary = await _source.fetch_download_plan(asset, res)
	if _selected != asset or _res_pick.get_item_metadata(_res_pick.selected) != res:
		return
	if not plan.ok:
		_size_label.text = "(unavailable)"
	elif plan.resolution != res:
		_size_label.text = "%s — only %s available" % [String.humanize_size(plan.total_size), plan.resolution.to_upper()]
	else:
		_size_label.text = String.humanize_size(plan.total_size)


# --- Public API (used by mcp/commons_tools.gd) -------------------------------------

func get_source() -> RefCounted:
	return _source


## Finds an asset by id in the cached "all" lists. `type_id` narrows the search.
func find_asset(asset_id: String, type_id := "") -> Dictionary:
	for t in _source.get_asset_types():
		if not type_id.is_empty() and t.id != type_id:
			continue
		var res: Dictionary = await _source.fetch_assets(t.id, "all")
		for a in res.get("assets", []):
			if a.id == asset_id:
				return a
	return {}


## Queues a download exactly like the Download button. Returns false if it
## was already queued.
func enqueue_download(asset: Dictionary, resolution: String) -> bool:
	for job in _download_queue:
		if job.asset.id == asset.id and job.resolution == resolution:
			return false
	_enqueue_download(asset, resolution)
	return true


## Prepares a downloaded model for Terrain3D and registers it on the open
## scene's Terrain3D node (if any). Returns {ok, error, variants, registered}.
func prep_for_terrain3d(asset: Dictionary, budgets: Array = [], do_register := true) -> Dictionary:
	if _prepping:
		return {"ok": false, "error": "a Terrain3D prep is already running"}
	var entry := Credits.find(asset.source, asset.id)
	if entry.is_empty():
		return {"ok": false, "error": "download %s first" % asset.id}
	_prepping = true
	_terrain_btn.disabled = true
	_progress.visible = true
	_dl_label.visible = true
	var result: Dictionary = await _prep.prep(entry.main_file, budgets)
	if result.ok:
		var scenes: Array = result.variants.map(func(v): return v.scene)
		result.registered = Terrain3DPrep.register(scenes) if do_register else {"ok": false, "error": "skipped"}
		Credits.set_extra(asset.source, asset.id, "terrain3d", {"out_dir": result.out_dir, "variants": result.variants})
		var reg: Dictionary = result.registered
		_set_status("Terrain3D: %d variant(s) from %s%s" % [result.variants.size(), asset.name,
			" → mesh asset ids %s" % [reg.ids] if reg.ok else " (not registered: %s)" % reg.error])
	else:
		_set_status("Terrain3D prep failed: %s" % result.error)
	_prepping = false
	if _download_queue.is_empty():
		_progress.visible = false
		_dl_label.visible = false
	if _selected.get("id") == asset.id:
		_update_installed_label()
	return result


func queue_state() -> Array:
	var out := []
	for job in _download_queue:
		out.append({"id": job.asset.id, "resolution": job.resolution})
	return out


# --- Downloads ----------------------------------------------------------------

func _on_download_pressed() -> void:
	if not _selected.is_empty():
		_enqueue_download(_selected, _res_pick.get_item_metadata(_res_pick.selected))


func _enqueue_download(asset: Dictionary, resolution: String) -> void:
	for job in _download_queue:
		if job.asset.id == asset.id and job.resolution == resolution:
			return  # already queued
	_download_queue.append({"asset": asset, "resolution": resolution})
	_update_queue_label()
	if not _downloader.busy:
		_process_downloads()


func _process_downloads() -> void:
	_progress.visible = true
	_dl_label.visible = true
	while not _download_queue.is_empty():
		var job: Dictionary = _download_queue[0]
		_progress.value = 0.0
		_update_queue_label()
		var result: Dictionary = await _downloader.download(_source, job.asset, job.resolution)
		_download_queue.pop_front()
		download_finished.emit(job.asset.id, job.resolution, result)
		if result.ok:
			_set_status("Downloaded %s → %s" % [job.asset.name, result.main_file])
			print("[Asset Commons] Downloaded %s → %s" % [job.asset.name, result.main_file])
			if _download_queue.is_empty():
				EditorInterface.get_file_system_dock().navigate_to_path(result.main_file)
		else:
			_set_status("Download failed: %s" % result.error)
			push_warning("[Asset Commons] Download of %s failed: %s" % [job.asset.id, result.error])
		if _selected.get("id") == job.asset.id:
			_update_installed_label()
	_progress.visible = false
	_dl_label.visible = false


func _update_queue_label() -> void:
	if _download_queue.is_empty():
		return
	var waiting := _download_queue.size() - 1
	_dl_label.text = "Starting %s…%s" % [_download_queue[0].asset.name, " (+%d queued)" % waiting if waiting > 0 else ""]


func _on_download_progress(fraction: float, message: String) -> void:
	_progress.value = fraction
	var waiting := _download_queue.size() - 1
	_dl_label.text = message + (" (+%d queued)" % waiting if waiting > 0 else "")


func _set_status(text: String) -> void:
	_status.text = text


static func _fmt_int(n: int) -> String:
	var s := str(absi(n))
	var out := ""
	while s.length() > 3:
		out = "," + s.right(3) + out
		s = s.left(s.length() - 3)
	return ("-" if n < 0 else "") + s + out

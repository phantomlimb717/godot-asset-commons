@tool
extends RefCounted
## Base class for an asset provider. To add one (e.g. ambientCG): extend this,
## override the "Provider API" methods, and add it to SOURCES in ui/browser_panel.gd.
##
## Assets are plain Dictionaries with these normalized keys:
##   id, name, source, type, description, page_url, thumbnail_url, thumbnail_key,
##   categories (Array), tags (Array), authors (Dictionary name -> role),
##   polycount (int, -1 = n/a), max_resolution (Vector2i),
##   extra_stats (Array of [label, value] rows for the detail pane),
##   download_count (int), date_published (int unix), license (String)

const DiskCache = preload("../core/disk_cache.gd")

var http: Node  # core/http_fetcher.gd
var cache: DiskCache


func setup(http_fetcher: Node) -> void:
	http = http_fetcher
	cache = DiskCache.new(get_id())


# --- Provider API -----------------------------------------------------------

func get_id() -> String:
	return "base"


func get_display_name() -> String:
	return "Base"


## {text, url} shown in the dock header.
func get_credit() -> Dictionary:
	return {"text": "", "url": ""}


## [{id, label}] — e.g. models / textures / HDRIs.
func get_asset_types() -> Array:
	return []


## Returns [{id, label}] in display order. An entry {separator: "Heading"}
## starts a new group. "all" is the conventional id for "no category filter".
func fetch_categories(_type_id: String, _force_refresh := false) -> Array:
	return []


## Labels shown in the resolution picker, e.g. ["1k", "2k", "4k"].
func get_resolutions() -> PackedStringArray:
	return PackedStringArray()


## Returns {ok, assets: Array[Dictionary], error, stale: bool}.
func fetch_assets(_type_id: String, _category_id: String, _force_refresh := false) -> Dictionary:
	return {"ok": false, "assets": [], "error": "not implemented"}


## Returns {ok, error, main_file, total_size, resolution,
##          files: [{url, path (relative to the asset folder), size, md5}]}.
func fetch_download_plan(_asset: Dictionary, _resolution: String) -> Dictionary:
	return {"ok": false, "error": "not implemented"}


## Runs after the files are imported, e.g. to build a material or sky resource
## from the downloaded textures. Returns {ok, error, main_file (res:// path)}.
func post_import(_asset: Dictionary, plan: Dictionary, folder: String) -> Dictionary:
	return {"ok": true, "main_file": folder.path_join(plan.main_file)}


# --- Shared helpers ---------------------------------------------------------

## Cached thumbnail download + decode. Returns null on failure.
func fetch_thumbnail(asset: Dictionary) -> Texture2D:
	var key := "thumb_%s" % asset.get("thumbnail_key", asset.id)
	var bytes: PackedByteArray
	if cache.has(key):
		bytes = cache.read_bytes(key)
	else:
		var res: Dictionary = await http.fetch(asset.thumbnail_url, "", "background")
		if not res.ok:
			return null
		bytes = res.body
		cache.write_bytes(key, bytes)
	var img := decode_image(bytes)
	return ImageTexture.create_from_image(img) if img else null


static func decode_image(bytes: PackedByteArray) -> Image:
	if bytes.size() < 12:
		return null
	var img := Image.new()
	var err := ERR_FILE_UNRECOGNIZED
	if bytes[0] == 0x89 and bytes[1] == 0x50:
		err = img.load_png_from_buffer(bytes)
	elif bytes[0] == 0xFF and bytes[1] == 0xD8:
		err = img.load_jpg_from_buffer(bytes)
	elif bytes.slice(8, 12).get_string_from_ascii() == "WEBP":
		err = img.load_webp_from_buffer(bytes)
	return img if err == OK else null

@tool
extends EditorPlugin
## Adds an "Asset Commons" main-screen tab (next to 2D / 3D / Script / Asset Store),
## and, when the Godot AI addon is installed, MCP tools for AI agents.

const Settings = preload("core/settings.gd")
const BrowserPanel = preload("ui/browser_panel.gd")
const CommonsTools = preload("mcp/commons_tools.gd")

## Godot AI is optional: reached by path so this addon never hard-depends on it.
const MCP_REGISTRY := "res://addons/godot_ai/custom_tools/mcp_tool_registry.gd"
const MCP_SPEC := "res://addons/godot_ai/custom_tools/mcp_custom_tool_spec.gd"

var _panel: Control
var _registry: Object  # McpToolRegistry our tools are registered with
var _registry_watch: Timer


func _enter_tree() -> void:
	Settings.register()
	_panel = BrowserPanel.new()
	EditorInterface.get_editor_main_screen().add_child(_panel)
	_make_visible(false)
	CommonsTools.panel = _panel
	# Godot AI creates a new registry whenever it (re)loads, possibly after us.
	# A light poll catches both cases and re-registers our tools.
	if ResourceLoader.exists(MCP_REGISTRY):
		_registry_watch = Timer.new()
		_registry_watch.wait_time = 2.0
		_registry_watch.timeout.connect(_check_registry)
		add_child(_registry_watch)
		_registry_watch.start()
		_check_registry.call_deferred()


func _exit_tree() -> void:
	_unregister_mcp_tools()
	CommonsTools.panel = null
	if _panel:
		_panel.queue_free()
		_panel = null


func _has_main_screen() -> bool:
	return true


func _make_visible(visible: bool) -> void:
	if _panel:
		_panel.visible = visible


func _get_plugin_name() -> String:
	return "Asset Commons"


func _get_plugin_icon() -> Texture2D:
	return EditorInterface.get_editor_theme().get_icon("Environment", "EditorIcons")


# --- Optional Godot AI (MCP) integration ------------------------------------------

func _check_registry() -> void:
	var current: Object = load(MCP_REGISTRY).get_instance()
	if current != null and current != _registry:
		_registry = current
		_register_mcp_tools()


func _register_mcp_tools() -> void:
	var spec_script: GDScript = load(MCP_SPEC)
	var handler_path: String = get_script().resource_path.get_base_dir().path_join("mcp/commons_tools.gd")
	for def in CommonsTools.specs():
		var spec: Object = spec_script.new()
		spec.name = def.name
		spec.description = def.description
		spec.params_schema = def.schema
		spec.script_path = handler_path
		spec.method = def.method
		spec.source_path = CommonsTools.SOURCE_PATH
		spec.source = "Asset Commons"
		spec.promoted = true
		spec.deferred = true
		spec.timeout_ms = def.get("timeout_ms", 30000)
		spec.requires_writable = def.get("writable", false)
		_registry.register(spec)


func _unregister_mcp_tools() -> void:
	if _registry_watch:
		_registry_watch.queue_free()
		_registry_watch = null
	var registry: Object = load(MCP_REGISTRY).get_instance() if ResourceLoader.exists(MCP_REGISTRY) else null
	if registry != null:
		registry.unregister_source(CommonsTools.SOURCE_PATH)
	_registry = null

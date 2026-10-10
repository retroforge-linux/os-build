extends RefCounted
## Settings > Display: two rows the QForge plugin adds under OGUI's own Scale slider.
##
##  - Game resolution: the size of gamescope's GAME display (the second Xwayland, where OGUI
##    launches games and Steam). Applied live through GAMESCOPE_XWAYLAND_MODE_CONTROL on the
##    shell's root window -- running games see a resolution change, new launches get the new
##    size; the panel plane scales it to the output. "Default" is the board profile's size
##    (QFORGE_GAMESCOPE_NESTED_W/H, exported by qforge-session), "Native" the output size.
##  - Reduced UI resolution: the shell itself renders at its 1280x800 design size and is scaled
##    up (Godot viewport stretch) instead of drawing every frame at the output size. Default from
##    the board profile (QFORGE_UI_VIEWPORT_RENDER).
##
## Both are stored in OGUI's settings (section "qforge"); absent = the profile default.

const SECTION := "qforge"
const RESOLUTIONS := [
	["default", "Default (this device)"],
	["native", "Native"],
	["1600x900", "1600 x 900"],
	["1280x720", "1280 x 720"],
	["960x540", "960 x 540"],
	["854x480", "854 x 480"],
]

var settings := load("res://core/global/settings_manager.tres") as SettingsManager
var dropdown_scene := load("res://core/ui/components/dropdown.tscn") as PackedScene
var toggle_scene := load("res://core/ui/components/toggle.tscn") as PackedScene
var logger := Log.get_logger("QForgeDisplay", Log.LEVEL.INFO)
var tree: SceneTree
var _resolution: Control  # OGUI Dropdown
var _reduced_ui: Control  # OGUI Toggle


## Apply the stored (or default) choices; call once at startup, menu or not.
func apply_all(scene_tree: SceneTree) -> void:
	tree = scene_tree
	apply_game_resolution(settings.get_value(SECTION, "game_resolution", "default") as String)
	apply_reduced_ui(reduced_ui_enabled())


## Add the two rows to Settings > Display. False when its layout is not the expected one.
func attach() -> bool:
	var menu: Node = tree.root.find_child("DisplaySettings", true, false)
	var box: Node = menu.get_node_or_null("VBoxContainer") if menu else null
	if not box:
		return false
	var after: Node = box.get_node_or_null("ScaleSlider")
	var index := after.get_index() + 1 if after else box.get_child_count()

	_resolution = dropdown_scene.instantiate()
	_resolution.name = "QForgeGameResolution"
	_resolution.title = "Game resolution"
	_resolution.description = "The screen size games and Steam render at; the display scales it to the panel. Lower is faster on this GPU."
	box.add_child(_resolution)
	box.move_child(_resolution, index)
	_resolution.clear()  # the dropdown scene ships a "None" placeholder item
	for r in RESOLUTIONS:
		_resolution.add_item(_label_for(r[0], r[1]))
	var current := settings.get_value(SECTION, "game_resolution", "default") as String
	_resolution.select(maxi(0, _keys().find(current)))
	_resolution.item_selected.connect(_on_resolution_selected)

	_reduced_ui = toggle_scene.instantiate()
	_reduced_ui.name = "QForgeReducedUI"
	_reduced_ui.text = "Reduced UI resolution"
	_reduced_ui.description = "Draw this interface at 1280x800 and scale it up. Smoother menus on a slower GPU, slightly softer text."
	box.add_child(_reduced_ui)
	box.move_child(_reduced_ui, index + 1)
	_reduced_ui.button_pressed = reduced_ui_enabled()
	_reduced_ui.toggled.connect(_on_reduced_ui_toggled)
	return true


func detach() -> void:
	for n in [_resolution, _reduced_ui]:
		if is_instance_valid(n):
			n.queue_free()


static func _keys() -> Array:
	return RESOLUTIONS.map(func(r): return r[0])


func _label_for(key: String, label: String) -> String:
	if key == "default":
		var s := default_size()
		return "%s, %d x %d" % [label, s.x, s.y]
	if key == "native":
		var n := native_size()
		return "%s, %d x %d" % [label, n.x, n.y]
	return label


## The output size gamescope gives the shell's own display.
func native_size() -> Vector2i:
	return DisplayServer.screen_get_size()


## The board profile's game-display size, or the output size when it sets none.
func default_size() -> Vector2i:
	var w := OS.get_environment("QFORGE_GAMESCOPE_NESTED_W")
	var h := OS.get_environment("QFORGE_GAMESCOPE_NESTED_H")
	if w.is_valid_int() and h.is_valid_int() and int(w) > 0 and int(h) > 0:
		return Vector2i(int(w), int(h))
	return native_size()


## "default", "native" or "WxH" -> a size.
func size_for(key: String) -> Vector2i:
	match key:
		"default":
			return default_size()
		"native":
			return native_size()
	var p := key.split("x")
	if p.size() == 2 and p[0].is_valid_int() and p[1].is_valid_int():
		return Vector2i(int(p[0]), int(p[1]))
	return default_size()


func apply_game_resolution(key: String) -> void:
	var s := size_for(key)
	# [xwayland server, width, height, allow super-resolution]; server 1 is the game display.
	var value := "1,%d,%d,0" % [s.x, s.y]
	var out := []
	var rc := OS.execute("xprop", ["-root", "-f", "GAMESCOPE_XWAYLAND_MODE_CONTROL", "32c", "-set", "GAMESCOPE_XWAYLAND_MODE_CONTROL", value], out, true)
	if rc != 0:
		logger.warn("could not set the game resolution (xprop exit %d): %s" % [rc, "".join(out)])
		return
	logger.info("game resolution %s -> %d x %d" % [key, s.x, s.y])


func reduced_ui_enabled() -> bool:
	var stored: Variant = settings.get_value(SECTION, "reduced_ui_resolution", null)
	if stored != null:
		return stored as bool
	return OS.get_environment("QFORGE_UI_VIEWPORT_RENDER") == "1"


func apply_reduced_ui(on: bool) -> void:
	var root := tree.root
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_VIEWPORT if on else Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	logger.info("UI renders at %s" % (str(root.content_scale_size) + ", scaled to " + str(root.size) if on else "the output size"))


func _on_resolution_selected(index: int) -> void:
	var key: String = RESOLUTIONS[index][0]
	settings.set_value(SECTION, "game_resolution", key)
	apply_game_resolution(key)


func _on_reduced_ui_toggled(pressed: bool) -> void:
	settings.set_value(SECTION, "reduced_ui_resolution", pressed)
	apply_reduced_ui(pressed)

extends RefCounted
## Settings > Display: two rows the QForge plugin adds under OGUI's own Scale slider.
##
##  - Game resolution: the size of gamescope's GAME display (the second Xwayland, where OGUI
##    launches games and Steam). Applied live through GAMESCOPE_XWAYLAND_MODE_CONTROL on the
##    shell's root window -- running games see a resolution change, new launches get the new
##    size; the panel plane scales it to the output. "Default" is the board profile's size
##    (QFORGE_GAMESCOPE_NESTED_W/H, exported by qforge-session), "Native" the output size.
##    The lower sizes are heights at the PANEL's aspect ratio ("720p" is 960 x 720 on the Air
##    Y's 4:3 panel, 1280 x 720 on a 16:9 one), so the game display is scaled to fill the
##    screen: a fixed 16:9 size on a 4:3 panel was letterboxed by gamescope, and a 4:3 game
##    inside it pillarboxed again (bars on all four sides). As ROCKNIX's fullscreen scale hint.
##  - Reduced UI resolution: the shell itself renders at its 1280x800 design size and is scaled
##    up (Godot viewport stretch) instead of drawing every frame at the output size. Default from
##    the board profile (QFORGE_UI_VIEWPORT_RENDER). While a game has the foreground the shell
##    always renders at the design size (set_backgrounded): it is only an overlay then, and goes
##    back to the chosen size the moment it is brought up over the game.
##
## Both are stored in OGUI's settings (section "qforge"); absent = the profile default.

const SECTION := "qforge"
const RESOLUTIONS := [
	["default", "Default (this device)"],
	["native", "Native"],
	["900p", "900p"],
	["720p", "720p"],
	["540p", "540p"],
	["480p", "480p"],
]

var settings := load("res://core/global/settings_manager.tres") as SettingsManager
var dropdown_scene := load("res://core/ui/components/dropdown.tscn") as PackedScene
var toggle_scene := load("res://core/ui/components/toggle.tscn") as PackedScene
var logger := Log.get_logger("QForgeDisplay", Log.LEVEL.INFO)
var tree: SceneTree
var _resolution: Control  # OGUI Dropdown
var _reduced_ui: Control  # OGUI Toggle
var _backgrounded := false  # a game has the foreground; the shell is only an overlay


## Apply the stored (or default) choices; call once at startup, menu or not.
func apply_all(scene_tree: SceneTree) -> void:
	tree = scene_tree
	apply_game_resolution(stored_resolution())
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
	_resolution.select(maxi(0, _keys().find(stored_resolution())))
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


## The stored choice. Sizes stored as "WxH" before the panel-aspect presets become their height
## preset ("1280x720" -> "720p"), so a 16:9 size no longer letterboxes on a 4:3 panel.
func stored_resolution() -> String:
	var key := settings.get_value(SECTION, "game_resolution", "default") as String
	var p := key.split("x")
	if p.size() == 2 and p[1].is_valid_int():
		key = p[1] + "p"
		settings.set_value(SECTION, "game_resolution", key)
	return key


func _label_for(key: String, label: String) -> String:
	if key == "default":
		var s := default_size()
		return "%s, %d x %d" % [label, s.x, s.y]
	if key == "native":
		var n := native_size()
		return "%s, %d x %d" % [label, n.x, n.y]
	var s := size_for(key)
	return "%s, %d x %d" % [label, s.x, s.y]


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
	var h := key.trim_suffix("p")
	if key.ends_with("p") and h.is_valid_int():
		return aspect_size(int(h))
	return default_size()


## `height` lines at the panel's aspect ratio (even width), never above the output size.
func aspect_size(height: int) -> Vector2i:
	var n := native_size()
	if n.y <= 0 or height >= n.y:
		return n
	var w := int(round(float(height) * n.x / n.y / 2.0)) * 2
	return Vector2i(w, height)


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


## A game took the foreground (true) or the shell was brought back up (false).
func set_backgrounded(on: bool) -> void:
	_backgrounded = on
	apply_reduced_ui(reduced_ui_enabled())


func apply_reduced_ui(on: bool) -> void:
	on = on or _backgrounded
	var root := tree.root
	var mode := Window.CONTENT_SCALE_MODE_VIEWPORT if on else Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	if root.content_scale_mode == mode:
		return
	root.content_scale_mode = mode
	logger.info("UI renders at %s" % (str(root.content_scale_size) + ", scaled to " + str(root.size) if on else "the output size"))


func _on_resolution_selected(index: int) -> void:
	var key: String = RESOLUTIONS[index][0]
	settings.set_value(SECTION, "game_resolution", key)
	apply_game_resolution(key)


func _on_reduced_ui_toggled(pressed: bool) -> void:
	settings.set_value(SECTION, "reduced_ui_resolution", pressed)
	apply_reduced_ui(pressed)

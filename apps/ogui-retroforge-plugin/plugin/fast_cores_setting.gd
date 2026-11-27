extends RefCounted
## Settings > General > "Pin to fast cores": how "Run on fast cores" (a game's choice on its RetroForge
## settings page, or an emulator's default in Apps) puts a game there. Off, the default: preferred, a
## uclamp.min on each of its threads, so they run on the fast cores and spill onto the slow ones only
## when every fast one is busy. On: pinned with taskset, never on a slow core, even when the fast ones
## are all busy. FAST_CORES=pin|prefer in ~/.config/retroforge/fast-cores.conf, which python/fastcores.py
## reads at each launch (retroforge-launch, retroforge-steam-direct and /usr/bin/steam, the store
## tool); a running game keeps how it started.

const GeneralBox := preload("general_box.gd")
const KEY := "FAST_CORES"

var notification_manager := load("res://core/global/notification_manager.tres")
var toggle_scene := load("res://core/ui/components/toggle.tscn") as PackedScene
var logger := Log.get_logger("RetroForgeFastCores", Log.LEVEL.INFO)
var tree: SceneTree
var _toggle: Control  # OGUI Toggle


func setup(scene_tree: SceneTree) -> RefCounted:
	tree = scene_tree
	return self


## ~/.config/retroforge/fast-cores.conf ($XDG_CONFIG_HOME when set), as python/fastcores.py finds it.
static func conf_path() -> String:
	var config := OS.get_environment("XDG_CONFIG_HOME")
	if config == "":
		config = OS.get_environment("HOME").path_join(".config")
	return config.path_join("retroforge").path_join("fast-cores.conf")


## Whether the conf's last FAST_CORES line says pin; anything else, or no file, is prefer.
static func pinned() -> bool:
	var file := FileAccess.open(conf_path(), FileAccess.READ)
	if not file:
		return false
	var value := ""
	for line in file.get_as_text().split("\n"):
		var parts := line.split("=", true, 1)
		if parts.size() == 2 and parts[0].strip_edges() == KEY:
			value = parts[1].strip_edges()
	return value == "pin"


## Add the toggle under Settings > General, after Pause game in menus. False when the layout differs.
func attach() -> bool:
	var menu: Node = tree.root.find_child("GeneralSettings", true, false)
	var box: Node = GeneralBox.find(menu)
	if not box:
		return false
	var after: Node = box.get_node_or_null("RetroForgePauseInMenus")
	_toggle = toggle_scene.instantiate()
	_toggle.name = "RetroForgeFastCores"
	_toggle.text = "Pin to fast cores"
	_toggle.description = "For games and emulators set to Run on fast cores: keep them on the fast CPU cores only. Off, they prefer the fast cores and use the slow ones too when all fast ones are busy."
	_toggle.separator_visible = false  # as the rows around it; read in _ready, so before add_child
	box.add_child(_toggle)
	if after:
		box.move_child(_toggle, after.get_index() + 1)
	_toggle.button_pressed = pinned()  # the setter does not emit toggled
	_toggle.toggled.connect(_on_toggled)
	return true


func detach() -> void:
	if is_instance_valid(_toggle):
		_toggle.queue_free()


## The Toggle only emits on the player's input. A failed save puts the toggle back and says so.
func _on_toggled(on: bool) -> void:
	var path := conf_path()
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file:
		file.store_string("# Settings > General > Pin to fast cores (python/fastcores.py)\n%s=%s\n" % [KEY, "pin" if on else "prefer"])
		file.close()
	if pinned() == on:
		logger.info("Run on fast cores: " + ("pinned" if on else "preferred"))
		return
	logger.warn("could not save " + path)
	notification_manager.show(Notification.new("Could not save Pin to fast cores"))
	if is_instance_valid(_toggle):
		_toggle.button_pressed = pinned()

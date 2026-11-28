extends RefCounted
## Settings > General > "Game crash dumps": off, the default, a game that crashes leaves no core file and
## is gone at once (systemd-coredump logs the crash); on, its core is kept for coredumpctl, which holds
## the crashed game's memory until it is written (41-46 s for Ghostrunner on the MANGMI Air X).
## GAME_CORE_DUMPS=on|off in ~/.config/retroforge/game-core-dumps.conf, which python/crash_dumps.py
## (retroforge-launch, the store tool) and /usr/bin/steam read at each launch; a running game keeps how
## it started.

const GeneralBox := preload("general_box.gd")
const KEY := "GAME_CORE_DUMPS"

var notification_manager := load("res://core/global/notification_manager.tres")
var toggle_scene := load("res://core/ui/components/toggle.tscn") as PackedScene
var logger := Log.get_logger("RetroForgeCrashDumps", Log.LEVEL.INFO)
var tree: SceneTree
var _toggle: Control  # OGUI Toggle


func setup(scene_tree: SceneTree) -> RefCounted:
	tree = scene_tree
	return self


## ~/.config/retroforge/game-core-dumps.conf ($XDG_CONFIG_HOME when set), as python/crash_dumps.py finds it.
static func conf_path() -> String:
	var config := OS.get_environment("XDG_CONFIG_HOME")
	if config == "":
		config = OS.get_environment("HOME").path_join(".config")
	return config.path_join("retroforge").path_join("game-core-dumps.conf")


## Whether the conf's last GAME_CORE_DUMPS line says on; anything else, or no file, is off.
static func enabled() -> bool:
	var file := FileAccess.open(conf_path(), FileAccess.READ)
	if not file:
		return false
	var value := ""
	for line in file.get_as_text().split("\n"):
		var parts := line.split("=", true, 1)
		if parts.size() == 2 and parts[0].strip_edges() == KEY:
			value = parts[1].strip_edges()
	return value == "on"


## Add the toggle under Settings > General, after Fast cores only. False when the layout differs.
func attach() -> bool:
	var menu: Node = tree.root.find_child("GeneralSettings", true, false)
	var box: Node = GeneralBox.find(menu)
	if not box:
		return false
	var after: Node = box.get_node_or_null("RetroForgeFastCores")
	_toggle = toggle_scene.instantiate()
	_toggle.name = "RetroForgeCrashDumps"
	_toggle.text = "Game crash dumps"
	_toggle.description = "For debugging. On: a game that crashes saves its memory to a file (coredumpctl), which can take up to a minute and space on the card. Off: it closes at once. For emulators, store games and Steam games."
	_toggle.separator_visible = false  # as the rows around it; read in _ready, so before add_child
	box.add_child(_toggle)
	if after:
		box.move_child(_toggle, after.get_index() + 1)
	_toggle.button_pressed = enabled()  # the setter does not emit toggled
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
		file.store_string("# Settings > General > Game crash dumps (python/crash_dumps.py)\n%s=%s\n" % [KEY, "on" if on else "off"])
		file.close()
	if enabled() == on:
		logger.info("Game crash dumps: " + ("on" if on else "off"))
		return
	logger.warn("could not save " + path)
	notification_manager.show(Notification.new("Could not save Game crash dumps"))
	if is_instance_valid(_toggle):
		_toggle.button_pressed = enabled()

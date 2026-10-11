extends RefCounted
## Settings > General > "Pause game in menus": the running game, emulator or app is frozen
## (SIGSTOP on its whole process tree, OGUI's RunningApp.suspend) while an OGUI menu covers it --
## the quick bar, the in-game menu, anything pushed over the in-game state -- and continued the
## moment it has the foreground again. Gamescope keeps showing its last frame under the menu; the
## game uses no CPU, GPU or audio meanwhile.
##
## A stopped process cannot act on SIGTERM, so "Exit game" would hang until it was continued:
## the app is continued synchronously (OS.execute) on app_stopped, which RunningApp.kill emits
## before it sends the signal. Steam apps are left alone: their tree holds the Steam client.
## Stored in OGUI's settings, section "qforge", key "pause_in_menus" (default on).

const SECTION := "qforge"
const KEY := "pause_in_menus"

var settings := load("res://core/global/settings_manager.tres") as SettingsManager
var launch_manager := load("res://core/global/launch_manager.tres") as LaunchManager
var in_game_state := load("res://assets/state/states/in_game.tres") as State
var toggle_scene := load("res://core/ui/components/toggle.tscn") as PackedScene
var logger := Log.get_logger("QForgePause", Log.LEVEL.INFO)
var tree: SceneTree
var _toggle: Control  # OGUI Toggle
var _paused: RunningApp


func setup(scene_tree: SceneTree) -> RefCounted:
	tree = scene_tree
	in_game_state.state_exited.connect(_on_in_game_exited)
	in_game_state.state_entered.connect(_on_in_game_entered)
	launch_manager.app_switched.connect(func(_from, _to): resume())
	return self


## Add the toggle under Settings > General's Animated Effects. False when the layout differs.
func attach() -> bool:
	var menu: Node = tree.root.find_child("GeneralSettings", true, false)
	var box: Node = menu.get_node_or_null("MarginContainer/VBoxContainer/VBoxContainer") if menu else null
	if not box:
		return false
	var after: Node = box.get_node_or_null("AnimatedEffectsToggle")
	_toggle = toggle_scene.instantiate()
	_toggle.name = "QForgePauseInMenus"
	_toggle.text = "Pause game in menus"
	_toggle.description = "Freeze the running game or emulator while a menu is open over it."
	box.add_child(_toggle)
	if after:
		box.move_child(_toggle, after.get_index() + 1)
	_toggle.button_pressed = enabled()
	_toggle.toggled.connect(func(on: bool): settings.set_value(SECTION, KEY, on))
	return true


func detach() -> void:
	resume()
	if is_instance_valid(_toggle):
		_toggle.queue_free()


func enabled() -> bool:
	return settings.get_value(SECTION, KEY, true) as bool


func _on_in_game_exited(_to: State) -> void:
	if not enabled() or _paused:
		return
	var app := launch_manager.get_current_app()
	if not app or app.state in [RunningApp.STATE.STOPPING, RunningApp.STATE.STOPPED] or app.is_steam_app():
		return
	_paused = app
	if not app.app_stopped.is_connected(_on_app_stopped):
		app.app_stopped.connect(_on_app_stopped.bind(app))
	app.suspend(true)
	logger.info("paused " + app.launch_item.name)


func _on_in_game_entered(_from: State) -> void:
	resume()


## Continue the paused app, if any. Synchronous: an exit right after must find it running.
func resume() -> void:
	if not _paused:
		return
	var app := _paused
	_paused = null
	var pids: Array = Reaper.pstree(app.pid)
	pids.push_front(app.pid)
	var args := PackedStringArray(["-CONT", "--"])
	for p in pids:
		args.append(str(p))
		args.append("-" + str(p))  # its process group, as suspend() stopped it
	OS.execute("kill", args)
	app.is_suspended = false
	logger.info("resumed " + app.launch_item.name)


func _on_app_stopped(app: RunningApp) -> void:
	if app == _paused:
		resume()

extends RefCounted
## Settings > General > "Pause game in menus": the running game, emulator or app is frozen
## (SIGSTOP on its whole process tree, OGUI's RunningApp.suspend) while an OGUI menu covers it --
## the quick bar, the in-game menu, anything pushed over the in-game state -- and continued the
## moment it has the foreground again. Gamescope keeps showing its last frame under the menu; the
## game uses no CPU, GPU or audio meanwhile.
##
## A stopped process cannot act on SIGTERM, so "Exit game" would hang until it was continued:
## the app is continued synchronously (OS.execute) on app_stopped, which RunningApp.kill emits
## before it sends the signal. A Steam game is frozen differently: OGUI's tree for it holds the
## Steam client (or a wrapper that waits on the kept one), so it is the game's own tree under
## Steam's reaper that stops, through `retroforge-steam-keep pause <appid>`, and Steam keeps
## running. That runs in the background (it reads /proc twice, ~0.3 s on the MANGMI Air X, too long
## to hold OGUI's frame), and so does its resume except before an exit; a pause and a resume started
## together end in the state asked for last.
## Stored in OGUI's settings, section "retroforge", key "pause_in_menus" (default on).
##
## The freeze is OGUI's own pause (RunningApp.suspend, is_suspended), so the running game card's
## Pause/Unpause entry, which toggles on is_suspended, sees it: the card only relabels itself on
## its own presses, so its label is set here ("Unpause" while frozen), or its first press looked
## like it did nothing. Unpause in the menu lets the game run behind it; closing the menu always
## goes back to a running game.
##
## The on-screen keyboard is the exception: it types into the game (KeyboardContext.TYPE.X11), so
## the game runs while the keyboard is the popup on top, and a keyboard opened over a menu resumes
## it. Frozen behind the keyboard, a game never saw the keys (Air X, 2026-10-28).

const GeneralBox := preload("general_box.gd")
const SteamApps := preload("steam_apps.gd")
const KEEP := "/usr/bin/retroforge-steam-keep"
const SECTION := "retroforge"
const RUNNING_GAME_CARD := "res://core/ui/card_ui/navigation/running_game_card.gd"
const KEY := "pause_in_menus"

var settings := load("res://core/global/settings_manager.tres") as SettingsManager
var launch_manager := load("res://core/global/launch_manager.tres") as LaunchManager
var in_game_state := load("res://assets/state/states/in_game.tres") as State
var osk_state := load("res://assets/state/states/osk.tres") as State
var global_state_machine := load("res://assets/state/state_machines/global_state_machine.tres") as StateMachine
var popup_state_machine := load("res://assets/state/state_machines/popup_state_machine.tres") as StateMachine
var toggle_scene := load("res://core/ui/components/toggle.tscn") as PackedScene
var logger := Log.get_logger("RetroForgePause", Log.LEVEL.INFO)
var tree: SceneTree
var _toggle: Control  # OGUI Toggle
var _paused: RunningApp
var _paused_steam := 0  # the Steam app id of _paused, when it is a Steam game frozen by keep


func setup(scene_tree: SceneTree) -> RefCounted:
	tree = scene_tree
	in_game_state.state_exited.connect(_on_in_game_exited)
	in_game_state.state_entered.connect(_on_in_game_entered)
	popup_state_machine.state_changed.connect(_on_popup_changed)
	launch_manager.app_switched.connect(func(_from, _to): resume())
	return self


## Add the toggle under Settings > General's Animated Effects. False when the layout differs.
func attach() -> bool:
	var menu: Node = tree.root.find_child("GeneralSettings", true, false)
	var box: Node = GeneralBox.find(menu)
	if not box:
		return false
	var after: Node = box.get_node_or_null("AnimatedEffectsToggle")
	_toggle = toggle_scene.instantiate()
	_toggle.name = "RetroForgePauseInMenus"
	_toggle.text = "Pause game in menus"
	_toggle.description = "Freeze the running game or emulator while a menu is open over it."
	_toggle.separator_visible = false  # read in _ready, so before add_child
	box.add_child(_toggle)
	if after:
		box.move_child(_toggle, after.get_index() + 1)
	_toggle.button_pressed = enabled()
	_toggle.toggled.connect(func(on: bool): settings.set_value(SECTION, KEY, on))
	return true


func detach() -> void:
	resume(true)
	if is_instance_valid(_toggle):
		_toggle.queue_free()


func enabled() -> bool:
	return settings.get_value(SECTION, KEY, true) as bool


func _on_in_game_exited(_to: State) -> void:
	if popup_state_machine.current_state() == osk_state:
		return
	_pause()


## The keyboard on top: the game runs. Another popup on top of the keyboard: frozen again.
func _on_popup_changed(_from: State, to: State) -> void:
	if to == osk_state:
		resume()
	elif to != null and _from == osk_state and global_state_machine.current_state() != in_game_state:
		_pause()


func _pause() -> void:
	if not enabled() or _paused:
		return
	var app := launch_manager.get_current_app()
	if not app or app.state in [RunningApp.STATE.STOPPING, RunningApp.STATE.STOPPED]:
		return
	if app.is_steam_app():
		var appid := SteamApps.appid_of(app.launch_item.args) if app.launch_item else 0
		if appid == 0:
			return
		_paused = app
		_paused_steam = appid
		if not app.app_stopped.is_connected(_on_app_stopped):
			app.app_stopped.connect(_on_app_stopped.bind(app))
		OS.create_process(KEEP, ["pause", str(appid)])
		logger.info("paused Steam app %d (%s)" % [appid, app.launch_item.name])
		return
	_paused = app
	if not app.app_stopped.is_connected(_on_app_stopped):
		app.app_stopped.connect(_on_app_stopped.bind(app))
	if not app.is_suspended:
		app.suspend(true)
	_sync_pause_label(app)
	logger.info("paused " + app.launch_item.name)


func _on_in_game_entered(_from: State) -> void:
	resume()


## Continue the paused app, if any. Synchronous: an exit right after must find it running. A Steam
## game is continued in the background unless `sync` (before an exit, or when the plugin unloads).
func resume(sync := false) -> void:
	if not _paused:
		return
	var app := _paused
	_paused = null
	if _paused_steam:
		var args := PackedStringArray(["resume", str(_paused_steam)])
		_paused_steam = 0
		if sync:
			OS.execute(KEEP, args)
		else:
			OS.create_process(KEEP, args)
		logger.info("resumed Steam app %s" % args[1])
		return
	var pids: Array = Reaper.pstree(app.pid)
	pids.push_front(app.pid)
	var args := PackedStringArray(["-CONT", "--"])
	for p in pids:
		args.append(str(p))
		args.append("-" + str(p))  # its process group, as suspend() stopped it
	OS.execute("kill", args)
	app.is_suspended = false
	_sync_pause_label(app)
	logger.info("resumed " + app.launch_item.name)


## Exit game: continue it first, also when it was paused from the menu's Pause entry outside a
## freeze of ours, so it can act on SIGTERM.
func _on_app_stopped(app: RunningApp) -> void:
	if app == _paused:
		resume(true)
	elif app.is_suspended:
		_paused = app
		_paused_steam = 0
		resume(true)


## The running game card of `app` labels its Pause entry by is_suspended, as its own press does.
func _sync_pause_label(app: RunningApp) -> void:
	for card in tree.root.find_children("*", "Container", true, false):
		var script := card.get_script() as Script
		if not script or script.resource_path != RUNNING_GAME_CARD or card.get("running_app") != app:
			continue
		var button = card.get("pause_button")
		if button:
			button.text = "Unpause" if app.is_suspended else "Pause"

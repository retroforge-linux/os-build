extends RefCounted
## Apps > Steam Client > "Steam: start games without Steam": the player's setting, kept by
## /usr/bin/retroforge-steam-direct (DIRECT_LAUNCH=on|off in ~/.config/retroforge/steam.conf), which
## /usr/bin/steam asks at every game launch. On: a game Steam has started on this device before starts
## the way Steam started it, without the Steam client and its ~1 GB (the Air X's Hades was killed in
## its first room with the client, and played without it). Its first launch, an x86 game, or any game
## while Steam's UI is open still go through Steam. With Steam kept running in the background
## (steam_keep.gd) the game still gets achievements, playtime, Steam Input and the cloud upload when
## it ends, but no cloud download before it; with it off, none of those, and a game that needs Steam
## closes. No overlay either way. Never set, it is on, on every board. The command decides all of
## that, so the toggle only shows what `retroforge-steam-direct status` says and runs `on` / `off`.

const GeneralBox := preload("general_box.gd")
const TOOL := "/usr/bin/retroforge-steam-direct"

var notification_manager := load("res://core/global/notification_manager.tres")
var toggle_scene := load("res://core/ui/components/toggle.tscn") as PackedScene
var logger := Log.get_logger("RetroForgeSteamDirect", Log.LEVEL.INFO)
var tree: SceneTree
var _toggle: Control  # OGUI Toggle


func setup(scene_tree: SceneTree) -> RefCounted:
	tree = scene_tree
	return self


## Add the toggle to target (Apps > Steam Client), else under Settings > General after the
## keep-Steam-running one. False when the layout differs or the command is missing.
func attach(target: Node = null) -> bool:  # target: Apps > Steam Client's rows (apps_page.gd)
	var menu: Node = tree.root.find_child("GeneralSettings", true, false)
	var box: Node = target if target else GeneralBox.find(menu)
	if not box or not FileAccess.file_exists(TOOL):
		return false
	var after: Node = null
	for name in ["RetroForgeSteamKeep", "RetroForgePauseInMenus", "AnimatedEffectsToggle"]:
		after = box.get_node_or_null(name)
		if after:
			break
	_toggle = toggle_scene.instantiate()
	_toggle.name = "RetroForgeSteamDirect"
	_toggle.text = "Steam: start games without Steam"
	_toggle.description = "Saves memory and skips Steam's launch steps. Cloud saves are not downloaded before playing; no overlay. Without Steam kept running, no achievements or cloud saves either."
	_toggle.separator_visible = false  # as the rows above it; read in _ready, so before add_child
	box.add_child(_toggle)
	if after:
		box.move_child(_toggle, after.get_index() + 1)
	_toggle.toggled.connect(_on_toggled)
	_load_status()
	return true


## The switch is set once retroforge-steam-direct answers. It is Python, ~0.5 s on the Air X, which
## held OGUI's first frames back at boot when attach() waited for it (2026-11-01).
func _load_status() -> void:
	var cmd := Command.create(TOOL, ["status"])
	if cmd.execute() != OK or (await cmd.finished) != 0 or not is_instance_valid(_toggle):
		return
	_toggle.button_pressed = cmd.stdout.strip_edges() == "on"


func detach() -> void:
	if is_instance_valid(_toggle):
		_toggle.queue_free()


## What retroforge-steam-direct reports: "on" or "off" ("" when it cannot run).
func status() -> String:
	var output: Array = []
	if OS.execute(TOOL, ["status"], output) != 0 or output.is_empty():
		return ""
	return str(output[0]).strip_edges()


## The Toggle only emits on the player's input: this never fires while it is built. A failure puts
## the toggle back to what is saved and says so.
func _on_toggled(on: bool) -> void:
	var want := "on" if on else "off"
	var cmd := Command.create(TOOL, [want])
	var code := -1
	if cmd.execute() == OK:
		code = await cmd.finished as int
	var now := status()
	if code == 0 and now == want:
		logger.info("start Steam games without Steam " + want)
		return
	logger.warn("retroforge-steam-direct %s exited %d (now %s): %s" % [want, code, now, cmd.stderr])
	_notify("Could not turn starting games without Steam " + want)
	if is_instance_valid(_toggle):
		_toggle.button_pressed = now == "on"  # the setter does not emit toggled


func _notify(text: String) -> void:
	notification_manager.show(Notification.new(text))

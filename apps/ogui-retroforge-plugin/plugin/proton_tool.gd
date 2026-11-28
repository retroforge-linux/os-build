extends RefCounted
## Apps > Proton: the Proton RetroForge keeps for Windows games, from Steam, GOG and Epic alike. It is
## an entry of the Apps list the plugin adds itself (entry(): no retroforge-emu catalog row), whose page
## is this row: the tool's release and a Download (Update once installed) button with its progress.
##
## /usr/bin/retroforge-proton says which tool this device takes (`status`: Proton-CachyOS arm64, or on
## ARMv8.0 CPUs its ARMv8.0 rebuild) and installs it as a user unit, waiting for it (`install`),
## so the download goes on if OGUI restarts. The progress is the percentage steam-compat-tools writes
## to ~/.local/share/retroforge/steam-compat-tools.progress, read here while the command runs (the row
## is looked up on every tick: the Apps page builds new rows at each visit). DXVK-Sarek is on in the
## tool only where the GPU needs it, which steam-compat-tools decides: nothing to choose here.

const TOOL := "/usr/bin/retroforge-proton"
const POLL := 0.5  # s between progress samples

var notification_manager := load("res://core/global/notification_manager.tres")
var row_scene := load("res://core/ui/components/card_button_setting.tscn") as PackedScene
var logger := Log.get_logger("RetroForgeProton", Log.LEVEL.INFO)
var tree: SceneTree
var _row: Control  # OGUI CardButtonSetting
var _running := false
var _shown := ""  # the row's text while a download runs


func setup(scene_tree: SceneTree) -> RefCounted:
	tree = scene_tree
	return self


## The Apps list's entry for Proton, as retroforge-emu lists an emulator (name, author, homepage for
## the credit line), or {} when the command is missing or cannot say.
func entry() -> Dictionary:
	if not FileAccess.file_exists(TOOL):
		return {}
	var now := status()
	if now.is_empty():
		return {}
	return {"name": "Proton", "kind": "proton", "author": now.get("author"), "homepage": now.get("homepage")}


## Add the row at the end of box (Apps > Proton's rows). False when the command is missing or cannot say.
func attach(box: Node) -> bool:
	if not box or not FileAccess.file_exists(TOOL):
		return false
	var now := status()
	if now.is_empty():
		return false
	_row = row_scene.instantiate()
	_row.name = "RetroForgeProtonTool"
	_row.text = _title(now)
	_row.separator_visible = false
	_label(now)
	box.add_child(_row)
	_row.disabled = _running
	_row.button_up.connect(install)
	return true


func detach() -> void:
	if is_instance_valid(_row):
		_row.queue_free()


## What `retroforge-proton status` reports: {name, display_name, author, homepage, installed (a tag or
## null), armv8, steam_default (Steam uses it by default on this board: an ARMv8.0 CPU, or a GPU that
## needs DXVK-Sarek)}, or {} when it cannot run.
func status() -> Dictionary:
	var output: Array = []
	if OS.execute(TOOL, ["status"], output) != 0 or output.is_empty():
		return {}
	var parsed = JSON.parse_string(str(output[0]))
	return parsed if parsed is Dictionary else {}


## The tool's name as the player reads it: the display name without "(RetroForge)".
func _title(now: Dictionary) -> String:
	return str(now.get("display_name", "Proton")).trim_suffix(" (RetroForge)")


## The row's title, description and button for `now` (status()), or the download's progress while it
## runs.
func _label(now: Dictionary) -> void:
	if not is_instance_valid(_row):
		return
	if _running:
		_row.description = _shown
		return
	_row.text = _title(now)
	var ours: bool = now.get("steam_default", false)
	var steam := "Steam uses it for every Windows game not set to another tool." if ours \
		else "In Steam, select it for a game: Properties > Compatibility."
	if now.get("installed") != null:
		_row.description = "Installed: %s. GOG and Epic games run with it. %s" % [now["installed"], steam]
		_row.button_text = "Update"
	else:
		var comes := "It comes with Steam Client and with the first GOG or Epic game you install." if ours \
			else "GOG and Epic games download it at their first install."
		_row.description = "Not installed. %s %s" % [comes, steam]
		_row.button_text = "Download"


func _progress(text: String) -> void:
	_shown = text
	_label({})


func _progress_file() -> String:
	var data := OS.get_environment("XDG_DATA_HOME")
	if data.is_empty():
		data = OS.get_environment("HOME").path_join(".local/share")
	return data.path_join("retroforge/steam-compat-tools.progress")


## steam-compat-tools' progress file: a percentage while it downloads, `unpacking` after.
func _poll() -> void:
	var f := FileAccess.open(_progress_file(), FileAccess.READ)
	if not f:
		return
	var text := f.get_as_text().strip_edges()
	if text == "unpacking":
		_progress("Installing...")
	elif text.is_valid_int():
		_progress("Downloading %d%%" % clampi(int(text), 0, 99))


func _poll_while_running() -> void:
	while _running:
		await tree.create_timer(POLL).timeout
		if _running:
			_poll()


## Download / Update: `retroforge-proton install`, polled for its progress until it ends. An Update that found nothing newer leaves the same
## release installed.
func install() -> void:
	if _running:
		return
	var before := status()
	_running = true
	if is_instance_valid(_row):
		_row.disabled = true
	_progress("Checking for the newest release...")
	var code := -1
	var cmd := Command.create(TOOL, ["install"])
	if cmd.execute() == OK:
		_poll_while_running()  # not awaited: runs beside the command
		code = await cmd.finished as int
	_running = false
	var now := status()
	var tool_name := _title(now) if not now.is_empty() else "Proton"
	var installed = now.get("installed")
	if code == 0 and installed != null and installed == before.get("installed"):
		_notify(tool_name + " is up to date")
	elif code == 0 and installed != null and now.get("steam_default", false):
		_notify(tool_name + " installed")
	elif code == 0 and installed != null:
		_notify(tool_name + " installed. Restart Steam to select it for a game.")
	else:
		logger.warn("retroforge-proton install exited %d (now %s): %s" % [code, now, cmd.stderr])
		_notify("Could not download %s. Check the network connection." % tool_name)
	if is_instance_valid(_row):
		_row.disabled = false
	if not now.is_empty():
		_label(now)


func _notify(text: String) -> void:
	notification_manager.show(Notification.new(text))

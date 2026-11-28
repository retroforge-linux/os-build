extends RefCounted
## Apps > Steam Client > "FEX for Linux games": the branch of Steam's FEX tool, which runs x86 Linux
## games (its Properties > Betas in Steam): Stable, Beta or Bleeding edge. Steam keeps one FEX tool for
## every game, so this is one setting, not a game's; Windows games use the FEX inside their Proton.
## /usr/bin/retroforge-steam-fex says what the tool is on and what it can be (`status`) and has the
## running Steam client change it (`set`: ~15 s, with Steam's download of the other build, 15-18 MB).
## It changes nothing while Steam runs a game (exit 3) or while no Steam client runs (exit 4), and
## the row says which. The row shows from the start, off until the status is read (~0.2 s), so the
## page's focus order is the same before and after; before Steam has installed the tool (it comes with
## the first x86 game) it stays off and says so.

const TOOL := "/usr/bin/retroforge-steam-fex"
const ABOUT := "The FEX build Steam runs x86 Linux games with. Stable is the one Valve ships; Beta and Bleeding edge are newer and less tested. Windows games use the FEX inside their Proton."
const CHANGING := "Changing it in Steam..."
const MISSING := "Steam installs its FEX with the first Linux game."

var notification_manager := load("res://core/global/notification_manager.tres")
var dropdown_scene := load("res://core/ui/components/dropdown.tscn") as PackedScene
var logger := Log.get_logger("RetroForgeSteamFex", Log.LEVEL.INFO)
var tree: SceneTree
var _row: Control  # OGUI Dropdown
var _names: Array = []  # what each item sets: a branch's name


func setup(scene_tree: SceneTree) -> RefCounted:
	tree = scene_tree
	return self


## Add the row at the end of target (Apps > Steam Client's rows, after the two toggles). False when
## there is no page or the command is missing.
func attach(target: Node = null) -> bool:
	if not target or not FileAccess.file_exists(TOOL):
		return false
	_row = dropdown_scene.instantiate()
	_row.name = "RetroForgeSteamFex"
	_row.title = "FEX for Linux games"
	_row.description = ABOUT
	_row.disabled = true
	target.add_child(_row)
	_row.clear()  # dropdown.tscn ships one placeholder item
	_row.item_selected.connect(_on_selected)
	_load_status(_row)
	return true


func detach() -> void:
	if is_instance_valid(_row):
		_row.queue_free()


## The row's items and text for what `retroforge-steam-fex status` printed. select() does not emit
## item_selected, so loading never changes anything.
func _show(row: Control, now: Dictionary) -> void:
	row.clear()
	_names = []
	if now.get("installed", false) != true:
		row.description = ABOUT + " " + MISSING
		row.disabled = true
		return
	for branch in now.get("branches", []):
		if branch is Dictionary:
			_names.append(str(branch.get("name", "")))
			row.add_item(str(branch.get("label", "")))
	var mine := str(now.get("branch", ""))
	if not mine in _names:  # a branch chosen in Steam that the row does not offer stays shown
		_names.append(mine)
		row.add_item(str(now.get("other", mine)))
	row.select(_names.find(mine))
	var installed := str(now.get("version", ""))
	row.description = ABOUT + ("" if installed == "" else " Installed: %s." % installed) \
		+ (" Steam is still downloading the one chosen." if now.get("updating", false) == true else "")
	row.disabled = false


func _load_status(row: Control) -> void:
	var cmd := Command.create(TOOL, ["status"])
	var code := -1
	if cmd.execute() == OK:
		code = await cmd.finished as int
	if not is_instance_valid(row):
		return  # the page was built again meanwhile
	var now = JSON.parse_string(cmd.stdout) if code == 0 else null
	if now is Dictionary:
		_show(row, now)
	else:
		logger.warn("retroforge-steam-fex status exited %d: %s" % [code, cmd.stderr])


## The Dropdown only emits on the player's input. Steam makes the change, so the row is off and says
## so until the command ends; a refusal says why, and the row then shows what the tool is on.
func _on_selected(index: int) -> void:
	var row := _row
	if index < 0 or index >= _names.size() or not is_instance_valid(row):
		return
	var want := str(_names[index])
	row.disabled = true
	row.description = CHANGING
	var cmd := Command.create(TOOL, ["set", want])
	var code := -1
	if cmd.execute() == OK:
		code = await cmd.finished as int
	var now = JSON.parse_string(cmd.stdout) if code == 0 else null
	if now is Dictionary:
		logger.info("Steam's FEX tool is on %s (%s)" % [want, now.get("version", "")])
		_notify("FEX for Linux games: %s" % str(now.get("version", want)) if now.get("updating", false) != true
			else "Steam is downloading the FEX chosen")
		if is_instance_valid(row):
			_show(row, now)
		return
	logger.warn("retroforge-steam-fex set %s exited %d: %s" % [want, code, cmd.stderr])
	match code:
		3: _notify("Close the Steam game that is running first")
		4: _notify("Steam is not running: start it once (Main menu > Steam), then choose again")
		_: _notify("Steam did not change its FEX")
	if is_instance_valid(row):
		_load_status(row)


func _notify(text: String) -> void:
	notification_manager.show(Notification.new(text))

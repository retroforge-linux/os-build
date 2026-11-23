extends ScrollContainer

## The right side of the Apps screen (apps_screen.gd): ONE catalog emulator at a time,
## the one focused in the screen's list (show_emulator).
##
## Its block: who made it (author, homepage, licence and its link:
## the attribution every emulator's licence asks for), installed vs tested version and size, and
## a button that is Download, Update or Open (the emulator's own UI, `retroforge-launch --gui`)
## -- emu_state.gd decides which, and the Revert / Install tested rows (plan emulator-latest) --, the
## player's choice for each of the emulator's options (options.json: renderer, resolution, aspect...;
## see emu_options.gd), the player's "Run on fast cores" default for that emulator (every launch of
## it, Open included, unless a game overrides it), and Delete once installed. Whether upstream has a
## newer build is only known online, and only asked when the player presses "Check for a newer
## version" (`retroforge-emu check --refresh`); the rows are rebuilt with its answer. Everything
## else goes through /usr/bin/retroforge-emu (list / check / install / rollback / remove); the page
## never downloads or verifies anything itself.
##
## Steam Client (retroforge-emu's "kind": "steam", installed by steam-install) shows its rows from
## emu_state.gd, then the Steam rows (steam_rows): no Delete and no emulator settings. Its progress
## comes from the file steam-install writes (the entry's "progress"), and Open starts Steam's own UI.
##
## Proton ("kind": "proton") is no catalog row: the plugin adds it (proton_entry), and its page is only
## the Proton rows (proton_rows: the tool with its Download / Update),
## which Steam, GOG and Epic games share.
##
## Built in code on the pattern of OGUI's own settings pages (library_settings_menu.tscn): a
## StateWatcher on this page's State hands focus to the page's FocusGroup, and Back pops the
## screen's state machine to return to the list.

const EMU_TOOL := "/usr/bin/retroforge-emu"
const LAUNCHER := "/usr/bin/retroforge-launch"
const LaunchArgs := preload("launch_args.gd")
const Credits := preload("credits.gd")
const EmuOptions := preload("emu_options.gd")
const EmuState := preload("emu_state.gd")
const PROGRESS_POLL := 0.5  # s between download progress samples
const CHECK_TIMEOUT := 60.0  # s a background `check` may take (two GitHub calls)
const EXIT_TEXT := {
	3: "Download failed: check the network connection.",
	4: "The download could not be verified; nothing was changed.",
	5: "Not enough free space, or the emulators folder is not writable.",
	6: "GitHub limits downloads from this network to 60 requests an hour. Try again in %s.",
}

var launch_manager := load("res://core/global/launch_manager.tres") as LaunchManager
var notification_manager := load("res://core/global/notification_manager.tres")
var section_scene := load("res://core/ui/components/section_label.tscn") as PackedScene
var row_scene := load("res://core/ui/components/card_button_setting.tscn") as PackedScene
var toggle_scene := load("res://core/ui/components/toggle.tscn") as PackedScene
var dropdown_scene := load("res://core/ui/components/dropdown.tscn") as PackedScene
var focus_group_scene := load("res://core/systems/input/focus_group.tscn") as PackedScene
var input_watcher_scene := load("res://core/systems/input/input_watcher.tscn") as PackedScene
var state_updater_scene := load("res://core/systems/state/state_updater.tscn") as PackedScene
var state_watcher_scene := load("res://core/systems/state/state_watcher.tscn") as PackedScene
var focus_group_setter_script := load("res://core/systems/input/focus_group_setter.gd") as GDScript

## The state this page owns on the screen's state machine; A on a list entry pushes it.
var state: State
## `retroforge-emu list`'s emulators (id -> entry), read by load_catalog().
var catalog := {}
## The emulator shown ("" = none yet).
var emulator_id := ""
## Adds the Steam rows (plugin.gd: keep running, start without Steam) to the box it gets, under Steam
## Client's own rows; called at every build of Steam Client's page.
var steam_rows := Callable()
## Apps > Proton's list entry ({} for none: proton_tool.gd entry()), read with the catalog, and the rows
## of its page (plugin.gd: the tool), called at every build of that page.
var proton_entry := Callable()
var proton_rows := Callable()
var logger := Log.get_logger("RetroForgeEmulators", Log.LEVEL.INFO)
var _rows: VBoxContainer
var _focus_group: FocusGroup
var _busy := {}  # emulator id -> true while an install or remove runs
## Emulator id -> the row showing its running download's progress. The page builds new rows when the
## player comes back to it (_reload), so the poll looks the row up on every tick: a row it was bound
## to is freed by then, and Godot refuses a freed object for a typed argument before the function
## can check it ("Cannot convert argument 2 from Object to Object", every tick, the shown progress
## frozen: HW, Pocket FIT, 2026-10-19).
var _progress_rows := {}
var _inside := false  # this page's state is the current one (it has the focus)
var _generation := 0  # refresh() calls: only the latest one builds rows
var _checks := {}  # emulator id -> its `retroforge-emu check` answer ({"latest", "error"})
var _checking := {}  # emulator id -> true while its check runs


func setup(page_state: State, state_machine: StateMachine) -> void:
	state = page_state
	name = "RetroForgeEmulatorsMenu"
	follow_focus = true
	horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL

	# Back returns to the list, unless the screen handles Back itself (state_machine null).
	if state_machine:
		_add_back(state_machine)
	_build_rows()


func _add_back(state_machine: StateMachine) -> void:
	var back = input_watcher_scene.instantiate()
	back.stop_propagation = true
	back.action = "ogui_east"
	var pop = state_updater_scene.instantiate()
	pop.state_machine = state_machine
	pop.action = 2  # StateUpdater.ACTION.POP
	pop.on_signal = "input_released"
	back.add_child(pop)
	add_child(back)


func _build_rows() -> void:
	var margin := MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	for side in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 5)
	add_child(margin)
	_rows = VBoxContainer.new()
	_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.add_child(_rows)
	_focus_group = focus_group_scene.instantiate() as FocusGroup
	_rows.add_child(_focus_group)

	# Entering this page's state gives it the focus.
	var watcher = state_watcher_scene.instantiate()
	watcher.state = state
	var setter: Node = focus_group_setter_script.new()
	setter.target = _focus_group
	setter.on_signal = "state_entered"
	watcher.add_child(setter)
	add_child(watcher)
	# Rows are rebuilt after every install / delete, which frees the focused one; while the page
	# is entered, refresh() hands the focus back.
	watcher.state_entered.connect(func(): _inside = true)
	watcher.state_exited.connect(func(): _inside = false)
	watcher.state_removed.connect(func(): _inside = false)


## Read the catalog again (`retroforge-emu list`): installed versions, updates.
func load_catalog() -> void:
	catalog = _list()
	var proton: Dictionary = proton_entry.call() if proton_entry.is_valid() else {}
	if not proton.is_empty() and not catalog.has("proton"):
		catalog["proton"] = proton


## Show one emulator (focusing its entry in the list).
func show_emulator(id: String) -> void:
	emulator_id = id
	refresh()


## "Check for a newer version": ask upstream now (`check --refresh`; never on its own: each ask
## costs two of the 60 GitHub requests an hour this network gets), say what it found, and rebuild
## the rows (an Update replaces Open when there is a newer build).
func _check(id: String, name_text: String, row: Control) -> void:
	if _checking.has(id) or _busy.has(id):
		return
	_checking[id] = true
	row.disabled = true
	row.description = "Asking upstream..."
	var cmd := Command.create(EMU_TOOL, ["check", id, "--refresh"])
	cmd.timeout = CHECK_TIMEOUT
	var code := -1
	if cmd.execute() == OK:
		code = await cmd.finished as int
	_checking.erase(id)
	var parsed = JSON.parse_string(cmd.stdout) if code == 0 else null
	var answer = parsed.get("emulators", {}).get(id) if parsed is Dictionary else null
	if not answer is Dictionary:
		logger.warn("retroforge-emu check %s exited %d: %s" % [id, code, cmd.stderr])
		_notify("Could not check %s for a newer version" % name_text)
	elif answer.get("error") != null:
		logger.info("%s: no newest build known: %s" % [id, answer["error"]])
		var error := str(answer["error"])
		_notify(_failure_text(6, error, name_text) if "requests an hour" in error
			else "Could not reach upstream to check %s: check the network connection." % name_text)
	else:
		_checks[id] = answer
		var installed = catalog.get(id, {}).get("installed")
		_notify("%s is up to date" % name_text if answer.get("latest") == installed
			else "%s %s is available" % [name_text, Credits.version_text(str(answer.get("latest")))])
	if id == emulator_id:
		refresh()


## Rebuild the rows of the shown emulator from the catalog last read.
func refresh() -> void:
	_generation += 1
	var generation := _generation
	for child in _rows.get_children():
		if child != _focus_group:
			child.queue_free()
	await get_tree().process_frame
	if generation != _generation:  # a newer refresh (the list moved on) builds the rows
		return
	if catalog.is_empty():
		_add_label("No emulator catalog found")
	elif catalog.has(emulator_id):
		_add_emulator(emulator_id, catalog[emulator_id])
	_focus_group.current_focus = null
	_focus_group.recalculate_focus()
	_confine_focus()
	if _inside:
		_focus_group.grab_focus()


## CardButtonSetting hands its focus to an inner button that has none of the neighbours FocusGroup
## set on the row, so Up from the first row (or Left) went to the nearest control on screen: an
## entry of the Emulators list, which swaps the page. Give the inner button the row's neighbours.
## (Dropdown forwards them itself.)
func _confine_focus() -> void:
	for row in _rows.get_children():
		var inner = row.get("card_button")
		if not (row is Control and inner is Control):
			continue
		for side in ["focus_neighbor_top", "focus_neighbor_bottom", "focus_neighbor_left",
				"focus_neighbor_right", "focus_next", "focus_previous"]:
			var path: NodePath = row.get(side)
			var target := row.get_node_or_null(path) if not path.is_empty() else null
			inner.set(side, target.get_path() if target else inner.get_path())


func _list() -> Dictionary:
	var output: Array = []
	if OS.execute(EMU_TOOL, ["list"], output) != 0 or output.is_empty():
		logger.warn("retroforge-emu list failed")
		return {}
	var parsed = JSON.parse_string(str(output[0]))
	if not parsed is Dictionary:
		return {}
	return parsed.get("emulators", {})


func _add_label(text: String) -> void:
	var label = section_scene.instantiate()
	label.text = text
	_rows.add_child(label)


func _add_credit(emu: Dictionary) -> void:
	var text := Credits.credit_text(emu)
	if text == "":
		return
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.modulate = Color(1, 1, 1, 0.7)
	_rows.add_child(label)


## The emulator's block (its name is the screen's title): who made it, then the build's rows -- the
## version with Download / Update / Open, Install tested, Check, Revert, Delete -- then under a
## "Settings" title the fast-cores default and one dropdown per option. Options show before the
## download too: a choice made then applies from the first launch. Lines: under the build's last row
## and under the title, nowhere else.
func _add_emulator(id: String, emu: Dictionary) -> void:
	var name_text := str(emu.get("name", id))
	_add_credit(emu)
	if emu.get("kind") == "proton":
		if proton_rows.is_valid():
			proton_rows.call(_rows)
		return
	var installed = emu.get("installed")
	var state := EmuState.rows(id, emu, _checks.get(id, {}))
	var last := _add_action_row(id, name_text, emu, state.main)
	if state.tested != null:
		last = _add_action_row(id, name_text, emu, state.tested)
	for row in state.extra:
		last = _add_action_row(id, name_text, emu, row)
	if emu.get("kind") == "steam":
		last.separator_visible = true
		if steam_rows.is_valid():
			steam_rows.call(_rows)
		return
	if installed != null:
		last = row_scene.instantiate()
		last.text = "Delete"
		last.description = "Removes the emulator. Its settings, saves and states are kept."
		last.button_text = "Delete"
		last.separator_visible = false
		last.button_up.connect(_remove.bind(id, name_text, last))
		_rows.add_child(last)
	# The build's rows end the first part; the settings follow under their own title. The options
	# come last: a dropdown's value box sits under its description, so a row placed after one reads
	# as if the box were its header.
	last.separator_visible = true
	_add_label("Settings")
	_rows.add_child(HSeparator.new())

	var fast = toggle_scene.instantiate()
	fast.text = "Run on fast cores"
	fast.description = "Games can override this in their own settings."
	fast.button_pressed = LaunchArgs.emulator_fast_cores(id)
	fast.separator_visible = false
	fast.toggled.connect(_set_fast_cores.bind(id, name_text, fast))
	_rows.add_child(fast)

	for option in EmuOptions.options_for(id):
		_add_option(id, name_text, option)


## One row of emu_state.gd: its button runs retroforge-emu with the row's args, or Open without.
func _add_action_row(id: String, name_text: String, emu: Dictionary, spec: Dictionary) -> Control:
	var row = row_scene.instantiate()
	row.text = spec.text
	row.description = spec.description
	row.button_text = spec.button
	row.separator_visible = false
	var args: Array = spec.args
	if args.is_empty():
		row.button_up.connect(_open.bind(id, name_text))
	elif args[0] == "rollback":
		row.button_up.connect(_rollback.bind(id, name_text, args, row))
	elif args[0] == "check":
		row.button_up.connect(_check.bind(id, name_text, row))
	else:
		row.button_up.connect(_install.bind(id, name_text, args, emu, row))
		if _busy.has(id) and _progress_row(id) == null:
			_progress_rows[id] = row
	_rows.add_child(row)
	if _busy.has(id):
		row.disabled = true
	return row


## Download / Update / Install tested: `retroforge-emu <args>`. The installed build before (null for a
## first download) tells an Update that found nothing newer from one that installed.
func _install(id: String, name_text: String, args: Array, emu: Dictionary, row: Control) -> void:
	if _busy.has(id):
		return
	_busy[id] = true
	_progress_rows[id] = row
	row.disabled = true
	row.description = "Downloading..."
	var before = emu.get("installed")
	var argv: Array[String] = []
	argv.assign(args)  # Command.create takes Array[String]
	var cmd := Command.create(EMU_TOOL, argv)
	if cmd.execute() != OK:
		_busy.erase(id)
		_notify("Could not start the download of " + name_text)
		_reload()
		return
	# Progress from the size of retroforge-emu's hidden .part file, named after the catalog's tag;
	# the size is the tested build's, close enough for a newer one.
	var part := OS.get_environment("HOME").path_join("emulators/%s/.%s.AppImage.part" % [id, str(emu.get("pinned", ""))])
	var poll := Timer.new()
	poll.wait_time = PROGRESS_POLL
	add_child(poll)
	# Steam, and an emulator with folders (RetroArch's shaders): the percentage is written to a file.
	if emu.get("progress") != null:
		poll.timeout.connect(_show_progress_file.bind(str(emu.get("progress")), id))
	else:
		poll.timeout.connect(_show_progress.bind(part, int(emu.get("size", 0)), id))
	poll.start()
	var code := await cmd.finished as int
	poll.queue_free()
	_busy.erase(id)
	_progress_rows.erase(id)
	if code == 0 and before != null and EmuState.unchanged(emu, _list().get(id, {})):
		_notify(name_text + " is up to date")
	elif code == 0 and emu.get("kind") == "steam" and before == null:
		# Its first start is Steam's own sign-in (a QR code for the Steam Mobile App).
		_notify("Steam is ready. Open it from Main menu > Steam to sign in.")
	elif code == 0:
		_notify(name_text + " installed")
	else:
		logger.warn("retroforge-emu %s exited %d: %s" % [" ".join(args), code, cmd.stderr])
		_notify(_failure_text(code, cmd.stderr, name_text))
	_reload()


## Revert: back to the build kept from before the last switch (offline, instant).
## Revert: `retroforge-emu <args>` (["rollback", id], or ["rollback", id, "--core=<core>"] for one
## libretro core of RetroArch).
func _rollback(id: String, name_text: String, args: Array, row: Control) -> void:
	if _busy.has(id):
		return
	_busy[id] = true
	row.disabled = true
	var core := ""
	if args.size() > 2 and str(args[2]).begins_with("--core="):
		core = str(args[2]).trim_prefix("--core=")
	var cmd := Command.create(EMU_TOOL, args)
	var code := -1
	if cmd.execute() == OK:
		code = await cmd.finished as int
	_busy.erase(id)
	if code == 0 and core != "":
		_notify("%s: the %s core is back to its previous build" % [name_text, core])
	elif code == 0:
		_notify("%s is back to %s" % [name_text, Credits.version_text(str(_installed(id)))])
	else:
		logger.warn("retroforge-emu %s exited %d: %s" % [" ".join(args), code, cmd.stderr])
		_notify(name_text + " could not be reverted")
	_reload()


## What a failed install says. A rate limit (exit 6) names the wait retroforge-emu read from
## GitHub ("try again in N min" on its stderr).
func _failure_text(code: int, stderr: String, name_text: String) -> String:
	var text: String = EXIT_TEXT.get(code, "Installing %s failed." % name_text)
	if code != 6:
		return text
	var found := RegEx.create_from_string("try again in ([0-9]+) min").search(stderr)
	var minutes := int(found.get_string(1)) if found else 60
	return text % ("1 minute" if minutes == 1 else "%d minutes" % minutes)


## The build `retroforge-emu list` reports as installed for `id`, or null.
func _installed(id: String) -> Variant:
	return _list().get(id, {}).get("installed")


## The row now showing `id`'s download, or null (the page is not shown, or is being rebuilt).
func _progress_row(id: String) -> Control:
	var row = _progress_rows.get(id)
	return row if is_instance_valid(row) else null


func _show_progress(part: String, size: int, id: String) -> void:
	var row := _progress_row(id)
	if size <= 0 or not row:
		return
	var f := FileAccess.open(part, FileAccess.READ)
	if f:
		row.description = "Downloading %d%%" % mini(99, f.get_length() * 100 / size)


func _show_progress_file(path: String, id: String) -> void:
	var row := _progress_row(id)
	if not row:
		return
	var f := FileAccess.open(path, FileAccess.READ)
	if f:
		row.description = "Downloading %d%%" % mini(99, int(f.get_as_text().strip_edges()))


func _remove(id: String, name_text: String, row: Control) -> void:
	if _busy.has(id):
		return
	var dialog := get_tree().get_first_node_in_group("dialog") as Dialog
	if dialog:
		dialog.open(row, "Delete %s?\nIts settings, saves and states are kept." % name_text, "Delete", "Cancel")
		if not await dialog.choice_selected:
			return
	_busy[id] = true
	var cmd := Command.create(EMU_TOOL, ["remove", id])
	var code := -1
	if cmd.execute() == OK:
		code = await cmd.finished as int
	_busy.erase(id)
	_notify(name_text + (" deleted" if code == 0 else " could not be deleted"))
	_reload()


func _reload() -> void:
	load_catalog()
	refresh()


## One option's dropdown: "Emulator's setting" (RetroForge leaves it alone; none on an option with a
## default), then each choice.
## Items are added once it is in the tree (the Dropdown's OptionButton is @onready); select() does
## not emit item_selected, so building the rows never saves.
func _add_option(id: String, name_text: String, option: Dictionary) -> void:
	var dropdown = dropdown_scene.instantiate()
	dropdown.title = option["label"]
	dropdown.description = option["description"]
	_rows.add_child(dropdown)
	dropdown.clear()  # dropdown.tscn ships one placeholder item, which would shift every index
	for text in EmuOptions.emulator_items(option):
		dropdown.add_item(text)
	dropdown.select(EmuOptions.emulator_index(option, EmuOptions.emulator_choice(id, option)))
	dropdown.item_selected.connect(_set_option.bind(id, name_text, option, dropdown))


func _set_option(index: int, id: String, name_text: String, option: Dictionary, dropdown: Control) -> void:
	var values := EmuOptions.emulator_values(option)
	if index < 0 or index >= values.size():
		logger.warn("%s: %s: no choice at item %d" % [id, option["id"], index])
		return
	if EmuOptions.set_emulator_choice(id, option, values[index]):
		logger.info("%s: %s = %s" % [id, option["id"], values[index] if values[index] != "" else "(emulator's setting)"])
		return
	logger.warn("could not write " + LaunchArgs.player_conf_path(id))
	_notify("Could not save the %s setting of %s" % [option["label"], name_text])
	dropdown.select(EmuOptions.emulator_index(option, EmuOptions.emulator_choice(id, option)))  # what is saved


## The Toggle only emits on the player's input: this never fires while the rows are built.
func _set_fast_cores(on: bool, id: String, name_text: String, toggle: Control) -> void:
	if LaunchArgs.set_emulator_fast_cores(id, on):
		logger.info("%s: fast cores by default %s" % [id, "on" if on else "off"])
		return
	logger.warn("could not write " + LaunchArgs.player_conf_path(id))
	_notify("Could not save the fast cores setting of " + name_text)
	toggle.button_pressed = not on  # back to what is saved (the setter does not emit toggled)


## The emulator's own UI, launched like a game so OGUI's overlay and Exit work.
func _open(id: String, name_text: String) -> void:
	var item := LibraryLaunchItem.new()
	item.name = name_text
	item.command = LAUNCHER
	item.args = PackedStringArray(["--gui", id])
	item.installed = true
	item._provider_id = "retroforge-roms"  # its EXIT hook reports a missing emulator
	if id == "steam-client":
		# Steam's own UI, with the flags the Steam plugin starts it with (/usr/bin/steam).
		item.name = "Steam"
		item.command = "steam"
		item.args = PackedStringArray(["-gamepadui", "-steamos3", "-steampal", "-steamdeck", "steam://open/bigpicture"])
		item._provider_id = ""
	launch_manager.launch(item)


func _notify(text: String) -> void:
	var note := Notification.new(text)
	notification_manager.show(note)

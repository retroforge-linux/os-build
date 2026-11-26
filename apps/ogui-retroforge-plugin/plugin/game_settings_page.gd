extends ScrollContainer

## Game settings > RetroForge: per-ROM options, in the screen the gear on OGUI's launch menu opens.
## For Steam games: their FEX TSO, launch option and resolution, which retroforge-steam-direct keeps
## and uses when it starts the game without the client; and an x86 game's graphics driver, which
## /usr/bin/steam sets before every launch of it.
## "Run on fast cores": the emulator's default (Main menu > Apps), On or Off for this game
## (CPUS=big / all in the game's conf, which retroforge-launch reads; launch_args.gd). "Screen size"
## (SCREEN=WxH: gamescope's games display for this game, the sizes of Settings > Display > Game
## resolution) and "Frame rate limit" (FPS_LIMIT=<fps>: gamescope's cap), which retroforge-launch sets
## for the run (window_size, frame_cap) and puts back after. Then one
## dropdown per option of the game's emulator (options.json, emu_options.gd): "Emulator default
## (<its choice>)" or a value for this game only, rebuilt at each visit (another game may run in
## another emulator). "Box art": scrape this game's art from ScreenScraper again (scrape_runner.gd;
## the library reloads when it is done, so the card shows the new art).
##
## Wired like that screen's own sections (game_settings.tscn): the button replaces the
## game-settings state with this page's State on focus and hands the focus to the page when
## pressed; the page fades in and out with its State (as game_settings_library.tscn) and Back
## returns through the screen's shared focus stack. The button only shows for RetroForge ROMs.

const LIBRARY_ID := "retroforge-roms"
const EmuOptions := preload("emu_options.gd")
const LaunchArgs := preload("launch_args.gd")
const ScrapeRunner := preload("scrape_runner.gd")
const SCRAPER_DEVID := "/usr/share/retroforge/scraper/devid"
const ART_DESCRIPTION := "Fetch this game's box art from ScreenScraper again."
const TITLE := "RetroForge"

var game_settings_state := load("res://assets/state/states/game_settings.tres") as State
var settings_state_machine := load("res://assets/state/state_machines/game_settings_state_machine.tres") as StateMachine
var focus_stack := load("res://core/ui/card_ui/launch/game_settings_focus.tres")
var dropdown_scene := load("res://core/ui/components/dropdown.tscn") as PackedScene
var button_scene := load("res://core/ui/components/card_button.tscn") as PackedScene
var setting_button_scene := load("res://core/ui/components/card_button_setting.tscn") as PackedScene
var library_manager := load("res://core/global/library_manager.tres") as LibraryManager
var notification_manager := load("res://core/global/notification_manager.tres")
var focus_group_scene := load("res://core/systems/input/focus_group.tscn") as PackedScene
var state_updater_scene := load("res://core/systems/state/state_updater.tscn") as PackedScene
var state_watcher_scene := load("res://core/systems/state/state_watcher.tscn") as PackedScene

var logger := Log.get_logger("RetroForgeGameSettings", Log.LEVEL.INFO)
var roms  # the plugin's ROM library (library_roms.gd)
var button: Control
var _state := State.new()
var _focus_group: FocusGroup
## Dropdown entries, in order: the game override each one saves.
const CPUS_CHOICES := ["", "big", "all"]

var _fast_cores: Control  # OGUI Dropdown
var _screen: Control  # OGUI Dropdown: "Screen size"
var _screen_keys: Array = []  # "", then WxH: what each item saves
var _fps: Control  # OGUI Dropdown: "Frame rate limit"
var _fps_values: Array = []  # "", then frame rates
const SCREEN_ABOUT := "The size this game runs at; the display scales it to the panel. Lower is faster on this GPU. Default: the game's picture size where its emulator draws one (Picture-sized window), else Settings > Display."
const FPS_ABOUT := "Caps the game's frame rate: steadier for a game that cannot hold the full rate, and longer battery. A limit that divides the screen's %d Hz paces evenly."
var _art: Control  # OGUI CardButtonSetting: "Box art"
var _scrape := ScrapeRunner.new()  # a field: a runner must outlive its worker thread
var _rows: VBoxContainer
var _option_rows: Array = []  # this game's option dropdowns, rebuilt at each visit
var _section_label: Label
var _item: LibraryLaunchItem  # the RetroForge launch item of the game being configured
const STEAM_LIBRARY_ID := "retroforge-steam"
const STEAM_DIRECT := "/usr/bin/retroforge-steam-direct"
const TSO_CHOICES := ["default", "on", "off"]
const TSO_ABOUT := "How closely FEX keeps x86 memory ordering between a game's threads. Off is faster on this CPU; some games then crash or glitch. Default: Valve's tested setting for the game, else On."
const DRIVER_CHOICES := ["default", "native", "x86"]
const DRIVER_ABOUT := "An x86 game's OpenGL and Vulkan driver. x86 Mesa: our x86 driver, emulated with the game. Native: the device's own, which FEX hands the game's calls to (less CPU, faster loading; a 32-bit game's Vulkan stays on x86), but some games crash on it. Default: x86 Mesa."
const DisplaySettings := preload("display_settings.gd")
var _steam_app := 0  # the Steam app id of the game being configured, 0 for none
var _tso: Control  # OGUI Dropdowns: the Steam game's own choices
var _launch: Control
var _launch_keys: Array = []
var _resolution: Control
var _resolution_keys: Array = []  # "default", then WxH: the sizes of Settings > Display > Game resolution
var _driver: Control
var _display := DisplaySettings.new()
const DIRECT_OFF := " Used only while Apps > Steam Client > \"Steam: start games without Steam\" is on."


## Add the page and its button to OGUI's game settings screen. False when its layout is not
## the one this was written against (then nothing is added).
func attach(menu: Node, rom_library) -> bool:
	var buttons: Node = menu.find_child("ButtonsContainer", true, false)
	var library_page: Node = menu.find_child("LibrarySettings", true, false)
	_section_label = menu.find_child("SectionLabel", true, false) as Label
	if not (buttons and library_page and _section_label):
		return false
	roms = rom_library
	_state.name = "retroforge_game_settings"
	_build_page()
	library_page.get_parent().add_child(self)
	_build_button(buttons)
	game_settings_state.state_entered.connect(_on_game_settings_entered)
	# Connected after game_settings.gd's own handler, which titles a section from its state's
	# name ("Retroforge"): ours runs second and sets the real name.
	settings_state_machine.state_changed.connect(_on_section_changed)
	return true


func detach() -> void:
	if game_settings_state.state_entered.is_connected(_on_game_settings_entered):
		game_settings_state.state_entered.disconnect(_on_game_settings_entered)
	if settings_state_machine.state_changed.is_connected(_on_section_changed):
		settings_state_machine.state_changed.disconnect(_on_section_changed)
	if is_instance_valid(button):
		button.queue_free()
	queue_free()


func _build_page() -> void:
	name = "RetroForgeGameSettings"
	visible = false
	follow_focus = true
	horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL

	var watcher = state_watcher_scene.instantiate()
	watcher.state = _state
	var fade := FadeEffect.new()
	fade.target = self
	fade.on_signal = "state_entered"
	fade.fade_out_signal = "state_exited"
	watcher.add_child(fade)
	add_child(watcher)

	var margin := MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	for side in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 4)
	add_child(margin)
	var rows := VBoxContainer.new()
	margin.add_child(rows)
	_rows = rows

	_fast_cores = dropdown_scene.instantiate()
	_fast_cores.title = "Run on fast cores"
	_fast_cores.description = "Keep the emulator on the fast CPU cores. Helps demanding systems (PS2, PS3, Wii U); PS1 does not need it. The default is set per emulator in Apps, in the main menu."
	_fast_cores.item_selected.connect(_on_fast_cores_selected)
	_focus_group = focus_group_scene.instantiate() as FocusGroup
	_focus_group.focus_stack = focus_stack
	rows.add_child(_focus_group)
	rows.add_child(_fast_cores)
	_focus_group.current_focus = _fast_cores
	_screen = _rom_dropdown(rows, "Screen size", SCREEN_ABOUT, _on_screen_selected)
	_fps = _rom_dropdown(rows, "Frame rate limit", FPS_ABOUT % refresh_rate(), _on_fps_selected)

	_art = setting_button_scene.instantiate()
	_art.text = "Box art"
	_art.button_text = "Scrape"
	_art.description = ART_DESCRIPTION
	_art.pressed.connect(_on_scrape_art)
	rows.add_child(_art)
	_scrape.progressed.connect(func(pct: int) -> void: _art.description = "Scraping... %d%%" % pct)
	_scrape.finished.connect(_on_art_scraped)

	_tso = _steam_dropdown("FEX TSO", TSO_ABOUT, "tso")
	_launch = _steam_dropdown("Launch option", "Which of the game's programs starts, as in Steam's launch dialog. Default: the one Steam last started.", "launch")
	_resolution = _steam_dropdown("Resolution", "The size the game draws at; the display scales it to the panel. Default: its Game resolution in Steam, else Settings > Display.", "resolution")
	_driver = _steam_dropdown("Graphics driver", DRIVER_ABOUT, "driver")


func _rom_dropdown(rows: Node, title: String, description: String, selected: Callable) -> Control:
	var dropdown = dropdown_scene.instantiate()
	dropdown.title = title
	dropdown.description = description
	dropdown.item_selected.connect(selected)
	rows.add_child(dropdown)
	return dropdown


func _steam_dropdown(title: String, description: String, key: String) -> Control:
	var dropdown = dropdown_scene.instantiate()
	dropdown.title = title
	dropdown.description = description
	dropdown.set_meta("about", description)
	dropdown.visible = false
	dropdown.item_selected.connect(func(index: int) -> void: _on_steam_choice(key, index))
	_rows.add_child(dropdown)
	return dropdown


func _build_button(buttons: Node) -> void:
	button = button_scene.instantiate()
	button.name = "RetroForgeButton"
	button.text = TITLE
	var show_page = state_updater_scene.instantiate()
	show_page.state_machine = settings_state_machine
	show_page.state = _state
	show_page.action = 3  # StateUpdater.ACTION.REPLACE, as the screen's own buttons
	show_page.on_signal = "focus_entered"
	button.add_child(show_page)
	var enter := FocusGroupSetter.new()
	enter.target = _focus_group
	enter.on_signal = "pressed"
	button.add_child(enter)

	var library_button := buttons.find_child("LibraryButton", false, false)
	buttons.add_child(button)
	if library_button:
		buttons.move_child(button, library_button.get_index() + 1)
	_recalculate(buttons)


## Show the button for RetroForge ROMs only, and load this game's saved choice.
func _on_game_settings_entered(_from: State) -> void:
	# Same lookup order as game_settings.gd, so the page always configures the titled game.
	var item = game_settings_state.get_meta("item") if game_settings_state.has_meta("item") \
		else game_settings_state.data.get("item")
	_item = item.get_launch_item(LIBRARY_ID) if item is LibraryItem else null
	var steam_item = item.get_launch_item(STEAM_LIBRARY_ID) if item is LibraryItem else null
	_steam_app = int(steam_item.metadata.get("steam_app", 0)) if steam_item and steam_item.metadata else 0
	var show := _item != null or _steam_app > 0
	for row in [_fast_cores, _screen, _fps, _art]:
		row.visible = _item != null
	_fill_steam_rows()
	if button.visible != show:
		button.visible = show
		_recalculate(button.get_parent())
	if _item == null:
		_build_options("")  # no RetroForge game: no rows of the last one left behind
	else:
		# Filled on each visit: the default's label follows the emulator's current setting.
		# select() does not emit item_selected, so loading never saves.
		_fast_cores.clear()
		_fast_cores.add_item("Emulator default (%s)" % ("On" if roms.emulator_fast_cores(_item) else "Off"))
		_fast_cores.add_item("On")
		_fast_cores.add_item("Off")
		_fast_cores.select(CPUS_CHOICES.find(roms.get_cpus(_item)))
		_fill_screen()
		_fill_fps()
		_art.disabled = not FileAccess.file_exists(SCRAPER_DEVID) or _scrape.running
		if not _scrape.running:
			_art.description = ART_DESCRIPTION if FileAccess.file_exists(SCRAPER_DEVID) else ScrapeRunner.failure_text(9, "")
		_build_options(roms.emulator_of(_item))


## The Steam game's own choices, from retroforge-steam-direct (about half a second, so off the UI
## thread); the rows stay hidden for anything else. The launch option only when Steam offers more
## than one.
func _fill_steam_rows() -> void:
	var app := _steam_app
	for row in [_tso, _launch, _resolution, _driver]:
		row.visible = false
	if _item != null:
		_focus_group.current_focus = _fast_cores
	if app <= 0 or not FileAccess.file_exists(STEAM_DIRECT):
		return
	var output: String = await _output_of(STEAM_DIRECT, ["game", str(app)])
	var data = JSON.parse_string(output) if output != "" else null
	if app != _steam_app or not data is Dictionary:
		return  # another game's page by now, or nothing to offer
	var settings: Dictionary = data.get("settings", {})
	var entries: Array = data.get("launch", [])
	# select() does not emit item_selected, so loading never saves.
	_tso.clear()
	for text in ["Default (On)", "On", "Off"]:
		_tso.add_item(text)
	_tso.select(maxi(TSO_CHOICES.find(settings.get("tso", "default")), 0))
	var hint := str(data.get("tso_hint", ""))
	_tso.set_meta("about", TSO_ABOUT + ("" if hint == "" else " Valve runs this game with it %s on the Steam Frame." % ("On" if hint == "1" else "Off")))
	_launch.clear()
	_launch_keys = ["default"]
	_launch.add_item("Default (as Steam last started it)")
	for entry in entries:
		_launch_keys.append(str(entry.get("key", "")))
		_launch.add_item(str(entry.get("description", "")))
	_launch.select(maxi(_launch_keys.find(settings.get("launch", "default")), 0))
	_resolution.clear()
	_resolution_keys = ["default"]
	var steam_size := str(data.get("steam_resolution", ""))
	var shown := _display.size_for(_display.stored_resolution())
	_resolution.add_item("Default (Steam's, %s)" % steam_size.replace("x", " x ") if steam_size != ""
		else "Default (Settings > Display, %d x %d)" % [shown.x, shown.y])
	for r in DisplaySettings.RESOLUTIONS.slice(1):
		var dims: Vector2i = _display.size_for(r[0])
		var key := "%dx%d" % [dims.x, dims.y]
		if not key in _resolution_keys:
			_resolution_keys.append(key)
			_resolution.add_item("%s, %d x %d" % [r[1], dims.x, dims.y])
	var mine := str(settings.get("resolution", "default"))
	if not mine in _resolution_keys:  # a size from before the display changed
		_resolution_keys.append(mine)
		_resolution.add_item(mine.replace("x", " x "))
	_resolution.select(_resolution_keys.find(mine))
	for row in [_tso, _launch, _resolution]:
		row.description = str(row.get_meta("about")) + ("" if data.get("direct", "on") == "on" else DIRECT_OFF)
	_driver.clear()
	for text in ["Default (x86 Mesa)", "Native", "x86 Mesa"]:
		_driver.add_item(text)
	_driver.select(maxi(DRIVER_CHOICES.find(settings.get("driver", "default")), 0))
	_tso.visible = true
	_driver.visible = data.get("x86", false) == true
	_launch.visible = entries.size() > 1
	_resolution.visible = _resolution_keys.size() > 1
	_focus_group.current_focus = _tso
	_focus_group.recalculate_focus()


## cmd's output when it exits 0, else "".
func _output_of(cmd_path: String, args: Array[String]) -> String:
	var cmd := Command.create(cmd_path, args)
	var code := -1
	if cmd.execute() == OK:
		code = await cmd.finished as int
	if code != 0:
		logger.warn("%s %s exited %d: %s" % [cmd_path, " ".join(PackedStringArray(args)), code, cmd.stderr])
	return cmd.stdout if code == 0 else ""


func _on_steam_choice(key: String, index: int) -> void:
	var values: Array = {"tso": TSO_CHOICES, "driver": DRIVER_CHOICES,
		"launch": _launch_keys}.get(key, _resolution_keys)
	if _steam_app <= 0 or index < 0 or index >= values.size():
		return
	var app := _steam_app
	var cmd := Command.create(STEAM_DIRECT, ["game", str(app), "set", key, str(values[index])])
	var code := -1
	if cmd.execute() == OK:
		code = await cmd.finished as int
	if code == 0:
		logger.info("Steam app %d: %s = %s" % [app, key, values[index]])
		return
	logger.warn("retroforge-steam-direct game %d set %s %s exited %d: %s" % [app, key, values[index], code, cmd.stderr])
	notification_manager.show(Notification.new("Could not save this game's " + key))
	_fill_steam_rows()


## The game's emulator options, after the fast-cores row. Removed from the tree before they are
## freed, so the FocusGroup never walks a dying row.
func _build_options(emulator: String) -> void:
	if _focus_group.current_focus in _option_rows:
		_focus_group.current_focus = _fast_cores
	for row in _option_rows:
		_rows.remove_child(row)
		row.queue_free()
	_option_rows.clear()
	if emulator != "":
		for option in EmuOptions.for_system(EmuOptions.options_for(emulator), str(_item.metadata["system"])):
			_add_option(emulator, option)
	_focus_group.recalculate_focus()


func _add_option(emulator: String, option: Dictionary) -> void:
	var dropdown = dropdown_scene.instantiate()
	dropdown.title = option["label"]
	dropdown.description = option["description"]
	_rows.add_child(dropdown)
	_option_rows.append(dropdown)
	dropdown.clear()  # dropdown.tscn ships one placeholder item, which would shift every index
	for text in EmuOptions.game_items(option, EmuOptions.emulator_choice(emulator, option)):
		dropdown.add_item(text)
	var system: String = _item.metadata["system"]
	var rom: String = _item.metadata["rom"]
	dropdown.select(EmuOptions.index_of(option, EmuOptions.game_choice(system, rom, option)))
	dropdown.item_selected.connect(_on_option_selected.bind(option, dropdown))


func _on_option_selected(index: int, option: Dictionary, dropdown: Control) -> void:
	var values := EmuOptions.values(option)
	if not _item:
		return
	if index < 0 or index >= values.size():
		logger.warn("%s: no choice at item %d" % [option["id"], index])
		return
	var system: String = _item.metadata["system"]
	var rom: String = _item.metadata["rom"]
	if EmuOptions.set_game_choice(system, rom, option, values[index]):
		logger.info("%s: %s = %s" % [_item.name, option["id"], values[index] if values[index] != "" else "(emulator default)"])
		return
	logger.warn("could not write " + LaunchArgs.game_conf_path(system, rom))
	dropdown.select(EmuOptions.index_of(option, EmuOptions.game_choice(system, rom, option)))  # what is saved


func _on_scrape_art() -> void:
	if not _item or _scrape.running:
		return
	if _scrape.start(["run", "--rom", str(_item.metadata["rom"]), "--all"]):
		_art.disabled = true
		_art.description = "Asking ScreenScraper..."


func _on_art_scraped(code: int, summary: Dictionary, error: String) -> void:
	_art.disabled = false
	_art.description = ART_DESCRIPTION
	var text := ScrapeRunner.failure_text(code, error) if code != 0 else \
		("New art saved." if int(summary.get("scraped", 0)) > 0 else "ScreenScraper does not know this game.")
	notification_manager.show(Notification.new(text))
	if code != 0:
		logger.warn("retroforge-scrape exited %d: %s" % [code, error])
	if int(summary.get("scraped", 0)) > 0:
		library_manager.load_library(LIBRARY_ID)


## Screen size: Default, then Settings > Display's sizes (WxH, one item per size); a saved size the
## list no longer has (the display changed) stays offered.
func _fill_screen() -> void:
	var mine := _game_value(LaunchArgs.SCREEN_KEY)
	_screen.clear()
	_screen_keys = [""]
	_screen.add_item("Default")
	for r in DisplaySettings.RESOLUTIONS.slice(1):
		var dims: Vector2i = _display.size_for(r[0])
		var key := "%dx%d" % [dims.x, dims.y]
		if dims.x > 0 and dims.y > 0 and not key in _screen_keys:  # no size while the screen's is unknown
			_screen_keys.append(key)
			_screen.add_item("%s, %d x %d" % [r[1], dims.x, dims.y])
	if mine != "" and not mine in _screen_keys:
		_screen_keys.append(mine)
		_screen.add_item(mine.replace("x", " x "))
	_screen.select(_screen_keys.find(mine))


## Frame rate limit: Off, then the rates that divide the screen's refresh (20 fps and up).
func _fill_fps() -> void:
	var mine := _game_value(LaunchArgs.FPS_KEY)
	_fps.clear()
	_fps_values = [""]
	_fps.add_item("Off")
	for fps in LaunchArgs.fps_choices(refresh_rate()):
		_fps_values.append(str(fps))
		_fps.add_item("%d fps" % fps)
	if mine != "" and not mine in _fps_values:
		_fps_values.append(mine)
		_fps.add_item("%s fps" % mine)
	_fps.select(_fps_values.find(mine))


## The screen's refresh rate in whole Hz (60 when the display does not say).
static func refresh_rate() -> int:
	var hz := roundi(DisplayServer.screen_get_refresh_rate())
	return hz if hz > 0 else 60


func _game_value(key: String) -> String:
	return LaunchArgs.game_value(str(_item.metadata["system"]), str(_item.metadata["rom"]), key)


func _save_game_value(key: String, value: String, what: String) -> void:
	if not _item:
		return
	if LaunchArgs.set_game_value(str(_item.metadata["system"]), str(_item.metadata["rom"]), key, value):
		logger.info("%s: %s %s" % [_item.name, what, value if value != "" else "default"])
	else:
		logger.warn("could not write " + LaunchArgs.game_conf_path(str(_item.metadata["system"]), str(_item.metadata["rom"])))


func _on_screen_selected(index: int) -> void:
	if index >= 0 and index < _screen_keys.size():
		_save_game_value(LaunchArgs.SCREEN_KEY, _screen_keys[index], "screen size")


func _on_fps_selected(index: int) -> void:
	if index >= 0 and index < _fps_values.size():
		_save_game_value(LaunchArgs.FPS_KEY, _fps_values[index], "frame rate limit")


func _on_fast_cores_selected(index: int) -> void:
	if _item and index >= 0 and index < CPUS_CHOICES.size():
		roms.set_cpus(_item, CPUS_CHOICES[index])


func _on_section_changed(_from: State, to: State) -> void:
	if to == _state:
		_section_label.text = TITLE


func _recalculate(buttons: Node) -> void:
	var group := buttons.find_child("FocusGroup", false, false)
	if group:
		group.recalculate_focus()

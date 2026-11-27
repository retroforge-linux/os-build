extends ScrollContainer

## Game settings > RetroForge: per-ROM options, in the screen the gear on OGUI's launch menu opens.
## For Steam games: their FEX TSO, launch option and resolution, which retroforge-steam-direct keeps
## and uses when it starts the game without the client; and an x86 game's graphics driver, which
## /usr/bin/steam sets before every launch of it. For an installed GOG or Epic game: its FEX TSO,
## Proton, game fixes, (Epic) online and resolution, which `store <s> launch` reads (its GAME CHOICES).
## For both, the graphics API of a Unity, Unreal or Godot game built with more than one
## (python/graphics_api.py), and Run on fast cores ("cpus": on, python/fastcores.py; how is Settings >
## General > Pin to fast cores).
## "Run on fast cores": the emulator's default (Main menu > Apps), On or Off for this game
## (CPUS=big / all in the game's conf, which retroforge-launch reads; launch_args.gd). "Screen size"
## (SCREEN=WxH: gamescope's games display for this game, the sizes of Settings > Display > Game
## resolution), which retroforge-launch sets for the run (window_size) and puts back after. Then one
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
const SCREEN_ABOUT := "The size this game runs at; the display scales it to the panel. Lower is faster on this GPU. Default: the game's picture size where its emulator draws one (Picture-sized window), else Settings > Display."
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
const STORE_TSO_ABOUT := "How closely FEX keeps x86 memory ordering between a game's threads. Off is faster on this CPU; some games then crash or glitch. Default: On."
const PROTON_ABOUT := "The Proton this game runs with. Default: the one RetroForge keeps up to date for this device (Main menu > Apps > Proton)."
const FIXES_ABOUT := "Per-game fixes from umu-protonfixes and RetroForge's own, applied before the game starts. Off runs the game as it is. Default: On."
const ONLINE_ABOUT := "Online, the game starts signed in to Epic: online play, and games whose DRM needs it. A game that first asks for Epic's consent can then wait forever. Default: Offline."
const STORE_RESOLUTION_ABOUT := "The size the game draws at; the display scales it to the panel. Default: Settings > Display."
const API_ABOUT := "The graphics API the game renders with, of those its engine has. DirectX runs through DXVK or vkd3d-proton; Vulkan and OpenGL go to the device's own driver. A game built without the one picked may not start or may draw wrong: set it back to Default."
const API_STEAM := " When Steam itself starts the game, only with Proton-CachyOS."
const GAME_CPUS_ABOUT := "Run the game on the fast CPU cores: helps a game the CPU holds back, for more power. Settings > General > Pin to fast cores says whether it may also use the slow ones when the fast ones are busy. Default: Off."
const GAME_CPUS_STEAM := " When the game starts from this library."
const API_LABELS := {"d3d11": "DirectX 11", "d3d12": "DirectX 12", "vulkan": "Vulkan", "opengl": "OpenGL"}
const STORE_TOOL := "/usr/lib/retroforge/store"
const STORE_LIBRARY_IDS := ["retroforge-gog", "retroforge-epic"]
const DisplaySettings := preload("display_settings.gd")
var _steam_app := 0  # the Steam app id of the game being configured, 0 for none
var _store := ""  # "gog" or "epic" for an installed store game being configured, else ""
var _store_game := ""  # its id in that store
var _tso: Control  # OGUI Dropdowns: the Steam or store game's own choices
var _proton: Control
var _fixes: Control
var _online: Control
var _launch: Control
var _resolution: Control
var _driver: Control
var _api: Control
var _game_cpus: Control  # Run on fast cores, for a Steam or store game
var _values := {}  # a row's key -> what each of its items saves
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
	_fast_cores.description = "Keep the emulator on the fast CPU cores. Helps demanding systems (PS2, PS3, Wii U); PS1 does not need it. The default is set per emulator in Apps, in the main menu; whether it may also use the slow cores, in Settings > General."
	_fast_cores.item_selected.connect(_on_fast_cores_selected)
	_focus_group = focus_group_scene.instantiate() as FocusGroup
	_focus_group.focus_stack = focus_stack
	rows.add_child(_focus_group)
	rows.add_child(_fast_cores)
	_focus_group.current_focus = _fast_cores
	_screen = _rom_dropdown(rows, "Screen size", SCREEN_ABOUT, _on_screen_selected)

	_art = setting_button_scene.instantiate()
	_art.text = "Box art"
	_art.button_text = "Scrape"
	_art.description = ART_DESCRIPTION
	_art.pressed.connect(_on_scrape_art)
	rows.add_child(_art)
	_scrape.progressed.connect(func(pct: int) -> void: _art.description = "Scraping... %d%%" % pct)
	_scrape.finished.connect(_on_art_scraped)

	# In this order, so a Steam game shows FEX TSO, Launch option, Resolution, Graphics driver,
	# Graphics API, Run on fast cores, and a store game FEX TSO, Proton, Game fixes, Online,
	# Resolution, Graphics API, Run on fast cores.
	_tso = _game_dropdown("FEX TSO", TSO_ABOUT, "tso")
	_proton = _game_dropdown("Proton", PROTON_ABOUT, "proton")
	_fixes = _game_dropdown("Game fixes", FIXES_ABOUT, "protonfixes")
	_online = _game_dropdown("Online", ONLINE_ABOUT, "online")
	_launch = _game_dropdown("Launch option", "Which of the game's programs starts, as in Steam's launch dialog. Default: the one Steam last started.", "launch")
	_resolution = _game_dropdown("Resolution", "The size the game draws at; the display scales it to the panel. Default: its Game resolution in Steam, else Settings > Display.", "resolution")
	_driver = _game_dropdown("Graphics driver", DRIVER_ABOUT, "driver")
	_api = _game_dropdown("Graphics API", API_ABOUT, "api")
	_game_cpus = _game_dropdown("Run on fast cores", GAME_CPUS_ABOUT, "cpus")


func _rom_dropdown(rows: Node, title: String, description: String, selected: Callable) -> Control:
	var dropdown = dropdown_scene.instantiate()
	dropdown.title = title
	dropdown.description = description
	dropdown.item_selected.connect(selected)
	rows.add_child(dropdown)
	return dropdown


func _game_dropdown(title: String, description: String, key: String) -> Control:
	var dropdown = dropdown_scene.instantiate()
	dropdown.title = title
	dropdown.description = description
	dropdown.set_meta("about", description)
	dropdown.visible = false
	dropdown.item_selected.connect(func(index: int) -> void: _on_game_choice(key, index))
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
	_store = ""
	_store_game = ""
	if item is LibraryItem and _steam_app <= 0:
		for library_id in STORE_LIBRARY_IDS:
			var store_item = item.get_launch_item(library_id)
			if store_item and store_item.installed:
				_store = library_id.trim_prefix("retroforge-")
				_store_game = store_item.provider_app_id
				break
	var show := _item != null or _steam_app > 0 or _store != ""
	for row in [_fast_cores, _screen, _art]:
		row.visible = _item != null
	_fill_game_rows()
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
		_art.disabled = not FileAccess.file_exists(SCRAPER_DEVID) or _scrape.running
		if not _scrape.running:
			_art.description = ART_DESCRIPTION if FileAccess.file_exists(SCRAPER_DEVID) else ScrapeRunner.failure_text(9, "")
		_build_options(roms.emulator_of(_item))


## The Steam or store game's own choices, from retroforge-steam-direct or `store <s> game` (about
## half a second, so off the UI thread); the rows stay hidden for anything else. A row shows only
## when it has a choice to make (a launch option when Steam offers more than one, a Proton when
## another one is installed, a graphics API when the game's engine has more than one).
func _fill_game_rows() -> void:
	var cmd := _rows_command()
	for row in [_tso, _proton, _fixes, _online, _launch, _resolution, _driver, _api, _game_cpus]:
		row.visible = false
	if _item != null:
		_focus_group.current_focus = _fast_cores
	if cmd.is_empty() or not FileAccess.file_exists(cmd[0]):
		return
	var output: String = await _output_of(cmd[0], cmd.slice(1))
	var data = JSON.parse_string(output) if output != "" else null
	if cmd != _rows_command() or not data is Dictionary:
		return  # another game's page by now, or nothing to offer
	# select() does not emit item_selected, so loading never saves.
	if _steam_app > 0:
		_fill_steam(data)
	else:
		_fill_store(data)
	_fill_api(data)
	_fill_row(_game_cpus, "cpus", [["default", "Default (Off)"], ["on", "On"]],
		str((data.get("settings", {}) as Dictionary).get("cpus", "default")))
	_game_cpus.description = GAME_CPUS_ABOUT + (GAME_CPUS_STEAM if _steam_app > 0 else "")
	_game_cpus.visible = true
	_focus_group.current_focus = _tso
	_focus_group.recalculate_focus()


## The command that prints the game's choices: [program, args...], or [] for no Steam or store game.
func _rows_command() -> Array[String]:
	if _steam_app > 0:
		return [STEAM_DIRECT, "game", str(_steam_app)]
	if _store != "":
		return [STORE_TOOL, _store, "game", _store_game]
	return []


## row's items ([value, label] each), the one saved selected: a saved value the list no longer has
## (the display changed, a Proton was removed) stays offered, as `other`.
func _fill_row(row: Control, key: String, items: Array, mine: String, other: String = "") -> void:
	row.clear()
	var values := []
	for entry in items:
		values.append(str(entry[0]))
		row.add_item(str(entry[1]))
	if not mine in values:
		values.append(mine)
		row.add_item(other if other != "" else mine)
	_values[key] = values
	row.select(values.find(mine))


## Default, then Settings > Display's sizes (WxH, one item per size).
func _resolution_items(default_label: String) -> Array:
	var items := [["default", default_label]]
	var keys := ["default"]
	for r in DisplaySettings.RESOLUTIONS.slice(1):
		var dims: Vector2i = _display.size_for(r[0])
		var key := "%dx%d" % [dims.x, dims.y]
		if dims.x > 0 and dims.y > 0 and not key in keys:  # no size while the screen's is unknown
			keys.append(key)
			items.append([key, "%s, %d x %d" % [r[1], dims.x, dims.y]])
	return items


func _fill_steam(data: Dictionary) -> void:
	var settings: Dictionary = data.get("settings", {})
	var entries: Array = data.get("launch", [])
	var hint := str(data.get("tso_hint", ""))
	_tso.set_meta("about", TSO_ABOUT + ("" if hint == "" else " Valve runs this game with it %s on the Steam Frame." % ("On" if hint == "1" else "Off")))
	_fill_row(_tso, "tso", [["default", "Default (On)"], ["on", "On"], ["off", "Off"]], str(settings.get("tso", "default")))
	var launches := [["default", "Default (as Steam last started it)"]]
	for entry in entries:
		launches.append([str(entry.get("key", "")), str(entry.get("description", ""))])
	_fill_row(_launch, "launch", launches, str(settings.get("launch", "default")))
	var steam_size := str(data.get("steam_resolution", ""))
	var shown := _display.size_for(_display.stored_resolution())
	var mine := str(settings.get("resolution", "default"))
	_fill_row(_resolution, "resolution", _resolution_items("Default (Steam's, %s)" % steam_size.replace("x", " x ") if steam_size != ""
		else "Default (Settings > Display, %d x %d)" % [shown.x, shown.y]), mine, mine.replace("x", " x "))
	_resolution.set_meta("about", "The size the game draws at; the display scales it to the panel. Default: its Game resolution in Steam, else Settings > Display.")
	for row in [_tso, _launch, _resolution]:
		row.description = str(row.get_meta("about")) + ("" if data.get("direct", "on") == "on" else DIRECT_OFF)
	_fill_row(_driver, "driver", [["default", "Default (x86 Mesa)"], ["native", "Native"], ["x86", "x86 Mesa"]], str(settings.get("driver", "default")))
	_tso.visible = true
	_driver.visible = data.get("x86", false) == true
	_launch.visible = entries.size() > 1
	_resolution.visible = (_values["resolution"] as Array).size() > 1


func _fill_store(data: Dictionary) -> void:
	var settings: Dictionary = data.get("settings", {})
	_fill_row(_tso, "tso", [["default", "Default (On)"], ["on", "On"], ["off", "Off"]], str(settings.get("tso", "default")))
	_tso.description = STORE_TSO_ABOUT
	# Display names as Main menu > Apps > Proton shows them (proton_tool.gd): without " (RetroForge)".
	var default_name := str(data.get("default_proton", "")).trim_suffix(" (RetroForge)")
	var default_key := str(data.get("default_proton_key", ""))
	var mine := str(settings.get("proton", "default"))
	var protons := [["default", "Default (%s)" % default_name if default_name != "" else "Default"]]
	for p in data.get("protons", []):
		if p is Dictionary and (str(p.get("key", "")) != default_key or str(p.get("key", "")) == mine):
			protons.append([str(p.get("key", "")), str(p.get("name", "")).trim_suffix(" (RetroForge)")])
	_fill_row(_proton, "proton", protons, mine)
	_fill_row(_fixes, "protonfixes", [["default", "Default (On)"], ["off", "Off"]], str(settings.get("protonfixes", "default")))
	_fill_row(_online, "online", [["default", "Default (Offline)"], ["on", "Online"]], str(settings.get("online", "default")))
	var shown := _display.size_for(_display.stored_resolution())
	var size := str(settings.get("resolution", "default"))
	_fill_row(_resolution, "resolution", _resolution_items("Default (Settings > Display, %d x %d)" % [shown.x, shown.y]),
		size, size.replace("x", " x "))
	_resolution.description = STORE_RESOLUTION_ABOUT
	_tso.visible = true
	_fixes.visible = true
	_proton.visible = (_values["proton"] as Array).size() > 1
	_online.visible = data.get("online", false) == true
	_resolution.visible = (_values["resolution"] as Array).size() > 1


func _fill_api(data: Dictionary) -> void:
	var apis: Array = data.get("apis", [])
	var mine := str((data.get("settings", {}) as Dictionary).get("api", "default"))
	var items := [["default", "Default (the game's own)"]]
	for api in apis:
		items.append([str(api), API_LABELS.get(str(api), str(api))])
	_fill_row(_api, "api", items, mine, API_LABELS.get(mine, mine))
	_api.description = API_ABOUT + (API_STEAM if _steam_app > 0 else "")
	_api.visible = apis.size() > 1 or mine != "default"


## cmd's output when it exits 0, else "".
func _output_of(cmd_path: String, args: Array[String]) -> String:
	var cmd := Command.create(cmd_path, args)
	var code := -1
	if cmd.execute() == OK:
		code = await cmd.finished as int
	if code != 0:
		logger.warn("%s %s exited %d: %s" % [cmd_path, " ".join(PackedStringArray(args)), code, cmd.stderr])
	return cmd.stdout if code == 0 else ""


func _on_game_choice(key: String, index: int) -> void:
	var values: Array = _values.get(key, [])
	var base := _rows_command()
	if base.is_empty() or index < 0 or index >= values.size():
		return
	var args: Array[String] = base.slice(1)
	args.append_array(["set", key, str(values[index])])
	var cmd := Command.create(base[0], args)
	var code := -1
	if cmd.execute() == OK:
		code = await cmd.finished as int
	if code == 0:
		logger.info("%s: %s = %s" % [" ".join(PackedStringArray(base.slice(1))), key, values[index]])
		return
	logger.warn("%s set %s %s exited %d: %s" % [" ".join(PackedStringArray(base)), key, values[index], code, cmd.stderr])
	notification_manager.show(Notification.new("Could not save this game's " + key))
	if base == _rows_command():
		_fill_game_rows()


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

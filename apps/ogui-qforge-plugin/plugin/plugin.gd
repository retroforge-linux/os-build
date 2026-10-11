extends Plugin

## QForge: ROM library with one library tab per system (plan Phase 4). Prototype: the PSX tab.
##
## OpenGamepadUI's library menu only fills its own two grids (Installed, All Games); a tab added
## through library_tabs_state gets placed in the TabContainer but its grid is ours to fill. Plugins
## are initialised BEFORE the library menu is ready (PluginManager comes first in card_ui.tscn), so
## tabs are added from library_loaded, which fires after the UI's first reload_library().

const LIBRARY_ID := "qforge-roms"
## Seconds between two looks at ~/roms (rom_watch.gd): a copied ROM shows up 5-10 s after the
## copy ends.
const RESCAN_INTERVAL := 5.0

var library_manager := load("res://core/global/library_manager.tres") as LibraryManager
var launch_manager := load("res://core/global/launch_manager.tres") as LaunchManager
var input_plumber := load("res://core/systems/input/input_plumber.tres") as InputPlumberInstance
var tabs_state := load("res://core/ui/card_ui/library/library_tabs_state.tres") as TabContainerState
var menu_state_machine := load("res://assets/state/state_machines/menu_state_machine.tres") as StateMachine
var launcher_state := load("res://assets/state/states/game_launcher.tres") as State
var card_scene := load("res://core/ui/components/card.tscn") as PackedScene
var scroller_scene := load("res://core/systems/input/scroller_joystick.tscn") as PackedScene

var roms  # our Library subclass; untyped so roms.SYSTEMS resolves at runtime
## system -> {"tab": ScrollContainer, "grid": HFlowContainer}
var _tabs := {}
var _emulators_button: Control
var _emulators_page: Control
var _game_settings_page: Control
var _hardware_card: Control
var _fan_test_card: Control
## Input boost (see _input): how long the UI renders every frame after the last input.
const INPUT_BOOST_SECS := 1.5
var _boost_timer: Timer
var _display: RefCounted  # display_settings.gd
var _overlay: RefCounted  # overlay_hiding.gd
var _osk_nav: RefCounted  # osk_navigation.gd
var _touch_keyboard: RefCounted  # touch_keyboard.gd
var _buttons: RefCounted  # button_layout.gd
var _watch: RefCounted  # rom_watch.gd
var _rescan_timer: Timer
var _rescanning := false


# No _init override: Plugin._init adds the node to the "plugin" group.
func _ready() -> void:
	logger = Log.get_logger("QForge", Log.LEVEL.INFO)
	roms = load(plugin_base.path_join("library_roms.gd")).new()
	add_library(roms)
	library_manager.library_loaded.connect(_on_library_loaded)
	logger.info("ROM library registered: %s" % library_manager.has_library(LIBRARY_ID))
	_watch = load(plugin_base.path_join("rom_watch.gd")).new().setup(roms.roms_dir(), roms.SYSTEMS.keys(), roms.dir_markers())
	_rescan_timer = Timer.new()
	_rescan_timer.wait_time = RESCAN_INTERVAL
	_rescan_timer.timeout.connect(_on_rescan_timer)
	add_child(_rescan_timer)
	_rescan_timer.start()
	# The settings menu is not ready yet when plugins initialise: add our page a frame later.
	await get_tree().process_frame
	_add_emulators_page()
	_add_game_settings_page()
	_add_hardware_card()
	_apply_render_mode()
	_overlay = load(plugin_base.path_join("overlay_hiding.gd")).new().setup(get_tree())
	_osk_nav = load(plugin_base.path_join("osk_navigation.gd")).new().setup(get_tree())
	_touch_keyboard = load(plugin_base.path_join("touch_keyboard.gd")).new().setup(get_tree())
	_buttons = load(plugin_base.path_join("button_layout.gd")).new().setup(get_tree())
	if not _buttons.attach():
		logger.warn("OGUI controller settings layout not found; no Nintendo layout toggle")
	_setup_input_boost()


func unload() -> void:
	if is_instance_valid(_rescan_timer):
		_rescan_timer.stop()
	for system in _tabs.keys():
		tabs_state.remove_tab(_tab_text(system))
	_tabs.clear()
	for node in [_emulators_button, _emulators_page]:
		if is_instance_valid(node):
			node.queue_free()
	if is_instance_valid(_game_settings_page):
		_game_settings_page.detach()
	if _display:
		_display.detach()
	if _overlay:
		_overlay.detach()
	if _touch_keyboard:
		_touch_keyboard.detach()
	if _buttons:
		_buttons.detach()
	for card in [_hardware_card, _fan_test_card]:
		if is_instance_valid(card):
			var qb_card: Node = card.find_parent("QuickBarCard*")
			(qb_card if qb_card else card).queue_free()


## Game settings > QForge (the gear on a ROM's launch menu): per-game options.
func _add_game_settings_page() -> void:
	var menu: Node = get_tree().root.find_child("GameSettingsMenu", true, false)
	var page = load(plugin_base.path_join("game_settings_page.gd")).new()
	if not menu or not page.attach(menu, roms):
		page.free()
		logger.warn("OGUI game settings layout not found; no per-game QForge options")
		return
	_game_settings_page = page
	logger.info("Game settings > QForge added")


## Settings > Emulators: a button in OGUI's settings list (after Library) and its page, wired
## like the built-in ones in settings_menu.tscn -- pressing the button replaces the settings
## state with the page's own (focus moves into the page), focusing it shows the page's tab and
## sets the section title.
func _add_emulators_page() -> void:
	var settings: Node = get_tree().get_first_node_in_group("settings_menu")
	if not settings:
		logger.warn("OGUI settings menu not found; no Emulators page")
		return
	var buttons: Node = settings.find_child("SettingButtonsContainer", true, false)
	var tabs: TabContainer = settings.find_child("TabContainer", true, false) as TabContainer
	var title_box: Node = settings.find_child("TitleContainer", true, false)
	var title: Label = title_box.find_child("SectionLabel", true, false) as Label if title_box else null
	if not (buttons and tabs and title):
		logger.warn("OGUI settings menu layout not found; no Emulators page")
		return

	var page_state := State.new()
	page_state.name = "settings_qforge_emulators"
	_emulators_page = load(plugin_base.path_join("emulators_page.gd")).new()
	_emulators_page.setup(page_state)
	tabs.add_child(_emulators_page)

	_emulators_button = load("res://core/ui/components/card_button.tscn").instantiate()
	_emulators_button.name = "QForgeEmulatorsButton"
	_emulators_button.text = "Emulators"
	var push = load("res://core/systems/state/state_updater.tscn").instantiate()
	push.state_machine = load("res://assets/state/state_machines/settings_state_machine.tres")
	push.state = page_state
	push.action = 3  # StateUpdater.ACTION.REPLACE, as the built-in buttons
	push.on_signal = "button_up"
	_emulators_button.add_child(push)
	var tab_setter := TabSetter.new()
	tab_setter.target = tabs
	tab_setter.tab_number = _emulators_page.get_index()
	tab_setter.on_signal = "focus_entered"
	_emulators_button.add_child(tab_setter)
	var text_setter := TextSetter.new()
	text_setter.target = title
	text_setter.text = "Emulators"
	text_setter.on_signal = "focus_entered"
	_emulators_button.add_child(text_setter)

	var library_button := buttons.find_child("LibraryButton", false, false)
	buttons.add_child(_emulators_button)
	if library_button:
		buttons.move_child(_emulators_button, library_button.get_index() + 1)
	var focus_group := buttons.find_child("FocusGroup", false, false)
	if focus_group:
		focus_group.recalculate_focus()
	logger.info("Settings > Emulators added")


## Automatic rescan: reload our library once ~/roms changed and settled (rom_watch.gd). Never
## while a game runs, nor while our own reload is still going.
func _on_rescan_timer() -> void:
	var busy := _rescanning or not launch_manager.get_running().is_empty()
	if not _watch.poll(busy):
		return
	logger.info("ROM folders changed: rescanning")
	_rescanning = true
	library_manager.load_library(LIBRARY_ID)


func _on_library_loaded(library_id: String) -> void:
	if library_id != LIBRARY_ID:
		return
	# Any load counts (start, Refresh Library, ours): it read what is on disk now.
	_watch.mark_loaded()
	_rescanning = false
	for system in roms.SYSTEMS:
		_refresh_system(system)


## Library items whose qforge-roms launch item belongs to the given system, sorted by name.
func _items_for(system: String) -> Array[LibraryItem]:
	var items: Array[LibraryItem] = []
	for item in library_manager.get_library_items():
		var launch := item.get_launch_item(LIBRARY_ID)
		if launch and system in launch.tags:
			items.append(item)
	return items


func _refresh_system(system: String) -> void:
	var items := _items_for(system)
	if items.is_empty():
		if system in _tabs:
			tabs_state.remove_tab(_tab_text(system))
			_tabs.erase(system)
		return
	if not system in _tabs:
		_tabs[system] = _make_tab()
		tabs_state.add_tab(_tab_text(system), _tabs[system]["tab"])
	var started := Time.get_ticks_msec()
	var grid: HFlowContainer = _tabs[system]["grid"]
	for child in grid.get_children():
		child.queue_free()
	for item in items:
		grid.add_child(await _build_card(item))
	logger.info("%s tab: %d game(s), cards built in %d ms" % [_tab_text(system), items.size(), Time.get_ticks_msec() - started])


func _tab_text(system: String) -> String:
	return roms.SYSTEMS[system]["name"]


## Same node layout as the library menu's AllGamesTab: library_menu.gd focuses the first card of a
## tab through get_child(1).get_child(0), so ScrollerJoystick first, then MarginContainer > grid.
func _make_tab() -> Dictionary:
	var tab := ScrollContainer.new()
	tab.visible = false
	tab.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	tab.add_child(scroller_scene.instantiate())
	var margin := MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_theme_constant_override("margin_left", 15)
	margin.add_theme_constant_override("margin_top", 100)
	margin.add_theme_constant_override("margin_right", 15)
	tab.add_child(margin)
	var grid := HFlowContainer.new()
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 26)
	grid.add_theme_constant_override("v_separation", 16)
	grid.alignment = FlowContainer.ALIGNMENT_CENTER
	margin.add_child(grid)
	return {"tab": tab, "grid": grid}


## As library_menu.gd's _build_card: pressing the card opens OGUI's game launch menu.
func _build_card(item: LibraryItem) -> Control:
	var card = card_scene.instantiate()
	await card.set_library_item(item)
	var on_button_up := func():
		launcher_state.data = {"item": item}
		menu_state_machine.push_state(launcher_state)
	card.button_up.connect(on_button_up)
	return card


## Quick bar > Hardware: the board's battery, temperatures, fan, clocks, backlight and LED
## groups, read from the standard tree /run/qforge/hw that /usr/lib/qforge/hw-map resolves from
## the board profile -- the one path every board exposes them at, so this card has no per-board
## code. Rows the map did not resolve stay hidden.
func _add_hardware_card() -> void:
	var card = load(plugin_base.path_join("hardware_card.gd")).new()
	card.setup(plugin_base)
	var icon := load("res://assets/ui/icons/battery-full.svg") as Texture2D
	# Straight to the quick bar with an explicit title, NOT Plugin.add_to_quick_bar: that passes no
	# title, so add_child_menu falls back to find_child("SectionLabel") and frees what it finds,
	# which on a code-built card either throws on null or frees a live node (OGUI SIGSEGV, Air X).
	var qb := get_tree().get_first_node_in_group("quick-bar")
	if not qb:
		card.free()
		logger.warn("OGUI quick bar not found; no Hardware card")
		return
	qb.add_child_menu(card, icon, null, "Hardware")
	_hardware_card = card
	logger.info("Quick bar > Hardware added")
	var fan_card = load(plugin_base.path_join("fan_test_card.gd")).new()
	fan_card.setup(plugin_base)
	qb.add_child_menu(fan_card, icon, null, "Fan test")
	_fan_test_card = fan_card
	logger.info("Quick bar > Fan test added")


## Settings > Display: Game resolution and Reduced UI resolution (display_settings.gd). The stored
## choices (or the board profile's defaults) are applied at startup whether or not the menu exists.
func _apply_render_mode() -> void:
	_display = load(plugin_base.path_join("display_settings.gd")).new()
	_display.apply_all(get_tree())
	if _display.attach():
		logger.info("Settings > Display: game resolution added")
	else:
		logger.warn("OGUI display settings layout not found; resolution settings not shown")


## OpenGamepadUI runs in Godot's low-processor mode, which draws only when something changed --
## the reason the idle shell costs nothing. It also paces animations: menu and card transitions
## reached the screen at ~35 fps on the Air X however cheap each frame was, and at 60+ with the
## mode off. So for INPUT_BOOST_SECS after every input event the mode is off (transitions run at
## the display rate), then back on (the idle shell draws nothing again).
func _setup_input_boost() -> void:
	_boost_timer = Timer.new()
	_boost_timer.one_shot = true
	_boost_timer.wait_time = INPUT_BOOST_SECS
	_boost_timer.timeout.connect(func(): OS.low_processor_usage_mode = true)
	add_child(_boost_timer)
	# Idle main-loop pacing. In low-processor mode Godot still wakes every
	# low_processor_usage_mode_sleep_usec (6.9 ms by default, ~145 times a second) and runs every
	# node's _process -- OGUI's main thread cost ~13% of a core on the Air X doing nothing. 16.7 ms
	# in the menus keeps a 60 Hz input response; 50 ms while a game covers the shell, where the
	# shell only has to notice the Guide button. Input still switches to full rate (above).
	var in_game_state := load("res://assets/state/states/in_game.tres") as State
	in_game_state.state_entered.connect(func(_from): _set_in_game(true))
	in_game_state.state_exited.connect(func(_to): _set_in_game(false))
	_set_idle_pacing(false)
	# The gamepad reaches OGUI as InputPlumber D-Bus signals, which OGUI turns into a chain of
	# Godot input events, one main-loop pass per hop (Guide -> ogui_guide -> ogui_menu -> state).
	# OGUI marks those events handled, so _input below never sees them and every hop slept the
	# full idle pace -- the in-game menu took ~200 ms of sleeping to open (Air Y, 2026-10-11).
	# Boost from the signal itself: the pass that receives it no longer sleeps.
	for device in input_plumber.get_composite_devices():
		_watch_input_plumber(device)
	input_plumber.composite_device_added.connect(_watch_input_plumber)


func _watch_input_plumber(device) -> void:
	for target in device.dbus_devices:
		if not target.input_event.is_connected(_on_input_plumber_event):
			target.input_event.connect(_on_input_plumber_event)


## Runs inside InputPlumberInstance.process(), which is bound while it emits: nothing here may
## reach code that calls back into it. The pointer park injects an input event (every _input
## handler runs), so it goes after process() returns.
func _on_input_plumber_event(event: String, value: float) -> void:
	_boost()
	if _touch_keyboard:
		_touch_keyboard.pointer_left.call_deferred()
	if event == "ui_guide" and value == 1.0 and _overlay:
		_overlay.expect_ui()


## The in-game state is current only while the game has the foreground: opening the quick bar
## or the in-game menu over it pushes another state (state_exited), closing it re-enters.
func _set_in_game(in_game: bool) -> void:
	_set_idle_pacing(in_game)
	if _display:
		_display.set_backgrounded(in_game)
	if _overlay:
		_overlay.set_in_game(in_game)


const IDLE_SLEEP_MENU_USEC := 16666
const IDLE_SLEEP_IN_GAME_USEC := 50000

func _set_idle_pacing(in_game: bool) -> void:
	OS.low_processor_usage_mode_sleep_usec = IDLE_SLEEP_IN_GAME_USEC if in_game else IDLE_SLEEP_MENU_USEC


func _input(event: InputEvent) -> void:
	if _touch_keyboard:
		_touch_keyboard.note_input(event)
	if _boost_timer == null:
		return
	if event is InputEventMouseMotion and (event as InputEventMouseMotion).relative.length() < 1.0:
		return
	if event is InputEventJoypadMotion and absf((event as InputEventJoypadMotion).axis_value) < 0.2:
		return
	_boost()


func _boost() -> void:
	if _boost_timer == null:
		return
	OS.low_processor_usage_mode = false
	_boost_timer.start()

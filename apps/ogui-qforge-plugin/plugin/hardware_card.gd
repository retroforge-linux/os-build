extends VBoxContainer
## Quick bar > Hardware: what the board reports, live, from the standard tree /run/qforge/hw
## (/usr/lib/qforge/hw-map). One row per thing the board has: battery, charger, temperatures,
## fan, clocks, backlight, LED groups. Rows for hardware the map did not resolve are hidden, so
## the card is the same code on every board.
##
## The plugin hands this to the quick bar with an explicit title (add_child_menu's 4th argument), so
## the quick bar never goes looking for a SectionLabel child to read and free: that lookup crashed
## OGUI when the label was found (the label freed mid-call) and threw when it was not (null base).
## Refreshes every REFRESH_SECS while the quick bar shows it; idle otherwise.
##
## Under the LED row: on/off, brightness and colour for the board's LEDs, through qforge-powerd
## (power_client.gd), which keeps the setting. Hidden on a board whose powerd reports no LEDs.
## The controls carry OGUI FocusGroups on the quick bar's focus stack: the quick bar card hands
## gamepad focus to the first FocusGroup it finds in its content when A opens it. Without one, A
## only expanded the card and moving down left it (and closed the menu).

const FOCUS_GROUP := "res://core/systems/input/focus_group.tscn"
const QB_FOCUS_STACK := "res://core/ui/card_ui/quick_bar/quick_bar_menu_focus.tres"


## An OGUI FocusGroup over `container`'s focusable children, on the quick bar's focus stack.
static func add_focus_group(container: Control) -> Node:
	var group: Node = (load(FOCUS_GROUP) as PackedScene).instantiate()
	group.set("focus_stack", load(QB_FOCUS_STACK))
	container.add_child(group)
	return group

const REFRESH_SECS := 2.0
const ROWS := [
	["battery", "Battery"],
	["charger", "Charger"],
	["thermal", "Temperatures"],
	["fan", "Fan"],
	["clocks", "Clocks"],
	["backlight", "Backlight"],
	["leds", "LEDs"],
	["device", "Board"],
]

var info  # hardware_info.gd
var _values := {}  # row key -> value Label
var _rows := {}    # row key -> row container
var _timer: Timer
var power  # power_client.gd
var _led_box: VBoxContainer
var _led_toggle: Control  # OGUI Toggle
var _led_slider: Control  # OGUI ValueSlider
var _led_debounce: Timer
var _led_syncing := false

const LED_COLORS := [
	["Blue", [0, 96, 255]], ["Cyan", [0, 200, 255]], ["Green", [0, 255, 64]],
	["Purple", [160, 0, 255]], ["Red", [255, 0, 0]], ["Orange", [255, 96, 0]], ["White", [255, 255, 255]],
]


## Load the reader from the plugin's own folder (OGUI mounts the plugin zip at res://plugins/<id>).
func setup(plugin_base: String, hw_root: String = "") -> void:
	info = load(plugin_base.path_join("hardware_info.gd")).new()
	if hw_root != "":
		info.root = hw_root
	power = load(plugin_base.path_join("power_client.gd")).new()


func _ready() -> void:
	name = "QForgeHardware"
	add_theme_constant_override("separation", 6)
	for row in ROWS:
		var box := VBoxContainer.new()
		box.name = row[0].capitalize()
		box.add_theme_constant_override("separation", 0)
		var key := Label.new()
		key.text = row[1]
		key.add_theme_font_size_override("font_size", 14)
		key.modulate = Color(1, 1, 1, 0.7)
		var value := Label.new()
		value.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		value.text = "—"
		box.add_child(key)
		box.add_child(value)
		add_child(box)
		_rows[row[0]] = box
		_values[row[0]] = value
		if row[0] == "leds":
			_led_box = _build_led_controls()
			add_child(_led_box)
	_timer = Timer.new()
	_timer.wait_time = REFRESH_SECS
	_timer.autostart = true
	_timer.timeout.connect(refresh)
	add_child(_timer)
	visibility_changed.connect(refresh)
	visibility_changed.connect(_sync_leds)
	refresh()
	_sync_leds()


func _build_led_controls() -> VBoxContainer:
	var box := VBoxContainer.new()
	box.name = "LedControls"
	box.visible = false
	_led_toggle = (load("res://core/ui/components/toggle.tscn") as PackedScene).instantiate()
	_led_toggle.text = "Lights"
	box.add_child(_led_toggle)
	_led_toggle.toggled.connect(func(on: bool):
		if not _led_syncing and power:
			power.set_led_enabled(on))
	# OGUI's slider applies its value before its range in _ready and reports the clamp as a change:
	# add it first and only listen afterwards, or merely building the card writes a brightness.
	_led_slider = (load("res://core/ui/components/slider.tscn") as PackedScene).instantiate()
	_led_slider.text = "Brightness"
	box.add_child(_led_slider)
	_led_slider.min_value = 0
	_led_slider.max_value = 100
	_led_slider.step = 5
	_led_debounce = Timer.new()
	_led_debounce.one_shot = true
	_led_debounce.wait_time = 0.25
	_led_debounce.timeout.connect(func():
		if power:
			power.set_led_brightness(int(round(_led_slider.value * 255.0 / 100.0))))
	box.add_child(_led_debounce)
	_led_slider.value_changed.connect(func(_v: float):
		if not _led_syncing:
			_led_debounce.start())
	var colors := HFlowContainer.new()
	for entry in LED_COLORS:
		var button := Button.new()
		button.focus_mode = Control.FOCUS_ALL
		button.custom_minimum_size = Vector2(44, 44)
		button.tooltip_text = entry[0]
		var swatch := StyleBoxFlat.new()
		swatch.bg_color = Color8(entry[1][0], entry[1][1], entry[1][2])
		swatch.set_corner_radius_all(22)
		for state in ["normal", "hover", "pressed"]:
			button.add_theme_stylebox_override(state, swatch)
		var rgb: Array = entry[1]
		button.pressed.connect(func():
			if power:
				power.set_led_color(rgb))
		colors.add_child(button)
	box.add_child(colors)
	var controls_group := add_focus_group(box)
	# first child: the quick bar card focuses the FIRST FocusGroup its depth-first search meets,
	# and the swatches' group (inside the HFlow) must not be it
	box.move_child(controls_group, 0)
	var colors_group := add_focus_group(colors)
	controls_group.set("focus_neighbor_bottom", colors_group)
	colors_group.set("focus_neighbor_top", controls_group)
	return box


## Read the setting back from powerd when the card shows; hide the controls without LEDs.
func _sync_leds() -> void:
	if _led_box == null or power == null or not is_visible_in_tree():
		return
	var led: Dictionary = power.get_led()
	_led_box.visible = led.get("count", 0) > 0
	if not _led_box.visible:
		return
	_led_syncing = true
	_led_toggle.button_pressed = led["enabled"]
	_led_slider.value = clampf(round(led["brightness"] * 100.0 / 255.0), 0, 100)
	_led_syncing = false


func refresh() -> void:
	if info == null or not is_visible_in_tree():
		return
	var d: Dictionary = info.snapshot()
	_set("battery", info.format_battery(d["battery"]) if d.has("battery") else "")
	var charger := ""
	if d.has("charger"):
		charger = "Connected" if d["charger"]["online"] else "Not connected"
		if d["charger"].get("status", "") not in ["", "Unknown"]:
			charger += " · " + str(d["charger"]["status"])
	_set("charger", charger)
	_set("thermal", info.format_temps(d["thermal"]) if d.has("thermal") else "")
	_set("fan", ("%d rpm" % d["fan_rpm"]) if d.has("fan_rpm") else "")
	_set("clocks", info.format_clocks(d))
	var bl := ""
	if d.has("backlight") and d["backlight"].get("brightness") != null and d["backlight"].get("max") != null and int(d["backlight"]["max"]) > 0:
		bl = "%d%% (%d / %d)" % [int(round(100.0 * float(d["backlight"]["brightness"]) / float(d["backlight"]["max"]))), d["backlight"]["brightness"], d["backlight"]["max"]]
	_set("backlight", bl)
	var leds := []
	if d.has("leds"):
		for group in d["leds"].keys():
			leds.append("%s ×%d" % [group, d["leds"][group]])
	_set("leds", ", ".join(leds))
	var dev: Dictionary = d.get("device", {})
	var board := str(dev.get("name", ""))
	if dev.get("soc", "") != "":
		board += " · " + str(dev["soc"])
	_set("device", board)


func _set(key: String, text: String) -> void:
	_values[key].text = text
	_rows[key].visible = text != ""

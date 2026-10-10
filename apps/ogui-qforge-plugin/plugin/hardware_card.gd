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


## Load the reader from the plugin's own folder (OGUI mounts the plugin zip at res://plugins/<id>).
func setup(plugin_base: String, hw_root: String = "") -> void:
	info = load(plugin_base.path_join("hardware_info.gd")).new()
	if hw_root != "":
		info.root = hw_root


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
	_timer = Timer.new()
	_timer.wait_time = REFRESH_SECS
	_timer.autostart = true
	_timer.timeout.connect(refresh)
	add_child(_timer)
	visibility_changed.connect(refresh)
	refresh()


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

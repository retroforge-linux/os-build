extends RefCounted
## The plugin's one way to qforge-powerd (org.qforge.Power1 on the system bus): the daemon that owns
## the board's fan and LEDs, found through the hardware map (docs/hardware-map.md). The UI never
## touches sysfs for them, so it is the same on every board -- a board without LEDs reports
## LedCount 0 and the controls stay hidden.
##
## busctl, because OGUI has no generic D-Bus client. Reads block (one short call when the quick
## bar shows); writes run as a separate process so the UI never waits on them.

const DEST := ["--system", "org.qforge.Power", "/org/qforge/Power", "org.qforge.Power1"]


## {count, enabled, color: [r, g, b], brightness}, or {} when powerd is not there.
func get_led() -> Dictionary:
	var out := []
	var args := ["--system", "get-property", "org.qforge.Power", "/org/qforge/Power", "org.qforge.Power1",
		"LedCount", "LedEnabled", "LedColor", "LedBrightness"]
	if OS.execute("busctl", args, out, true) != 0 or out.is_empty():
		return {}
	return parse_led("".join(out))


## busctl prints one property per line: "u 10", "b true", "au 3 0 96 255", "u 64".
static func parse_led(text: String) -> Dictionary:
	var lines := text.strip_edges().split("\n")
	if lines.size() < 4:
		return {}
	var count := lines[0].split(" ")
	var enabled := lines[1].split(" ")
	var color := lines[2].split(" ")
	var brightness := lines[3].split(" ")
	if count.size() < 2 or enabled.size() < 2 or color.size() < 5 or brightness.size() < 2:
		return {}
	return {
		"count": int(count[1]),
		"enabled": enabled[1] == "true",
		"color": [int(color[2]), int(color[3]), int(color[4])],
		"brightness": int(brightness[1]),
	}


## {test, pwm, temp, mode} -- FanTest is "" when the curve runs; {} without powerd.
func get_fan() -> Dictionary:
	var out := []
	var args := ["--system", "get-property", "org.qforge.Power", "/org/qforge/Power", "org.qforge.Power1",
		"FanTest", "FanPwm", "Temperature", "FanMode"]
	if OS.execute("busctl", args, out, true) != 0 or out.is_empty():
		return {}
	return parse_fan("".join(out))


## busctl lines: 's "40% at 25 Hz (software PWM)"', "u 0", "u 57", 's "managed"'.
static func parse_fan(text: String) -> Dictionary:
	var lines := text.strip_edges().split("\n")
	if lines.size() < 4:
		return {}
	var unquote := func(line: String) -> String:
		var v := line.substr(2).strip_edges()
		return v.trim_prefix("\"").trim_suffix("\"")
	return {
		"test": unquote.call(lines[0]),
		"pwm": int(lines[1].split(" ")[-1]),
		"temp": int(lines[2].split(" ")[-1]),
		"mode": unquote.call(lines[3]),
	}


func fan_test_start(duty_percent: int, hz: int) -> void:
	OS.create_process("busctl", ["--system", "call", "org.qforge.Power", "/org/qforge/Power",
		"org.qforge.Power1", "FanTestStart", "uu", str(clampi(duty_percent, 0, 100)), str(clampi(hz, 1, 500))])


func fan_test_stop() -> void:
	OS.create_process("busctl", ["--system", "call", "org.qforge.Power", "/org/qforge/Power",
		"org.qforge.Power1", "FanTestStop"])


func set_led_enabled(on: bool) -> void:
	_write("LedEnabled", ["b", "true" if on else "false"])


func set_led_color(rgb: Array) -> void:
	_write("LedColor", ["au", "3", str(rgb[0]), str(rgb[1]), str(rgb[2])])


func set_led_brightness(level: int) -> void:
	_write("LedBrightness", ["u", str(clampi(level, 0, 255))])


func _write(prop: String, value: Array) -> void:
	var args := ["--system", "set-property", "org.qforge.Power", "/org/qforge/Power", "org.qforge.Power1", prop]
	args.append_array(value)
	OS.create_process("busctl", args)

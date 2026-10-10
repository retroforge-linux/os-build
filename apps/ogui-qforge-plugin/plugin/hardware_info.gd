extends RefCounted
## QForge hardware info: one reader for the board's battery, charger, temperatures, fan, clocks,
## backlight and LED groups, from the standard tree /usr/lib/qforge/hw-map resolves into
## /run/qforge/hw (links into sysfs, so every value is live). Nothing here is board-specific: a
## new board only needs its hw-map profile right, and this card shows whatever it resolved.
##
## Pure GDScript (no OGUI types), so tests/test-plugin.sh can run it in a stock headless Godot
## against a fabricated tree (set `root` after new()).

const DEFAULT_ROOT := "/run/qforge/hw"
const THERMAL_ROLES := ["cpu", "gpu", "battery", "skin"]

## The tree to read; tests point it at a fabricated one. (No _init override: the plugin lint
## forbids it, see tests/test-plugin.sh.)
var root: String = DEFAULT_ROOT


## First line of a file, stripped; "" when it cannot be read. sysfs reports a 4 KiB length for
## every attribute, so this reads what is there and stops.
static func read_text(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var line := f.get_line()
	f.close()
	return line.strip_edges()


## An integer attribute under the tree, or null when absent or not a number.
func read_int(rel: String) -> Variant:
	var s := read_text(root.path_join(rel))
	if s == "" or not s.is_valid_int():
		return null
	return int(s)


func read_str(rel: String) -> String:
	return read_text(root.path_join(rel))


func has(rel: String) -> bool:
	var p := root.path_join(rel)
	return DirAccess.dir_exists_absolute(p) or FileAccess.file_exists(p)


## Subdirectory names (links count), sorted.
func list_dirs(rel: String) -> PackedStringArray:
	var d := DirAccess.open(root.path_join(rel))
	if d == null:
		return PackedStringArray()
	var names := d.get_directories()
	names.sort()
	return names


## hw.env: KEY=value lines, values quoted by printf %q ('...' or backslash-escaped spaces).
func env() -> Dictionary:
	var out := {}
	var f := FileAccess.open(root.path_join("hw.env"), FileAccess.READ)
	if f == null:
		return out
	while not f.eof_reached():
		var line := f.get_line().strip_edges()
		if line == "" or line.begins_with("#") or not line.contains("="):
			continue
		var key := line.get_slice("=", 0)
		var value := line.substr(key.length() + 1)
		if value.length() >= 2 and value.begins_with("'") and value.ends_with("'"):
			value = value.substr(1, value.length() - 2)
		elif value.length() >= 3 and value.begins_with("$'") and value.ends_with("'"):
			value = value.substr(2, value.length() - 3)
		value = value.replace("\\ ", " ").replace("\\'", "'")
		out[key] = value
	f.close()
	return out


## Everything the tree knows right now. Absent hardware is absent from the dictionary (no
## "battery" key when the board resolved none), so a view can hide the row.
func snapshot() -> Dictionary:
	var d := {}
	var e := env()
	d["device"] = {
		"id": e.get("QFORGE_DEVICE_ID", ""),
		"name": e.get("QFORGE_DEVICE_NAME", ""),
		"soc": e.get("QFORGE_SOC_CLASS", ""),
	}
	if has("battery"):
		var b := {
			"capacity": read_int("battery/capacity"),
			"status": read_str("battery/status"),
			"health": read_str("battery/health"),
			"technology": read_str("battery/technology"),
			"voltage_uv": read_int("battery/voltage_now"),
			"current_ua": read_int("battery/current_now"),
			"temp_deci_c": read_int("battery/temp"),
			"cycles": read_int("battery/cycle_count"),
			"charge_full_uah": read_int("battery/charge_full"),
			"charge_design_uah": read_int("battery/charge_full_design"),
		}
		d["battery"] = b
	if has("charger"):
		d["charger"] = {
			"online": read_int("charger/online") == 1,
			"status": read_str("charger/status"),
		}
	var temps := {}
	for role in THERMAL_ROLES:
		var t: Variant = read_int("thermal/%s/temp" % role)
		if t != null:
			temps[role] = float(t) / 1000.0
	var all := {}
	for zone in list_dirs("thermal/all"):
		var t: Variant = read_int("thermal/all/%s/temp" % zone)
		if t != null:
			all[zone] = float(t) / 1000.0
	if not temps.is_empty() or not all.is_empty():
		d["thermal"] = {"roles": temps, "all": all}
	var rpm: Variant = read_int("fan/fan1_input")
	if rpm != null:
		d["fan_rpm"] = rpm
	if has("gpu"):
		d["gpu"] = {
			"cur_mhz": _mhz(read_int("gpu/cur_freq"), 1000000),
			"min_mhz": _mhz(read_int("gpu/min_freq"), 1000000),
			"max_mhz": _mhz(read_int("gpu/max_freq"), 1000000),
		}
	var policies := []
	for pol in list_dirs("cpu/cpufreq"):
		if not pol.begins_with("policy"):
			continue
		policies.append({
			"policy": pol,
			"cpus": read_str("cpu/cpufreq/%s/related_cpus" % pol),
			"cur_mhz": _mhz(read_int("cpu/cpufreq/%s/scaling_cur_freq" % pol), 1000),
			"max_mhz": _mhz(read_int("cpu/cpufreq/%s/scaling_max_freq" % pol), 1000),
		})
	if not policies.is_empty():
		d["cpu"] = policies
	if has("backlight"):
		d["backlight"] = {
			"brightness": read_int("backlight/brightness"),
			"max": read_int("backlight/max_brightness"),
		}
	var leds := {}
	for group in list_dirs("leds"):
		leds[group] = list_dirs("leds/%s" % group).size()
	if not leds.is_empty():
		d["leds"] = leds
	return d


static func _mhz(v: Variant, per_mhz: int) -> Variant:
	if v == null:
		return null
	return int(round(float(v) / per_mhz))


# --- Formatting, one line per row of the card -----------------------------------------------

## "100% · Full · 4.38 V · 0.00 W · 23 °C · Good · 24 cycles · 88% of design"
static func format_battery(b: Dictionary) -> String:
	var parts := []
	if b.get("capacity") != null:
		parts.append("%d%%" % b["capacity"])
	if b.get("status", "") != "":
		parts.append(str(b["status"]))
	var v: Variant = b.get("voltage_uv")
	var i: Variant = b.get("current_ua")
	if v != null:
		parts.append("%.2f V" % (float(v) / 1e6))
	if v != null and i != null:
		var w := absf(float(v) * float(i) / 1e12)
		var flow := ""
		if i != 0:
			flow = " in" if _charging(b) else " out"
		parts.append("%.2f W%s" % [w, flow])
	if b.get("temp_deci_c") != null:
		parts.append("%d °C" % int(round(float(b["temp_deci_c"]) / 10.0)))
	if b.get("health", "") != "" and b["health"] != "Unknown":
		parts.append(str(b["health"]))
	if b.get("cycles") != null and int(b["cycles"]) > 0:
		parts.append("%d cycles" % b["cycles"])
	var full: Variant = b.get("charge_full_uah")
	var design: Variant = b.get("charge_design_uah")
	if full != null and design != null and int(design) > 0:
		parts.append("%d%% of design" % int(round(100.0 * float(full) / float(design))))
	return " · ".join(parts)


static func _charging(b: Dictionary) -> bool:
	var status := str(b.get("status", ""))
	if status == "Charging" or status == "Full":
		return true
	if status == "Discharging":
		return false
	# No status: the kernel's convention is current_now > 0 while charging.
	return int(b.get("current_ua", 0)) > 0


## "CPU 54 °C · GPU 48 °C · Battery 23 °C" from the roles, with the hottest cpu* zone when the
## board has several (per core or per cluster) so a single hot core is not hidden.
static func format_temps(t: Dictionary) -> String:
	var roles: Dictionary = t.get("roles", {})
	var all: Dictionary = t.get("all", {})
	var parts := []
	var cpu_max := -1000.0
	for zone in all.keys():
		if str(zone).begins_with("cpu"):
			cpu_max = maxf(cpu_max, float(all[zone]))
	if cpu_max > -1000.0 or roles.has("cpu"):
		var c: float = maxf(cpu_max, float(roles.get("cpu", -1000.0)))
		parts.append("CPU %d °C" % int(round(c)))
	for role in [["gpu", "GPU"], ["battery", "Battery"], ["skin", "Skin"]]:
		if roles.has(role[0]):
			parts.append("%s %d °C" % [role[1], int(round(float(roles[role[0]])))])
	return " · ".join(parts)


## "GPU 320 / 1050 MHz · CPU 1017 / 2016, 1056 / 2112 MHz"
static func format_clocks(d: Dictionary) -> String:
	var parts := []
	if d.has("gpu"):
		var g: Dictionary = d["gpu"]
		if g.get("cur_mhz") != null:
			var s := "GPU %d" % g["cur_mhz"]
			if g.get("max_mhz") != null:
				s += " / %d" % g["max_mhz"]
			parts.append(s + " MHz")
	if d.has("cpu"):
		var pol := []
		for p in d["cpu"]:
			if p.get("cur_mhz") == null:
				continue
			var s := "%d" % p["cur_mhz"]
			if p.get("max_mhz") != null:
				s += " / %d" % p["max_mhz"]
			pol.append(s)
		if not pol.is_empty():
			parts.append("CPU " + ", ".join(pol) + " MHz")
	return " · ".join(parts)

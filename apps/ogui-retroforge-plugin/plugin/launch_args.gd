extends RefCounted

## retroforge-launch's command line for a ROM, the key a ROM's options are saved under, and the
## player confs retroforge-launch reads. No OGUI types, so tests/test-plugin.sh can run them in a
## stock Godot.
##
## The player's choices live in two confs of `KEY=value` lines (the last line of a key wins), read
## by retroforge-launch at each start (emuopts):
##   - per emulator, Main menu > Apps: ~/.config/retroforge/emulators/<emu>.conf (Open included);
##   - per game, Game settings > RetroForge: ~/.config/retroforge/games/<system>/<rom file>.conf.
## "Run on fast cores" is CPUS=big|all in either; no line in the game's conf = the emulator's default.

const LAUNCH_CONF := "/etc/retroforge/launch.conf"
const CPUS_VALUES := ["big", "all"]
const SCREEN_KEY := "SCREEN"  # a game's games display size, WxH (retroforge-launch: window_size)


## A ROM's identity for per-game options: "<system>/<file name>". Not the card name, which
## changes when a same-named ROM appears (rom_names.gd).
static func rom_id(system: String, path: String) -> String:
	return system + "/" + _rom_file(path)


## The ROM's file name (a folder's name for a PS3 dump), as retroforge-launch names its game conf.
static func _rom_file(path: String) -> String:
	return path.trim_suffix("/").get_file()


## Arguments for retroforge-launch. An array, not a command line: a ROM path with spaces stays one
## argument. Every choice is in the confs, so a card never needs rewriting when one changes.
static func for_rom(system: String, path: String) -> PackedStringArray:
	return PackedStringArray([system, path])


## The emulator launch.conf maps a system to ("" if none). Same rule as retroforge-launch: a
## `system=emulator` line, the last one wins.
static func emulator_for(system: String, launch_conf: String) -> String:
	var emulator := ""
	var line_re := RegEx.create_from_string("^" + system + "=([a-z0-9_-]+)\\s*$")
	for line in launch_conf.split("\n"):
		var m := line_re.search(line)
		if m:
			emulator = m.get_string(1)
	return emulator


## A conf's value for key ("" when unset), read the way retroforge-launch reads it: the last line.
static func conf_value(conf: String, key: String) -> String:
	var value := ""
	for line in conf.split("\n"):
		if line.begins_with(key + "="):
			value = line.trim_prefix(key + "=")
	return value


## The CPUS value of a conf: "big", "all", or "" when unset or not one of those.
static func conf_cpus(conf: String) -> String:
	var value := conf_value(conf, "CPUS")
	return value if value in CPUS_VALUES else ""


## The conf with key set to value: every key= line replaced by one, other lines kept. An empty
## value removes the key (the level above decides).
static func conf_with(conf: String, key: String, value: String) -> String:
	var lines := PackedStringArray()
	for line in conf.split("\n"):
		if line != "" and not line.begins_with(key + "="):
			lines.append(line)
	if value != "":
		lines.append(key + "=" + value)
	return "\n".join(lines) + "\n" if not lines.is_empty() else ""


static func _config_dir() -> String:
	var config := OS.get_environment("XDG_CONFIG_HOME")
	if config == "":
		config = OS.get_environment("HOME").path_join(".config")
	return config.path_join("retroforge")


## Where retroforge-launch looks for the player's settings of an emulator.
static func player_conf_path(emulator: String) -> String:
	return _config_dir().path_join("emulators/%s.conf" % emulator)


## Where retroforge-launch looks for a game's own settings.
static func game_conf_path(system: String, path: String) -> String:
	return _config_dir().path_join("games/%s/%s.conf" % [system, _rom_file(path)])


static func read_text(path: String) -> String:
	return FileAccess.get_file_as_string(path) if FileAccess.file_exists(path) else ""


## The player's fast-cores default for an emulator: true when its conf says CPUS=big.
static func emulator_fast_cores(emulator: String) -> bool:
	return conf_cpus(read_text(player_conf_path(emulator))) == "big"


## Save the player's fast-cores default for an emulator. False when the file could not be written.
static func set_emulator_fast_cores(emulator: String, on: bool) -> bool:
	return set_conf_value(player_conf_path(emulator), "CPUS", "big" if on else "all")


## A game's fast-cores override: "" (the emulator's default), "big" or "all".
static func game_cpus(system: String, path: String) -> String:
	return conf_cpus(read_text(game_conf_path(system, path)))


## Save a game's fast-cores override ("" = the emulator's default). False when it could not be written.
static func set_game_cpus(system: String, path: String, cpus: String) -> bool:
	return set_conf_value(game_conf_path(system, path), "CPUS", cpus if cpus in CPUS_VALUES else "")


## A game's own value for key ("" when unset): SCREEN_KEY.
static func game_value(system: String, path: String, key: String) -> String:
	return conf_value(read_text(game_conf_path(system, path)), key)


## Save a game's own value for key ("" removes it). False when it could not be written.
static func set_game_value(system: String, path: String, key: String, value: String) -> bool:
	return set_conf_value(game_conf_path(system, path), key, value)


## Set key=value in a conf ("" removes it). Written to a temporary file and renamed over the conf,
## so a full disk or a power cut never leaves it half written. False when it could not be written.
static func set_conf_value(path: String, key: String, value: String) -> bool:
	var text := conf_with(read_text(path), key, value)
	if text == "":  # nothing left: no empty conf for a game that only has defaults
		return not FileAccess.file_exists(path) or DirAccess.remove_absolute(path) == OK
	if DirAccess.make_dir_recursive_absolute(path.get_base_dir()) != OK:
		return false
	var tmp := path + ".part"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if not f:
		return false
	var written := f.store_string(text)
	f.close()
	if not written or DirAccess.rename_absolute(tmp, path) != OK:
		DirAccess.remove_absolute(tmp)
		return false
	return true

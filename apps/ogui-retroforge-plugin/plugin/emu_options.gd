extends RefCounted

## Per-emulator options (renderer, resolution, aspect...) for the plugin's pages: what the image's
## options.json offers, and the player's choice at each level. No OGUI types, so tests/test-plugin.sh
## can run them in a stock Godot.
##
## retroforge-launch (emuopts) is what applies a choice and checks options.json in full (files,
## actions, every choice writing the same settings); tests/test-emuopts.sh loads every options.json
## the image ships through those checks. This reads what the pages show -- each option's id, label,
## description and choices (value + label) -- and holds them to the launcher's rules on those, so a
## page never saves a line the launcher would not read as that option's value.
## A choice is a `<id>=<value>` line in a player conf (launch_args.gd), the same files as CPUS:
##   - Main menu > Apps: the emulator's conf. No line = "Emulator's setting": RetroForge leaves
##     the emulator's own setting alone (what the player set in the emulator's UI applies). An option
##     with a "default" has no such item: no line = that choice.
##   - Game settings > RetroForge: the game's conf. No line = "Emulator default": the choice above.

const LaunchArgs := preload("launch_args.gd")
const DATA_DIR := "/usr/share/retroforge/emulators"
const UNSET_EMULATOR := "Emulator's setting"
const UNSET_GAME := "Emulator default"


## The options of an emulator, in options.json's order: [{id, label, description, choices: [{value,
## label}]}], and "default" for an option that has one. [] when it has none or the file is not what retroforge-launch reads.
static func options_for(emulator: String, data_dir: String = DATA_DIR) -> Array:
	return parse(LaunchArgs.read_text(data_dir.path_join(emulator).path_join("options.json")))


## options.json text -> the options the pages show; [] on anything unexpected (the launcher would
## refuse that file anyway, and a page must never offer a value it cannot apply).
static func parse(text: String) -> Array:
	if text == "":
		return []
	var data = JSON.parse_string(text)
	if not (data is Dictionary and data.get("options") is Array):
		return []
	var out: Array = []
	var ids := {}
	for option in data["options"]:
		var shown := _option(option)
		if shown.is_empty() or ids.has(shown["id"]):
			return []
		ids[shown["id"]] = true
		out.append(shown)
	return out


## Same patterns as emuopts: an id is a conf key (never CPUS, never with '=' or a space), a value a
## conf value (never empty: "" is the unset item).
static func _matches(pattern: String, text: String) -> bool:
	return RegEx.create_from_string(pattern).search(text) != null


static func _one_line(value) -> bool:
	return value is String and not "\n" in value


static func _option(option) -> Dictionary:
	if not (option is Dictionary and option.get("id") is String and _matches("^[a-z][a-z0-9_]*$", option["id"])
			and _one_line(option.get("label")) and option.get("choices") is Array and not option["choices"].is_empty()):
		return {}
	var choices: Array = []
	var seen := {}
	for choice in option["choices"]:
		if not (choice is Dictionary and choice.get("value") is String and _one_line(choice.get("label"))
				and _matches("^[A-Za-z0-9_.:+-]+$", choice["value"]) and not seen.has(choice["value"])
				and choice.get("set") is Array and not choice["set"].is_empty()):
			return {}
		seen[choice["value"]] = true
		choices.append({"value": choice["value"], "label": choice["label"]})
	var out := {"id": option["id"], "label": option["label"], "description": str(option.get("description", "")),
		"choices": choices}
	if option.has("default"):
		if not (option["default"] is String and seen.has(option["default"])):
			return {}
		out["default"] = option["default"]
	return out


## The values the emulator level's items stand for, in item order: "" (unset) first unless the option
## has a default, then each choice.
static func emulator_values(option: Dictionary) -> Array:
	return values(option).slice(1) if option.has("default") else values(option)


## The emulator level's item for a saved value: its default's (or unset) when it is not a choice.
static func emulator_index(option: Dictionary, value: String) -> int:
	var items := emulator_values(option)
	return maxi(0, items.find(value if items.has(value) else option.get("default", "")))


## The values the game level's items stand for, in item order: "" (unset) first, then each choice.
static func values(option: Dictionary) -> Array:
	var out: Array = [""]
	for choice in option["choices"]:
		out.append(choice["value"])
	return out


## The label of a choice value ("" when the option has no such choice).
static func choice_label(option: Dictionary, value: String) -> String:
	for choice in option["choices"]:
		if choice["value"] == value:
			return choice["label"]
	return ""


## Dropdown items at the emulator level: "Emulator's setting" (not with a default), then each choice.
static func emulator_items(option: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	for value in emulator_values(option):
		out.append(UNSET_EMULATOR if value == "" else choice_label(option, value))
	return out


## Dropdown items at the game level: "Emulator default (<what the emulator level says>)", then each choice.
static func game_items(option: Dictionary, emulator_value: String) -> PackedStringArray:
	var current := choice_label(option, emulator_value if emulator_value != "" else str(option.get("default", "")))
	var out := PackedStringArray(["%s (%s)" % [UNSET_GAME, current if current != "" else UNSET_EMULATOR.to_lower()]])
	for choice in option["choices"]:
		out.append(choice["label"])
	return out


## The game level's item for a saved value: 0 (unset) when it is not one of the choices.
static func index_of(option: Dictionary, value: String) -> int:
	return maxi(0, values(option).find(value))


## A conf's choice for an option ("" = unset, or a value the option does not have).
static func conf_choice(conf: String, option: Dictionary) -> String:
	var value := LaunchArgs.conf_value(conf, option["id"])
	return value if choice_label(option, value) != "" else ""


static func emulator_choice(emulator: String, option: Dictionary) -> String:
	return conf_choice(LaunchArgs.read_text(LaunchArgs.player_conf_path(emulator)), option)


static func game_choice(system: String, rom: String, option: Dictionary) -> String:
	return conf_choice(LaunchArgs.read_text(LaunchArgs.game_conf_path(system, rom)), option)


## Save a choice ("" = unset). False when the conf could not be written.
static func set_emulator_choice(emulator: String, option: Dictionary, value: String) -> bool:
	return LaunchArgs.set_conf_value(LaunchArgs.player_conf_path(emulator), option["id"], value)


static func set_game_choice(system: String, rom: String, option: Dictionary, value: String) -> bool:
	return LaunchArgs.set_conf_value(LaunchArgs.game_conf_path(system, rom), option["id"], value)

extends RefCounted
## What Settings > Library > RetroAchievements tells the player (cheevos_settings.gd), from
## /usr/bin/retroforge-cheevos' exit codes (its header) and status. No OGUI types: tested on a stock
## Godot (tests/test-plugin.sh).

const PREFIX := "retroforge-cheevos: "
const NOT_SIGNED_IN := "Not signed in. A free account from retroachievements.org."
## Every system whose emulator takes the sign-in: RetroArch's cores (plan retroarch) and the standalone
## emulators the launcher hands it to (plan standalone-cheevos).
const SYSTEMS := "Game Boy, SNES, Mega Drive, N64, PlayStation, PS2, PSP, GameCube, Wii and Dreamcast"


## A failed login, logout or hardcore change, from the tool's exit code and its last stderr line.
static func failure_text(code: int, error: String) -> String:
	var text := error.strip_edges()
	var reason := text.get_slice("\n", text.count("\n")).trim_prefix(PREFIX)
	match code:
		-1:
			return "This build has no RetroAchievements sign-in."
		2:
			return "Enter your RetroAchievements user name and password."
		3:
			return "RetroAchievements could not be reached. Check the network and try again."
		5:
			if reason.begins_with("RetroArch is running"):
				return "Close the game first: RetroArch is running and would undo this."
			return "RetroArch's settings could not be saved."
		7:
			return "RetroAchievements refused your user name or password."
		8:
			return "RetroAchievements did not answer as expected. Try again later."
	return "RetroAchievements failed (%d)." % code


## The account row's description, from `retroforge-cheevos status` ({} when it could not run).
static func account_text(status: Dictionary) -> String:
	if status.get("signed_in", false) == true:
		return "Signed in as %s. %s games earn achievements." % [str(status.get("user")), SYSTEMS]
	return NOT_SIGNED_IN

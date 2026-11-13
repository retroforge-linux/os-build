extends RefCounted
## What Settings > Library > RetroAchievements tells the player (cheevos_settings.gd), from
## /usr/bin/retroforge-cheevos' exit codes (its header) and status. No OGUI types: tested on a stock
## Godot (tests/test-plugin.sh).

const NOT_SIGNED_IN := "Not signed in. A free account from retroachievements.org."
## Every system whose emulator takes the sign-in: RetroArch's cores (plan retroarch) and the standalone
## emulators the launcher hands it to (plan standalone-cheevos).
const SYSTEMS := "Game Boy, SNES, Mega Drive, N64, PlayStation, PS2, PSP, GameCube, Wii and Dreamcast"


## A failed login, logout or hardcore change, from the tool's exit code (its stderr is for the log:
## every code has one meaning since the tool stopped refusing while RetroArch runs).
static func failure_text(code: int, _error: String) -> String:
	match code:
		-1:
			return "This build has no RetroAchievements sign-in."
		2:
			return "Enter your RetroAchievements user name and password."
		3:
			return "RetroAchievements could not be reached. Check the network and try again."
		5:
			return "Your RetroAchievements sign-in could not be saved."
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

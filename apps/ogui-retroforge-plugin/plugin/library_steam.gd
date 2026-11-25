extends Library

## The player's Steam games: every game the account owns, installed or not, from the Steam client
## they signed into (/usr/lib/retroforge/steam-library reads its caches), without the second sign-in
## the OGUI Steam plugin needs (steamcmd). An installed game launches as that plugin starts it,
## `steam ... -silent steam://rungameid/<appid>`: OGUI takes the Steam app id from that argument
## (LibraryLaunchItem.get_app_id), so gamescope focuses the game's window, and runs its Steam
## handling (RunningApp.is_steam_app).
##
## A game that is not installed gets OGUI's Install, and an installed one Uninstall. An Install is
## first Steam's own, in the background with nothing of Steam's shown (steam-install-app --quiet: with
## Steam kept running, when Steam has nothing to ask). Otherwise both are handed to Steam
## (steam://install/<appid>, steam://uninstall/<appid>), whose own screen opens in Big Picture,
## started as Main menu > Apps > Steam Client starts it. The game's app manifest then says when the
## download is done, and with the client's writes how it goes (install_progressed). Steam downloads
## while its client runs: an install here ends as failed when the client is gone first, and Steam
## carries on with it at its next start.

const SteamApps := preload("steam_apps.gd")
const RomNames := preload("rom_names.gd")
const HELPER := "/usr/lib/retroforge/steam-library"
const INSTALL_APP := "/usr/lib/retroforge/steam-install-app"
## s an install in the background may take for Steam to write the game's app manifest.
const MANIFEST_WAIT := 30.0
## s between two looks at an install's app manifest.
const POLL := 2.0

var launch_manager := load("res://core/global/launch_manager.tres") as LaunchManager


# Set in _ready, not _init: overriding _init skips Library._init, which is what registers the
# library with the LibraryManager (on ready). Ready handlers run before ready is emitted.
func _ready() -> void:
	library_id = "retroforge-steam"
	store_id = "retroforge"
	supports_uninstall = true
	logger = Log.get_logger("RetroForgeSteam", Log.LEVEL.INFO)


func steam_root() -> String:
	return SteamApps.steam_root()


func get_library_launch_items() -> Array[LibraryLaunchItem]:
	var games = await _games()
	var items: Array[LibraryLaunchItem] = []
	if games == null:  # a failed listing is not an empty library (as library_store.gd, issue #32)
		logger.warn("Steam library not listed: its games stay as they were")
		return items
	var installed := 0
	for game in games:
		items.append(_launch_item(game))
		installed += 1 if game["installed"] else 0
	_drop_stale(items)
	logger.info("Found %d Steam game(s), %d installed" % [items.size(), installed])
	return items


## steam-library's games, run on a worker thread: on a large account it reads tens of MB. null when
## it failed.
func _games() -> Variant:
	var out := []
	var task := WorkerThreadPool.add_task(func() -> void:
		var output: Array = []
		out.append(OS.execute(HELPER, [], output))
		out.append("".join(output)))
	while not WorkerThreadPool.is_task_completed(task):
		await get_tree().process_frame
	WorkerThreadPool.wait_for_task_completion(task)
	if out.size() < 2 or out[0] != 0:
		logger.warn("%s failed (exit %s)" % [HELPER, out[0] if out.size() > 0 else "?"])
		return null
	return SteamApps.parse_library(out[1])


## OGUI's load_library only ever adds: remove our cards whose game is gone (a refund, a license
## removed), or whose install state changed, before LibraryManager adds this scan's items (deferred).
func _drop_stale(items: Array[LibraryLaunchItem]) -> void:
	var wanted := {}
	for item in items:
		wanted[item.name] = "%s %s" % [item.provider_app_id, item.installed]
	var current := {}
	for app in library_manager.get_library_items([]):
		var launch := app.get_launch_item(library_id)
		if launch:
			current[app.name] = "%s %s" % [launch.provider_app_id, launch.installed]
	for name in RomNames.stale(current, wanted):
		logger.info("Steam game changed or gone: " + name)
		library_manager.remove_library_launch_item(library_id, name)


func _launch_item(game: Dictionary) -> LibraryLaunchItem:
	var item := LibraryLaunchItem.new()
	item.name = game["name"]
	item.provider_app_id = str(game["appid"])
	item.command = "steam"
	item.args = SteamApps.launch_args(game["appid"])
	item.tags = PackedStringArray(["retroforge", "steam"])
	item.categories = PackedStringArray(["game"])
	item.installed = game["installed"]
	item.metadata = {"steam_app": game["appid"], "dir": game["dir"]}
	return item


## OGUI's Install (Library.install_to calls this).
func install(item: LibraryLaunchItem) -> void:
	install_completed.emit(item, await _through_steam(item, "install"))


func uninstall(item: LibraryLaunchItem) -> void:
	uninstall_completed.emit(item, await _through_steam(item, "uninstall"))


## Install in the background first, then hand an install Steam has to ask about, or an uninstall, to
## Steam's UI, and follow the game's app manifest until it is done: true, or false once the client
## is gone first, or once no OGUI launch goes through Steam any more (the player left Steam's UI, or
## it never came up) without the client having the install going (Steam's own install returns to OGUI
## as soon as Steam has queued the download, /usr/bin/steam).
func _through_steam(item: LibraryLaunchItem, verb: String) -> bool:
	var appid := item.provider_app_id.to_int()
	# The client's writes from here on are the download's progress (SteamApps.install_progress); a client
	# that starts, or restarts, during the install counts from its own start.
	var pid := SteamApps.client_pid()
	var base := SteamApps.written(pid)
	if verb == "install":
		var quiet: int = await _quiet_install(appid)
		if quiet == 0:
			logger.info("%s: Steam installs it in the background" % item.name)
			return await _follow(item, verb, appid, pid, base, false)
	logger.info("%s: %s through Steam" % [item.name, verb])
	var steam := LibraryLaunchItem.new()
	steam.name = "Steam"
	steam.command = "steam"
	steam.args = SteamApps.ui_args("steam://%s/%d" % [verb, appid])
	steam.installed = true
	steam._provider_id = ""
	launch_manager.launch(steam)
	return await _follow(item, verb, appid, pid, base, true)


## steam-install-app --quiet on a worker thread: 0 once Steam has queued the download with nothing of
## its shown, 3 when Steam has to ask (left to its UI), else not done.
func _quiet_install(appid: int) -> int:
	if not FileAccess.file_exists(INSTALL_APP):
		return 1
	var out := []
	var task := WorkerThreadPool.add_task(func() -> void:
		out.append(OS.execute(INSTALL_APP, ["--quiet", str(appid)])))
	while not WorkerThreadPool.is_task_completed(task):
		await get_tree().process_frame
	WorkerThreadPool.wait_for_task_completion(task)
	return out[0] if out.size() > 0 else 1


func _follow(item: LibraryLaunchItem, verb: String, appid: int, pid: int, base: int, launched: bool) -> bool:
	var root := SteamApps.steam_root()
	var shown := 0.0
	var waited := 0.0
	while true:
		await get_tree().create_timer(POLL).timeout
		var state := SteamApps.app_state(root, appid)
		if verb == "install" and not state.is_empty():
			var now := SteamApps.client_pid()
			if now != pid:
				pid = now
				base = 0
			var wrote := SteamApps.written(pid)
			var progress := SteamApps.install_progress(state, wrote - base if wrote >= 0 and base >= 0 else 0)
			if progress > shown:
				shown = progress
				install_progressed.emit(item, shown)
			if SteamApps.install_complete(state["flags"]):
				return true
		elif verb == "uninstall" and state.is_empty():
			return true
		if launched and _steam_in_use():
			continue
		waited += POLL
		if verb == "install" and SteamApps.client_running() and (not state.is_empty() or not launched and waited < MANIFEST_WAIT):
			continue
		logger.info("%s: Steam closed before the %s was done" % [item.name, verb])
		return false
	return false


## True while OGUI runs a launch through /usr/bin/steam: this one, Steam opened from Main menu >
## Apps > Steam Client (whose client this one's hands the install to), or a Steam game. Not the
## client process: kept running between games (steam_keep.gd), it outlives every launch.
func _steam_in_use() -> bool:
	for app in launch_manager.get_running():
		if app.launch_item and app.launch_item.command == "steam":
			return true
	return false

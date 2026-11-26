extends RefCounted

## The player's Steam games, from the Steam client they signed into (Main menu > Apps > Steam
## Client): no sign-in of its own, as the OGUI Steam plugin's steamcmd needs. No OGUI types, so
## tests/test-plugin.sh runs it in a stock headless Godot.
##
## Which games, owned and installed, is /usr/lib/retroforge/steam-library's to say (it reads the
## client's binary caches); parse_library() takes its JSON. This file has what the plugin needs
## besides: how a game is launched, its install's progress from its app manifest, its art (what the
## client cached, else Valve's CDN), and what a rescan depends on.

## The flags /usr/bin/steam gets for Steam's own UI, as the OGUI Steam plugin starts it.
const UI_ARGS := ["-gamepadui", "-steamos3", "-steampal", "-steamdeck"]
## A game is started as the OGUI Steam plugin starts it: -silent keeps Steam's own UI hidden.
const LAUNCH_ARGS := ["-gamepadui", "-steamos3", "-steampal", "-steamdeck", "-silent"]
## StateFlags bits of an app manifest: fully installed (also while an update is pending), and the
## ones that say an install or update is still going (update required/running/paused/started,
## downloading, staging, committing).
const FULLY_INSTALLED := 4
const STILL_GOING := 2 | 256 | 512 | 1024 | 0x100000 | 0x200000 | 0x400000
## OGUI's BoxArtProvider.LAYOUT (GRID_PORTRAIT, GRID_LANDSCAPE, BANNER, LOGO) -> the client's files;
## the first of each is also the file's name on Valve's CDN. The client's newer cache names the
## portrait library_capsule.jpg (300x450, in a hashed folder): 19 of 161 games had only that one
## (Pocket FIT, 2026-10-29).
const ART := [
	["library_600x900.jpg", "library_600x900_2x.jpg", "library_capsule.jpg"],
	["header.jpg", "library_header.jpg"],
	["library_hero.jpg"],
	["logo.png"],
]
## Where Valve serves every app's library art (what the OGUI Steam plugin fetches too).
const ART_CDN := "https://steamcdn-a.akamaihd.net/steam/apps"
## s before art that could not be fetched is tried again.
const ART_RETRY := 86400


## Where /usr/bin/steam keeps the client: $XDG_DATA_HOME/Steam, else ~/.local/share/Steam.
static func steam_root() -> String:
	var data := OS.get_environment("XDG_DATA_HOME")
	if data == "":
		data = OS.get_environment("HOME").path_join(".local/share")
	return data.path_join("Steam")


## steam-library's JSON -> [{"appid": int, "name": String, "installed": bool, "dir": String}], the
## entries without an app id or a name dropped; [] for anything that is not its JSON.
static func parse_library(text: String) -> Array:
	var parsed = JSON.parse_string(text)
	if not parsed is Dictionary or not parsed.get("games") is Array:
		return []
	var games := []
	for g in parsed["games"]:
		# JSON numbers come back as floats.
		if not g is Dictionary or not typeof(g.get("appid")) in [TYPE_INT, TYPE_FLOAT] or str(g.get("name", "")) == "":
			continue
		games.append({"appid": int(g["appid"]), "name": str(g["name"]), "installed": g.get("installed") == true,
				"dir": str(g.get("dir", ""))})
	return games


## Every "key" "value" line of a text VDF (an .acf is one) as [depth, key, value], depth counting
## the braces it sits in. Values are unescaped (\" and \\).
static func vdf_pairs(text: String) -> Array:
	var re := RegEx.create_from_string('^\\s*"([^"]+)"\\s+"((?:[^"\\\\]|\\\\.)*)"\\s*$')
	var pairs := []
	var depth := 0
	for line in text.split("\n"):
		var s := line.strip_edges()
		if s == "{":
			depth += 1
			continue
		if s == "}":
			depth -= 1
			continue
		var m := re.search(line)
		if m:
			pairs.append([depth, m.get_string(1), m.get_string(2).replace('\\"', '"').replace("\\\\", "\\")])
	return pairs


## The client's library folders: its own root, then each "path" of steamapps/libraryfolders.vdf
## (an SD card, another drive), each once.
static func library_dirs(root: String) -> PackedStringArray:
	var dirs := PackedStringArray([root.trim_suffix("/")])
	var vdf := root.path_join("steamapps/libraryfolders.vdf")
	if not FileAccess.file_exists(vdf):
		return dirs
	for pair in vdf_pairs(FileAccess.get_file_as_string(vdf)):
		var path: String = pair[2].trim_suffix("/")
		if pair[0] == 2 and pair[1] == "path" and path != "" and not path in dirs:
			dirs.append(path)
	return dirs


## An app's install as its manifest says it, in any library folder: {"flags", "done", "total",
## "to_stage"}, the download's bytes done and to do and the bytes it writes to disk (0 when not
## downloading); {} while it has no manifest.
static func app_state(root: String, appid: int) -> Dictionary:
	for lib in library_dirs(root):
		var path := lib.path_join("steamapps/appmanifest_%d.acf" % appid)
		if not FileAccess.file_exists(path):
			continue
		var fields := {}
		for pair in vdf_pairs(FileAccess.get_file_as_string(path)):
			if pair[0] == 1 and pair[1] in ["StateFlags", "BytesDownloaded", "BytesToDownload", "BytesToStage"] and not fields.has(pair[1]):
				fields[pair[1]] = str(pair[2]).to_int()
		return {"flags": fields.get("StateFlags", 0), "done": fields.get("BytesDownloaded", 0),
				"total": fields.get("BytesToDownload", 0), "to_stage": fields.get("BytesToStage", 0)}
	return {}


## An install's progress, 0 to 1. Steam writes the manifest's BytesDownloaded when a download starts
## and when it ends, not while it runs (Dispatch: 100 MB of 22.7 GB for its whole download, MANGMI Air
## X, 2026-11-25), so `wrote`, the bytes the client has written since the install began, counts too,
## of the bytes the download writes (BytesToStage, else BytesToDownload). Below 1 until the manifest
## says it is installed: other writes of the client's count as well.
static func install_progress(state: Dictionary, wrote: int) -> float:
	if state.is_empty():
		return 0.0
	if install_complete(state["flags"]):
		return 1.0
	var p := 0.0
	if state["total"] > 0:
		p = float(state["done"]) / state["total"]
	var stage: int = state.get("to_stage", 0)
	if stage <= 0:
		stage = state["total"]
	if stage > 0 and wrote > 0:
		p = maxf(p, float(wrote) / stage)
	return clampf(p, 0.0, 0.99)


## True once an install has ended: fully installed, nothing still going.
static func install_complete(flags: int) -> bool:
	return flags & FULLY_INSTALLED != 0 and flags & STILL_GOING == 0


## The Steam app a launch's arguments start (steam://rungameid/<appid>), or 0: our library's, the
## shortcut Steam writes for a game, the OGUI Steam plugin's.
static func appid_of(args: PackedStringArray) -> int:
	for arg in args:
		if arg.begins_with("steam://rungameid/"):
			var id := arg.trim_prefix("steam://rungameid/")
			return id.to_int() if id.is_valid_int() else 0
	return 0


## A launch of Steam's own UI (Main menu > Apps > Steam Client, an install or uninstall from the
## library, the desktop Steam entry): `steam` without a game to start.
static func is_ui_launch(item) -> bool:  # a LibraryLaunchItem (untyped: tests load this without OGUI)
	return item != null and item.command == "steam" and appid_of(item.args) == 0


static func launch_args(appid: int) -> PackedStringArray:
	var args := PackedStringArray(LAUNCH_ARGS)
	args.append("steam://rungameid/%d" % appid)
	return args


## Steam's own UI, opened at a steam:// URI (steam://install/<appid>, steam://uninstall/<appid>).
static func ui_args(uri: String) -> PackedStringArray:
	var args := PackedStringArray(UI_ARGS)
	args.append(uri)
	return args


## Steam Client is installed, as steam-install's status says: the client's arm64 binary, and the x86
## guest beside the client's folder unless RETROFORGE_STEAM_X86_GUEST=0. Two file checks.
static func client_installed(root: String) -> bool:
	if not FileAccess.file_exists(root.path_join("steamrtarm64/steam")):
		return false
	if OS.get_environment("RETROFORGE_STEAM_X86_GUEST") == "0":
		return true
	var guest := OS.get_environment("RETROFORGE_STEAM_X86_GUEST_DIR")
	if guest == "":
		guest = root.get_base_dir().path_join("retroforge/fex-guest")
	return FileAccess.file_exists(guest.path_join("current"))


## Steam Client's install runs: steam-install's progress file is there, from the install's start to
## its end. Not one from before this boot, which an install cut off left (steam-install status also
## removes it, once no install runs). The client and its guest are in place before the install's
## last stages, and Steam opened during them kept the install waiting (MANGMI Air X, 2026-11-21).
static func install_running() -> bool:
	var cache := OS.get_environment("XDG_CACHE_HOME")
	if cache == "":
		cache = OS.get_environment("HOME").path_join(".cache")
	var path := cache.path_join("retroforge/steam-install-steam-client.progress")
	return FileAccess.file_exists(path) and FileAccess.get_modified_time(path) >= _boot_time()


## The Steam client's PID while it runs, else 0: ~/.steam/steam.pid names a live process called steam
## (the client leaves the file behind when it ends; retroforge-steam-keep reads it the same way). By
## line: Godot reads a whole /proc file as empty.
static func client_pid(home: String = "", proc: String = "/proc") -> int:
	if home == "":
		home = OS.get_environment("HOME")
	var f := FileAccess.open(home.path_join(".steam/steam.pid"), FileAccess.READ)
	if f == null:
		return 0
	var pid := f.get_line().strip_edges()
	if not pid.is_valid_int():
		return 0
	var comm := FileAccess.open(proc.path_join(pid).path_join("comm"), FileAccess.READ)
	return pid.to_int() if comm != null and comm.get_line().strip_edges() == "steam" else 0


static func client_running(home: String = "", proc: String = "/proc") -> bool:
	return client_pid(home, proc) > 0


## The bytes a process has written to disk (write_bytes of /proc/<pid>/io; the client itself writes a
## download's files), or -1 when it cannot be read.
static func written(pid: int, proc: String = "/proc") -> int:
	if pid <= 0:
		return -1
	var f := FileAccess.open(proc.path_join(str(pid)).path_join("io"), FileAccess.READ)
	if f == null:
		return -1
	while not f.eof_reached():
		var line := f.get_line()
		if line.begins_with("write_bytes:"):
			return line.get_slice(":", 1).strip_edges().to_int()
	return -1


## The kernel's boot time (Unix seconds, /proc/stat btime), 0 when unknown. Read by line: Godot reads
## a whole /proc file as empty (its size is 0).
static func _boot_time() -> int:
	var f := FileAccess.open("/proc/stat", FileAccess.READ)
	if f == null:
		return 0
	while not f.eof_reached():
		var line := f.get_line()
		if line.begins_with("btime "):
			return int(line.get_slice(" ", 1))
	return 0


## The client's cached art of an app for an OGUI layout, or "". Where the client keeps it:
## librarycache/<appid>/<file>, or one folder further down (newer clients put some art under a
## hashed folder), or librarycache/<appid>_<file> (older clients).
static func art_path(root: String, appid: int, kind: int) -> String:
	if kind < 0 or kind >= ART.size():
		return ""
	var cache := root.path_join("appcache/librarycache")
	var app_dir := cache.path_join(str(appid))
	for file in ART[kind]:
		var direct := app_dir.path_join(file)
		if FileAccess.file_exists(direct):
			return direct
		if DirAccess.dir_exists_absolute(app_dir):
			for sub in DirAccess.get_directories_at(app_dir):
				if FileAccess.file_exists(app_dir.path_join(sub).path_join(file)):
					return app_dir.path_join(sub).path_join(file)
		var flat := cache.path_join("%d_%s" % [appid, file])
		if FileAccess.file_exists(flat):
			return flat
	return ""


## Where fetched art is kept: $XDG_CACHE_HOME/retroforge/steam-art, else ~/.cache/...
static func art_cache_dir() -> String:
	var cache := OS.get_environment("XDG_CACHE_HOME")
	if cache == "":
		cache = OS.get_environment("HOME").path_join(".cache")
	return cache.path_join("retroforge/steam-art")


## An app's art for a layout from Valve's CDN, kept in cache_dir/<appid>/<file>: its path, or "" when
## it could not be fetched. Only an HTTP error (curl exit 22: the CDN has no such file) is not tried
## again for ART_RETRY, so a game without that art stays without it; a network failure is tried again
## at the next ask, as library_store.gd does.
## Blocks for the download: call it off the main thread. TEST SEAM: RETROFORGE_STEAM_ART_CDN.
static func fetch_art(cache_dir: String, appid: int, kind: int) -> String:
	if kind < 0 or kind >= ART.size() or appid <= 0:
		return ""
	var file: String = ART[kind][0]
	var dest := cache_dir.path_join(str(appid)).path_join(file)
	if FileAccess.file_exists(dest):
		return dest
	var missing := dest + ".missing"
	if FileAccess.file_exists(missing) and Time.get_unix_time_from_system() - FileAccess.get_modified_time(missing) < ART_RETRY:
		return ""
	DirAccess.make_dir_recursive_absolute(dest.get_base_dir())
	var base := OS.get_environment("RETROFORGE_STEAM_ART_CDN")
	if base == "":
		base = ART_CDN
	var part := dest + ".part"
	var code := OS.execute("curl", ["-fsSL", "--max-time", "20", "-o", part, "%s/%d/%s" % [base, appid, file]])
	if code == 0 and FileAccess.file_exists(part) and FileAccess.get_size(part) > 0:
		DirAccess.rename_absolute(part, dest)
		DirAccess.remove_absolute(missing)
		return dest
	DirAccess.remove_absolute(part)
	if code in [22, 37]:  # 37: the file:// test seam's "no such file"
		var mark := FileAccess.open(missing, FileAccess.WRITE)
		if mark:
			mark.close()
	return ""


## What a rescan depends on, for steam_watch.gd, as "path size mtime", sorted: the client's caches
## of the account's licenses and apps (a game bought elsewhere), libraryfolders.vdf, and every app
## manifest (Steam rewrites one when an install starts, progresses and ends). The current client's
## app cache is a folder of 256 shards, each written aside and renamed in: the folder's own mtime
## moves with every one, so it counts by that (size 0) instead of 256 files every poll.
static func snapshot(root: String) -> PackedStringArray:
	var lines := PackedStringArray()
	for file in ["appcache/packageinfo.vdf", "appcache/appinfo.vdf", "steamapps/libraryfolders.vdf"]:
		var path := root.path_join(file)
		if FileAccess.file_exists(path):
			lines.append("%s %d %d" % [path, FileAccess.get_size(path), FileAccess.get_modified_time(path)])
	var shards := root.path_join("appcache/appinfo")
	if DirAccess.dir_exists_absolute(shards):
		lines.append("%s 0 %d" % [shards, FileAccess.get_modified_time(shards)])
	for lib in library_dirs(root):
		var apps := lib.path_join("steamapps")
		if not DirAccess.dir_exists_absolute(apps):
			continue
		for file in DirAccess.get_files_at(apps):
			if file.begins_with("appmanifest_") and file.ends_with(".acf"):
				var path := apps.path_join(file)
				lines.append("%s %d %d" % [path, FileAccess.get_size(path), FileAccess.get_modified_time(path)])
	lines.sort()
	return lines

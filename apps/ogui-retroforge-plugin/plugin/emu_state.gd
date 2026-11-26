extends RefCounted

## What the Apps page offers for one emulator (plan emulator-latest, Phase 2), from its
## `retroforge-emu list` entry and its `retroforge-emu check` answer ({} until one arrives, or
## offline). No OGUI types, so tests/test-plugin.sh runs it in a stock headless Godot.
##
## rows() -> {"main": row, "tested": row or null, "extra": [row...]}; "tested" (Install tested version)
## goes right below the main row, "extra" before Delete. A row is {"text", "description", "button",
## "args"}: the retroforge-emu arguments its button runs (["install", id], ["install", id,
## "--tested"], ["rollback", id], ["check", id, "--refresh"]), or [] for Open.
##
## Tested = the catalog's pin ("tested" in list), the build RetroForge checked. An entry that
## follows upstream ("follows_latest") installs upstream's newest by default; the page says when the
## installed build is not the tested one, and offers it back. Whether upstream has a newer build is
## asked only when the player presses "Check for a newer version" (each ask costs two of the 60
## GitHub requests an hour this network gets); a failed or missing check offers no Update.
##
## An entry with libretro cores (RetroArch: list's and check's "cores", per core its installed /
## previous build and its newest): a newer core is an Update of the entry (install updates RetroArch
## and its cores together), a missing core is a Repair (install fetches what is missing), and each
## core that kept its previous build has its own Revert row (rollback <id> --core=<core>).
##
## An entry with folders (RetroArch's shader presets: list's "folders", known offline) that is installed
## without one, or with an older one, offers an Update for it.

const Credits := preload("credits.gd")


static func rows(id: String, emu: Dictionary, check: Dictionary) -> Dictionary:
	if emu.get("kind") == "steam":
		return steam_rows(id, emu)
	var installed = emu.get("installed")
	var tested = emu.get("tested")
	var follows: bool = emu.get("follows_latest", false) == true
	var self_update: bool = emu.get("self_update", false) == true
	var nightly: bool = tested == null and follows  # no tested build at all (Cemu's nightly, DuckStation's latest)
	var latest = check.get("latest") if check.get("error") == null else null
	var mb := int(emu.get("size", 0)) / 1048576
	var install := ["install", id]
	var main := {"button": "Open", "args": []}

	if installed == null:
		main.text = "Not installed"
		main.button = "Download"
		main.args = install
		if nightly:
			main.description = "Newest upstream build, about %d MB. Not tested by RetroForge." % mb
		elif not follows:
			main.description = "Version %s, %d MB." % [_v(tested), mb]
		elif latest != null and latest != tested:
			main.description = "Version %s, the newest from upstream, about %d MB. RetroForge tested %s." % [
				_v(latest), mb, _v(tested)]
		else:
			main.description = "The newest version from upstream, about %d MB. RetroForge tested %s." % [
				mb, _v(tested)]
	else:
		main.text = ("" if nightly else "Version ") + _v(installed)
		if installed == tested:
			main.text += " · Tested"
		if self_update:
			# PortMaster: it offers its own updates when opened.
			main.description = "Installed. Updates itself: open it to check."
		elif follows and latest != null and latest != installed:
			main.button = "Update"
			main.args = install
			main.description = "Update to %s available, about %d MB." % [_v(latest), mb]
		elif not follows and emu.get("update", false):
			main.button = "Update"
			main.args = install
			main.description = "Update to %s available, %d MB." % [_v(tested), mb]
		elif nightly:
			main.description = "Installed. Builds come straight from upstream, untested by RetroForge."
		elif installed != tested:
			main.description = "Installed straight from upstream. RetroForge tested %s." % _v(tested)
		else:
			main.description = "Installed."

	var cores: Dictionary = emu.get("cores") if emu.get("cores") is Dictionary else {}
	var core_checks: Dictionary = check.get("cores") if check.get("cores") is Dictionary else {}
	var missing := []
	var newer := []
	var cores_current := true
	for core in cores:
		var have = cores[core].get("installed") if cores[core] is Dictionary else null
		var answer = core_checks.get(core)
		var newest = answer.get("latest") if answer is Dictionary and answer.get("error") == null else null
		if have == null:
			missing.append(core)
		elif newest != null and newest != have:
			newer.append(core)
		if newest == null or newest != have:
			cores_current = false
	if installed != null and not missing.is_empty():
		main.button = "Repair"
		main.args = install
		main.description = ("The %s core is missing: its games will not start. Repair downloads it." % missing[0]
			if missing.size() == 1 else
			"The %s cores are missing: their games will not start. Repair downloads them." % ", ".join(missing))
	elif installed != null and not newer.is_empty():
		if main.button == "Update":
			main.description += " Newer cores too."
		else:
			main.button = "Update"
			main.args = install
			main.description = "Newer cores available: %s." % ", ".join(newer)
	elif installed != null and main.button == "Open":
		var folders: Dictionary = emu.get("folders") if emu.get("folders") is Dictionary else {}
		var due := []
		var due_mb := 0
		for folder in folders:
			if folders[folder] is Dictionary and folders[folder].get("due") == true:
				due.append(folder)
				due_mb += int(folders[folder].get("size", 0)) / 1048576
		if not due.is_empty():
			main.button = "Update"
			main.args = install
			main.description = "To download: %s, about %d MB." % [", ".join(due), due_mb]

	var extra := []
	if installed != null and follows and not self_update and main.button != "Update":
		var checked: bool = latest != null and latest == installed and cores_current
		extra.append({"text": "Check for a newer version", "button": "Check",
			"description": ("Up to date: %s is the newest from upstream." % _v(installed)) if checked
				else "Asks upstream whether a newer version is out.",
			"args": ["check", id, "--refresh"]})
	if installed != null and emu.get("previous") != null:
		extra.append({"text": "Revert to " + _v(emu["previous"]), "button": "Revert",
			"description": "Goes back to the version installed before, kept on this device.",
			"args": ["rollback", id]})
	for core in cores:
		var prev = cores[core].get("previous") if cores[core] is Dictionary else null
		if installed != null and prev != null and cores[core].get("installed") != null:
			extra.append({"text": "Revert the %s core to %s" % [core, _v(prev)], "button": "Revert",
				"description": "Goes back to the core build installed before, kept on this device.",
				"args": ["rollback", id, "--core=" + str(core)]})
	var tested_row = null
	if follows and tested != null and installed != tested and not (self_update and installed != null):
		tested_row = {"text": "Install tested version (%s)" % _v(tested), "button": "Install",
			"description": "The version RetroForge tested, %d MB." % mb,
			"args": ["install", id, "--tested"]}
	return {"main": main, "tested": tested_row, "extra": extra}


## Whether an install changed nothing: the same build, cores and folders in `list` before and after.
static func unchanged(before: Dictionary, after: Dictionary) -> bool:
	return ["installed", "cores", "folders"].all(func(key): return before.get(key) == after.get(key))


## Steam Client (retroforge-emu's "kind": "steam"): Download until installed, then Open (Steam's own
## UI) and Repair (the install again: it fetches only what is missing). Valve's client updates
## itself, so there is no Update, Check or Revert.
static func steam_rows(id: String, emu: Dictionary) -> Dictionary:
	var mb := int(emu.get("size", 0)) / 1048576
	var install := ["install", id]
	var repair := {"text": "Repair", "button": "Repair", "args": install,
		"description": "Downloads again whatever of it is missing."}
	var main := {"button": "Open", "args": []}
	var extra := []
	if emu.get("installed") == null:
		main.text = "Not installed"
		main.button = "Download"
		main.args = install
		main.description = "Valve's Steam for arm64, with what x86 games need under FEX: about %d MB. Updates itself once installed." % mb
	else:
		main.text = "Installed"
		main.description = "Opens Steam. It updates itself."
		extra.append(repair)
	return {"main": main, "tested": null, "extra": extra}


static func _v(tag) -> String:
	return Credits.version_text(str(tag)) if tag != null else "?"

# launch_def — retroforge-launch's emulator definitions: launch.conf (which emulator runs a system)
# and emulator.json (how to run it), checked as data; then what a definition puts into $HOME before
# the start: first-run seeds (and the single/dual-screen layout a moved card follows), the files kept
# current (sync) and the per-system settings.
#
# Emulators are not in the image: the RetroForge OGUI plugin downloads each one (retroforge-emu) into
# /home/player/emulators/<emulator>/ and points `current` at the version to run. This is what every
# ROM card runs. /etc/retroforge/launch.conf maps a system to its emulator (last `<system>=<emulator>`
# line wins); /usr/share/retroforge/emulators/<emulator>/emulator.json says how to run it -- DATA ONLY:
#
#   {"format": "appimage" | "appimage-sharun" | "scripts" | "binary",   how the download is
#                                                  packaged (FORMATS below)
#    "root": "roms/ports/PortMaster",              scripts only: the folder under $HOME retroforge-emu
#                                                  unpacked the download into
#    "binary": "usr/bin/x",                        the program inside it (relative, no '..')
#    "args": ["-batch", "--", "{rom}"],            a game's command line; "{rom}" exactly once,
#                                                  "{system}" (the card's system) anywhere in an arg
#    "gui_args": ["-bigpicture"],                  --gui's command line (no "{rom}")
#    "system_args": {"md": ["--system", "Mega Drive"]},  put before args when the card's system has
#                                                  an entry (one emulator, several systems it must
#                                                  be told about); "{system}" allowed
#    "system_requires": {"segacd": [{"any": ["bios/a.bin", "bios/b.bin"]}],   files under $HOME a
#                        "snes": [{"any": ["emulators/x/cores/c.so"],        game of that system
#                                  "status": "not-installed"}]},              needs (below)
#    "system_settings": [{"file": ".config/x/x.cfg",  settings written into the emulator's own file
#                         "format": "ini", "separator": " = ",   before every GAME, "{system}" in the
#                         "set": [{"section": "", "key": "save_folder",   file and the values = the
#                                  "value": "/home/player/saves/{system}"}]}],  card's system (below)
#    "env": {"NAME": "value"},                     added to the emulator's environment
#    "gamepad_profile": "guide-hotkeys.yaml",      an InputPlumber device profile next to this
#                                                  file, declared to OpenGamepadUI for the run:
#                                                  it loads it while the game has focus (below)
#    "core_dumps": false,                          no core file when it crashes (default true; below)
#    "seed": [{"file": "x.ini", "to": ".config/x/x.ini"}],   first-run settings (below)
#    "sync": [{"file": "x.txt", "to": "roms/x/x.txt"}],      RetroForge's own files, kept current (below)
#    "install": [{"from": "bios/fw.bin",            a one-time step with the emulator's own binary
#                 "unless": ".config/x/fw/ok",       (below); paths under $HOME
#                 "args": ["--installfw", "{file}"]}],
#    "stub": {"psn": "%RPCS3_GAMEID%:{text}"},     a ROM with this extension is a stub: a text file
#                                                  whose first line replaces "{text}", and the
#                                                  result replaces "{rom}" (below)
#    "achievements": [{"file": ..., "format": ..., "set": [...]}],   where the emulator keeps its
#                                                  RetroAchievements sign-in: the player's one
#                                                  sign-in is written there at every launch
#                                                  (the achievements module's header)
#    "notes": ["..."]}                             why, for people; ignored here
#
# Anything else in it, or a format this script does not know, is refused (exit 2): a definition that
# needs code is a new FORMAT here, never shell in the definition (plan Phase 4b, launcher redesign).
#
# First-run settings (seed) live in the image next to emulator.json and are copied into $HOME before
# the emulator's first start — never over an existing file, so whatever the player changes in the
# emulator is kept. One set per emulator serves every device: InputPlumber presents each handheld's
# joypad as the same virtual pad. A seed with a dual_screen_file (melonDS, Azahar: the bottom screen
# in its own window, for the second panel) is the exception: /home is on the card, and a card moves
# between boards. Which variant was seeded is kept in ~/.config/retroforge/seed-board/<emulator>
# (single|dual); on a board of the other kind, only the settings the two variants disagree on are
# rewritten to this board's, the player's other changes kept. A home seeded before that record
# existed is judged by those settings: one variant's exactly, or left alone (the player's own).
#
# Per-system settings (system_settings): one emulator serving several systems that has ONE save or
# state folder, set only in its config file -- no flag, no -C (armGBA: gb, gbc, gba). Before every
# game, each entry's settings are written into its file (emuopts' patchers: ini/toml/yaml/xml,
# a missing file is created) with "{system}" in the file path and the values replaced by the card's
# system, so saves land in ~/saves/<system> as the shared layout says. Never for --gui (Open has no
# system): the file keeps the last game's values, or the seed's. A setting the player changes in the
# emulator's own menu is put back at the next game -- these are RetroForge's, as system_args are. A
# file that cannot be written is a warning, not a blocked game (as with sync).
#
# Per-system requirements (system_requires): files a game of that system cannot run without, that no
# seed provides -- RetroArch's core for the system (installed with RetroArch: "status": "not-installed",
# the plugin says to download it again) or a BIOS the player copies in (the default status,
# "missing-file": the plugin names every file of "any", one is enough: the Mega CD BIOS of any
# region). Checked before a game starts, after the not-installed check; a missing one ends the
# launch with exit 3 and `<status> <emulator>[ <path>...]` in the status file, without starting the
# emulator (a core it cannot load, or a BIOS it does not have, is a black screen). Never for --gui.
# Paths are relative to $HOME, no '..', no whitespace (the status line is split on spaces).
#
# Kept current (sync): files that are RetroForge's, not the player's, placed into the download's world --
# PortMaster's mod_RetroForge.txt and libgl_RetroForge.txt, which every port sources from PortMaster's
# folder. Copied from the image at every launch when missing or different (an image update must
# reach an existing install, which a seed never would), atomically. A failed copy is a warning: the
# emulator still starts.

import json
import os
import re
import shutil

import achievements
import emuopts
from launch_common import EMU_DATA_DIR, ENV, HOME, Exit, device_field, log
from launch_formats import FORMATS

LAUNCH_CONF = ENV.get("RETROFORGE_LAUNCH_CONF", "/etc/retroforge/launch.conf")
SEED_BOARD_DIR = os.path.join(HOME, ".config", "retroforge", "seed-board")
SYSTEM_ID = re.compile(r"[a-z0-9_]+")
DEFINITION_KEYS = {"format", "root", "binary", "args", "gui_args", "system_args", "system_requires",
                   "system_settings", "env",
                   "seed", "sync", "install", "stub", "core_dumps", "exit_resend",
                   "gamepad_profile", "achievements", "notes"}
EXIT_RESEND_MAX = 30  # s: an exit_resend longer than this is a typo, not a plan
ROM = "{rom}"
FILE = "{file}"
SYSTEM = "{system}"
TEXT = "{text}"  # in a stub template: the stub file's first line


def launch_map():
    """launch.conf as {system: emulator}; the last `<system>=<emulator>` line of a system wins."""
    found = {}
    try:
        with open(LAUNCH_CONF, errors="replace") as f:
            for line in f:
                m = re.fullmatch(r"([a-z0-9_]+)=([a-z0-9_-]*)\s*", line.rstrip("\n"))
                if m:
                    found[m.group(1)] = m.group(2)
    except OSError:
        pass
    return found


def emulator_for(system):
    found = launch_map().get(system)
    if not found:
        raise Exit(2, f"no emulator for system '{system}' in {LAUNCH_CONF}")
    return found


def systems_of(emulator):
    """The systems launch.conf gives an emulator, sorted (its "{system}" settings folders)."""
    return sorted(s for s, e in launch_map().items() if e == emulator)


def clean_str(value):
    """A string a command line or environment can carry (no NUL, encodable)."""
    if not isinstance(value, str) or "\0" in value:
        return False
    try:
        value.encode()
    except UnicodeEncodeError:
        return False
    return True


def safe_relative(path):
    """A file path under some root: relative, normalised (no '..', '.', '//' or trailing '/')."""
    return (clean_str(path) and path not in ("", ".") and not path.startswith("/")
            and os.path.normpath(path) == path and ".." not in path.split("/"))


def str_list(value):
    return isinstance(value, list) and all(clean_str(v) for v in value)


def load_definition(emulator):
    path = os.path.join(EMU_DATA_DIR, emulator, "emulator.json")
    try:
        with open(path) as f:
            d = json.load(f)
    except FileNotFoundError:
        raise Exit(2, f"missing {path}") from None
    except (OSError, ValueError) as err:
        raise Exit(2, f"{path} is not readable JSON: {err}") from None

    def bad(why):
        return Exit(2, f"{path}: {why}")

    if not isinstance(d, dict):
        raise bad("not a JSON object")
    unknown = set(d) - DEFINITION_KEYS
    if unknown:
        raise bad(f"unknown keys {sorted(unknown)} (a definition is data; new behaviour is a format)")
    if not isinstance(d.get("format"), str) or d["format"] not in FORMATS:
        raise bad(f"format {d.get('format')!r} is not one of {sorted(FORMATS)}")
    if (d["format"] == "scripts") != ("root" in d) or ("root" in d and not safe_relative(d["root"])):
        raise bad("root (a relative folder under $HOME, without '..') is required for the scripts "
                  "format and only for it")
    if not safe_relative(d.get("binary")):
        raise bad("binary must be a relative path inside the download, without '..'")
    if d["format"] == "binary" and d["binary"] != "current":
        # The download IS the program, and the not-installed check looks at `current`: any other
        # name would pass that check and then fail to start.
        raise bad('a binary definition runs the download itself: binary must be "current"')
    args = d.get("args")
    if not str_list(args) or args.count(ROM) != 1:
        raise bad(f'args must be a list of strings holding "{ROM}" exactly once')
    gui_args = d.get("gui_args", [])
    if not str_list(gui_args) or ROM in gui_args or any(SYSTEM in a for a in gui_args):
        raise bad(f'gui_args must be a list of strings without "{ROM}" or "{SYSTEM}" (no game, no system)')
    system_args = d.get("system_args", {})
    if not (isinstance(system_args, dict)
            and all(isinstance(k, str) and SYSTEM_ID.fullmatch(k) and str_list(v) and ROM not in v
                    for k, v in system_args.items())):
        raise bad(f'system_args must map system names to lists of strings without "{ROM}"')
    system_requires = d.get("system_requires", {})
    if not (isinstance(system_requires, dict)
            and all(isinstance(k, str) and SYSTEM_ID.fullmatch(k) and isinstance(v, list)
                    and all(requirement_ok(r) for r in v) for k, v in system_requires.items())):
        raise bad('system_requires must map system names to lists of {"any": [<path under $HOME>, ...]'
                  f'[, "status": one of {sorted(REQUIRE_STATUSES)}]}}, paths relative, without '
                  "'..' or whitespace")
    system_settings = d.get("system_settings", [])
    if not (isinstance(system_settings, list) and all(system_settings_entry_ok(s) for s in system_settings)):
        raise bad('system_settings entries must be {"file": <path under $HOME>, "format": <one of '
                  f'{", ".join(emuopts.FORMATS)}>[, "separator": "=" with optional spaces, ini/toml only], '
                  '"set": [{"section", "key", "value": one-line strings, key not empty}, ...]}, '
                  f'without "{ROM}"')
    env = d.get("env", {})
    if not (isinstance(env, dict)
            and all(isinstance(k, str) and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", k)
                    and clean_str(v) for k, v in env.items())):
        raise bad("env must map variable names to strings")
    seed, sync = d.get("seed", []), d.get("sync", [])
    for key, entries in (("seed", seed), ("sync", sync)):
        # A seed may name another file for dual-screen boards (device-env declares a second panel).
        allowed = ({"file", "to"}, {"file", "to", "dual_screen_file"}) if key == "seed" else ({"file", "to"},)
        if not (isinstance(entries, list)
                and all(isinstance(s, dict) and set(s) in allowed
                        and safe_relative(s["file"]) and safe_relative(s["to"])
                        and safe_relative(s.get("dual_screen_file", "x")) for s in entries)):
            raise bad(f'{key} entries must be {{"file": <in the image>, "to": <path under $HOME>}}'
                      + (', optionally "dual_screen_file": <in the image>' if key == "seed" else "")
                      + ", all relative without '..'")
    install = d.get("install", [])
    if not (isinstance(install, list)
            and all(isinstance(i, dict) and set(i) == {"from", "unless", "args"}
                    and safe_relative(i["from"]) and safe_relative(i["unless"])
                    and not re.search(r"\s", i["from"] + i["unless"])
                    and str_list(i["args"]) and i["args"].count(FILE) == 1 and ROM not in i["args"]
                    and not any(SYSTEM in a for a in i["args"])
                    for i in install)):
        # No whitespace: `from` goes into the space-separated status line the plugin splits.
        raise bad('install entries must be {"from": <path under $HOME>, "unless": <path under $HOME>, '
                  f'"args": [... "{FILE}" once, no "{ROM}" or "{SYSTEM}" ...]}}, paths relative, '
                  "without '..' or whitespace")
    stub = d.get("stub", {})
    if not (isinstance(stub, dict)
            and all(isinstance(k, str) and re.fullmatch(r"[a-z0-9]+", k)
                    and clean_str(v) and v.count(TEXT) == 1 and ROM not in v and SYSTEM not in v
                    for k, v in stub.items())):
        raise bad(f'stub must map ROM extensions (lowercase, no dot) to strings holding "{TEXT}" '
                  f'exactly once, without "{ROM}" or "{SYSTEM}"')
    if stub and d["format"] == "scripts":
        raise bad("stub is for emulators, not the scripts format (a scripts ROM is run, not passed)")
    core_dumps = d.get("core_dumps", True)
    if not isinstance(core_dumps, bool):
        raise bad("core_dumps must be true or false")
    gamepad_profile = d.get("gamepad_profile")
    if gamepad_profile is not None and not safe_relative(gamepad_profile):
        raise bad("gamepad_profile must be a relative path next to this file, without '..'")
    cheevos = d.get("achievements", [])
    if not (isinstance(cheevos, list) and all(achievements.entry_ok(e, safe_relative) for e in cheevos)):
        raise bad('achievements entries must be {"file": <path under $HOME>, "format": <one of '
                  f'{", ".join(achievements.FORMATS)}>, ...}} as the achievements module\'s header '
                  'says: "set" lists for files of settings, "value" for a secret, one-line values '
                  f'whose only {{...}} are {", ".join(achievements.PLACEHOLDERS)}')
    exit_resend = d.get("exit_resend")
    if exit_resend is not None and not (isinstance(exit_resend, (int, float)) and not isinstance(exit_resend, bool)
                                        and 0 < exit_resend <= EXIT_RESEND_MAX):
        raise bad(f"exit_resend must be a number of seconds, more than 0 and at most {EXIT_RESEND_MAX}")
    return {"format": d["format"], "root": d.get("root"), "binary": d["binary"], "args": args, "gui_args": gui_args,
            "system_args": system_args, "system_requires": system_requires, "system_settings": system_settings, "env": env, "seed": seed,
            "sync": sync, "install": install, "stub": stub, "core_dumps": core_dumps,
            "exit_resend": exit_resend, "gamepad_profile": gamepad_profile, "achievements": cheevos}


REQUIRE_STATUSES = {"missing-file", "not-installed"}  # what the plugin turns into a message


def requirement_ok(r):
    """One system_requires entry: {"any": [paths], "status"?}."""
    return (isinstance(r, dict) and {"any"} <= set(r) <= {"any", "status"}
            and isinstance(r["any"], list) and r["any"]
            and all(safe_relative(p) and not re.search(r"\s", p) for p in r["any"])
            and r.get("status", "missing-file") in REQUIRE_STATUSES)


def missing_requirement(entries):
    """The first entry none of whose files exists under $HOME, or None."""
    for r in entries:
        if not any(os.path.isfile(os.path.join(HOME, p)) for p in r["any"]):
            return r
    return None


def system_settings_entry_ok(s):
    """One system_settings entry: a file under $HOME in a format emuopts patches, and the one-line
    settings to write there. No "{rom}": a ROM path belongs on the command line only."""
    if not (isinstance(s, dict) and {"file", "format", "set"} <= set(s) <= {"file", "format", "separator", "set"}):
        return False
    if not (safe_relative(s["file"]) and s["format"] in emuopts.FORMATS and isinstance(s["set"], list) and s["set"]):
        return False
    if "separator" in s and not (s["format"] in emuopts.LINE_FORMATS and clean_str(s["separator"])
                                 and "\n" not in s["separator"] and s["separator"].strip() == "="):
        return False
    return all(isinstance(a, dict) and set(a) == {"section", "key", "value"}
               and all(clean_str(a[k]) and "\n" not in a[k] and ROM not in a[k] for k in a)
               and a["key"].strip() for a in s["set"])


def apply_system_settings(emulator, entries, system):
    """Write each entry's settings for this game's system ("{system}" in the file and the values)."""
    for s in entries:
        path = os.path.join(HOME, s["file"].replace(SYSTEM, system))
        edits = [(a["section"], a["key"], a["value"].replace(SYSTEM, system)) for a in s["set"]]
        try:
            emuopts.patch_file(path, s["format"], edits, s.get("separator", "="))
        except emuopts.FILE_ERRORS as err:
            log(f"warning: {emulator}: could not write {system}'s settings to {path}: {err}")


def dual_screen():
    """Whether the board has a second panel: device-env's RETROFORGE_SECONDARY_CONNECTOR is set."""
    return bool(device_field("RETROFORGE_SECONDARY_CONNECTOR"))


def seed_first_run(emulator, seed):
    # Ask device-env only when a seed has a dual-screen variant.
    variants = [s for s in seed if "dual_screen_file" in s]
    board = ("dual" if dual_screen() else "single") if variants else None
    seeded = set()
    for s in seed:
        dst = os.path.join(HOME, s["to"])
        if os.path.lexists(dst):
            continue
        dual = board == "dual" and "dual_screen_file" in s
        src = os.path.join(EMU_DATA_DIR, emulator, s["dual_screen_file"] if dual else s["file"])
        if not os.path.isfile(src):
            raise Exit(2, f"{emulator}'s emulator.json seeds {src}, which the image does not have")
        try:
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copyfile(src, dst)
        except OSError as err:
            raise Exit(2, f"could not seed {dst}: {err}") from None
        seeded.add(s["to"])
        log(f"first run of {emulator}: seeded {dst}{' (dual-screen board)' if dual else ''}")
    if variants:
        follow_board(emulator, [s for s in variants if s["to"] not in seeded], board)


def follow_board(emulator, entries, board):
    """A home seeded on a board with the other panel count (the card moved): this board's layout."""
    marker = os.path.join(SEED_BOARD_DIR, emulator)
    try:
        with open(marker) as f:
            recorded = f.read().strip()
    except OSError:
        recorded = None
    for s in entries:
        dst = os.path.join(HOME, s["to"])
        if os.path.islink(dst) or not os.path.isfile(dst):
            continue
        try:
            layout = layout_settings(os.path.join(EMU_DATA_DIR, emulator, s["file"]),
                                     os.path.join(EMU_DATA_DIR, emulator, s["dual_screen_file"]))
            was = recorded if recorded in ("single", "dual") else seeded_board(dst, layout)
            if was in (None, board):
                continue
            emuopts.write_atomic(dst, switch_layout(dst, layout, board).encode())
        except (OSError, UnicodeError) as err:
            log(f"warning: {emulator}: could not switch {dst} to the {board}-screen layout: {err}")
            continue
        log(f"{emulator}: {dst} was set up on a {was}-screen board: {board}-screen layout")
    if recorded != board:
        try:
            emuopts.write_atomic(marker, f"{board}\n".encode())
        except OSError as err:
            log(f"warning: {emulator}: could not record the {board}-screen seed in {marker}: {err}")


# INI and melonDS's TOML alike: "[section]" headers, "key = value" lines (spaces optional).
SECTION_LINE = re.compile(r"\s*\[([^\]]+)\]\s*$")
SETTING_LINE = re.compile(r"\s*([^\s=#;\[][^=]*?)\s*=\s*(.*?)\s*$")


def settings(path):
    """{(section, key): (value, line)} of a settings file; the first of a repeated key."""
    found, section = {}, ""
    with open(path, encoding="utf-8") as f:
        for line in f.read().splitlines():
            if m := SECTION_LINE.match(line):
                section = m.group(1).strip()
            elif m := SETTING_LINE.match(line):
                found.setdefault((section, m.group(1)), (m.group(2), line))
    return found


def layout_settings(single_file, dual_file):
    """{(section, key): {"single": line | None, "dual": line | None}} for every setting the two
    seed variants disagree on (missing from one: None, the emulator's default)."""
    single, dual = settings(single_file), settings(dual_file)
    return {k: {"single": single[k][1] if k in single else None, "dual": dual[k][1] if k in dual else None}
            for k in single.keys() | dual.keys()
            if (single.get(k) or (None,))[0] != (dual.get(k) or (None,))[0]}


def seeded_board(path, layout):
    """Which variant's layout the file holds, or None (neither: the player's own). A setting a
    variant leaves out matches anything: the emulator may have written its default back."""
    have = {k: v[0] for k, v in settings(path).items()}
    for board in ("single", "dual"):
        if all(v[board] is None or have.get(k) == SETTING_LINE.match(v[board]).group(2)
               for k, v in layout.items()):
            return board
    return None


def switch_layout(path, layout, board):
    """The file's text with each layout setting as the board's seed has it: replaced in place,
    added at the end of its section (a new section at the end), or removed (None)."""
    with open(path, encoding="utf-8") as f:
        lines = f.read().splitlines()
    out, ends, done, section = [], {}, set(), ""
    for line in lines:
        if m := SECTION_LINE.match(line):
            section = m.group(1).strip()
        elif (m := SETTING_LINE.match(line)) and (k := (section, m.group(1))) in layout:
            if k not in done and layout[k][board] is not None:
                out.append(layout[k][board])
            done.add(k)
            ends[section] = len(out)
            continue
        out.append(line)
        if line.strip():
            ends[section] = len(out)
    missing = {}
    for k, v in sorted(layout.items()):
        if k not in done and v[board] is not None:
            missing.setdefault(k[0], []).append(v[board])
    # Insert from the bottom up so the recorded section ends stay valid.
    for sec in sorted((s for s in missing if s in ends), key=ends.get, reverse=True):
        out[ends[sec]:ends[sec]] = missing[sec]
    for sec in (s for s in missing if s not in ends):
        out += ([""] if out and out[-1].strip() else []) + [f"[{sec}]"] + missing[sec]
    return "\n".join(out) + "\n"


def sync_files(emulator, sync):
    """RetroForge's own files (sync above): the image's copy, whenever the one under $HOME differs."""
    for s in sync:
        src = os.path.join(EMU_DATA_DIR, emulator, s["file"])
        dst = os.path.join(HOME, s["to"])
        try:
            with open(src, "rb") as f:
                want = f.read()
            try:
                with open(dst, "rb") as f:
                    if f.read() == want:
                        continue
            except OSError:
                pass
            emuopts.write_atomic(dst, want)
            log(f"{emulator}: updated {dst}")
        except OSError as err:
            log(f"warning: {emulator}: could not place {dst}: {err}")

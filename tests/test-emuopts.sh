#!/usr/bin/env bash
# Offline test for emuopts, retroforge-launch's per-emulator options (.claude/plans/emulator-options.plan.md).
#
#   tests/test-emuopts.sh
#
# WHY THIS EXISTS. emuopts writes into the emulators' own settings files before every launch, and a
# mistake there is not a failed launch but a player's settings damaged for good:
#
#   - a patcher that re-serialises a file loses the comments, order and settings RetroForge does not
#     manage (Snes9x and ClownMDEmu rebuild theirs anyway; DuckStation, PPSSPP, RPCS3 do not);
#   - a game-level override that is not put back stays in the emulator's settings, for every other game;
#     a double Exit (SIGKILL) or a power cut must not change that: the journal is restored at the next launch;
#   - a setting that was absent must be absent again after the restore (the emulator's default), not
#     written back with some value;
#   - an options.json with a path outside $HOME, or a value with a newline, would let image data write
#     anywhere or inject lines.
#
# The plugin's ROM cards and retroforge-launch's own run are covered in test-launch.sh; this is the module.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/rootfs/overlay/usr/lib/retroforge/python"
EMU_DATA_DIR="$ROOT/rootfs/overlay/usr/share/retroforge/emulators"
[ -f "$LIB/emuopts.py" ] || { echo "missing input: $LIB/emuopts.py" >&2; exit 1; }

T="$(mktemp -d)" && [ -d "$T" ] || { echo "mktemp -d failed" >&2; exit 1; }
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT

# -I: isolated (no user site, no cwd on sys.path); -B: no __pycache__ inside rootfs/overlay.
python3 -I -B - "$LIB" "$T" "$EMU_DATA_DIR" <<'PY'
import json, os, sys
sys.path.insert(0, sys.argv[1])
import emuopts as eo

T, DATA = sys.argv[2], sys.argv[3]
PASS = FAIL = 0
CASE = ""


def check(what, got, want):
    global PASS, FAIL
    if got == want:
        PASS += 1
        print(f"  ok   {CASE} -- {what}")
    else:
        FAIL += 1
        print(f"  FAIL {CASE} -- {what}\n         got:  {got!r}\n         want: {want!r}")


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


def read(path):
    with open(path) as f:
        return f.read()


# ================================================================================================
CASE = "player confs"
write(f"{T}/c/a.conf", "# set by Main menu > Emulators\nCPUS=all\naspect=4:3\nCPUS=big\n$(touch x)\nnoequals\n")
check("last line of a key wins, comments and lines without '=' skipped", eo.read_conf(f"{T}/c/a.conf"),
      {"CPUS": "big", "aspect": "4:3"})
check("a missing conf is empty", eo.read_conf(f"{T}/c/none.conf"), {})
check("a game conf is named after the ROM file", eo.game_conf_path("/g", "psx", "/roms/psx/Crash (USA).chd"),
      "/g/psx/Crash (USA).chd.conf")
check("a folder ROM (PS3 dump) with a trailing slash too", eo.game_conf_path("/g", "ps3", "/roms/ps3/GAME/"),
      "/g/ps3/GAME.conf")
check("CPUS: the game's wins", eo.cpus_choice({"CPUS": "big"}, {"CPUS": "all"}), "all")
check("CPUS: the emulator's when the game has none", eo.cpus_choice({"CPUS": "big"}, {}), "big")
check("CPUS: a bad game value falls back to the emulator's", eo.cpus_choice({"CPUS": "big"}, {"CPUS": "fast"}), "big")
check("CPUS: all by default", eo.cpus_choice({}, {}), "all")

# ================================================================================================
CASE = "ini patcher"
INI = "; comment\n[Display]\nAspectRatio = Auto (Game Native)\nVSync=false\n\n[GPU]\nRenderer=Vulkan\n"
check("get", eo.ini_get(INI, "Display", "AspectRatio"), "Auto (Game Native)")
check("get: another section's key is not it", eo.ini_get(INI, "GPU", "VSync"), None)
check("replace keeps the line's spacing, everything else untouched",
      eo.ini_set(INI, "Display", "AspectRatio", "16:9"),
      "; comment\n[Display]\nAspectRatio = 16:9\nVSync=false\n\n[GPU]\nRenderer=Vulkan\n")
check("add: after the section's last setting, before its blank line",
      eo.ini_set(INI, "Display", "ShowFPS", "true"),
      "; comment\n[Display]\nAspectRatio = Auto (Game Native)\nVSync=false\nShowFPS=true\n\n[GPU]\nRenderer=Vulkan\n")
check("add: a new section at the end, with the file's separator",
      eo.ini_set(INI, "Main", "EmulationSpeed", "1", " = "),
      INI + "[Main]\nEmulationSpeed = 1\n")
check("remove: the line goes, nothing else", eo.ini_set(INI, "Display", "VSync", None),
      "; comment\n[Display]\nAspectRatio = Auto (Game Native)\n\n[GPU]\nRenderer=Vulkan\n")
check("remove what is not there: unchanged", eo.ini_set(INI, "GPU", "Nope", None), INI)
for text in (INI, INI + "\n", "[a]\nx=1"):
    check(f"add then remove in a new section: the file as it was ({text[-6:]!r})",
          eo.ini_set(eo.ini_set(text, "Hacks", "K", "1"), "Hacks", "K", None), text if text.endswith("\n") else text + "\n")
check("removing the last key of a section that has comments keeps it",
      eo.ini_set("[s]\n; mine\nk=1\n", "s", "k", None), "[s]\n; mine\n")
check("root section (before any header)", eo.ini_set("[x]\na=1\n", "", "top", "1"), "top=1\n[x]\na=1\n")
check("an empty file gets the section", eo.ini_set("", "S", "k", "v"), "[S]\nk=v\n")
QT = "[Renderer]\ngraphics_api\\default=true\ngraphics_api=1\n"
check("QSettings keys with a backslash (Azahar's \\default)",
      eo.ini_set(QT, "Renderer", "graphics_api\\default", "false"),
      "[Renderer]\ngraphics_api\\default=false\ngraphics_api=1\n")
check("a key that is a prefix of another is not confused", eo.ini_get(QT, "Renderer", "graphics_api"), "1")
check("a repeated key: every line set", eo.ini_set("[s]\nk=1\nk=2\n", "s", "k", "3"), "[s]\nk=3\nk=3\n")
check("a commented-out key is not the key", eo.ini_get("[s]\n;k=1\n# k=2\n", "s", "k"), None)
CLOWN = "[Miscellaneous]\nvsync = on\n"
check("ClownMDEmu's strict ' = ' kept on replace", eo.ini_set(CLOWN, "Miscellaneous", "vsync", "off"),
      "[Miscellaneous]\nvsync = off\n")
check("a value holding \\x85 / U+2028 stays one line", eo.ini_set("[s]\nk=a\u2028b\x85c\nz=1\n", "s", "z", "2"),
      "[s]\nk=a\u2028b\x85c\nz=2\n")

# ================================================================================================
CASE = "toml patcher (ini lines)"
TOML = "# xemu\n[display]\nrenderer = 'VULKAN'\n\n[display.ui]\nfit = 'scale'\n"
check("dotted table headers are sections", eo.ini_get(TOML, "display.ui", "fit"), "'scale'")
check("a quoted value written verbatim", eo.ini_set(TOML, "display", "renderer", "'OPENGL'"),
      "# xemu\n[display]\nrenderer = 'OPENGL'\n\n[display.ui]\nfit = 'scale'\n")
check("a subtable is not its parent", eo.ini_get(TOML, "display", "fit"), None)
AOT = "[a]\nx=1\n[[t]]\nk=1\n[b]\n"
check("[[array of tables]] ends the section before it", eo.ini_get(AOT, "a", "k"), None)
check("...so a key added to [a] goes in [a]", eo.ini_set(AOT, "a", "k", "9"), "[a]\nx=1\nk=9\n[[t]]\nk=1\n[b]\n")

# ================================================================================================
CASE = "yaml patcher"
YML = ("# RPCS3\nMiscellaneous:\n  Start games in fullscreen mode: true\nVideo:\n  Renderer: Vulkan\n"
       "  Performance Overlay:\n    Enabled: false\n    Position: Top Left\n  Frame limit: Auto\n")
check("get a nested key", eo.yaml_get(YML, "Video/Performance Overlay", "Enabled"), "false")
check("get: same leaf name, other parent", eo.yaml_get(YML, "Video", "Enabled"), None)
check("replace a nested value, the rest untouched",
      eo.yaml_set(YML, "Video/Performance Overlay", "Enabled", "true"),
      YML.replace("    Enabled: false", "    Enabled: true"))
check("add a leaf at the end of its parent's block",
      eo.yaml_set(YML, "Video", "Aspect ratio", "16:9"),
      YML + "  Aspect ratio: 16:9\n")
check("add inside a nested block, before the parent's next key",
      eo.yaml_set(YML, "Video/Performance Overlay", "Detail level", "Low"),
      YML.replace("    Position: Top Left\n", "    Position: Top Left\n    Detail level: Low\n"))
check("add missing parents, two spaces a level",
      eo.yaml_set(YML, "Core", "SPU Block Size", "Mega"), YML + "Core:\n  SPU Block Size: Mega\n")
check("add a missing child mapping under an existing parent",
      eo.yaml_set("Video:\n  Renderer: Vulkan\nAudio:\n  x: 1\n", "Video/Vulkan", "Adapter", "Turnip"),
      "Video:\n  Renderer: Vulkan\n  Vulkan:\n    Adapter: Turnip\nAudio:\n  x: 1\n")
check("remove a leaf", eo.yaml_set(YML, "Video", "Frame limit", None), YML.replace("  Frame limit: Auto\n", ""))
check("add then remove under new parents: the file as it was",
      eo.yaml_set(eo.yaml_set(YML, "Core/SPU", "Block", "Mega"), "Core/SPU", "Block", None), YML)
check("a parent that keeps other children stays",
      eo.yaml_set(YML, "Video/Performance Overlay", "Enabled", None).count("Performance Overlay:"), 1)
LIST = "Video:\n  Res: 1\n  Foo:\n    - a\n    - b\nOther: 1\n"
check("add after a list under the parent's last child, not inside it",
      eo.yaml_set(LIST, "Video", "New", "2"), "Video:\n  Res: 1\n  Foo:\n    - a\n    - b\n  New: 2\nOther: 1\n")
FOUR = "Video:\n    Res: 1\nOther: 1\n"
check("a 4-space file gets 4-space keys", eo.yaml_set(FOUR, "Video", "New", "2"), "Video:\n    Res: 1\n    New: 2\nOther: 1\n")
check("...and 4-space new mappings", eo.yaml_set(FOUR, "Video/Sub", "K", "v"),
      "Video:\n    Res: 1\n    Sub:\n        K: v\nOther: 1\n")

# ================================================================================================
CASE = "xml patcher"
XML = ('<?xml version="1.0" encoding="UTF-8"?>\n<!-- RetroForge -->\n<content>\n    <Graphic>\n'
       '        <api>1</api>\n    </Graphic>\n</content>\n')
check("get", eo.xml_get(XML, "Graphic", "api"), "1")
out = eo.xml_set(XML, "Graphic", "api", "0")
check("set an existing element", eo.xml_get(out, "Graphic", "api"), "0")
check("comments inside the root survive the rewrite",
      "<!-- kept -->" in eo.xml_set(XML.replace("<Graphic>", "<!-- kept --><Graphic>"), "Graphic", "api", "0"), True)
out = eo.xml_set(XML, "Graphic/Overlay", "Position", "1")
check("add nested elements", eo.xml_get(out, "Graphic/Overlay", "Position"), "1")
check("the sibling is kept", eo.xml_get(out, "Graphic", "api"), "1")
check("remove", eo.xml_get(eo.xml_set(XML, "Graphic", "api", None), "Graphic", "api"), None)
check("the comment before the root survives (Cemu's seed)",
      eo.xml_set(XML, "Graphic", "api", "0").startswith('<?xml version="1.0" encoding="UTF-8"?>\n<!-- RetroForge -->\n<content>'), True)
check("a file with no declaration gets one", eo.xml_set("<content/>", "Graphic", "api", "1").startswith("<?xml"), True)
added = eo.xml_set(XML, "Graphic/Overlay", "Position", "1")
check("removing the only child of a parent it needed removes the parent too",
      eo.xml_set(added, "Graphic/Overlay", "Position", None), eo.xml_set(XML, "Graphic", "api", "1"))
check("...but a parent with other children stays",
      eo.xml_get(eo.xml_set(eo.xml_set(added, "Graphic/Overlay", "FPS", "true"), "Graphic/Overlay", "Position", None),
                 "Graphic/Overlay", "FPS"), "true")

# ================================================================================================
CASE = "options.json"
GOOD = {"files": {"main": {"path": ".config/fake/settings.ini", "format": "ini", "separator": " = "}},
        "options": [{"id": "aspect", "label": "Aspect ratio", "description": "d",
                     "choices": [{"value": "4:3", "label": "4:3",
                                  "set": [{"file": "main", "section": "Display", "key": "AspectRatio", "value": "4:3"}]},
                                 {"value": "16:9", "label": "16:9",
                                  "set": [{"file": "main", "section": "Display", "key": "AspectRatio", "value": "16:9"},
                                          {"args": ["-wide"]}, {"env": {"FAKE_WIDE": "1"}}]}]}]}


def load(d):
    write(f"{T}/data/x/options.json", json.dumps(d) if not isinstance(d, str) else d)
    try:
        return eo.load_options(f"{T}/data", "x")
    except eo.OptionsError as err:
        return f"refused: {err}"


check("a valid file loads", load(GOOD)["options"][0]["id"], "aspect")
check("no options.json: None", eo.load_options(f"{T}/data", "nope"), None)


def refused(what, change):
    if isinstance(change, str):
        got = load(change)
    else:
        d = json.loads(json.dumps(GOOD))
        change(d)
        got = load(d)
    check(what + ": refused", isinstance(got, str) and got.startswith("refused"), True)


refused("not JSON", "{")
refused("unknown top-level key", lambda d: d.update(code="x"))
refused("path outside $HOME", lambda d: d["files"]["main"].update(path="../etc/passwd"))
refused("absolute path", lambda d: d["files"]["main"].update(path="/etc/passwd"))
refused("unknown format", lambda d: d["files"]["main"].update(format="conf"))
refused("a separator on yaml", lambda d: d["files"]["main"].update(format="yaml"))
refused("a separator that is not '='", lambda d: d["files"]["main"].update(separator=":"))
refused("an undeclared file", lambda d: d["options"][0]["choices"][0]["set"][0].update(file="other"))
refused("a value with a newline", lambda d: d["options"][0]["choices"][0]["set"][0].update(value="1\n[x]"))
refused("an empty key", lambda d: d["options"][0]["choices"][0]["set"][0].update(key=" "))
refused("an unknown action", lambda d: d["options"][0]["choices"][0]["set"].append({"shell": "rm"}))
refused("a bad env name", lambda d: d["options"][0]["choices"][1]["set"].append({"env": {"A-B": "1"}}))
refused("an uppercase option id", lambda d: d["options"][0].update(id="Aspect"))
refused("a repeated option", lambda d: d["options"].append(d["options"][0]))
refused("a repeated choice value", lambda d: d["options"][0]["choices"].append(d["options"][0]["choices"][0]))
refused("a choice value with a space", lambda d: d["options"][0]["choices"][0].update(value="4 3"))
refused("a choice with nothing to do", lambda d: d["options"][0]["choices"][0].update(set=[]))
refused("choices writing different settings",
        lambda d: d["options"][0]["choices"][1]["set"].append({"file": "main", "section": "Display", "key": "Other", "value": "1"}))
JSONFILE = json.loads(json.dumps(GOOD))
JSONFILE["files"]["main"].update(path=".config/fake/config.json", format="json")
got = load(JSONFILE)
check("a json-format file is refused (its writer went with gopher64)",
      isinstance(got, str) and got.startswith("refused"), True)
# A choice can turn the picture-sized window off (window_size), and an option can name the choice that
# applies when none is saved (default): every emulator with window_size offers picture_window, On.
SIZED = {"files": {"main": {"path": ".config/fake/sized.ini", "format": "ini", "separator": " = "}},
         "options": [{"id": "picture_window", "label": "Picture-sized window", "default": "on",
                      "choices": [{"value": "on", "label": "On", "set": [
                                       {"window_size": True},
                                       {"file": "main", "section": "", "key": "full", "value": "no"}]},
                                  {"value": "off", "label": "Off", "set": [
                                       {"window_size": False},
                                       {"file": "main", "section": "", "key": "full", "value": "yes"}]}]}]}
sized = load(SIZED)
check("an option with a default and window_size loads", isinstance(sized, dict), True)
for what, e_conf, g_conf, want in (("nothing saved: the default, on", {}, {}, True),
                                   ("off for the emulator", {"picture_window": "off"}, {}, False),
                                   ("off for the game only", {}, {"picture_window": "off"}, False),
                                   ("on for the game, off for the emulator", {"picture_window": "off"},
                                    {"picture_window": "on"}, True),
                                   ("an unknown value is the default", {"picture_window": "maybe"}, {}, True)):
    check(f"window_size: {what}", eo.window_size(sized, e_conf, g_conf), want)
check("window_size: options without the action leave it on", eo.window_size(load(GOOD), {"aspect": "16:9"}, {}), True)
got = []
SH = f"{T}/sizedhome"
eo.apply(sized, SH, f"{SH}/state", "x", {}, {}, got.append)
check("a default is written as the emulator's choice", (read(f"{SH}/.config/fake/sized.ini"), got), ("full = no\n", []))
eo.apply(sized, SH, f"{SH}/state", "x", {}, {"picture_window": "off"}, got.append)
check("a game's choice goes over the default", read(f"{SH}/.config/fake/sized.ini"), "full = yes\n")
eo.restore(SH, f"{SH}/state", "x", got.append)
check("... and the default is back after the run", (read(f"{SH}/.config/fake/sized.ini"), got), ("full = no\n", []))


def sized_refused(what, change):
    d = json.loads(json.dumps(SIZED))
    change(d["options"][0])
    got = load(d)
    check(what + ": refused", isinstance(got, str) and got.startswith("refused"), True)


sized_refused("a default that is not a choice", lambda o: o.update(default="maybe"))
sized_refused("a default that is not a string", lambda o: o.update(default=True))
sized_refused("window_size that is not true or false", lambda o: o["choices"][0]["set"][0].update(window_size="on"))
sized_refused("window_size in one choice only", lambda o: o["choices"][1]["set"].pop(0))
PER_SYSTEM = json.loads(json.dumps(GOOD))
PER_SYSTEM["files"]["main"]["path"] = ".config/fake/{system}/settings.ini"
check("a '{system}' settings folder loads", load(PER_SYSTEM)["files"]["main"]["path"], ".config/fake/{system}/settings.ini")
refused("another placeholder in a path", lambda d: d["files"]["main"].update(path=".config/{rom}/settings.ini"))
refused("'{system}' then '..'", lambda d: d["files"]["main"].update(path=".config/{system}/../../x.ini"))
SOME = json.loads(json.dumps(GOOD))
SOME["options"][0]["systems"] = ["n64"]
check("an option for some systems loads", load(SOME)["options"][0]["systems"], ["n64"])
refused("systems that are not a list", lambda d: d["options"][0].update(systems="n64"))
refused("systems empty", lambda d: d["options"][0].update(systems=[]))
refused("a system that is not an id", lambda d: d["options"][0].update(systems=["../n64"]))
for emu in sorted(os.listdir(DATA)):
    if os.path.exists(os.path.join(DATA, emu, "options.json")):
        try:
            eo.load_options(DATA, emu)
            check(f"the image's {emu}/options.json loads", True, True)
        except eo.OptionsError as err:
            check(f"the image's {emu}/options.json loads", str(err), True)

# ================================================================================================
CASE = "picture_window"
# A picture-sized window (window_size) breaks shaders: every emulator that has one lets the player
# turn it off (per emulator and per game), On unless they did, and says why. And no other does.
for emu in sorted(os.listdir(DATA)):
    try:
        with open(os.path.join(DATA, emu, "emulator.json")) as f:
            has = "window_size" in json.load(f)
        opts = eo.load_options(DATA, emu) or {"options": []}
    except (OSError, ValueError, eo.OptionsError):
        continue  # reported above, or not an emulator
    picture = [o for o in opts["options"] if any("window_size" in a for c in o["choices"] for a in c["set"])]
    if not has:
        check(f"{emu}: no window_size, so nothing to turn off", picture, [])
        continue
    check(f"{emu}: one picture_window option, On by default, that says it breaks shaders",
          [(o["id"], o.get("default"), [c["value"] for c in o["choices"]], "reaks shaders" in o["description"])
           for o in picture], [("picture_window", "on", ["on", "off"], True)])
    check(f"{emu}: on = sized to the picture, off = not",
          [eo.window_size(opts, {"picture_window": v}, {}) for v in ("on", "off")], [True, False])
# RetroArch's window is its own: off, it must fill the screen rather than open at video_scale 1.
ra = eo.load_options(DATA, "retroarch")
got = []
for value, want in (("off", '"true"'), ("on", '"false"')):
    h = f"{T}/rahome"
    write(f"{h}/.config/retroarch/retroarch.cfg", read(os.path.join(DATA, "retroarch", "retroarch.cfg")))
    eo.apply(ra, h, f"{h}/state", "retroarch", {"picture_window": value}, {}, got.append)
    check(f"retroarch: {value} writes video_fullscreen {want}",
          (eo.ini_get(read(f"{h}/.config/retroarch/retroarch.cfg"), "", "video_fullscreen"), got), (want, []))

# ================================================================================================
CASE = "image options.json against its seeds"
# Every choice of every shipped options.json, on the file RetroForge seeds there (empty when none):
# each setting reads back as written, a TOML/XML file still parses, and the restore gives the seed back
# byte for byte.
import tomllib
import xml.etree.ElementTree as ET
def same_files(got, want, opts, paths):
    """Byte for byte, except XML: the patcher re-serialises the root (re-indented, as Cemu itself does
    on every save), so XML compares as the canonical document, comments included, plus what precedes
    the root (the seed's comment there must survive)."""
    fmt = {p: opts["files"][n]["format"] for n in paths for p in paths[n]}
    def canon(p, text):
        if fmt[p] != "xml":
            return text
        root = ET.tostring(eo._xml_parse(text), encoding="unicode")
        return (eo.XML_PROLOG.match(text).group(0).strip(),
                ET.canonicalize(root, with_comments=True, strip_text=True))
    return {p: canon(p, t) for p, t in got.items()} == {p: canon(p, t) for p, t in want.items()}


LAUNCH = {}  # launch.conf as {system: emulator}, as retroforge-launch reads it
for line in read(os.path.join(DATA, "..", "..", "..", "..", "etc", "retroforge", "launch.conf")).splitlines():
    if "=" in line and not line.lstrip().startswith("#"):
        s, e = line.split("=", 1)
        LAUNCH[s.strip()] = e.strip()
for emu in sorted(os.listdir(DATA)):
    opts_path = os.path.join(DATA, emu, "options.json")
    if not os.path.exists(opts_path):
        continue
    try:
        opts = eo.load_options(DATA, emu)
    except eo.OptionsError:
        continue  # reported by the case above
    with open(os.path.join(DATA, emu, "emulator.json")) as f:
        seeds = {s["to"]: s["file"] for s in json.load(f).get("seed", [])}
    home = f"{T}/seedhome-{emu}"
    # A "{system}" file is the run's system's: the game level is applied for the first one.
    systems = sorted(s for s, e in LAUNCH.items() if e == emu)
    system = systems[0] if systems else None
    for option in opts["options"]:
        # An option for some systems is applied in a game of the first of them.
        osys = option["systems"][0] if "systems" in option else system
        paths = {n: eo.expand_path(f["path"], [osys] if osys else []) for n, f in opts["files"].items()}
        for choice in option["choices"]:
            for name, fdef in opts["files"].items():
                for path in eo.expand_path(fdef["path"], systems):
                    src = os.path.join(DATA, emu, seeds[path]) if path in seeds else None
                    write(os.path.join(home, path), read(src) if src else "")
            originals = {p: read(os.path.join(home, p)) for n in paths for p in paths[n]}
            got = []
            eo.apply(opts, home, f"{home}/state", emu, {}, {option["id"]: choice["value"]}, got.append,
                     systems=systems, system=osys)
            where = f"{emu} {option['id']}={choice['value']}"
            ok = not got and all(paths.values())
            for a in (a for a in choice["set"] if "file" in a):
                fdef = opts["files"][a["file"]]
                for path in paths[a["file"]]:
                    text = read(os.path.join(home, path))
                    ok = ok and eo.get_setting(fdef["format"], text, a["section"], a["key"]) == a["value"]
                    if fdef["format"] == "toml":
                        tomllib.loads(text)
                    if fdef["format"] == "xml":
                        ET.fromstring(text)
            check(f"{where}: written as declared, file still valid", (ok, got), (True, []))
            eo.restore(home, f"{home}/state", emu, got.append)
            back = {p: read(os.path.join(home, p)) for n in paths for p in paths[n]}
            check(f"{where}: restored to the seed exactly", same_files(back, originals, opts, paths), True)

# ================================================================================================
CASE = "apply and restore"
OPTS = load(GOOD)
HOME, STATE = f"{T}/home", f"{T}/state"
SETTINGS = f"{HOME}/.config/fake/settings.ini"
JOURNAL = eo.journal_path(STATE, "x")
warnings = []
warn = warnings.append
BASE = "# the player's\n[Display]\nAspectRatio = Auto\nVSync = true\n"
write(SETTINGS, BASE)

args, env = eo.apply(OPTS, HOME, STATE, "x", {}, {}, warn)
check("nothing chosen: no args, no env", (args, env), ([], {}))
check("nothing chosen: the file is untouched", read(SETTINGS), BASE)
check("nothing chosen: no journal", os.path.exists(JOURNAL), False)

args, env = eo.apply(OPTS, HOME, STATE, "x", {"aspect": "4:3"}, {}, warn)
check("emulator level: written into the emulator's file", eo.ini_get(read(SETTINGS), "Display", "AspectRatio"), "4:3")
check("emulator level: no journal (it stays)", os.path.exists(JOURNAL), False)
eo.restore(HOME, STATE, "x", warn)
check("emulator level: a restore leaves it", eo.ini_get(read(SETTINGS), "Display", "AspectRatio"), "4:3")

args, env = eo.apply(OPTS, HOME, STATE, "x", {"aspect": "4:3"}, {"aspect": "16:9"}, warn)
check("game level beats the emulator's: its args and env", (args, env), (["-wide"], {"FAKE_WIDE": "1"}))
eo.restore(HOME, STATE, "x", warn)  # what retroforge-launch does after the run and before the next
args, env = eo.apply(OPTS, HOME, STATE, "x", {"aspect": "16:9"}, {"aspect": "4:3"}, warn)
check("...and only the winner's: the emulator's 16:9 args are not added under a 4:3 game", (args, env), ([], {}))
eo.restore(HOME, STATE, "x", warn)
check("...the emulator's value is written (it stays) even under a game override",
      eo.ini_get(read(SETTINGS), "Display", "AspectRatio"), "16:9")
args, env = eo.apply(OPTS, HOME, STATE, "x", {"aspect": "4:3"}, {"aspect": "16:9"}, warn)
check("game level: written for the run", eo.ini_get(read(SETTINGS), "Display", "AspectRatio"), "16:9")
check("game level: journalled", os.path.exists(JOURNAL), True)
eo.restore(HOME, STATE, "x", warn)
check("restore: the emulator-level value is back", eo.ini_get(read(SETTINGS), "Display", "AspectRatio"), "4:3")
check("restore: the journal is gone", os.path.exists(JOURNAL), False)
check("restore: comments and other settings untouched", read(SETTINGS), BASE.replace("Auto", "4:3"))

write(SETTINGS, BASE.replace("AspectRatio = Auto\n", ""))
eo.apply(OPTS, HOME, STATE, "x", {}, {"aspect": "4:3"}, warn)
check("a setting that was absent: added for the run (file separator)", read(SETTINGS),
      "# the player's\n[Display]\nVSync = true\nAspectRatio = 4:3\n")
eo.restore(HOME, STATE, "x", warn)
check("...and absent again after (the emulator's default)", read(SETTINGS), BASE.replace("AspectRatio = Auto\n", ""))

write(SETTINGS, BASE)
eo.apply(OPTS, HOME, STATE, "x", {}, {"aspect": "16:9"}, warn)
# The launcher is SIGKILLed here (double Exit): no restore. The emulator rewrote its file on the way out.
write(SETTINGS, read(SETTINGS) + "NewKey = 1\n")
eo.restore(HOME, STATE, "x", warn)  # the next launch, before anything else
check("crash recovery: the next launch puts the value back, keeps what the emulator added",
      read(SETTINGS), BASE + "NewKey = 1\n")

warnings.clear()
before = read(SETTINGS)
eo.apply(OPTS, HOME, STATE, "x", {"aspect": "21:9"}, {}, warn)
check("an unknown value: ignored with a warning", (read(SETTINGS) == before, len(warnings)), (True, 1))

write(JOURNAL, "{ not json")
warnings.clear()
eo.restore(HOME, STATE, "x", warn)
check("an unreadable journal: removed with a warning", (os.path.exists(JOURNAL), len(warnings)), (False, 1))

os.makedirs(f"{T}/home-dir/.config/fake/settings.ini")  # a directory where the file should be
warnings.clear()
args, env = eo.apply(OPTS, f"{T}/home-dir", STATE, "x", {}, {"aspect": "16:9"}, warn)
check("an unreadable file: a warning, the args still come", (args, bool(warnings)), (["-wide"], True))
check("...and no journal for what was never patched", os.path.exists(JOURNAL), False)

write(SETTINGS, BASE)
eo.apply(OPTS, HOME, STATE, "x", {}, {"aspect": "16:9"}, warn)
os.chmod(os.path.dirname(SETTINGS), 0o500)  # the restore cannot replace the file
warnings.clear()
eo.restore(HOME, STATE, "x", warn)
os.chmod(os.path.dirname(SETTINGS), 0o700)
check("a failed restore keeps its journal for the next launch", (os.path.exists(JOURNAL), bool(warnings)), (True, True))
eo.restore(HOME, STATE, "x", warn)
check("...which then restores", (read(SETTINGS), os.path.exists(JOURNAL)), (BASE, False))

# A restore that failed, then a game launch the same way: the old original must win, not the stale override.
write(SETTINGS, BASE)
eo.apply(OPTS, HOME, STATE, "x", {}, {"aspect": "16:9"}, warn)  # game A, then killed
os.chmod(os.path.dirname(SETTINGS), 0o500)
eo.restore(HOME, STATE, "x", warn)  # next launch: the restore fails
os.chmod(os.path.dirname(SETTINGS), 0o700)
eo.apply(OPTS, HOME, STATE, "x", {}, {"aspect": "4:3"}, warn)  # game B
eo.restore(HOME, STATE, "x", warn)
check("a failed restore then another game: the player's original comes back", read(SETTINGS), BASE)

os.chmod(SETTINGS, 0o600)
eo.apply(OPTS, HOME, STATE, "x", {"aspect": "4:3"}, {}, warn)
check("a patched file keeps its permissions", oct(os.stat(SETTINGS).st_mode & 0o777), "0o600")
os.rename(SETTINGS, SETTINGS + ".real")
os.symlink(os.path.basename(SETTINGS) + ".real", SETTINGS)
eo.apply(OPTS, HOME, STATE, "x", {"aspect": "16:9"}, {}, warn)
check("a symlinked settings file stays a symlink, its target patched",
      (os.path.islink(SETTINGS), eo.ini_get(read(SETTINGS + ".real"), "Display", "AspectRatio")), (True, "16:9"))
os.unlink(SETTINGS); os.rename(SETTINGS + ".real", SETTINGS)

TOMLOPTS = {"files": {"t": {"path": "m.toml", "format": "toml", "separator": " = "}},
            "options": [{"id": "r", "label": "R", "choices": [
                {"value": "bad", "label": "bad", "set": [{"file": "t", "section": "3D", "key": "Renderer", "value": "'unterminated"}]}]}]}
write(f"{HOME}/m.toml", "[3D]\nRenderer = 1\n")
warnings.clear()
eo.apply(TOMLOPTS, HOME, STATE, "x", {"r": "bad"}, {}, warn)
check("a patch that would break the TOML is not written (melonDS would empty its config)",
      (read(f"{HOME}/m.toml"), bool(warnings)), ("[3D]\nRenderer = 1\n", True))

for what, entry in (("a path outside home", {"path": "/etc/passwd"}),
                    ("a relative path", {"path": "x.ini"}),
                    ("a multi-line value", {"value": "1\n[evil]"}),
                    ("a value that is not a string", {"value": 3}),
                    ("an odd separator", {"separator": ":"})):
    e = {"path": SETTINGS, "format": "ini", "separator": "=", "section": "Display", "key": "AspectRatio", "value": "x"}
    e.update(entry)
    write(JOURNAL, json.dumps({"version": 1, "restore": [e]}))
    write(SETTINGS, BASE)
    warnings.clear()
    eo.restore(HOME, STATE, "x", warn)
    check(f"a journal entry with {what}: the journal is dropped, nothing written",
          (read(SETTINGS), os.path.exists(JOURNAL), bool(warnings)), (BASE, False, True))

# ================================================================================================
CASE = "per-system settings folders"
# ClownMDEmu: -u ~/.config/clownmdemu/<system>, one configuration.ini per system.
PS = load(PER_SYSTEM)
MD, CD = (f"{HOME}/.config/fake/{s}/settings.ini" for s in ("md", "segacd"))
for p in (MD, CD):
    write(p, BASE)
warnings.clear()
eo.apply(PS, HOME, STATE, "x", {"aspect": "4:3"}, {}, warn, systems=["md", "segacd"], system="md")
check("emulator level: written in every system's folder",
      [eo.ini_get(read(p), "Display", "AspectRatio") for p in (MD, CD)], ["4:3", "4:3"])
eo.apply(PS, HOME, STATE, "x", {"aspect": "16:9"}, {}, warn, systems=["md", "segacd"], system=None)
check("Open (no system): the emulator level still reaches every folder",
      [eo.ini_get(read(p), "Display", "AspectRatio") for p in (MD, CD)], ["16:9", "16:9"])
eo.apply(PS, HOME, STATE, "x", {"aspect": "4:3"}, {"aspect": "16:9"}, warn, systems=["md", "segacd"], system="segacd")
check("game level: only the run's system", [eo.ini_get(read(p), "Display", "AspectRatio") for p in (MD, CD)],
      ["4:3", "16:9"])
eo.restore(HOME, STATE, "x", warn)
check("...restored to the emulator level after", [eo.ini_get(read(p), "Display", "AspectRatio") for p in (MD, CD)],
      ["4:3", "4:3"])
before = [read(p) for p in (MD, CD)]
eo.apply(PS, HOME, STATE, "x", {}, {"aspect": "16:9"}, warn, systems=[], system=None)
check("no system known at all: nothing written, no journal", ([read(p) for p in (MD, CD)], os.path.exists(JOURNAL)),
      (before, False))
check("a system that is not an id never becomes a path", eo.expand_path("a/{system}/b", ["md", "../x", "a/b"]), ["a/md/b"])
check("a path without '{system}' is itself", eo.expand_path("a/b", ["md"]), ["a/b"])

# ================================================================================================
CASE = "an option for some systems"
# RetroArch's N64 resolution: armN64's file, N64 games only; Open (no system) keeps it.
SO = load(SOME)
write(SETTINGS, BASE)
eo.apply(SO, HOME, STATE, "x", {"aspect": "4:3"}, {"aspect": "16:9"}, warn, systems=["n64", "snes"], system="snes")
check("another system's game: neither level written, no journal",
      (read(SETTINGS), os.path.exists(JOURNAL)), (BASE, False))
eo.apply(SO, HOME, STATE, "x", {"aspect": "4:3"}, {"aspect": "16:9"}, warn, systems=["n64", "snes"], system="n64")
check("its system's game: the game's value for the run", eo.ini_get(read(SETTINGS), "Display", "AspectRatio"), "16:9")
eo.restore(HOME, STATE, "x", warn)
check("...and the emulator's after", eo.ini_get(read(SETTINGS), "Display", "AspectRatio"), "4:3")
eo.apply(SO, HOME, STATE, "x", {"aspect": "16:9"}, {}, warn, systems=["n64", "snes"], system=None)
check("Open: the emulator level is written", eo.ini_get(read(SETTINGS), "Display", "AspectRatio"), "16:9")
check("for_system: the option for n64 only", ([o["id"] for o in eo.for_system(SO, "n64")["options"]],
      eo.for_system(SO, "snes")["options"], len(eo.for_system(SO, None)["options"])), (["aspect"], [], 1))
check("no warnings", warnings, [])

print(f"\n{PASS} passed, {FAIL} failed")
sys.exit(1 if FAIL else 0)
PY

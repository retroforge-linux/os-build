# steam_tool — a Steam game's compatibility tool (Game settings > RetroForge > Compatibility tool): the
# choice Steam's own Properties > Compatibility page makes. retroforge-steam-direct lists the tools and
# makes the choice (`game APPID [set tool NAME]`), and its launches without the client follow it
# (follow_tool there); retroforge-steam-proton uses the config.vdf editor below, and asks here which
# board gets our build as Steam's tool and for which games (our_proton, proton_game).
#
# WHERE STEAM KEEPS IT. <Steam>/config/config.vdf, CompatToolMapping: the game's own entry (priority
# 250, the player's) and "0", the default (75). A game with no entry gets Valve's recommendation for it
# (85 or 100) before the default: Hollow Knight ran with Proton 11.0-3 (ARM64) and Stardew Valley with
# Steam Linux Runtime 1.0 while "0" named our build (MANGMI Air X, 2026-11-27).
#
# WHICH TOOLS. Steam's page lists 17 for a Windows game and 21 for one with a Linux build. Offered here
# (user's choice, 2026-11-27):
#   - the tools in <Steam>/compatibilitytools.d: ours, and any the player added;
#   - the Protons of Steam's arm64 list (app 3043620, "Steam Frame ARM64 Compat List": Proton 11.0-3
#     (ARM64), Proton Experimental (ARM64)). Only the game's own x86 code is emulated, by the FEX each of
#     them ships. Valve builds them with LSE atomics, which the kernel emulates on an ARMv8.0 CPU:
#     "slower on this CPU" there. Not on a GPU that needs DXVK-Sarek (needs_sarek: the Adreno 610 and
#     613): Valve's Protons carry only upstream DXVK, so no DirectX game starts with them there (Among
#     Us, MANGMI Air X, 2026-11-28: "d3d11: failed to create factory (80004005)", then Unity's crash
#     handler), and the row would offer a game that does not start (user's choice, 2026-11-28);
#   - for a game with a Linux build, the Linux runtime Steam lists (app 891390's, `unlisted` 0: Steam
#     Linux Runtime 1.0). It runs that build, which is x86, all of it through Steam's FEX tool.
# Not the 14 x86 Protons (all of Wine under FEX, a 1.3 GB download and an x86 runtime), nor the tools
# Steam marks incompatible (fex, the other runtimes). A game set to one of those in Steam keeps it, and
# the row shows it. A tool that is not installed is Steam's to download, when the game next starts.
#
# VALVE'S RECOMMENDATION comes from two places in the app cache, and the first that names a tool counts:
# `extended/app_mappings` of Steam's lists (priority 100; Hollow Knight: "proton-stable") and the game's
# own Deck test result, `common/steam_deck_compatibility/configuration/recommended_runtime` (85:
# "native", or a Proton; SuperTux: "proton-10.0-3RC"). The arm64 client runs any Proton named there as
# Proton 11.0-3 (ARM64) (both games, MANGMI Air X, 2026-11-28). So a game with a Linux build can be one
# Steam starts with a Proton all the same (proton_game).
#
# DEFAULT is no entry of the game's own: Steam's choice. Except on a board where our build is Steam's
# tool (our_proton: an ARMv8.0 CPU, or a GPU that needs DXVK-Sarek), for a game Steam would start with a
# Proton, whose entry retroforge-steam-proton sets to our build at every start of the client: there
# Default sets that entry instead of removing it. Removed, the game would run with Valve's Proton until
# the client's next start put ours back, and each switch redoes Wine's prefix set-up.
#
# HOW A CHANGE IS MADE (choose):
#   - a client runs (the kept one, as a rule): through the client's own call, in its SharedJSContext
#     page over the DevTools port (steam-install-app's client): SteamClient.Apps.SpecifyCompatTool(appid,
#     name), an empty name for no entry. It applies at once, and the client writes config.vdf in the same
#     second, which is how this knows it took (Among Us, Air X, 2026-11-27). A frozen web helper is
#     woken for it (retroforge-steam-keep full: ~5 s, no window) and frozen again. With no DevTools
#     page, a kept client nothing uses is stopped and the file edited; any other client: Failed;
#   - no client: the entry is written to config.vdf, the rest of the text kept byte for byte. Never under
#     a running client: it writes its own copy over the file when it exits;
#   - while Steam runs a game: Busy. Waking the client's UI takes memory the game may need (Air X).
#
# TEST SEAMS (tests/test-steam-tool.sh): RETROFORGE_CPUINFO, RETROFORGE_PROC, RETROFORGE_STEAM_KEEP_CLI,
# RETROFORGE_STEAM_DEVTOOLS_LIB (steam-install-app, whose own seams name the port and its wait),
# RETROFORGE_STEAM_TOOL_WAIT (s to see the client's write, 5), XDG_RUNTIME_DIR (the lock),
# RETROFORGE_DEVICE_ENV and RETROFORGE_STEAM_SAREK (needs_sarek).
import contextlib
import fcntl
import functools
import importlib.machinery
import importlib.util
import json
import os
import shlex
import subprocess
import time

MAPPING = ["InstallConfigStore", "Software", "Valve", "Steam", "CompatToolMapping"]
EMPTY_VDF = '"InstallConfigStore"\n{\n}\n'  # what an edit starts from before the client wrote one
ARMV8_PROTON = "proton-cachyos-armv8-retroforge"  # steam-compat-tools' proton-cachyos-armv8.pin
ARM64_PROTON = "proton-cachyos-arm64-retroforge"  # and its proton-cachyos-arm64.pin
OWN_PRIORITY = "250"  # an entry the player made, as Steam's page writes it
ARM64_LIST, STEAMPLAY_LIST = 3043620, 891390  # Steam's tool lists in the app cache
LISTS = (ARM64_LIST, STEAMPLAY_LIST)  # the arm64 one first: its aliases win, as in the client (proton-stable)
FULLY_INSTALLED = 4
SAREK_SOCS = ("SM6115", "SM4450")  # Adreno 610 and 613: steam-compat-tools' WHICH GPUS NEED SAREK
PROC = os.environ.get("RETROFORGE_PROC", "/proc")
KEEP = os.environ.get("RETROFORGE_STEAM_KEEP_CLI", "/usr/bin/retroforge-steam-keep")
DEVTOOLS_LIB = os.environ.get("RETROFORGE_STEAM_DEVTOOLS_LIB", "/usr/lib/retroforge/steam-install-app")
SET_WAIT = float(os.environ.get("RETROFORGE_STEAM_TOOL_WAIT", "5"))

SET_JS = """(async () => {
  if (!window.SteamClient || !SteamClient.Apps || typeof SteamClient.Apps.SpecifyCompatTool !== "function") return "nofn";
  try { await Promise.race([Promise.resolve(SteamClient.Apps.SpecifyCompatTool(%d, %s)), new Promise(r => setTimeout(r, 3000))]); }
  catch (e) { return "error"; }
  return "ok";
})()"""


class Busy(Exception):
    """Steam runs a game: its tools are not changed now."""


class Failed(Exception):
    """The choice could not be made; the message says why."""


# ---- VDF text: one entry changed, the rest of the text kept as it is ---------------------------------
def tokens(text):
    """(kind, value, start, end) per token: "str", "{" or "}". ValueError on anything else."""
    i = 0
    while i < len(text):
        c = text[i]
        if c.isspace():
            i += 1
        elif text.startswith("//", i):
            end = text.find("\n", i)
            i = len(text) if end < 0 else end
        elif c in "{}":
            yield c, c, i, i + 1
            i += 1
        elif c == '"':
            j, value = i + 1, []
            while j < len(text) and text[j] != '"':
                if text[j] == "\\" and j + 1 < len(text):
                    j += 1
                value.append(text[j])
                j += 1
            if j >= len(text):
                raise ValueError("a string is not closed")
            yield "str", "".join(value), i, j + 1
            i = j + 1
        else:
            raise ValueError(f"unexpected {c!r} at {i}")


def closing(toks, i):
    depth = 0
    for j in range(i, len(toks)):
        depth += toks[j][0] == "{"
        depth -= toks[j][0] == "}"
        if depth == 0:
            return j
    raise ValueError("a section is not closed")


def find(toks, lo, hi, key):
    """(key index, value index) of key among the entries toks[lo:hi] (case-insensitive), or None."""
    i = lo
    while i < hi:
        if toks[i][0] != "str" or i + 1 >= hi:
            raise ValueError("not key/value pairs")
        j = i + 1
        if toks[i][1].lower() == key.lower():
            return i, j
        i = closing(toks, j) + 1 if toks[j][0] == "{" else j + 1
    return None


def quote(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def nest(keys, values, depth):
    pad = "\t" * depth
    if not keys:
        return "".join(f"{pad}{quote(k)}\t\t{quote(v)}\n" for k, v in values.items())
    return f"{pad}{quote(keys[0])}\n{pad}{{\n{nest(keys[1:], values, depth + 1)}{pad}}}\n"


def set_entry(text, path, values):
    """text with the section at path holding values (created when missing)."""
    toks = list(tokens(text))
    lo, hi, close, depth = 0, len(toks), None, 0
    line_of = lambda tok: text.rfind("\n", 0, tok[2]) + 1
    for n, key in enumerate(path):
        hit = find(toks, lo, hi, key)
        if hit is None:
            at = line_of(toks[close]) if close is not None else len(text)
            return text[:at] + nest(path[n:], values, depth) + text[at:]
        j = hit[1]
        if toks[j][0] != "{":
            raise ValueError(f"{key} is a value, not a section")
        close = closing(toks, j)
        lo, hi, depth = j + 1, close, depth + 1
    edits = []
    for key, value in values.items():
        hit = find(toks, lo, hi, key)
        if hit is None:
            at = line_of(toks[close])
            edits.append((at, at, "\t" * depth + f"{quote(key)}\t\t{quote(value)}\n"))
        elif toks[hit[1]][0] == "str":
            edits.append((toks[hit[1]][2], toks[hit[1]][3], quote(value)))
        else:
            raise ValueError(f"{key} is a section, not a value")
    for start, end, new in sorted(edits, reverse=True):
        text = text[:start] + new + text[end:]
    return text


def remove_entry(text, path):
    """text without the section at path, its lines gone; text itself when there is none."""
    toks = list(tokens(text))
    lo, hi = 0, len(toks)
    for n, key in enumerate(path):
        hit = find(toks, lo, hi, key)
        if hit is None or toks[hit[1]][0] != "{":
            return text
        close = closing(toks, hit[1])
        if n == len(path) - 1:
            start = text.rfind("\n", 0, toks[hit[0]][2]) + 1
            end = text.find("\n", toks[close][3])
            return text[:start] + text[len(text) if end < 0 else end + 1:]
        lo, hi = hit[1] + 1, close
    return text


def mappings(text):
    """{entry key: tool name} of CompatToolMapping in text ({} without one)."""
    toks = list(tokens(text))
    lo, hi = 0, len(toks)
    for key in MAPPING:
        hit = find(toks, lo, hi, key)
        if hit is None or toks[hit[1]][0] != "{":
            return {}
        lo, hi = hit[1] + 1, closing(toks, hit[1])
    out, i = {}, lo
    while i < hi:
        j = i + 1
        if toks[j][0] == "{":
            name = find(toks, j + 1, closing(toks, j), "name")
            out[toks[i][1]] = toks[name[1]][1] if name and toks[name[1]][0] == "str" else ""
            i = closing(toks, j) + 1
        else:
            i = j + 1
    return out


def tree(text):
    """text as nested dicts, keys as written (a tool's name is written to config.vdf as it is spelled)."""
    toks = list(tokens(text))

    def section(i, hi):
        out = {}
        while i < hi:
            if toks[i][0] != "str" or i + 1 >= hi or toks[i + 1][0] == "}":
                raise ValueError("not key/value pairs")
            if toks[i + 1][0] == "{":
                close = closing(toks, i + 1)
                out[toks[i][1]] = section(i + 2, close)
                i = close + 1
            else:
                out[toks[i][1]] = toks[i + 1][1]
                i += 2
        return out
    return section(0, len(toks))


def child(node, key):
    """node's entry for key, whatever its case; {} without one."""
    for k, v in node.items() if isinstance(node, dict) else ():
        if k.lower() == key.lower():
            return v
    return {}


def read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return ""


# ---- The CPU, the game, the tools --------------------------------------------------------------------
def lacks_atomics(cpuinfo=None):
    """True on an ARMv8.0 CPU: a core without LSE atomics (the SM6115's)."""
    try:
        with open(cpuinfo or os.environ.get("RETROFORGE_CPUINFO", "/proc/cpuinfo"), encoding="utf-8", errors="replace") as f:
            feats = [line.split(":", 1)[1].split() for line in f if line.startswith("Features")]
    except OSError:
        return False
    return any("atomics" not in x for x in feats)


@functools.lru_cache(maxsize=None)
def needs_sarek():
    """Whether this GPU needs DXVK-Sarek, by the SoC class device-env reports (RETROFORGE_STEAM_SAREK=on|off
    decides instead, when set). Asked once a run."""
    forced = os.environ.get("RETROFORGE_STEAM_SAREK")
    if forced in ("on", "off"):
        return forced == "on"
    try:
        out = subprocess.run([os.environ.get("RETROFORGE_DEVICE_ENV", "/usr/lib/retroforge/device-env")],
                             capture_output=True, text=True, timeout=30).stdout
    except (OSError, subprocess.SubprocessError):
        return False
    for line in out.splitlines():
        if line.startswith("RETROFORGE_SOC_CLASS="):
            value = shlex.split(line.split("=", 1)[1]) or [""]
            return value[0] in SAREK_SOCS
    return False


def platforms(app):
    """The platforms Steam's app cache lists for app (its node): windows, macos, linux."""
    common = app.get("appinfo", app).get("common", {})
    return [p for p in str(common.get("oslist", "")).lower().split(",") if p] if isinstance(common, dict) else []


def our_proton(cpuinfo=None):
    """The Proton build that is Steam's tool on this board, which retroforge-steam-proton sets ("" where
    Steam keeps its own): the ARMv8.0 rebuild on a CPU without LSE atomics, else Proton-CachyOS's arm64
    build where the GPU needs DXVK-Sarek, which no Proton of Valve's carries."""
    if lacks_atomics(cpuinfo):
        return ARMV8_PROTON
    return ARM64_PROTON if needs_sarek() else ""


def valve_mappings(nodes):
    """{app id: tool} of `app_mappings` in Steam's lists (nodes: their app cache nodes, others ignored):
    the games Valve itself maps to a tool on Linux. The first list that names a game counts."""
    out = {}
    for listed in LISTS:
        node = nodes.get(listed, {})
        entries = node.get("appinfo", node).get("extended", {}).get("app_mappings", {})
        for key, entry in entries.items() if isinstance(entries, dict) else ():
            if isinstance(entry, dict) and str(entry.get("platform", "linux")).lower() == "linux":
                out.setdefault(str(entry.get("appid", key)), str(entry.get("tool", "")))
    return out


def valve_tool(appid, app, mapped):
    """The tool Valve recommends for the game, "" for none (see VALVE'S RECOMMENDATION)."""
    name = mapped.get(str(appid), "")
    if not name:
        common = app.get("appinfo", app).get("common", {})
        deck = common.get("steam_deck_compatibility", {}) if isinstance(common, dict) else {}
        conf = deck.get("configuration", {}) if isinstance(deck, dict) else {}
        name = str(conf.get("recommended_runtime", "")) if isinstance(conf, dict) else ""
    return name


def proton_game(appid, app, mapped):
    """A game or demo Steam would start with a Proton, the ones our build is set for: one listed for
    Windows and not for Linux, or one with a Linux build that Valve recommends a Proton for (mapped:
    valve_mappings). A game Valve leaves on its Linux build is not one."""
    common = app.get("appinfo", app).get("common", {})
    kind = str(common.get("type", "")).lower() if isinstance(common, dict) else ""
    have = platforms(app)
    if kind not in ("game", "demo") or "windows" not in have:
        return False
    return "linux" not in have or valve_tool(appid, app, mapped).lower().startswith("proton")


def local_tools(root):
    """[{name, display, source, folder}] of <root>/compatibilitytools.d: each folder's compatibilitytool.vdf."""
    base, out = os.path.join(root, "compatibilitytools.d"), []
    try:
        folders = sorted(os.listdir(base))
    except OSError:
        return out
    for d in folders:
        folder = os.path.join(base, d)
        try:
            tools = child(child(tree(read(os.path.join(folder, "compatibilitytool.vdf"))), "compatibilitytools"), "compat_tools")
        except ValueError:
            continue
        for name, entry in tools.items() if isinstance(tools, dict) else ():
            if isinstance(entry, dict):
                out.append({"name": name, "display": str(child(entry, "display_name") or name),
                            "source": str(child(entry, "from_oslist") or "windows").lower(),
                            "folder": os.path.normpath(os.path.join(folder, str(child(entry, "install_path") or ".")))})
    return out


_nodes, _listed = {}, {}


def list_nodes(sl, root):
    """The app cache nodes of Steam's lists (LISTS); {} when the cache cannot be read. Read once a run."""
    if root not in _nodes:
        try:
            _nodes[root] = sl.app_nodes(root, set(LISTS))
        except (OSError, sl.Unreadable):
            _nodes[root] = {}
    return _nodes[root]


def listed_tools(sl, root):
    """[{name, display, source, appid, aliases, list, unlisted}] of Steam's own tools, from its lists in the
    app cache, in LISTS' order; [] when the cache cannot be read or holds no list."""
    if root in _listed:
        return _listed[root]
    out, nodes = [], list_nodes(sl, root)
    for listed in LISTS:
        node = nodes.get(listed, {})
        tools = node.get("appinfo", node).get("extended", {}).get("compat_tools", {})
        for name, entry in tools.items() if isinstance(tools, dict) else ():
            if isinstance(entry, dict):
                out.append({"name": str(name), "display": str(entry.get("display_name") or name),
                            "source": str(entry.get("from_oslist", "")).lower(), "appid": str(entry.get("appid", "")),
                            "aliases": [a for a in str(entry.get("aliases", "")).lower().split(",") if a],
                            "list": listed, "unlisted": str(entry.get("unlisted", 0))})
    _listed[root] = out
    return out


def app_folder(sl, root, appid):
    """The folder of a fully installed app (one of Steam's tools), in any library; "" without one."""
    if not str(appid).isdigit():
        return ""
    for lib in sl.library_dirs(root):
        fields = {}
        for depth, key, value in sl.vdf_pairs(sl.read_text(os.path.join(lib, "steamapps", f"appmanifest_{appid}.acf"))):
            if depth == 1 and key in ("installdir", "StateFlags") and key not in fields:
                fields[key] = value
        if fields:
            flags, name = fields.get("StateFlags", "0"), fields.get("installdir", "")
            folder = os.path.join(lib, "steamapps", "common", name)
            done = flags.isdigit() and int(flags) & FULLY_INSTALLED
            return folder if done and name.strip("/.") and os.path.isdir(folder) else ""
    return ""


def find_tool(sl, root, name):
    """The tool a CompatToolMapping name means: {name, display, source, folder ("" while it is not
    installed)}; None for a name nothing lists. A compatibilitytools.d tool first, then Steam's own by
    name, then by alias."""
    want = name.lower()
    for tool in local_tools(root):
        if tool["name"].lower() == want:
            return tool
    listed = listed_tools(sl, root)
    for tool in [t for t in listed if t["name"].lower() == want] + [t for t in listed if want in t["aliases"]]:
        return dict(tool, folder=app_folder(sl, root, tool["appid"]))
    return None


def config_path(root):
    return os.path.join(root, "config", "config.vdf")


def own_tool(root, appid):
    """The name in appid's own CompatToolMapping entry; "" for none, or a config.vdf that does not parse."""
    try:
        return mappings(read(config_path(root))).get(str(appid), "")
    except ValueError:
        return ""


def short(display):
    """A tool's name as Main menu > Apps > Proton shows it: without " (RetroForge)"."""
    return display[:-len(" (RetroForge)")] if display.endswith(" (RetroForge)") else display


def our_default(sl, root, appid, app):
    """Our build's name where it is the game's Default (see DEFAULT) and is installed, else ""."""
    name = our_proton()
    if not (name and proton_game(appid, app, valve_mappings(list_nodes(sl, root)))):
        return ""
    ours = [t for t in local_tools(root) if t["name"] == name and os.path.isfile(os.path.join(t["folder"], "proton"))]
    return name if ours else ""


def choices(sl, root, appid, app):
    """What the row shows: {"choice": "default" or a tool's name, "default": Default's label, "tools":
    [{name, label}] (see WHICH TOOLS), and "other", the label of a choice the list does not offer}."""
    have, armv8, default = platforms(app), lacks_atomics(), our_default(sl, root, appid, app)
    local, tools, sarek = local_tools(root), [], needs_sarek()
    for tool in local:
        if tool["source"] in have and tool["name"] != default:
            tools.append({"name": tool["name"], "label": short(tool["display"])})
    for tool in listed_tools(sl, root):
        if tool["source"] not in have:
            continue
        if tool["list"] == ARM64_LIST and tool["source"] == "windows":
            if sarek:
                continue   # Valve's Protons have no DXVK-Sarek: no DirectX game starts on this GPU
            notes = ["slower on this CPU"] if armv8 else []
        elif tool["source"] == "linux" and tool["unlisted"] == "0":
            notes = ["the game's Linux build"]
        else:
            continue
        if not app_folder(sl, root, tool["appid"]):
            notes.append("not installed")
        tools.append({"name": tool["name"], "label": ", ".join([tool["display"]] + notes)})
    ours = next((short(t["display"]) for t in local if t["name"] == default), default)
    out = {"choice": "default", "default": f"Default ({ours})" if default else "Default (Steam's choice)", "tools": tools}
    own = own_tool(root, appid)
    if own and own.lower() != default.lower():
        found = find_tool(sl, root, own)
        name = (found["name"] if found else own).lower()
        out["choice"] = next((t["name"] for t in tools if t["name"].lower() == name), own)
        if not any(t["name"] == out["choice"] for t in tools):
            out["other"] = short(found["display"]) if found else own
    return out


# ---- Making the choice --------------------------------------------------------------------------------
def client_pid():
    """The Steam client's PID: ~/.steam/steam.pid, while it names a live process called steam; else None."""
    try:
        with open(os.path.join(os.path.expanduser("~"), ".steam", "steam.pid")) as f:
            pid = f.read().strip()
        with open(os.path.join(PROC, pid, "comm")) as f:
            return pid if pid.isdigit() and f.read().strip() == "steam" else None
    except OSError:
        return None


def game_running():
    """True while Steam runs a game: one of its reapers (`reaper SteamLaunch AppId=...`, not OGUI's own,
    which starts every app under one: retroforge-steam-keep's `launches`)."""
    try:
        pids = [p for p in os.listdir(PROC) if p.isdigit()]
    except OSError:
        return False
    for pid in pids:
        try:
            with open(os.path.join(PROC, pid, "comm")) as f:
                if f.read().strip() != "reaper":
                    continue
            with open(os.path.join(PROC, pid, "cmdline"), "rb") as f:
                argv = f.read().split(b"\0")
        except OSError:
            continue
        if len(argv) >= 3 and argv[1] == b"SteamLaunch" and b"opengamepadui" not in argv[0]:
            return True
    return False


def keep(*args):
    """retroforge-steam-keep ARGS: (exit status, what it printed); (None, "") when it cannot run."""
    try:
        res = subprocess.run([KEEP, *args], capture_output=True, text=True, timeout=90)
    except (OSError, subprocess.SubprocessError):
        return None, ""
    return res.returncode, res.stdout.strip()


def devtools():
    """steam-install-app as a module: its DevTools client (page_url, evaluate)."""
    loader = importlib.machinery.SourceFileLoader("steam_install_app", DEVTOOLS_LIB)
    spec = importlib.util.spec_from_loader("steam_install_app", loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def settled(root, appid, name, wait):
    """True once config.vdf has name as appid's own tool, within wait s."""
    deadline = time.monotonic() + wait
    while True:
        if own_tool(root, appid).lower() == name.lower():
            return True
        if time.monotonic() >= deadline:
            return False
        time.sleep(0.2)


def write(root, appid, name):
    """config.vdf with name as appid's own tool, or without an entry for it (no client runs)."""
    path, key = config_path(root), MAPPING + [str(appid)]
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    except FileNotFoundError:
        text = EMPTY_VDF
    new = set_entry(text, key, {"name": name, "config": "", "priority": OWN_PRIORITY}) if name else remove_entry(text, key)
    if new == text:
        return
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path + ".part", "w", encoding="utf-8") as f:
        f.write(new)
    os.replace(path + ".part", path)


def client_call(expression, done, log, what):
    """The running client evaluates expression in its SharedJSContext page (it answers "ok" once it has
    made the call), and done() then says whether the client did what was asked. (True when it did, whether
    its web helper was frozen.) A frozen web helper is woken for it (retroforge-steam-keep full, held
    while this runs) and frozen again; one that was awake, Steam's UI open, is left awake."""
    me = str(os.getpid())
    woke = keep("full", me)[1] == "woke"
    try:
        dt = devtools()
        url = dt.page_url()
        deadline = time.monotonic() + dt.WAIT
        # A web helper just woken serves its page a moment before SteamClient is there ("nofn"), and a
        # call the client did not take shows as nothing done: both are tried again until the wait is over.
        while url:
            if dt.evaluate(url, expression) == "ok" and done():
                return True, woke
            if time.monotonic() >= deadline:
                break
            time.sleep(0.5)
        log(f"{what}: " + ("Steam's client did not take it" if url else f"no DevTools page from Steam's UI at {dt.DEVTOOLS}"))
    except (OSError, ValueError) as err:
        log(f"{what}: DevTools: {err}")
    finally:
        if woke:
            keep("minimal", me)
    return False, woke


def live(root, appid, name, log):
    """The running client makes name appid's tool (see HOW A CHANGE IS MADE); Failed when it does not."""
    took, woke = client_call(SET_JS % (appid, json.dumps(name)), lambda: settled(root, appid, name, SET_WAIT), log, f"app {appid}")
    if took:
        return
    # Without the client's own call: a kept client nothing uses is stopped, and the file edited.
    if woke and keep("stop-unused")[0] == 0:
        for _ in range(60):
            if not client_pid():
                write(root, appid, name)
                log(f"app {appid}: stopped the kept Steam to set its tool; the next launch starts it again")
                return
            time.sleep(0.25)
    raise Failed("the running Steam client did not take it")


@contextlib.contextmanager
def locked():
    """One change at a time: two would each wake and freeze the client's web helper."""
    path = os.path.join(os.environ.get("XDG_RUNTIME_DIR") or "/tmp", "retroforge-steam-tool.lock")
    with open(path, "a") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        yield


def choose(sl, root, appid, app, value, log):
    """Make value ("default", or a tool's name) appid's tool, as Steam's own page would. True when
    anything changed. Busy while Steam runs a game; Failed when it could not be done."""
    name = our_default(sl, root, appid, app) if value == "default" else value
    try:
        with locked():
            if own_tool(root, appid).lower() == name.lower():
                return False
            if game_running():
                raise Busy("Steam is running a game")
            if client_pid():
                live(root, appid, name, log)
            else:
                write(root, appid, name)
    except (OSError, ValueError) as err:
        raise Failed(f"{config_path(root)}: {err}")
    return True

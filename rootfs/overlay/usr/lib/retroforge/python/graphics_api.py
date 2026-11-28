# graphics_api — the graphics API a Windows game renders with (Game settings > RetroForge > Graphics API),
# for Steam games (retroforge-steam-direct) and the stores' (/usr/lib/retroforge/store).
#
# A game picks its API itself; the engines that ship more than one take it from the command line:
#   Unity    -force-d3d11, -force-d3d12, -force-vulkan
#   Unreal   -dx11, -dx12, -vulkan (no OpenGL: Unreal deprecated its OpenGL renderer in 4.26 and dropped it
#            in 5, and the GL marker below also turns up from other libraries: Dispatch, an Unreal 5 game)
#   Godot 4  --rendering-driver vulkan|d3d12; OpenGL is its Compatibility renderer, so that one is
#            --rendering-method gl_compatibility --rendering-driver opengl3
# Under Proton, DirectX goes through DXVK (Sarek on the Adreno 610/613) or vkd3d-proton, and Vulkan and
# OpenGL go to the device's own driver through Wine.
#
# WHAT A GAME OFFERS. A Unity build says which APIs it was made with: the BuildSettings object in
# <game>_Data/globalgamemanagers ends with m_GraphicsAPIs, Unity's GraphicsDeviceType numbers (2
# Direct3D 11, 18 Direct3D 12, 21 Vulkan; its last field from Unity 5.6 to 6000.3). The player checks a
# forced API against that list: one not in it logs "Forced GfxDevice 'Vulkan' was not built from
# editor, shaders will not be available" and InitializeEngineGraphics fails (Megabonk lists only [2],
# RP5 2026-11-28), except Direct3D 12, which it lets through on Direct3D 11's shaders (UnityPlayer.dll
# 2023.2.22). So for Unity: each API listed, and DirectX 12 too with a D3D12/ folder (its runtime)
# beside a game that lists DirectX 11 (Megabonk has one). A list that cannot be read (Unity before 5.6,
# or data packed into data.unity3d) offers DirectX 11, and DirectX 12 with that folder, never Vulkan.
# Unity's player links every API, so its binary says nothing.
# Unreal and Godot: what their binary links (the functions it looks up are there by name:
# vkGetInstanceProcAddr, D3D11CreateDevice, D3D12CreateDevice, wglCreateContextAttribsARB). Whether
# their shaders were built for each is not in their files where they can be read (Unreal's pak index is
# encrypted: Ghostrunner, 2026-11-26). A choice the game was not built for can fail to start or draw
# wrong; Default is the game's own.
#
# A scan reads the engine binary (Ghostrunner's 84 MB exe: ~1 s from the SD card) and is cached in
# <cache>/retroforge/graphics-apis.json, keyed by the binary's path, size and mtime; Unity's list is a
# few KB at the start of globalgamemanagers, read each time. A launch does not scan: args() needs only
# the engine, which a few file checks find.
#
# NEVER RAISES: a game this cannot read offers nothing, and launches without a flag.

import glob
import json
import mmap
import os
import struct

APIS = ("d3d11", "d3d12", "vulkan", "opengl")  # the order a row lists them in
LABELS = {"d3d11": "DirectX 11", "d3d12": "DirectX 12", "vulkan": "Vulkan", "opengl": "OpenGL"}
ARGS = {
    "unity": {"d3d11": ["-force-d3d11"], "d3d12": ["-force-d3d12"], "vulkan": ["-force-vulkan"]},
    "unreal": {"d3d11": ["-dx11"], "d3d12": ["-dx12"], "vulkan": ["-vulkan"]},
    "godot": {"vulkan": ["--rendering-driver", "vulkan"], "d3d12": ["--rendering-driver", "d3d12"],
              "opengl": ["--rendering-method", "gl_compatibility", "--rendering-driver", "opengl3"]},
}
MARKS = {"vulkan": b"vkGetInstanceProcAddr", "d3d11": b"D3D11CreateDevice", "d3d12": b"D3D12CreateDevice",
         "opengl": b"wglCreateContextAttribsARB"}
UNITY_DEVICES = {"d3d11": 2, "d3d12": 18, "vulkan": 21}  # UnityEngine.Rendering.GraphicsDeviceType


def _cache_path():
    return os.path.join(os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"), "retroforge",
                        "graphics-apis.json")


def _exes(folder):
    try:
        return sorted(e.path for e in os.scandir(folder) if e.is_file() and e.name.lower().endswith(".exe"))
    except OSError:
        return []


def _subdirs(folder):
    try:
        return sorted(e.path for e in os.scandir(folder) if e.is_dir())
    except OSError:
        return []


def _unreal_binary(game_dir):
    """An Unreal game's own program: the largest exe in <project>/Binaries/Win64 (the one at the top is
    its bootstrap, which hands its arguments on), else None. Unreal games have an Engine folder."""
    if not os.path.isdir(os.path.join(game_dir, "Engine")):
        return None
    found = [p for project in _subdirs(game_dir) if os.path.basename(project) != "Engine"
             for p in _exes(os.path.join(project, "Binaries", "Win64"))]
    try:
        return max(found, key=os.path.getsize) if found else None
    except OSError:
        return None


def _unity_player(game_dir, exe):
    """The folder of a Unity game's player (UnityPlayer.dll, else an <exe>_Data folder), else None."""
    folders = ([os.path.dirname(exe)] if exe else []) + [game_dir] + _subdirs(game_dir)
    for folder in folders:
        if os.path.isfile(os.path.join(folder, "UnityPlayer.dll")):
            return folder
        if any(os.path.isdir(p[:-4] + "_Data") for p in _exes(folder)):
            return folder
    return None


def _unity_built(player, exe):
    """The GraphicsDeviceType numbers a Unity game was built with (BuildSettings.m_GraphicsAPIs in its
    <exe>_Data/globalgamemanagers), else None when there is no list this can read."""
    named = [exe[:-4] + "_Data"] if exe and exe.lower().endswith(".exe") else []
    data = next((d for d in named + [p[:-4] + "_Data" for p in _exes(player)]
                 if os.path.isfile(os.path.join(d, "globalgamemanagers"))), None)
    if not data:
        return None
    try:
        with open(os.path.join(data, "globalgamemanagers"), "rb") as f:
            head = f.read(48)
            form, offset = struct.unpack_from(">8xII", head)
            if form < 17:  # before Unity 5.6, which brought Vulkan
                return None
            if form >= 22:
                offset = struct.unpack_from(">12xQ", head, 20)[0]
            start = 48 if form >= 22 else 20
            e = ">" if head[16] else "<"
            f.seek(start)
            built = _build_settings(f.read(min(offset - start, 1 << 24)), form, e)
            if not built:
                return None
            f.seek(offset + built[0])
            obj = f.read(built[1])
    except (OSError, ValueError, IndexError, struct.error):
        return None
    return _graphics_apis(obj, built[2], e)


def _build_settings(meta, form, e):
    """(start, size) of the BuildSettings object (class 141) from a SerializedFile's metadata (format 17
    and later), and the Unity version it names, else None."""
    def i32(p):  # a count or size, which a damaged file must not make negative or past its end
        n = struct.unpack_from(e + "i", meta, p)[0]
        if not 0 <= n <= len(meta):
            raise ValueError(n)
        return n

    pos = meta.index(b"\0")
    version, pos = meta[:pos], pos + 5  # and the target platform
    typetree, pos = meta[pos], pos + 1
    classes, pos = [], pos + 4
    for _ in range(i32(pos - 4)):
        cid = struct.unpack_from(e + "i", meta, pos)[0]
        pos += 4 + 3 + (16 if cid == 114 else 0) + 16  # stripped, script index, script id, type hash
        if typetree:
            pos += 8 + i32(pos) * (32 if form >= 19 else 24) + i32(pos + 4)  # nodes, their strings
            if form >= 21:
                pos += 4 + 4 * i32(pos)
        classes.append(cid)
    pos += 4
    for _ in range(i32(pos - 4)):
        pos = (pos + 3) & ~3
        if form >= 22:
            start, size, tid = struct.unpack_from(e + "8xQIi", meta, pos)
            pos += 24
        else:
            start, size, tid = struct.unpack_from(e + "8xIIi", meta, pos)
            pos += 20
        if classes[tid] == 141:
            return start, size, version
    return None


def _graphics_apis(obj, version, e):
    """m_GraphicsAPIs from a BuildSettings object: the last field, after m_Version and, by Unity version,
    m_AuthToken (5.6-2021, 6000) and two hash maps of 20- and 32-byte entries (5.6-2019). Found by the
    layout that ends exactly at the object's end with only device numbers in it (a token's characters
    or a hash read as numbers are far larger); None when none does."""
    def count(p):
        return struct.unpack_from(e + "i", obj, p)[0] if 0 <= p <= len(obj) - 4 else -1

    def after(p, entry):  # past a string (entry 1) or a map
        n = count(p)
        return -1 if n < 0 else (p + 4 + n * entry + 3) & ~3

    at = obj.find(struct.pack(e + "i", len(version)) + version)
    if at < 0:
        return None
    at = (at + 4 + len(version) + 3) & ~3
    for p in (at, after(at, 1), after(after(after(at, 1), 20), 32)):
        n = count(p)
        if 0 <= n <= 64 and p + 4 + 4 * n == len(obj):
            found = struct.unpack_from(e + f"{n}i", obj, p + 4)
            if all(0 <= d < 64 for d in found):
                return set(found)
    return None


def _godot_major(path):
    """Godot's major version from a .pck, or from an exe with its pack at the end (12 bytes: the pack's
    size, then GDPC), else None."""
    try:
        with open(path, "rb") as f:
            head = f.read(20)
            if head[:4] != b"GDPC":
                f.seek(-12, os.SEEK_END)
                size, magic = struct.unpack("<Q4s", f.read(12))
                if magic != b"GDPC":
                    return None
                f.seek(-12 - size, os.SEEK_END)
                head = f.read(20)
            if head[:4] != b"GDPC" or len(head) < 20:
                return None
            return struct.unpack("<IIII", head[4:20])[1]
    except (OSError, struct.error, ValueError):
        return None


def _godot_binary(game_dir, exe):
    """A Godot 4 game's program, else None: an exe beside a Godot 4 .pck, or one with the pack in it."""
    for folder in ([os.path.dirname(exe)] if exe else []) + [game_dir]:
        exes = _exes(folder)
        for pck in sorted(glob.glob(os.path.join(glob.escape(folder), "*.pck"))):
            if _godot_major(pck) == 4:
                same = [e for e in exes if e[:-4].lower() == pck[:-4].lower()]
                return (same or ([exe] if exe else []) or exes or [pck])[0]
        for e in ([exe] if exe else []) + exes:
            if _godot_major(e) == 4:
                return e
    return None


def engine(game_dir, exe=None):
    """(engine, its binary) for a Windows game's folder (and the program it starts, when known):
    ("unity" | "unreal" | "godot", path), else (None, None)."""
    if not game_dir or not os.path.isdir(game_dir):
        return None, None
    player = _unity_player(game_dir, exe)
    if player:
        return "unity", os.path.join(player, "UnityPlayer.dll")
    binary = _unreal_binary(game_dir)
    if binary:
        return "unreal", binary
    binary = _godot_binary(game_dir, exe)
    if binary:
        return "godot", binary
    return None, None


def _linked(binary):
    """The APIs a binary links (MARKS), cached by path, size and mtime."""
    try:
        st = os.stat(binary)
    except OSError:
        return []
    key = f"{binary}|{st.st_size}|{int(st.st_mtime)}"
    path = _cache_path()
    try:
        with open(path, encoding="utf-8") as f:
            cache = json.load(f)
    except (OSError, ValueError):
        cache = {}
    cache = cache if isinstance(cache, dict) else {}
    if isinstance(cache.get(key), list):
        return cache[key]
    try:
        with open(binary, "rb") as f, mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as m:
            found = [api for api in APIS if m.find(MARKS[api]) >= 0]
    except (OSError, ValueError):
        return []
    cache = {k: v for k, v in cache.items() if not k.startswith(binary + "|")}
    cache[key] = found
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path + ".part", "w", encoding="utf-8") as f:
            json.dump(cache, f)
        os.replace(path + ".part", path)
    except OSError:
        pass
    return found


def offered(game_dir, exe=None):
    """(engine, [the APIs a row offers, in APIS order]) for a Windows game: (None, []) when it has one
    API or none this knows of."""
    name, binary = engine(game_dir, exe)
    if not name:
        return None, []
    if name == "unity":
        player = os.path.dirname(binary)
        built = _unity_built(player, exe)
        built = {UNITY_DEVICES["d3d11"]} if built is None else built
        apis = [a for a, n in UNITY_DEVICES.items() if n in built]
        if UNITY_DEVICES["d3d11"] in built and os.path.isdir(os.path.join(player, "D3D12")):
            apis.append("d3d12")
    else:
        apis = [a for a in _linked(binary) if a in ARGS[name]]
    apis = [a for a in APIS if a in apis]
    return (name, apis) if len(apis) > 1 else (None, [])


def args(game_dir, exe, api):
    """The words that make a game render with `api`: [] for "default", an engine this does not know or
    an API its engine does not take."""
    if api not in APIS:
        return []
    name, _ = engine(game_dir, exe)
    return list(ARGS.get(name, {}).get(api, []))


def with_args(words, extra):
    """words with extra after them, unless extra's first word is in words already (the player's own)."""
    return list(words) if not extra or extra[0] in words else list(words) + list(extra)

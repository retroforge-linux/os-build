#!/usr/bin/env bash
# Offline test for python/graphics_api.py: which graphics APIs Game settings > RetroForge > Graphics API
# offers a Unity game.
#
#   tests/test-graphics-api.sh
#
# WHY THIS EXISTS. A Unity player refuses a forced API its build does not list (BuildSettings'
# m_GraphicsAPIs in globalgamemanagers): Megabonk lists only Direct3D 11, so -force-vulkan logged
# "Forced GfxDevice 'Vulkan' was not built from editor, shaders will not be available" and the game never
# started (RP5, 2026-11-28). So the row offers what the list has, read in every layout Unity has written
# it in, and no Vulkan when the list cannot be read. The files come from tests/lib-unity-data.py.
#
# test-store.sh and test-steam-direct.sh cover the row and the launch flag through their tools.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/rootfs/overlay/usr/lib/retroforge/python"
[ -f "$LIB/graphics_api.py" ] || { echo "missing input: $LIB/graphics_api.py" >&2; exit 1; }

T="$(mktemp -d)" && [ -d "$T" ] || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$T"' EXIT

# -I: isolated (no user site, no cwd on sys.path); -B: no __pycache__ inside rootfs/overlay.
XDG_CACHE_HOME="$T/cache" python3 -I -B - "$LIB" "$T" "$ROOT/tests/lib-unity-data.py" <<'PY'
import os, random, runpy, shutil, struct, sys
sys.path.insert(0, sys.argv[1])
import graphics_api as ga

T = sys.argv[2]
unity_data = runpy.run_path(sys.argv[3])["write"]
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


def game(name, layout="2023", apis=(2,), d3d12=False, typetree=False, sub="", exe="Game.exe"):
    """A Unity game's folder: its player (in sub), <exe>_Data/globalgamemanagers listing apis, D3D12/."""
    top = os.path.join(T, name)
    shutil.rmtree(top, ignore_errors=True)
    player = os.path.join(top, sub)
    os.makedirs(os.path.join(player, exe[:-4] + "_Data"))
    for f in ("UnityPlayer.dll", exe):
        open(os.path.join(player, f), "w").close()
    if d3d12:
        os.makedirs(os.path.join(player, "D3D12"))
    if layout:
        unity_data(os.path.join(player, exe[:-4] + "_Data", "globalgamemanagers"), layout, list(apis), typetree)
    return top, os.path.join(player, exe)


CASE = "Megabonk"
# Unity 2023.2.22f1, m_GraphicsAPIs [2], a D3D12/ folder (its D3D12Core.dll), as on the RP5 2026-11-28.
top, exe = game("Megabonk", "2023", [2], d3d12=True, exe="Megabonk.exe")
check("DirectX 11 and 12, no Vulkan: its build lists only Direct3D 11", ga.offered(top, exe), ("unity", ["d3d11", "d3d12"]))
check("the same without the program's name", ga.offered(top), ("unity", ["d3d11", "d3d12"]))
shutil.rmtree(os.path.join(top, "D3D12"))
check("without its D3D12 folder: one API, no row", ga.offered(top, exe), (None, []))

CASE = "every layout"
for layout in ("2018", "2019", "2020", "2023", "6000"):
    for tt in (False, True):
        top, exe = game("Layout", layout, [2, 21], typetree=tt)
        how = f"{layout}{' with type trees' if tt else ''}"
        check(f"{how}: Direct3D 11 and Vulkan listed, both offered", ga.offered(top, exe), ("unity", ["d3d11", "vulkan"]))
        top, exe = game("Layout", layout, [21, 18, 2], typetree=tt)
        check(f"{how}: all three, in the row's order", ga.offered(top, exe), ("unity", ["d3d11", "d3d12", "vulkan"]))

CASE = "what the build lists"
top, exe = game("Dx12Vk", "6000", [18, 21])
check("no Direct3D 11 listed: not offered (the player refuses it)", ga.offered(top, exe), ("unity", ["d3d12", "vulkan"]))
top, exe = game("Dx12Only", "6000", [18], d3d12=True)
check("Direct3D 12 only: one API, no row", ga.offered(top, exe), (None, []))
top, exe = game("VkOnly", "2020", [21])
check("Vulkan only: one API, no row", ga.offered(top, exe), (None, []))
top, exe = game("Gl", "2020", [2, 17])
check("OpenGL Core listed: not a choice for Unity here", ga.offered(top, exe), (None, []))
top, exe = game("Empty", "2023", [])
check("an empty list: nothing", ga.offered(top, exe), (None, []))
top, exe = game("Vk", "2023", [2, 21])
check("args: Vulkan's flag", ga.args(top, exe, "vulkan"), ["-force-vulkan"])
unity_data(os.path.join(os.path.dirname(exe), "Game_Data", "globalgamemanagers"), "2023", [2])
check("read each time: a rebuilt list counts at once", ga.offered(top, exe), (None, []))

CASE = "which _Data"
top, exe = game("Sub", "2019", [2, 21], sub="x64Vk")
check("a player in a subfolder", ga.offered(top), ("unity", ["d3d11", "vulkan"]))
top, exe = game("Two", "2023", [2, 21])
os.makedirs(os.path.join(top, "Launcher_Data"))
open(os.path.join(top, "Launcher.exe"), "w").close()
unity_data(os.path.join(top, "Launcher_Data", "globalgamemanagers"), "2023", [2])
check("the program's own <exe>_Data", ga.offered(top, exe), ("unity", ["d3d11", "vulkan"]))
check("another program's", ga.offered(top, os.path.join(top, "Launcher.exe")), (None, []))

CASE = "no list"
gg = lambda top: os.path.join(top, "Game_Data", "globalgamemanagers")
top, exe = game("Old", "5.4", [2, 21], d3d12=True)
check("before Unity 5.6 (format 15): DirectX 11 and 12 by its folder, never Vulkan", ga.offered(top, exe),
      ("unity", ["d3d11", "d3d12"]))
top, exe = game("Packed", None, d3d12=True)
open(os.path.join(top, "Game_Data", "data.unity3d"), "wb").close()
check("data packed into data.unity3d: the same", ga.offered(top, exe), ("unity", ["d3d11", "d3d12"]))
top, exe = game("Cut", "2023", [2, 21], d3d12=True)
data = open(gg(top), "rb").read()
for cut in (0, 10, 40, data.rindex(struct.pack("<i", 21)) + 2):  # the last: inside the list
    open(gg(top), "wb").write(data[:cut])
    check(f"a file cut at {cut} bytes: no Vulkan", ga.offered(top, exe), ("unity", ["d3d11", "d3d12"]))
open(gg(top), "wb").write(data.replace(b"2023.2.22f1\0", b"2023.2.21f1\0", 1))
check("BuildSettings naming another Unity than the file: no list, no Vulkan", ga.offered(top, exe),
      ("unity", ["d3d11", "d3d12"]))
noise = random.Random(7)
for i in range(200):
    open(gg(top), "wb").write(data[:48] + noise.randbytes(len(data) - 48) if i % 2 else noise.randbytes(len(data)))
    if ga.offered(top, exe) != ("unity", ["d3d11", "d3d12"]):
        break
check("noise, in its header or after it: no Vulkan, no exception", ga.offered(top, exe), ("unity", ["d3d11", "d3d12"]))
types = data.index(b"2023.2.22f1\0") + 12 + 5
open(gg(top), "wb").write(data[:types] + struct.pack("<i", 0x7FFFFFFF) + data[types + 4:])
check("a type count of 2^31 - 1: given up at once", ga.offered(top, exe), ("unity", ["d3d11", "d3d12"]))
os.remove(gg(top))
os.mkdir(gg(top))
check("a folder in its place", ga.offered(top, exe), ("unity", ["d3d11", "d3d12"]))

print(f"\n{PASS} passed, {FAIL} failed")
sys.exit(1 if FAIL else 0)
PY

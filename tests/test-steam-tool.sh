#!/usr/bin/env bash
# Offline test for a Steam game's compatibility tool (Game settings > RetroForge > Compatibility tool):
# python/steam_tool.py through `retroforge-steam-direct game APPID [set tool NAME]`.
#
#   tests/test-steam-tool.sh
#
# WHY THIS EXISTS. Each rule below fails as a game that starts with the wrong tool, a Steam setting
# the player did not make, or a config.vdf the client throws away:
#   the list: the tools in compatibilitytools.d, the Protons of Steam's arm64 list and, for a game with
#     a Linux build, the Linux runtime Steam lists; not the x86 Protons nor the tools Steam hides; a tool
#     Steam has yet to download says so, and Valve's Protons say they are slower on an ARMv8.0 CPU; on a
#     GPU that needs DXVK-Sarek (Adreno 610/613) Valve's Protons are not offered: no DirectX game starts
#     with them there;
#   Default: no entry of the game's own, except where our build is Steam's tool (an ARMv8.0 CPU, a GPU
#     that needs DXVK-Sarek) for a game Steam would start with a Proton (Windows-only, or with a Linux
#     build that Valve maps to a Proton all the same: Hollow Knight, SuperTux), whose default is the
#     entry retroforge-steam-proton gives it (our build);
#   what the row shows: the game's own entry, an alias as the tool it means, a tool the list does not
#     offer as it is;
#   no client running: the entry is written to config.vdf and the rest stays byte for byte; Default
#     removes it; a name is written as its tool spells it;
#   a client running: the client's own call makes the change (its web helper woken and frozen again
#     when it was frozen), and config.vdf is never written under it; with no DevTools page a kept
#     client nothing uses is stopped first; anything else fails and says so;
#   Steam running a game: nothing changes (exit 3).
# Steam's DevTools port is a stand-in that takes the page's one call and, like the client, writes
# config.vdf itself; the client's app cache is written by tests/lib-steam-appinfo.py.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIRECT="$ROOT/rootfs/overlay/usr/bin/retroforge-steam-direct"
LIBRARY="$ROOT/rootfs/overlay/usr/lib/retroforge/steam-library"
DEVLIB="$ROOT/rootfs/overlay/usr/lib/retroforge/steam-install-app"
PYLIB="$ROOT/rootfs/overlay/usr/lib/retroforge/python"
for f in "$DIRECT" "$LIBRARY" "$DEVLIB" "$PYLIB/steam_tool.py"; do [ -f "$f" ] || { echo "missing: $f" >&2; exit 1; }; done

PASS=0; FAIL=0; CASE=""
ok()  { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }

T="$(mktemp -d)" && [ -d "$T" ] || { echo "mktemp -d failed" >&2; exit 1; }
SERVER=""
trap '[ -n "$SERVER" ] && kill "$SERVER" 2>/dev/null; rm -rf "$T"' EXIT

H="$T/home"; S="$H/.local/share/Steam"; VDF="$S/config/config.vdf"; TOOLS="$S/compatibilitytools.d"
OURS=proton-cachyos-armv8-retroforge
mkdir -p "$S/config" "$T/proc" "$T/run" "$T/dev" "$H/.steam"
printf 'processor\t: 0\nFeatures\t: fp asimd evtstrm aes pmull sha1 sha2 crc32 cpuid\n' >"$T/v80"
printf 'processor\t: 0\nFeatures\t: fp asimd aes pmull sha1 sha2 crc32 atomics fphp cpuid\n' >"$T/v82"

acf() {  # acf <appid> <installdir> <StateFlags>
  mkdir -p "$S/steamapps"
  printf '"AppState"\n{\n\t"appid"\t\t"%s"\n\t"name"\t\t"%s"\n\t"StateFlags"\t\t"%s"\n\t"installdir"\t\t"%s"\n}\n' "$1" "$2" "$3" "$2" \
    >"$S/steamapps/appmanifest_$1.acf"
}
tool() {  # tool <folder> <internal name> <display name>: a compatibilitytools.d Proton
  mkdir -p "$TOOLS/$1"; printf '#!/bin/sh\n' >"$TOOLS/$1/proton"
  printf '"compatibilitytools"\n{\n  "compat_tools"\n  {\n    "%s" // Internal name of this tool\n    {\n      "install_path" "."\n      "display_name" "%s"\n      "from_oslist"  "windows"\n      "to_oslist"    "linux"\n    }\n  }\n}\n' \
    "$2" "$3" >"$TOOLS/$1/compatibilitytool.vdf"
}
tool "$OURS" "$OURS" "Proton-CachyOS ARMv8.0 (RetroForge)"
tool GE-Proton10-1 GE-Proton10-1 "GE-Proton10-1"
acf 1145360 Hades 4; acf 413150 "Stardew Valley" 4; acf 367520 "Hollow Knight" 4; acf 1572920 SuperTux 4
acf 4628740 "Proton 11.0 (ARM64)" 4; acf 1070560 SteamLinuxRuntime 4; acf 4427310 "Proton Experimental (ARM64)" 2
mkdir -p "$S/steamapps/common/Proton 11.0 (ARM64)" "$S/steamapps/common/SteamLinuxRuntime" "$S/steamapps/common/Proton Experimental (ARM64)"

# The app cache: a Windows-only game, one with a Linux build, two with a Linux build that Valve maps to
# a Proton all the same (Hollow Knight in its list of games, SuperTux in its Deck test result), and
# Steam's two tool lists as the client has them (MANGMI Air X, 2026-11-27), cut to one tool of each kind.
python3 - "$T/apps.json" <<'PY' && python3 "$ROOT/tests/lib-steam-appinfo.py" shards "$S" "$T/apps.json"
import json, sys
apps = {
    1145360: {"appinfo": {"appid": 1145360, "common": {"name": "Hades", "type": "Game", "oslist": "windows"}}},
    413150: {"appinfo": {"appid": 413150, "common": {"name": "Stardew Valley", "type": "Game", "oslist": "windows,macos,linux",
        "steam_deck_compatibility": {"category": 3, "configuration": {"recommended_runtime": "native"}}}}},
    367520: {"appinfo": {"appid": 367520, "common": {"name": "Hollow Knight", "type": "Game", "oslist": "windows,macos,linux",
        "steam_deck_compatibility": {"category": 3, "configuration": {"recommended_runtime": "native"}}}}},
    1572920: {"appinfo": {"appid": 1572920, "common": {"name": "SuperTux", "type": "Game", "oslist": "windows,macos,linux",
        "steam_deck_compatibility": {"category": 2, "configuration": {"recommended_runtime": "proton-10.0-3RC"}}}}},
    3043620: {"appinfo": {"appid": 3043620, "common": {"name": "Steam Frame ARM64 Compat List", "type": "Config"}, "extended": {"compat_tools": {
        "lepton": {"aliases": "lepton-stable", "appid": 3029110, "display_name": "Lepton", "from_oslist": "android", "to_oslist": "linux"},
        "proton-experimental-arm64": {"aliases": "proton-experimental", "appid": 4427310, "display_name": "Proton Experimental (ARM64)", "from_oslist": "windows", "to_oslist": "linux"},
        "proton_11-arm64": {"aliases": "proton-stable-arm64,proton-stable", "appid": 4628740, "display_name": "Proton 11.0-3 (ARM64)", "from_oslist": "windows", "require_tool_appid": 4185400, "to_oslist": "linux"},
        "fex": {"aliases": "fex-stable", "appid": 3127680, "display_name": "fex", "from_oslist": "linux", "to_oslist": "linux", "unlisted": 1},
        "steamlinuxruntime_steamrt4-arm64": {"appid": 4185400, "display_name": "Steam Linux Runtime 4.0 for arm64", "from_oslist": "linux", "to_oslist": "linux", "unlisted": 1}}}}},
    891390: {"appinfo": {"appid": 891390, "common": {"name": "SteamPlay 2.0 Manifests", "type": "Config"}, "extended": {"app_mappings": {
        "367520": {"appid": 367520, "comment": "hk", "config": "none", "platform": "linux", "tool": "proton-stable"}}, "compat_tools": {
        "proton_experimental": {"aliases": "proton-experimental", "appid": 1493710, "display_name": "Proton Experimental", "from_oslist": "windows", "to_oslist": "linux"},
        "proton_11": {"aliases": "proton-9,proton-stable", "appid": 4628710, "display_name": "Proton 11.0-3", "from_oslist": "windows", "to_oslist": "linux"},
        "proton_9": {"aliases": "proton-9.0-4pin", "appid": 2805730, "display_name": "Proton 9.0-4", "from_oslist": "windows", "to_oslist": "linux"},
        "steamlinuxruntime_sniper": {"aliases": "sniper", "appid": 1628350, "display_name": "Steam Linux Runtime 3.0", "from_oslist": "linux", "to_oslist": "linux", "unlisted": 1},
        "steamlinuxruntime": {"aliases": "native,scout", "appid": 1070560, "display_name": "Steam Linux Runtime 1.0", "from_oslist": "linux", "to_oslist": "linux", "unlisted": 0},
        "legacysteamruntime": {"appid": 4690330, "display_name": "Legacy Steam Runtime", "from_oslist": "linux", "to_oslist": "linux", "unlisted": 2}}}}},
}
json.dump(apps, open(sys.argv[1], "w"))
PY

vdf() {  # vdf [<appid> <tool>]...: a config.vdf like the client's, each game's own tool after the default
  { printf '"InstallConfigStore"\n{\n\t"Software"\n\t{\n\t\t"Valve"\n\t\t{\n\t\t\t"Steam"\n\t\t\t{\n\t\t\t\t"AutoUpdateWindowEnabled"\t\t"0"\n\t\t\t\t"CompatToolMapping"\n\t\t\t\t{\n'
    printf '\t\t\t\t\t"0"\n\t\t\t\t\t{\n\t\t\t\t\t\t"name"\t\t"%s"\n\t\t\t\t\t\t"config"\t\t""\n\t\t\t\t\t\t"priority"\t\t"75"\n\t\t\t\t\t}\n' "$OURS"
    while [ $# -ge 2 ]; do
      printf '\t\t\t\t\t"%s"\n\t\t\t\t\t{\n\t\t\t\t\t\t"name"\t\t"%s"\n\t\t\t\t\t\t"config"\t\t""\n\t\t\t\t\t\t"priority"\t\t"250"\n\t\t\t\t\t}\n' "$1" "$2"; shift 2
    done
    printf '\t\t\t\t}\n\t\t\t\t"Accounts"\n\t\t\t\t{\n\t\t\t\t\t"someone"\n\t\t\t\t\t{\n\t\t\t\t\t\t"SteamID"\t\t"1"\n\t\t\t\t\t}\n\t\t\t\t}\n\t\t\t}\n\t\t}\n\t}\n}\n'; } >"$VDF"
}
tool_of() {  # tool_of <key>: "name priority" of that CompatToolMapping entry, "" without one
  python3 - "$VDF" "$1" <<'PY'
import re, sys
m = re.search(r'"CompatToolMapping"\s*\{(.*)', open(sys.argv[1]).read(), re.S)
e = m and re.search(r'"%s"\s*\{\s*"name"\s*"([^"]*)"\s*"config"\s*"([^"]*)"\s*"priority"\s*"([^"]*)"' % sys.argv[2], m.group(1))
print(f"{e.group(1)} {e.group(3)}" if e else "")
PY
}

# retroforge-steam-keep: records its calls; `full` prints $T/keep.full (woke: the web helper was
# frozen); `stop-unused` exits $T/keep.stop (1: left running), and stops the client when that is 0.
cat >"$T/keep" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$T/keep.calls"
case "\$1" in
  full) cat "$T/keep.full" 2>/dev/null ;;
  stop-unused) rc="\$(cat "$T/keep.stop" 2>/dev/null || echo 1)"; [ "\$rc" = 0 ] && rm -rf "$T/proc/7780"; exit "\$rc" ;;
esac
exit 0
EOF
chmod +x "$T/keep"

# Steam's DevTools port: /json/list names the SharedJSContext page (not in mode nopage), and the page
# takes one Runtime.evaluate: the call is recorded, and in mode apply the tool is written to
# config.vdf, as the client does; mode ignore answers and writes nothing; mode nofn has no SteamClient.
cat >"$T/devtools.py" <<'PY'
import base64, hashlib, json, os, re, socket, struct, sys
root, state = sys.argv[1], sys.argv[2]
sys.path.insert(0, sys.argv[3])
import steam_tool
srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", 0)); srv.listen(8)
port = srv.getsockname()[1]
with open(os.path.join(state, "port.part"), "w") as f:
    f.write(str(port))
os.replace(os.path.join(state, "port.part"), os.path.join(state, "port"))
while True:
    c, _ = srv.accept()
    try:
        head = b""
        while b"\r\n\r\n" not in head:
            d = c.recv(4096)
            if not d:
                break
            head += d
        with open(os.path.join(state, "mode")) as f:
            mode = f.read().strip()
        if b"/json/list" in head.split(b"\r\n", 1)[0]:
            pages = [] if mode == "nopage" else [{"title": "SharedJSContext", "webSocketDebuggerUrl": f"ws://127.0.0.1:{port}/devtools/page/1"}]
            body = json.dumps(pages).encode()
            c.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: %d\r\n\r\n" % len(body) + body)
            continue
        key = re.search(rb"Sec-WebSocket-Key: (\S+)", head).group(1)
        accept = base64.b64encode(hashlib.sha1(key + b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest())
        c.sendall(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + accept + b"\r\n\r\n")

        def read(n):
            buf = b""
            while len(buf) < n:
                d = c.recv(n - len(buf))
                if not d:
                    raise OSError("closed")
                buf += d
            return buf
        b0, b1 = read(2)
        n = b1 & 0x7F
        n = struct.unpack(">H", read(2))[0] if n == 126 else struct.unpack(">Q", read(8))[0] if n == 127 else n
        mask = read(4)
        expr = json.loads(bytes(b ^ mask[i % 4] for i, b in enumerate(read(n))))["params"]["expression"]
        m = re.search(r'SpecifyCompatTool\((\d+), ("(?:[^"\\]|\\.)*")\)', expr)
        value = "nofn"
        if m and mode != "nofn":
            appid, name = m.group(1), json.loads(m.group(2))
            with open(os.path.join(state, "calls"), "a") as f:
                f.write(f"{appid} {name}\n")
            if mode == "apply":
                steam_tool.write(root, appid, name)
            value = "ok"
        out = json.dumps({"id": 1, "result": {"result": {"type": "string", "value": value}}}).encode()
        c.sendall(b"\x81" + (bytes([len(out)]) if len(out) < 126 else b"\x7e" + struct.pack(">H", len(out))) + out)
    except (OSError, ValueError, AttributeError, KeyError):
        pass
    finally:
        c.close()
PY
echo apply >"$T/dev/mode"
python3 "$T/devtools.py" "$S" "$T/dev" "$PYLIB" & SERVER=$!
for _ in $(seq 100); do [ -s "$T/dev/port" ] && break; sleep 0.05; done
[ -s "$T/dev/port" ] || { echo "the stand-in DevTools port did not start" >&2; exit 1; }
PORT="$(cat "$T/dev/port")"

# device-env: the SoC class in $T/soc (a board whose GPU runs upstream DXVK, unless a case says otherwise)
printf '#!/bin/sh\necho "RETROFORGE_SOC_CLASS=$(cat "%s/soc")"\n' "$T" >"$T/device-env"; chmod +x "$T/device-env"; echo SM8550 >"$T/soc"
DENV=(env -u RETROFORGE_STEAM_ROOT -u XDG_DATA_HOME -u XDG_CONFIG_HOME -u XDG_CACHE_HOME -u RETROFORGE_STEAM_DIRECT -u RETROFORGE_STEAM_SAREK
      -u http_proxy -u HTTP_PROXY HOME="$H" XDG_RUNTIME_DIR="$T/run" RETROFORGE_PROC="$T/proc" RETROFORGE_STEAM_LIBRARY="$LIBRARY"
      RETROFORGE_DEVICE_ENV="$T/device-env"
      RETROFORGE_STEAM_KEEP_CLI="$T/keep" RETROFORGE_STEAM_DEVTOOLS_LIB="$DEVLIB" RETROFORGE_STEAM_DEVTOOLS="http://127.0.0.1:$PORT"
      RETROFORGE_STEAM_DEVTOOLS_WAIT=1 RETROFORGE_STEAM_TOOL_WAIT=0.6)
direct() {  # direct <cpuinfo> [VAR=value...] args...: OUT, ERR, RC
  local cpu="$1"; shift
  local -a vars=()
  while [[ "$1" == *=* ]]; do vars+=("$1"); shift; done
  OUT="$("${DENV[@]}" RETROFORGE_CPUINFO="$T/$cpu" "${vars[@]}" python3 "$DIRECT" "$@" 2>"$T/err")"; RC=$?
  ERR="$(cat "$T/err")"
}
tools() { python3 -c 'import json, sys; t = json.loads(sys.argv[1])["tool"]; print(t["choice"], "|", t["default"], "|", "; ".join(x["name"] + "=" + x["label"] for x in t["tools"]), "|", t.get("other", ""))' "$OUT"; }
client() { echo 7780 >"$H/.steam/steam.pid"; mkdir -p "$T/proc/7780"; echo steam >"$T/proc/7780/comm"; }   # a client runs
no_client() { rm -rf "$T/proc/7780"; rm -f "$H/.steam/steam.pid"; }
calls() { cat "$1" 2>/dev/null | tr '\n' ';'; }
reset() { rm -f "$T/keep.calls" "$T/keep.full" "$T/keep.stop" "$T/dev/calls"; echo apply >"$T/dev/mode"; }

# ================================================================================================
CASE="the list"
vdf
direct v82 game 1145360
[ "$RC" = 0 ] && [ "$(tools)" = "default | Default (Steam's choice) | GE-Proton10-1=GE-Proton10-1; $OURS=Proton-CachyOS ARMv8.0; proton-experimental-arm64=Proton Experimental (ARM64), not installed; proton_11-arm64=Proton 11.0-3 (ARM64) | " ] \
  && ok "a Windows game: compatibilitytools.d's tools and the arm64 Protons, one of them yet to download; no x86 Proton" \
  || bad "rc=$RC tools=$(tools 2>&1) err=$ERR"
direct v82 game 413150
[ "$(tools)" = "default | Default (Steam's choice) | GE-Proton10-1=GE-Proton10-1; $OURS=Proton-CachyOS ARMv8.0; proton-experimental-arm64=Proton Experimental (ARM64), not installed; proton_11-arm64=Proton 11.0-3 (ARM64); steamlinuxruntime=Steam Linux Runtime 1.0, the game's Linux build | " ] \
  && ok "a game with a Linux build: also the Linux runtime Steam lists, not fex nor the runtimes Steam hides" || bad "tools=$(tools 2>&1)"
direct v80 game 1145360
[ "$(tools)" = "default | Default (Proton-CachyOS ARMv8.0) | GE-Proton10-1=GE-Proton10-1; proton-experimental-arm64=Proton Experimental (ARM64), slower on this CPU, not installed; proton_11-arm64=Proton 11.0-3 (ARM64), slower on this CPU | " ] \
  && ok "ARMv8.0, a Windows-only game: Default is our build, and Valve's Protons say they are slower here" || bad "tools=$(tools 2>&1)"
direct v80 game 413150
grep -q "^default | Default (Steam's choice) | GE-Proton10-1=GE-Proton10-1; $OURS=Proton-CachyOS ARMv8.0; " <<<"$(tools)" \
  && ok "ARMv8.0, a game with a Linux build: Default is Steam's choice, and our build is one of the tools" || bad "tools=$(tools 2>&1)"
mv "$TOOLS/$OURS" "$T/ours.away"
direct v80 game 1145360
grep -q "^default | Default (Steam's choice) | GE-Proton10-1=" <<<"$(tools)" && ok "ARMv8.0 before our build is installed: Default is Steam's choice" || bad "tools=$(tools 2>&1)"
mv "$T/ours.away" "$TOOLS/$OURS"
# A GPU that needs DXVK-Sarek (the Air X's Adreno 610, the SM4450's 613): Valve's Protons carry only
# upstream DXVK, so no DirectX game starts with them there (Among Us, MANGMI Air X, 2026-11-28).
echo SM6115 >"$T/soc"
direct v80 game 1145360
[ "$(tools)" = "default | Default (Proton-CachyOS ARMv8.0) | GE-Proton10-1=GE-Proton10-1 | " ] \
  && ok "the Adreno 610 (SM6115): Valve's Protons are not offered; a Windows game has Default and the player's own tools" || bad "tools=$(tools 2>&1)"
direct v80 game 413150
[ "$(tools)" = "default | Default (Steam's choice) | GE-Proton10-1=GE-Proton10-1; $OURS=Proton-CachyOS ARMv8.0; steamlinuxruntime=Steam Linux Runtime 1.0, the game's Linux build | " ] \
  && ok "there a game with a Linux build chooses between our build and its Linux build" || bad "tools=$(tools 2>&1)"
direct v80 game 367520
[ "$(tools)" = "default | Default (Proton-CachyOS ARMv8.0) | GE-Proton10-1=GE-Proton10-1; steamlinuxruntime=Steam Linux Runtime 1.0, the game's Linux build | " ] \
  && ok "one that Valve's list maps to a Proton (Hollow Knight): Default is our build, as for a Windows game, its Linux build the other choice" || bad "tools=$(tools 2>&1)"
direct v80 game 1572920
[ "$(tools)" = "default | Default (Proton-CachyOS ARMv8.0) | GE-Proton10-1=GE-Proton10-1; steamlinuxruntime=Steam Linux Runtime 1.0, the game's Linux build | " ] \
  && ok "and one whose Deck test result names a Proton (SuperTux)" || bad "tools=$(tools 2>&1)"
echo SM4450 >"$T/soc"
direct v82 game 1145360
[ "$(tools)" = "default | Default (Steam's choice) | GE-Proton10-1=GE-Proton10-1; $OURS=Proton-CachyOS ARMv8.0 | " ] \
  && ok "the Adreno 613 (SM4450, a CPU with LSE atomics): the same" || bad "tools=$(tools 2>&1)"
tool proton-cachyos-arm64-retroforge proton-cachyos-arm64-retroforge "Proton-CachyOS arm64 (RetroForge)"
direct v82 game 1145360
[ "$(tools)" = "default | Default (Proton-CachyOS arm64) | GE-Proton10-1=GE-Proton10-1; $OURS=Proton-CachyOS ARMv8.0 | " ] \
  && ok "there Proton-CachyOS's arm64 build, once installed, is a Windows game's Default" || bad "tools=$(tools 2>&1)"
direct v82 game 367520
grep -q "^default | Default (Proton-CachyOS arm64) | GE-Proton10-1=GE-Proton10-1; $OURS=Proton-CachyOS ARMv8.0; steamlinuxruntime=" <<<"$(tools)" \
  && ok "and Hollow Knight's" || bad "tools=$(tools 2>&1)"
rm -r "$TOOLS/proton-cachyos-arm64-retroforge"
vdf 1145360 proton_11-arm64; cp "$VDF" "$T/before.vdf"
direct v82 game 1145360
grep -q "^proton_11-arm64 | .* | Proton 11.0-3 (ARM64)$" <<<"$(tools)" && ok "a game set to one in Steam keeps it, shown by its name" || bad "tools=$(tools 2>&1)"
vdf
direct v82 game 1145360 set tool proton_11-arm64
[ "$RC" = 2 ] && [ -z "$(tool_of 1145360)" ] && ok "and it is no choice to make there" || bad "rc=$RC entry=$(tool_of 1145360)"
direct v82 RETROFORGE_STEAM_SAREK=off game 1145360
grep -q "proton_11-arm64=Proton 11.0-3 (ARM64)" <<<"$(tools)" || bad "RETROFORGE_STEAM_SAREK=off: tools=$(tools 2>&1)"
echo SM8550 >"$T/soc"
direct v82 RETROFORGE_STEAM_SAREK=on game 1145360
! grep -q "proton_11-arm64=" <<<"$(tools)" && ok "RETROFORGE_STEAM_SAREK=on|off decides instead of the SoC, for testing" || bad "tools=$(tools 2>&1)"
mv "$S/appcache" "$T/appcache.away"
direct v82 game 1145360
[ "$RC" = 0 ] && [ "$(tools)" = "default | Default (Steam's choice) |  | " ] && ok "no app cache: nothing to offer" || bad "rc=$RC tools=$(tools 2>&1)"
mv "$T/appcache.away" "$S/appcache"

CASE="what the row shows"
vdf 1145360 proton_11-arm64
direct v82 game 1145360
grep -q "^proton_11-arm64 | " <<<"$(tools)" && ok "the game's own tool" || bad "tools=$(tools 2>&1)"
vdf 1145360 proton-stable
direct v82 game 1145360
grep -q "^proton_11-arm64 | " <<<"$(tools)" && ok "an alias as the tool it means here (proton-stable: the arm64 list's)" || bad "tools=$(tools 2>&1)"
vdf 1145360 proton_9
direct v82 game 1145360
grep -q "^proton_9 | .* | Proton 9.0-4$" <<<"$(tools)" && ok "a tool set in Steam that the list does not offer, by its name there" || bad "tools=$(tools 2>&1)"
vdf 1145360 "$OURS"
direct v80 game 1145360
grep -q "^default | " <<<"$(tools)" && ok "ARMv8.0: the entry retroforge-steam-proton gives a Windows game is Default" || bad "tools=$(tools 2>&1)"
direct v82 game 1145360
grep -q "^$OURS | " <<<"$(tools)" && ok "the same entry on a CPU with LSE atomics is the player's choice" || bad "tools=$(tools 2>&1)"
vdf 367520 "$OURS"
direct v80 game 367520
grep -q "^default | " <<<"$(tools)" && ok "ARMv8.0: so is the entry it gives a game with a Linux build that Valve maps to a Proton" || bad "tools=$(tools 2>&1)"

CASE="no client running"
no_client; reset; vdf 413150 GE-Proton10-1; cp "$VDF" "$T/before.vdf"
direct v82 game 1145360 set tool proton_11-arm64
[ "$RC" = 0 ] && [ "$(tool_of 1145360)" = "proton_11-arm64 250" ] && grep -q "^proton_11-arm64 | " <<<"$(tools)" \
  && ok "the game's own entry is written, at the priority Steam's page gives one, and the row shows it" || bad "rc=$RC entry=$(tool_of 1145360) err=$ERR"
[ "$(diff "$T/before.vdf" "$VDF" | grep -c '^<')" = 0 ] && [ "$(diff "$T/before.vdf" "$VDF" | grep -c '^>')" = 6 ] \
  && [ "$(tool_of 0)" = "$OURS 75" ] && [ "$(tool_of 413150)" = "GE-Proton10-1 250" ] \
  && ok "the rest of config.vdf stays: the entry's six lines are all that is new" || bad "diff: $(diff "$T/before.vdf" "$VDF")"
[ ! -e "$T/keep.calls" ] && [ ! -e "$T/dev/calls" ] && ok "nothing of the client's is asked" || bad "keep=$(calls "$T/keep.calls") dev=$(calls "$T/dev/calls")"
direct v82 game 1145360 set tool default
[ "$RC" = 0 ] && cmp -s "$VDF" "$T/before.vdf" && ok "Default removes the entry: config.vdf byte for byte as before" || bad "rc=$RC diff: $(diff "$VDF" "$T/before.vdf")"
direct v82 game 1145360 set tool default
[ "$RC" = 0 ] && cmp -s "$VDF" "$T/before.vdf" && ok "Default again changes nothing" || bad "rc=$RC"
direct v80 game 1145360 set tool default
[ "$RC" = 0 ] && [ "$(tool_of 1145360)" = "$OURS 250" ] && ok "ARMv8.0: Default sets a Windows-only game's entry to our build, as retroforge-steam-proton would" \
  || bad "rc=$RC entry=$(tool_of 1145360)"
direct v80 game 413150 set tool default
[ "$RC" = 0 ] && [ -z "$(tool_of 413150)" ] && ok "ARMv8.0: Default removes the entry of a game with a Linux build" || bad "rc=$RC entry=$(tool_of 413150)"
direct v80 game 367520 set tool steamlinuxruntime
[ "$RC" = 0 ] && [ "$(tool_of 367520)" = "steamlinuxruntime 250" ] || bad "Hollow Knight's Linux build: rc=$RC entry=$(tool_of 367520) err=$ERR"
direct v80 game 367520 set tool default
[ "$RC" = 0 ] && [ "$(tool_of 367520)" = "$OURS 250" ] && grep -q "^default | " <<<"$(tools)" \
  && ok "ARMv8.0: but sets our build for one that Valve maps to a Proton, set to its Linux build before" || bad "rc=$RC entry=$(tool_of 367520)"
direct v82 game 1145360 set tool ge-proton10-1
[ "$RC" = 2 ] && ok "a name is a choice only as its tool spells it" || bad "rc=$RC"
direct v82 game 1145360 set tool GE-Proton10-1
[ "$RC" = 0 ] && [ "$(tool_of 1145360)" = "GE-Proton10-1 250" ] && ok "and is written that way" || bad "rc=$RC entry=$(tool_of 1145360)"
cp "$VDF" "$T/before.vdf"
for name in proton_9 steamlinuxruntime fex nonsense; do
  direct v82 game 1145360 set tool "$name"
  [ "$RC" = 2 ] && cmp -s "$VDF" "$T/before.vdf" || bad "$name: rc=$RC"
done
ok "a tool the list does not offer this game is refused (an x86 Proton, the Linux runtime for a Windows game, fex)"
rm -f "$VDF"
direct v82 game 1145360 set tool proton_11-arm64
[ "$RC" = 0 ] && [ "$(tool_of 1145360)" = "proton_11-arm64 250" ] && ok "no config.vdf yet: one with the entry" || bad "rc=$RC $(cat "$VDF" 2>&1)"
printf '"InstallConfigStore"\n{\n\t"Software" oops\n' >"$VDF"; cp "$VDF" "$T/before.vdf"
direct v82 game 1145360 set tool proton_11-arm64
[ "$RC" = 1 ] && cmp -s "$VDF" "$T/before.vdf" && grep -q "could not set its compatibility tool" <<<"$ERR" \
  && ok "a config.vdf that does not parse is left alone, and it says so" || bad "rc=$RC err=$ERR"

CASE="a client running"
client; reset; vdf; echo woke >"$T/keep.full"
direct v82 game 1145360 set tool proton_11-arm64
[ "$RC" = 0 ] && [ "$(calls "$T/dev/calls")" = "1145360 proton_11-arm64;" ] && [ "$(tool_of 1145360)" = "proton_11-arm64 250" ] \
  && ok "the client's own call makes the change (SteamClient.Apps.SpecifyCompatTool), and the client writes config.vdf" \
  || bad "rc=$RC dev=$(calls "$T/dev/calls") entry=$(tool_of 1145360) err=$ERR"
grep -qE '^full [0-9]+;minimal [0-9]+;$' <<<"$(calls "$T/keep.calls")" \
  && ok "a frozen web helper is woken for it, held while it runs, and frozen again" || bad "keep=$(calls "$T/keep.calls")"
reset; echo woke >"$T/keep.full"
direct v82 game 1145360 set tool default
[ "$RC" = 0 ] && [ "$(calls "$T/dev/calls")" = "1145360 ;" ] && [ -z "$(tool_of 1145360)" ] \
  && ok "Default is the client's call with no name, which removes the entry" || bad "rc=$RC dev=$(calls "$T/dev/calls") entry=$(tool_of 1145360)"
reset
direct v82 game 1145360 set tool GE-Proton10-1
[ "$RC" = 0 ] && [ "$(tool_of 1145360)" = "GE-Proton10-1 250" ] && grep -qE '^full [0-9]+;$' <<<"$(calls "$T/keep.calls")" \
  && ok "a web helper that was awake (Steam's UI open) is left awake" || bad "rc=$RC keep=$(calls "$T/keep.calls")"
reset
direct v82 game 1145360 set tool GE-Proton10-1
[ "$RC" = 0 ] && [ ! -e "$T/dev/calls" ] && [ ! -e "$T/keep.calls" ] && ok "the tool it already has: nothing is asked" || bad "rc=$RC dev=$(calls "$T/dev/calls")"
reset; echo ignore >"$T/dev/mode"; cp "$VDF" "$T/before.vdf"
direct v82 game 1145360 set tool proton_11-arm64
[ "$RC" = 1 ] && cmp -s "$VDF" "$T/before.vdf" && grep -q "the running Steam client did not take it" <<<"$ERR" \
  && ok "a client that does not take the call: config.vdf is never written under it, and it says so" || bad "rc=$RC err=$ERR diff=$(diff "$VDF" "$T/before.vdf")"
python3 -c 'import json, sys; assert json.loads(sys.argv[1])["tool"]["choice"] == "GE-Proton10-1"' "$OUT" 2>/dev/null \
  && bad "a failed set still prints the game's choices" || ok "and prints no choices (the page shows its notice and reads them again)"
reset; echo nopage >"$T/dev/mode"; echo woke >"$T/keep.full"; echo 0 >"$T/keep.stop"
direct v82 game 1145360 set tool proton_11-arm64
[ "$RC" = 0 ] && [ "$(tool_of 1145360)" = "proton_11-arm64 250" ] && grep -qE '^full [0-9]+;minimal [0-9]+;stop-unused;$' <<<"$(calls "$T/keep.calls")" \
  && grep -q "stopped the kept Steam" <<<"$ERR" \
  && ok "no DevTools page: a kept client nothing uses is stopped, then the file is edited" || bad "rc=$RC keep=$(calls "$T/keep.calls") err=$ERR"
client; reset; echo nopage >"$T/dev/mode"; echo woke >"$T/keep.full"; echo 1 >"$T/keep.stop"; cp "$VDF" "$T/before.vdf"
direct v82 game 1145360 set tool GE-Proton10-1
[ "$RC" = 1 ] && cmp -s "$VDF" "$T/before.vdf" && ok "no DevTools page and the client in use: nothing changes" || bad "rc=$RC keep=$(calls "$T/keep.calls")"
reset; echo nopage >"$T/dev/mode"; echo 0 >"$T/keep.stop"
direct v82 game 1145360 set tool GE-Proton10-1
[ "$RC" = 1 ] && cmp -s "$VDF" "$T/before.vdf" && ! grep -q stop-unused "$T/keep.calls" \
  && ok "no DevTools page and its web helper awake (Steam's UI open): the client is not stopped" || bad "rc=$RC keep=$(calls "$T/keep.calls")"

CASE="Steam running a game"
reset; mkdir -p "$T/proc/8100" "$T/proc/8200"
echo reaper >"$T/proc/8100/comm"; printf '/usr/share/opengamepadui/reaper\0SteamLaunch\0AppId=1145360\0--\0steam\0' >"$T/proc/8100/cmdline"
direct v82 game 1145360 set tool GE-Proton10-1
[ "$RC" = 0 ] && [ "$(tool_of 1145360)" = "GE-Proton10-1 250" ] && ok "OGUI's own reaper (it starts every app under one) is not a Steam game" || bad "rc=$RC err=$ERR"
echo reaper >"$T/proc/8200/comm"; printf '%s\0SteamLaunch\0AppId=413150\0--\0x\0' "$S/steamrtarm64/reaper" >"$T/proc/8200/cmdline"
reset; cp "$VDF" "$T/before.vdf"
direct v82 game 1145360 set tool proton_11-arm64
[ "$RC" = 3 ] && cmp -s "$VDF" "$T/before.vdf" && [ ! -e "$T/dev/calls" ] && [ ! -e "$T/keep.calls" ] && grep -q "Steam is running a game" <<<"$ERR" \
  && ok "exit 3: nothing is asked of the client, whose web helper stays frozen beside the game" || bad "rc=$RC err=$ERR keep=$(calls "$T/keep.calls")"
no_client
direct v82 game 1145360 set tool proton_11-arm64
[ "$RC" = 3 ] && cmp -s "$VDF" "$T/before.vdf" && ok "nor is the file edited under a game started without the client" || bad "rc=$RC"
direct v82 game 1145360
[ "$RC" = 0 ] && grep -q "^GE-Proton10-1 | " <<<"$(tools)" && ok "the row still reads" || bad "rc=$RC tools=$(tools 2>&1)"
rm -rf "$T/proc/8100" "$T/proc/8200"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

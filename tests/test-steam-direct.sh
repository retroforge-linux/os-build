#!/usr/bin/env bash
# Offline test for /usr/bin/retroforge-steam-direct and /usr/bin/steam's "Without the client" block:
# Steam games started without the Steam client, on by default (first for the MANGMI Air X, 3.5 GB:
# Hades was killed in its first room with the client, and played without it, 2026-10-22).
#
#   tests/test-steam-direct.sh
#
# WHY THIS EXISTS. Each rule below fails as a game that does not start, starts differently from how
# Steam starts it, or a Steam that never comes back:
#   the setting: on by default, on every board; saved
#     beside the other Steam settings (DXVK_SAREK, KEEP_RUNNING), which stay; an override for testing;
#   what is replayed: Steam's own newest logged launch of that game ("Game process added"), from
#     console_log.txt or console_log.previous.txt, kept in a cache so a rotated log does not lose it;
#     run as Steam ran it (/bin/sh -c, at oom_score_adj 900), word for word, from the launch entry's
#     working folder, with Steam's compat variables (the game's library on an SD card too) and the
#     launch's own environment; with the compatibility tool the game is set to in Steam now, when that
#     is an installed Proton on the logged launch's runtime;
#   when it is not: the setting off (silently), a client running other than the kept one in the
#     background (a stale steam.pid is not one), a game Steam never started here, not installed or
#     changing, an x86 game (Steam's FEX tool), a compat tool that is gone, a game set to a tool its
#     logged launch cannot be given (one Steam has yet to download, its Linux build), or set back to
#     Steam's choice since; each says why, and nothing runs;
#   the wrapper: execs the helper for a game it can start, with the D-Bus check and DXVK-Sarek done
#     and none of the client's own set-up; with keep-running on, the kept client beside it, minimal:
#     started first (and signed in) when Steam has a remembered sign-in, without the game's URI; the
#     game starts anyway when it does not sign in in time; everything else (Steam's UI, a first launch,
#     the kept client's own run) starts the client as before.
# Steam's programs are stubs that record how they were called; the client's binary caches are written
# by a small encoder of Valve's binary KeyValues (as in test-steam-library.sh).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIRECT="$ROOT/rootfs/overlay/usr/bin/retroforge-steam-direct"
WRAP="$ROOT/rootfs/overlay/usr/bin/steam"
LIBRARY="$ROOT/rootfs/overlay/usr/lib/retroforge/steam-library"
for f in "$DIRECT" "$WRAP" "$LIBRARY"; do [ -f "$f" ] || { echo "missing: $f" >&2; exit 1; }; done

PASS=0; FAIL=0; CASE=""
ok()  { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }

T="$(mktemp -d)" && [ -d "$T" ] || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$T"' EXIT

H="$T/home"; S="$H/.local/share/Steam"; SD="$T/sdcard/SteamLibrary"
CONF="$H/.config/retroforge/steam.conf"; CACHE="$H/.cache/retroforge/steam-direct"
SLOG="$S/logs/console_log.txt"
SLR="$S/steamapps/common/SteamLinuxRuntime_4-arm64"; PROTON="$S/steamapps/common/Proton 11.0 (ARM64)"
GAME="$S/steamapps/common/Hades"
mkdir -p "$S/logs" "$S/linuxarm64" "$S/steamrtarm64" "$SLR" "$PROTON" "$GAME/x64Vk" "$GAME/x64" "$T/proc"

# Steam's programs: the launch wrapper records its arguments (one per line), working folder and the
# environment the game gets, and exits with $T/game.rc; the rest only have to be there.
cat >"$S/linuxarm64/steam-launch-wrapper" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >"$T/ran.args"; pwd >"$T/ran.cwd"; env >"$T/ran.env"; trap -p >"$T/ran.traps"
cat /proc/self/oom_score_adj >"$T/ran.oom"
exit "\$(cat "$T/game.rc" 2>/dev/null || echo 0)"
EOF
for f in "$S/steamrtarm64/reaper" "$SLR/_v2-entry-point" "$PROTON/proton" "$GAME/x64Vk/Hades.exe" "$GAME/x64/Hades.exe"; do
  printf '#!/bin/sh\nexit 0\n' >"$f"
done
chmod +x "$S/linuxarm64/steam-launch-wrapper" "$S/steamrtarm64/reaper" "$SLR/_v2-entry-point" "$PROTON/proton"
printf '"manifest"\n{\n  "commandline" "/_v2-entry-point --verb=%%verb%% --"\n}\n' >"$SLR/toolmanifest.vdf"
printf '"manifest"\n{\n  "commandline" "/proton %%verb%%"\n  "require_tool_appid" "4185400"\n}\n' >"$PROTON/toolmanifest.vdf"

acf() {  # acf <library> <appid> <installdir> <StateFlags>
  mkdir -p "$1/steamapps"
  printf '"AppState"\n{\n\t"appid"\t\t"%s"\n\t"name"\t\t"%s"\n\t"StateFlags"\t\t"%s"\n\t"installdir"\t\t"%s"\n\t"UserConfig"\n\t{\n\t\t"installdir"\t\t"not this"\n\t}\n}\n' \
    "$2" "$3" "$4" "$3" >"$1/steamapps/appmanifest_$2.acf"
}
acf "$S" 1145360 Hades 4
acf "$S" 4185400 SteamLinuxRuntime_4-arm64 4
acf "$S" 4628740 "Proton 11.0 (ARM64)" 4

# The app cache (mkappinfo [format]: the current client's shards, or 29 for an older client's
# appinfo.vdf; tests/lib-steam-appinfo.py): Hades's launch entries (the Vulkan one runs from x64Vk; one
# entry names a working folder that is not its executable's), Valve's per-game Proton settings (app
# 891390), and Steam's own compatibility tools (that app's list and the arm64 one, app 3043620).
mkappinfo() {
  python3 - "$T/apps.json" <<'PY' && python3 "$ROOT/tests/lib-steam-appinfo.py" "${1:-shards}" "$S" "$T/apps.json"
import json, sys
apps = {
    1145360: {"appinfo": {"appid": 1145360, "common": {"name": "Hades", "type": "Game", "oslist": "windows",
                                                       "steam_frame_compatibility": {"configuration": {"tso_enable": 0}}}, "config": {
        "installdir": "Hades", "launch": {
            "0": {"executable": "x64\\Hades.exe", "workingdir": "x64\\", "arguments": "/c=..\\ /steampowered"},
            "1": {"executable": "x64Vk\\Hades.exe", "workingdir": "x64Vk\\", "arguments": "/c=..\\ /steampowered"},
            "2": {"executable": "Odd\\x64Vk\\Hades.exe", "workingdir": "x64\\"},
            "3": {"executable": "./NoDir/Game.exe"},
            "4": {"executable": "x64\\Hades.exe", "workingdir": "Odd\\", "arguments": "/c=..\\ -dx11 \"/name=two words\""},
            "9": {"executable": "Game.app", "config": {"oslist": "macos"}},
            "10": {"executable": "Beta\\Hades.exe", "config": {"BetaKey": "nightly-qa"}},
            "11": {"executable": "None\\Hades.exe", "type": "none"},
            "12": {"executable": "x86\\Hades.exe", "config": {"oslist": "windows", "osarch": "32"}},
            "13": {"executable": "Desk\\Hades.exe", "config": {"steamdeck": "0"}},
            "15": {"executable": "Deck\\Hades.exe", "description": "Deck", "description_loc": {"english": "Hades (Steam Deck)"},
                   "config": {"oslist": "windows", "osarch": "64", "steamdeck": "1"}}}}}},
    3405340: {"appinfo": {"appid": 3405340, "common": {"name": "Megabonk", "type": "Game",
                                                       "steam_frame_compatibility": {"configuration": {"tso_enable": 1}}}}},
    891390: {"appinfo": {"appid": 891390, "common": {"name": "SteamPlay 2.0 Manifests", "type": "Config"}, "extended": {
        "compat_tools": {"steamlinuxruntime": {"aliases": "native,scout", "appid": 1070560, "display_name": "Steam Linux Runtime 1.0",
                                               "from_oslist": "linux", "to_oslist": "linux", "unlisted": 0}},
        "app_compat_configs": {"2310": {"appid": 2310, "config": "oldglstr", "comment": "QUAKE"},
                               "1145360": {"appid": 1145360, "config": "gamedrive,heapdelayfree", "comment": "test"}}}}},
    3043620: {"appinfo": {"appid": 3043620, "common": {"name": "Steam Frame ARM64 Compat List", "type": "Config"}, "extended": {"compat_tools": {
        "proton-experimental-arm64": {"aliases": "proton-experimental", "appid": 4427310, "display_name": "Proton Experimental (ARM64)",
                                      "from_oslist": "windows", "to_oslist": "linux"},
        "proton_11-arm64": {"aliases": "proton-stable-arm64,proton-stable", "appid": 4628740, "display_name": "Proton 11.0-3 (ARM64)",
                            "from_oslist": "windows", "require_tool_appid": 4185400, "to_oslist": "linux"}}}}},
}
json.dump(apps, open(sys.argv[1], "w"))
PY
}
mkappinfo

# Steam's own log line for a launch, as the client writes it (the first two paths unquoted, the
# others quoted, the game's /c=..\ as /c=..\\, two spaces after waitforexitandrun).
cmdline() {  # cmdline <appid> <runtime> <proton> <exe>
  printf "%s --oom-score-adjust 900 -- %s SteamLaunch AppId=%s -- '%s'/_v2-entry-point --verb=waitforexitandrun -- '%s'/proton waitforexitandrun  '%s' /c=..\\\\\\\\ /steampowered /DirectLoadShell=true" \
    "$S/linuxarm64/steam-launch-wrapper" "$S/steamrtarm64/reaper" "$1" "$2" "$3" "$4"
}
logline() {  # logline <file> <stamp> <appid> <command>
  printf '[%s] Game process added : AppID %s "%s", ProcID 8664, IP 0.0.0.0:0\n' "$2" "$3" "$4" >>"$1"
}
HADES_CMD="$(cmdline 1145360 "$SLR" "$PROTON" "$GAME/x64Vk/Hades.exe")"
fresh_log() {  # the client's log as it was after Hades's launches, nothing kept yet
  : >"$SLOG"; rm -f "$S/logs/console_log.previous.txt" "$CACHE"/*.json
  echo "[2026-10-22 10:07:15] Running install script evaluator for AppID 1145360, 2 step(s)  $S/linuxarm64/steam-launch-wrapper -- x" >>"$SLOG"
  logline "$SLOG" "2026-10-22 09:00:34" 1145360 "$(cmdline 1145360 "$SLR" "$PROTON" "$GAME/x64/Hades.exe")"
  logline "$SLOG" "2026-10-22 09:30:00" 413150 "$(cmdline 413150 "$SLR" "$PROTON" "$S/steamapps/common/Stardew/x.exe")"
  logline "$SLOG" "2026-10-22 10:07:35" 1145360 "$HADES_CMD"
  echo "[2026-10-22 10:08:43] Game process removed: AppID 1145360 \"$HADES_CMD\", ProcID 8833" >>"$SLOG"
}

printf '{"ICD": {"api_version": "1.4.363", "library_arch": "64", "library_path": "/usr/lib/libvulkan_freedreno.so"}, "file_format_version": "1.0.1"}\n' >"$T/turnip_icd.json"
DENV=(env -u RETROFORGE_STEAM_ROOT -u XDG_DATA_HOME -u XDG_CONFIG_HOME -u XDG_CACHE_HOME -u RETROFORGE_STEAM_DIRECT
      -u SteamAppId -u STEAM_COMPAT_CONFIG -u STEAM_COMPAT_DATA_PATH -u DISPLAY -u RETROFORGE_GAMESCOPE_NESTED_W
      -u RETROFORGE_GAMESCOPE_NESTED_H HOME="$H" RETROFORGE_PROC="$T/proc"
      RETROFORGE_STEAM_LIBRARY="$LIBRARY" RETROFORGE_VULKAN_ICD="$T/turnip_icd.json")
direct() {  # direct [VAR=value...] -- args...
  local -a vars=()
  while [ "$1" != -- ]; do vars+=("$1"); shift; done; shift
  OUT="$("${DENV[@]}" "${vars[@]}" python3 "$DIRECT" "$@" 2>"$T/err")"; RC=$?
  ERR="$(cat "$T/err")"
}
ran_env() { grep -m1 "^$1=" "$T/ran.env" | cut -d= -f2-; }
reset_run() { rm -f "$T/ran.args" "$T/ran.cwd" "$T/ran.env" "$T/ran.oom" "$T/game.rc"; }

# ================================================================================================
CASE="setting"
direct -- status
[ "$OUT" = on ] && grep -q "the default" <<<"$ERR" && ok "on by default, on any board, and says so" || bad "out=$OUT err=$ERR"
printf '# Steam settings, mine\nDXVK_SAREK=on\nKEEP_RUNNING=off\nDIRECT_LAUNCH=on\n' | { mkdir -p "${CONF%/*}"; cat >"$CONF"; }
direct -- on
[ "$OUT" = on ] && [ "$(grep -c '^DIRECT_LAUNCH=' "$CONF")" = 1 ] && grep -qx "DIRECT_LAUNCH=on" "$CONF" \
  && grep -qx "DXVK_SAREK=on" "$CONF" && grep -qx "KEEP_RUNNING=off" "$CONF" && grep -qx "# Steam settings, mine" "$CONF" \
  && ok "on is saved once, beside the DXVK-Sarek and keep-running settings, which stay" || bad "out=$OUT conf=$(cat "$CONF")"
direct -- off
[ "$OUT" = off ] && grep -qx "DIRECT_LAUNCH=off" "$CONF" && ok "off is kept over the default" || bad "out=$OUT conf=$(cat "$CONF")"
direct -- status
[ "$OUT" = off ] && grep -q "steam.conf" <<<"$ERR" && ok "and read back, from the file" || bad "out=$OUT err=$ERR"
direct RETROFORGE_STEAM_DIRECT=on -- status
[ "$OUT" = on ] && ok "RETROFORGE_STEAM_DIRECT overrides the file" || bad "out=$OUT"
rm -f "$CONF"
direct -- off
[ "$OUT" = off ] && head -1 "$CONF" | grep -q '^# ' && grep -qx "DIRECT_LAUNCH=off" "$CONF" && ok "a new steam.conf gets its comment line" || bad "conf=$(cat "$CONF")"
direct -- sideways; [ "$RC" = 2 ] && ok "a bad invocation is exit 2" || bad "rc=$RC"
direct -- check Hades; [ "$RC" = 2 ] && grep -q "not an app id" <<<"$ERR" && ok "an app id that is not a number is exit 2" || bad "rc=$RC err=$ERR"

CASE="check: off"
fresh_log; rm -rf "$CACHE"
direct -- check 1145360
[ "$RC" = 1 ] && [ -z "$ERR" ] && ok "the setting off: exit 1, silently (Steam starts the game, as always)" || bad "rc=$RC err=$ERR"

CASE="check"
rm -f "$CONF"
direct -- check 1145360
[ "$RC" = 0 ] && [ -z "$ERR" ] && ok "a game Steam has started here: it starts without the client" || bad "rc=$RC err=$ERR"
[ -f "$CACHE/1145360.json" ] && python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d["logged"] == "2026-10-22 10:07:35" and d["command"] == sys.argv[2] else 1)' "$CACHE/1145360.json" "$HADES_CMD" \
  && ok "Steam's newest launch of it is kept (the 10:07 Vulkan one, not the 09:00 one)" || bad "cache: $(cat "$CACHE/1145360.json" 2>&1)"
direct -- check 268910
[ "$RC" = 1 ] && grep -q "app 268910 starts through Steam: Steam has not started it on this device yet" <<<"$ERR" \
  && ok "a game Steam never started here goes through Steam (its install scripts, its prefix), and that is said" || bad "rc=$RC err=$ERR"

CASE="check: the client"
mkdir -p "$H/.steam" "$T/proc/7780"; echo 7780 >"$H/.steam/steam.pid"; echo steam >"$T/proc/7780/comm"
direct -- check 1145360
[ "$RC" = 1 ] && grep -q "the Steam client is running" <<<"$ERR" && ok "a running client gets the game (overlay, cloud, achievements, no more memory)" || bad "rc=$RC err=$ERR"
echo "0::/user.slice/user-1000.slice/user@1000.service/app.slice/retroforge-steam.service" >"$T/proc/7780/cgroup"
direct -- check 1145360
[ "$RC" = 0 ] && ok "the kept client in the background (retroforge-steam.service) does not take the game: it stays beside it" || bad "rc=$RC err=$ERR"
echo "0::/user.slice/user-1000.slice/session-3.scope" >"$T/proc/7780/cgroup"
direct -- check 1145360
[ "$RC" = 1 ] && ok "a client of a launch of its own (Steam's UI open) does" || bad "rc=$RC err=$ERR"
rm -f "$T/proc/7780/cgroup"
echo bash >"$T/proc/7780/comm"
direct -- check 1145360
[ "$RC" = 0 ] && ok "a steam.pid left by a killed client, its pid now another program's, is not a client" || bad "rc=$RC err=$ERR"
rm -rf "$T/proc/7780"
direct -- check 1145360
[ "$RC" = 0 ] && ok "nor one whose process is gone" || bad "rc=$RC err=$ERR"

CASE="check: the log"
: >"$SLOG"; rm -rf "$CACHE"
logline "$S/logs/console_log.previous.txt" "2026-10-21 22:00:00" 1145360 "$HADES_CMD"
direct -- check 1145360
[ "$RC" = 0 ] && [ -f "$CACHE/1145360.json" ] && ok "a launch in console_log.previous.txt counts, and is kept" || bad "rc=$RC err=$ERR"
rm -f "$S/logs/console_log.previous.txt"
direct -- check 1145360
[ "$RC" = 0 ] && ok "rotated out of both logs, the kept launch still starts it" || bad "rc=$RC err=$ERR"
logline "$SLOG" "2026-10-22 11:00:00" 1145360 "$(cmdline 1145360 "$SLR" "$PROTON" "$GAME/x64/Hades.exe")"
direct -- check 1145360
grep -q '"logged": "2026-10-22 11:00:00"' "$CACHE/1145360.json" && grep -q 'x64/Hades.exe' "$CACHE/1145360.json" \
  && ok "a newer launch in the log replaces the kept one (the player chose DirectX this time)" || bad "cache: $(cat "$CACHE/1145360.json")"
logline "$SLOG" "2026-01-01 00:00:05" 1145360 "$HADES_CMD"
direct -- check 1145360
grep -q '"logged": "2026-01-01 00:00:05"' "$CACHE/1145360.json" && grep -q 'x64Vk/Hades.exe' "$CACHE/1145360.json" \
  && ok "the log's last launch wins by its place, not its stamp (written before the clock was set)" || bad "cache: $(cat "$CACHE/1145360.json")"
fresh_log
direct -- remember
[ "$RC" = 0 ] && grep -q 'x64Vk/Hades.exe' "$CACHE/1145360.json" && grep -q 'Stardew/x.exe' "$CACHE/413150.json" \
  && ok "remember keeps every game's newest launch (what /usr/bin/steam runs before the client starts)" || bad "rc=$RC $(ls "$CACHE" 2>&1)"
fresh_log
logline "$SLOG" "2026-10-22 10:30:00" 42 "/usr/bin/true SteamLaunch AppId=4242 -- x"
acf "$S" 42 FortyTwo 4
direct -- check 42
[ "$RC" = 1 ] && grep -q "has not started it on this device yet" <<<"$ERR" \
  && ok "a logged command that is not Steam's reaper for that app is not a launch of it" || bad "rc=$RC err=$ERR"
rm -f "$S/steamapps/appmanifest_42.acf"
fresh_log
logline "$SLOG" "2026-10-25 03:16:37" 1145360 ""
direct -- check 1145360
[ "$RC" = 0 ] && grep -q 'x64Vk/Hades.exe' "$CACHE/1145360.json" \
  && ok "a game the client did not start (logged by the kept client with an empty command) is not Steam's newest launch" || bad "rc=$RC err=$ERR"

CASE="check: the game"
acf "$S" 1145360 Hades 1026
direct -- check 1145360
[ "$RC" = 1 ] && grep -q "its files are not ready (StateFlags 1026)" <<<"$ERR" && ok "while Steam updates it: through Steam" || bad "rc=$RC err=$ERR"
acf "$S" 1145360 Hades 6
direct -- check 1145360
[ "$RC" = 0 ] && [ -z "$ERR" ] && ok "an update Steam has only queued (StateFlags 2) does not stop it" || bad "rc=$RC err=$ERR"
acf "$S" 1145360 Hades 68
direct -- check 1145360
[ "$RC" = 0 ] && ok "nor does a run Steam did not see end (StateFlags 64, the client was killed)" || bad "rc=$RC err=$ERR"
acf "$S" 1145360 Hades $((4 | 0x40000))
direct -- check 1145360
[ "$RC" = 1 ] && grep -q "not ready" <<<"$ERR" && ok "any other bit (adding files) leaves it to Steam" || bad "rc=$RC err=$ERR"
mv "$S/steamapps/appmanifest_1145360.acf" "$T/hades.acf"
direct -- check 1145360
[ "$RC" = 1 ] && grep -q "it is not installed" <<<"$ERR" && ok "uninstalled: through Steam" || bad "rc=$RC err=$ERR"
printf '"AppState"\n{\n\t"appid"\t\t"1145360"\n\t"StateFlags"\t\t"4"\n\t"installdir"\t\t""\n}\n' >"$S/steamapps/appmanifest_1145360.acf"
direct -- check 1145360
[ "$RC" = 1 ] && grep -q "names no folder" <<<"$ERR" && ok "an app manifest with no folder (every game would be its)" || bad "rc=$RC err=$ERR"
mv "$T/hades.acf" "$S/steamapps/appmanifest_1145360.acf"; acf "$S" 1145360 Hades 4

CASE="check: the tools"
mv "$PROTON" "$T/proton-away"
direct -- check 1145360
[ "$RC" = 1 ] && grep -q "Proton 11.0 (ARM64)/proton is gone" <<<"$ERR" && ok "a compat tool that is gone: through Steam, which picks what is installed now" || bad "rc=$RC err=$ERR"
mv "$T/proton-away" "$PROTON"
FEX="$S/steamapps/common/FEX"; SNIPER="$S/steamapps/common/SteamLinuxRuntime_sniper"; PX86="$S/steamapps/common/Proton 11.0"
mkdir -p "$FEX" "$SNIPER" "$PX86" "$S/steamapps/common/Trine/bin"
touch "$FEX/toolmanifest.vdf" "$FEX/fex-wrapper" "$SNIPER/toolmanifest.vdf" "$SNIPER/_v2-entry-point" "$PX86/toolmanifest.vdf" "$PX86/proton" "$S/steamapps/common/Trine/bin/trine.exe"
acf "$S" 3127680 FEX 4; acf "$S" 1628350 SteamLinuxRuntime_sniper 4; acf "$S" 35700 Trine 4
logline "$SLOG" "2026-10-22 10:40:00" 35700 "$S/linuxarm64/steam-launch-wrapper -- $S/steamrtarm64/reaper SteamLaunch AppId=35700 -- '$FEX'/fex-wrapper -- '$SNIPER'/_v2-entry-point --verb=waitforexitandrun -- '$PX86'/proton waitforexitandrun '$S/steamapps/common/Trine/bin/trine.exe'"
direct -- check 35700
[ "$RC" = 1 ] && grep -q "FEX tool" <<<"$ERR" && ok "an x86 Proton through Steam's FEX tool: through Steam" || bad "rc=$RC err=$ERR"
logline "$SLOG" "2026-10-22 10:41:00" 35700 "$S/linuxarm64/steam-launch-wrapper -- $S/steamrtarm64/reaper SteamLaunch AppId=35700 -- '$S/steamapps/common/Trine/bin/trine.exe'"
direct -- check 35700
[ "$RC" = 1 ] && grep -q "names no compat tool" <<<"$ERR" && ok "a launch with no compat tool at all is not replayed" || bad "rc=$RC err=$ERR"
fresh_log; logline "$SLOG" "2026-10-22 10:50:00" 1145360 "$HADES_CMD -log $S/logs/hades-run.log"
direct -- check 1145360
[ "$RC" = 0 ] && ok "a file the game is told to write, in a folder that is there, is not a tool that is gone" || bad "rc=$RC err=$ERR"
logline "$SLOG" "2026-10-22 10:51:00" 1145360 "$S/linuxarm64/steam-launch-wrapper -- $S/steamrtarm64/reaper SteamLaunch AppId=1145360 -- '$SLR'/_v2-entry-point --verb=waitforexitandrun -- '$PROTON'/proton waitforexitandrun"
direct -- check 1145360
[ "$RC" = 1 ] && grep -q "names no program of the game" <<<"$ERR" && ok "a launch that runs nothing of the game is not replayed" || bad "rc=$RC err=$ERR"
fresh_log; mv "$S/linuxarm64/steam-launch-wrapper" "$T/slw"
direct -- check 1145360
[ "$RC" = 1 ] && grep -q "steam-launch-wrapper is gone" <<<"$ERR" && ok "Steam's launch wrapper gone: through Steam" || bad "rc=$RC err=$ERR"
mv "$T/slw" "$S/linuxarm64/steam-launch-wrapper"

# ================================================================================================
CASE="run"
fresh_log; reset_run
direct DISPLAY=:1 OGUI_ID=Hades -- run 1145360
[ "$RC" = 0 ] && [ -f "$T/ran.args" ] && ok "Steam's launch ran, through Steam's own launch wrapper" || bad "rc=$RC err=$ERR"
want="$(printf '%s\n' --oom-score-adjust 900 -- "$S/steamrtarm64/reaper" SteamLaunch AppId=1145360 -- "$SLR/_v2-entry-point" \
  --verb=waitforexitandrun -- "$PROTON/proton" waitforexitandrun "$GAME/x64Vk/Hades.exe" '/c=..\' /steampowered /DirectLoadShell=true)"
[ "$(cat "$T/ran.args")" = "$want" ] && ok "word for word as Steam ran it (/bin/sh -c): quoted paths with spaces, the game's /c=..\\" \
  || bad "args: $(cat "$T/ran.args")"
[ "$(cat "$T/ran.cwd")" = "$GAME/x64Vk" ] && ok "from the Vulkan launch entry's working folder" || bad "cwd: $(cat "$T/ran.cwd")"
[ "$(ran_env SteamAppId)" = 1145360 ] && [ "$(ran_env SteamGameId)" = 1145360 ] && [ "$(ran_env SteamOverlayGameId)" = 1145360 ] \
  && [ "$(ran_env STEAM_COMPAT_APP_ID)" = 1145360 ] && ok "the app id, as Steam gives it" || bad "env: $(grep -i appid "$T/ran.env")"
[ "$(ran_env STEAM_COMPAT_CLIENT_INSTALL_PATH)" = "$S" ] && [ "$(ran_env STEAM_COMPAT_DATA_PATH)" = "$S/steamapps/compatdata/1145360" ] \
  && [ "$(ran_env STEAM_COMPAT_INSTALL_PATH)" = "$GAME" ] && [ "$(ran_env STEAM_COMPAT_SHADER_PATH)" = "$S/steamapps/shadercache/1145360" ] \
  && ok "Proton's prefix, the game, the client and the shader cache" || bad "env: $(grep STEAM_COMPAT "$T/ran.env")"
[ "$(ran_env STEAM_COMPAT_TOOL_PATHS)" = "$PROTON:$SLR" ] && [ "$(ran_env STEAM_COMPAT_LIBRARY_PATHS)" = "$S/steamapps" ] \
  && ok "the compat tools, Proton then its runtime, and the library (what pressure-vessel shares)" || bad "tools=$(ran_env STEAM_COMPAT_TOOL_PATHS) libs=$(ran_env STEAM_COMPAT_LIBRARY_PATHS)"
[ "$(ran_env STEAM_COMPAT_CONFIG)" = "gamedrive,heapdelayfree" ] && [ "$(ran_env SteamDeck)" = 1 ] \
  && ok "Valve's per-game Proton setting (app 891390), and SteamDeck=1 as the -steamdeck client sets it" || bad "config=$(ran_env STEAM_COMPAT_CONFIG) deck=$(ran_env SteamDeck)"
[ "$(ran_env DISPLAY)" = :1 ] && [ "$(ran_env OGUI_ID)" = Hades ] && ok "over the launch's own environment (OGUI's display and id)" || bad "env: $(grep -E '^(DISPLAY|OGUI_ID)=' "$T/ran.env")"
grep -q "starting app 1145360 without the Steam client, as Steam started it at 2026-10-22 10:07:35" <<<"$ERR" \
  && ok "and says so, with which of Steam's launches" || bad "err=$ERR"
[ -f "$T/ran.traps" ] && ! grep -q SIGPIPE "$T/ran.traps" \
  && ok "SIGPIPE is not left ignored (Python ignores it, and exec keeps that)" || bad "traps: $(cat "$T/ran.traps" 2>&1)"
[ "$(cat "$T/ran.oom" 2>/dev/null)" = 900 ] \
  && ok "the launch starts at oom_score_adj 900, the OOM killer's first choice, before Steam's wrapper sets anything" \
  || bad "oom_score_adj: $(cat "$T/ran.oom" 2>&1)"
reset_run; echo 3 >"$T/game.rc"
direct -- run 1145360
[ "$RC" = 3 ] && ok "the game's exit status is the launch's (the helper becomes the launch)" || bad "rc=$RC"
reset_run; mkdir -p "$T/proc/7780"; echo steam >"$T/proc/7780/comm"   # ~/.steam/steam.pid says 7780
direct RETROFORGE_STEAM_DIRECT=off -- run 1145360
[ "$RC" = 0 ] && [ -f "$T/ran.args" ] && ok "run, which /usr/bin/steam execs after a check, asks neither the setting nor for a client again" || bad "rc=$RC err=$ERR"
rm -rf "$T/proc/7780"

CASE="run: the tool Steam is set to now"
OURS="$S/compatibilitytools.d/proton-cachyos-armv8-retroforge"; mkdir -p "$OURS" "$S/config"
printf '#!/bin/sh\nexit 0\n' >"$OURS/proton"; chmod +x "$OURS/proton"
printf '"manifest"\n{\n  "commandline" "/proton %%verb%%"\n  "require_tool_appid" "4185400"\n}\n' >"$OURS/toolmanifest.vdf"
printf '"compatibilitytools"\n{\n  "compat_tools"\n  {\n    "proton-cachyos-armv8-retroforge" // Internal name\n    {\n      "install_path" "."\n    }\n  }\n}\n' >"$OURS/compatibilitytool.vdf"
mapping() {  # mapping <the game's own tool|-> <Steam's default tool>: config.vdf's CompatToolMapping
  { printf '"InstallConfigStore"\n{\n\t"Software"\n\t{\n\t\t"Valve"\n\t\t{\n\t\t\t"Steam"\n\t\t\t{\n\t\t\t\t"CompatToolMapping"\n\t\t\t\t{\n'
    [ "$1" != - ] && printf '\t\t\t\t\t"1145360"\n\t\t\t\t\t{\n\t\t\t\t\t\t"name"\t\t"%s"\n\t\t\t\t\t}\n' "$1"
    printf '\t\t\t\t\t"0"\n\t\t\t\t\t{\n\t\t\t\t\t\t"name"\t\t"%s"\n\t\t\t\t\t}\n\t\t\t\t}\n\t\t\t}\n\t\t}\n\t}\n}\n' "$2"; } >"$S/config/config.vdf"
}
fresh_log; reset_run; mapping - proton-cachyos-armv8-retroforge
direct -- run 1145360
grep -qxF "$OURS/proton" "$T/ran.args" && [ "$(ran_env STEAM_COMPAT_TOOL_PATHS)" = "$OURS:$SLR" ] && grep -q "runs with proton-cachyos-armv8-retroforge" <<<"$ERR" \
  && ok "Steam's default is our tool: it runs instead of the Proton Steam logged" || bad "args=$(grep proton "$T/ran.args") err=$ERR"
fresh_log; reset_run; mapping proton_11-arm64 proton-cachyos-armv8-retroforge
direct -- run 1145360
grep -qxF "$PROTON/proton" "$T/ran.args" && ok "a game set to the tool Steam logged keeps its logged launch (one of Steam's own, by its app's folder)" || bad "args=$(grep proton "$T/ran.args") err=$ERR"
fresh_log; reset_run; mapping - proton-cachyos-armv8-retroforge
sed -i.b 's/4185400/1628350/' "$OURS/toolmanifest.vdf"
direct -- run 1145360
grep -qxF "$PROTON/proton" "$T/ran.args" && ok "a tool on another runtime is not swapped in" || bad "args=$(grep proton "$T/ran.args")"
mapping proton-cachyos-armv8-retroforge proton_11-arm64
direct -- check 1145360
[ "$RC" = 1 ] && grep -q "set to run with proton-cachyos-armv8-retroforge now, which Steam's last launch of it did not use" <<<"$ERR" \
  && ok "nor replayed when the game itself is set to it: Steam starts it on that runtime once" || bad "rc=$RC err=$ERR"
mv "$OURS/toolmanifest.vdf.b" "$OURS/toolmanifest.vdf"

# The game's own tool (Game settings > RetroForge > Compatibility tool, or Steam's Properties): followed
# at once where the logged launch can be given it.
CASE="run: the tool the game is set to"
OURS_CMD="$(cmdline 1145360 "$SLR" "$OURS" "$GAME/x64Vk/Hades.exe")"
ours_log() { fresh_log; logline "$SLOG" "2026-10-23 08:00:00" 1145360 "$OURS_CMD"; }   # Steam last ran it with our build
fresh_log; reset_run; mapping proton-cachyos-armv8-retroforge proton_11-arm64
direct -- run 1145360
grep -qxF "$OURS/proton" "$T/ran.args" && [ "$(ran_env STEAM_COMPAT_TOOL_PATHS)" = "$OURS:$SLR" ] \
  && ok "set to a compatibilitytools.d Proton: it runs instead of the one Steam logged" || bad "args=$(grep proton "$T/ran.args") err=$ERR"
ours_log; reset_run; mapping proton_11-arm64 proton-cachyos-armv8-retroforge
direct -- run 1145360
grep -qxF "$PROTON/proton" "$T/ran.args" && [ "$(ran_env STEAM_COMPAT_TOOL_PATHS)" = "$PROTON:$SLR" ] && grep -q "runs with Proton 11.0 (ARM64), not proton-cachyos-armv8-retroforge" <<<"$ERR" \
  && ok "set to one of Steam's own Protons, installed: its app's folder takes the logged tool's place" || bad "args=$(grep proton "$T/ran.args") err=$ERR"
ours_log; reset_run; mapping proton-stable proton-cachyos-armv8-retroforge
direct -- run 1145360
grep -qxF "$PROTON/proton" "$T/ran.args" && ok "set by an alias (proton-stable): the tool it means in the arm64 list" || bad "args=$(grep proton "$T/ran.args") err=$ERR"
ours_log; reset_run; mapping proton-experimental-arm64 proton-cachyos-armv8-retroforge
direct -- check 1145360
[ "$RC" = 1 ] && grep -q "app 1145360 starts through Steam: it is set to run with Proton Experimental (ARM64) now" <<<"$ERR" \
  && ok "set to a tool Steam has yet to download: through Steam, which downloads it" || bad "rc=$RC err=$ERR"
direct -- run 1145360
[ "$RC" = 1 ] && [ ! -e "$T/ran.args" ] && ok "and nothing is replayed with the old tool" || bad "rc=$RC args=$(cat "$T/ran.args" 2>&1)"
acf "$S" 1070560 SteamLinuxRuntime 4; mkdir -p "$S/steamapps/common/SteamLinuxRuntime"
mapping steamlinuxruntime proton-cachyos-armv8-retroforge
direct -- check 1145360
[ "$RC" = 1 ] && grep -q "set to run with Steam Linux Runtime 1.0 now" <<<"$ERR" \
  && ok "set to the Linux runtime (the game's other build): through Steam" || bad "rc=$RC err=$ERR"
mapping some-tool-that-is-gone proton-cachyos-armv8-retroforge
direct -- check 1145360
[ "$RC" = 1 ] && grep -q "set to run with some-tool-that-is-gone now" <<<"$ERR" && ok "set to a tool nothing lists: through Steam" || bad "rc=$RC err=$ERR"
mv "$S/appcache" "$T/appcache.away"; reset_run
direct -- run 1145360
grep -qxF "$OURS/proton" "$T/ran.args" && ok "Steam's lists unreadable: a name that cannot be looked up leaves the logged launch as it is" || bad "rc=$RC args=$(grep proton "$T/ran.args" 2>&1) err=$ERR"
mv "$T/appcache.away" "$S/appcache"
# Back to Steam's choice (Default): no entry to follow, so the launch logged with the tool just left is
# not replayed, until Steam has logged a newer one.
printf 'Features\t: fp asimd atomics\n' >"$T/v82"
ours_log; reset_run; mapping proton-cachyos-armv8-retroforge proton_11-arm64
direct RETROFORGE_CPUINFO="$T/v82" -- game 1145360 set tool default
[ "$RC" = 0 ] && ! grep -q '"1145360"' "$S/config/config.vdf" && [ -f "$CACHE/1145360.stale" ] \
  && ok "Default: the game's entry is gone from config.vdf, and Steam's launch with the old tool is marked" || bad "rc=$RC err=$ERR $(ls "$CACHE" 2>&1)"
direct -- check 1145360
[ "$RC" = 1 ] && grep -q "its compatibility tool went back to Steam's choice after Steam's launch of 2026-10-23 08:00:00" <<<"$ERR" \
  && ok "that launch is not replayed: Steam starts the game once, with its own choice" || bad "rc=$RC err=$ERR"
logline "$SLOG" "2026-10-23 09:00:00" 1145360 "$HADES_CMD"
direct -- check 1145360
[ "$RC" = 0 ] && [ ! -e "$CACHE/1145360.stale" ] && ok "once Steam has logged a newer launch, that one is replayed, and the mark is gone" || bad "rc=$RC err=$ERR"
direct RETROFORGE_CPUINFO="$T/v82" -- game 1145360 set tool proton_11-arm64
[ "$RC" = 0 ] && [ ! -e "$CACHE/1145360.stale" ] && ok "a tool chosen leaves no mark: its entry is followed" || bad "rc=$RC err=$ERR"
fresh_log; reset_run; mapping proton_11-arm64 proton-cachyos-armv8-retroforge
direct RETROFORGE_CPUINFO="$T/v82" -- game 1145360 set tool default
direct -- run 1145360
[ -f "$CACHE/1145360.stale" ] && grep -qxF "$OURS/proton" "$T/ran.args" \
  && ok "Default where Steam's default is a compatibilitytools.d tool: the launch is replayed with that one, as for any game with no tool of its own" \
  || bad "rc=$RC args=$(grep proton "$T/ran.args" 2>&1) err=$ERR"
rm -f "$S/steamapps/appmanifest_1070560.acf" "$CACHE/1145360.stale"; rm -rf "$S/steamapps/common/SteamLinuxRuntime"
rm -rf "$S/compatibilitytools.d" "$S/config/config.vdf"

CASE="run: per-game choices"
GAMES="$H/.config/retroforge/steam-games.json"
direct -- game 1145360
[ "$RC" = 0 ] && python3 -c 'import json, sys; d = json.loads(sys.argv[1]); assert d["settings"] == {"tso": "default", "launch": "default", "resolution": "default", "driver": "default", "api": "default", "cpus": "default"}, d; assert d["apis"] == [], d; assert d["x86"] is False, d; assert d["tso_hint"] == "0", d; assert [e["key"] for e in d["launch"]] == ["0", "1", "2", "3", "4", "15"], d; assert d["launch"][-1]["description"] == "Hades (Steam Deck)", d; assert d["direct"] in ("on", "off"), d' "$OUT" \
  && ok "game: every choice at its default, and the launch entries Steam's dialog offers here, in its order" || bad "rc=$RC out=$OUT err=$ERR"
[ -z "$ERR" ] && ok "game: the current client's app cache shards read without a word" || bad "err=$ERR"
mkappinfo 29; ENTRIES="$OUT"
direct -- game 1145360
[ "$RC" = 0 ] && [ "$OUT" = "$ENTRIES" ] && [ -z "$ERR" ] && ok "game: an older client's appinfo.vdf, the same" || bad "rc=$RC out=$OUT err=$ERR"
rm -f "$S/appcache/appinfo.vdf"
direct -- game 1145360
[ "$RC" = 0 ] && grep -q "Steam's app cache: .*appinfo.vdf" <<<"$ERR" && python3 -c 'import json, sys; assert json.loads(sys.argv[1])["launch"] == []' "$OUT" \
  && ok "game: no app cache at all: no launch entries, and says so" || bad "rc=$RC out=$OUT err=$ERR"
mkappinfo
direct -- game 1145360 set launch 0
[ "$RC" = 0 ] && python3 -c 'import json, sys; assert json.load(open(sys.argv[1])) == {"1145360": {"launch": "0"}}' "$GAMES" \
  && ok "set: saved in steam-games.json" || bad "rc=$RC $(cat "$GAMES" 2>&1)"
direct -- game 1145360 set proton experimental
[ "$RC" = 2 ] && ok "set: proton is no choice any more (one ARMv8.0 build, Steam's default)" || bad "rc=$RC"
direct -- game 1145360 set tso maybe
[ "$RC" = 2 ] && ok "set: a value that is not a choice is refused" || bad "rc=$RC"
direct -- game 1145360 set sarek on
[ "$RC" = 2 ] && ok "set: sarek is no choice any more (Sarek follows the GPU)" || bad "rc=$RC"
fresh_log; reset_run
direct -- run 1145360
grep -qxF "$GAME/x64/Hades.exe" "$T/ran.args" && grep -qxF "$PROTON/proton" "$T/ran.args" && [ "$(cat "$T/ran.cwd")" = "$GAME/x64" ] \
  && ok "run: the chosen launch option, from its own working folder, with the Proton Steam logged" || bad "args=$(grep -E 'proton|Hades' "$T/ran.args") cwd=$(cat "$T/ran.cwd")"
[ -z "$(ran_env PROTON_DXVK_SAREK)" ] && ok "run: no PROTON_DXVK_SAREK (the tool's user_settings.py decides)" || bad "sarek=$(ran_env PROTON_DXVK_SAREK)"
[ "$(ran_env STEAM_FEX_TSOENABLED)" = 0 ] && ok "run: FEX TSO by default as Valve runs the game on the Steam Frame (Hades: off)" || bad "tso=$(ran_env STEAM_FEX_TSOENABLED)"
direct -- game 1145360 set tso on; fresh_log; reset_run
direct -- run 1145360
[ "$(ran_env STEAM_FEX_TSOENABLED)" = 1 ] && ok "run: the player's choice over Valve's (STEAM_FEX_TSOENABLED, Proton's FEX config)" || bad "tso=$(ran_env STEAM_FEX_TSOENABLED)"
direct -- game 1145360 set tso default
direct -- game 1145360 set launch 4; fresh_log; reset_run; mkdir "$GAME/Odd"
direct -- run 1145360
want="$(printf '%s\n' "$GAME/x64/Hades.exe" '/c=..\' -dx11 '/name=two words' /DirectLoadShell=true)"
[ "$(grep -A9 -xF "$GAME/x64/Hades.exe" "$T/ran.args")" = "$want" ] && [ "$(cat "$T/ran.cwd")" = "$GAME/Odd" ] \
  && ok "run: the launch option's own arguments and working folder, the player's extra words kept" \
  || bad "args=$(tail -6 "$T/ran.args" | tr "\n" "|") cwd=$(cat "$T/ran.cwd")"
rmdir "$GAME/Odd"
for k in launch tso; do direct -- game 1145360 set $k default; done
python3 -c 'import json, sys; assert json.load(open(sys.argv[1])) == {}' "$GAMES" && ok "all back to default: nothing kept" || bad "$(cat "$GAMES")"
rm -rf "$S/compatibilitytools.d" "$GAMES"

CASE="run: on fast cores"
# python/fastcores.py: a fake topology (4 little at 284, 4 big at 1024), and a uclampset that says what it
# was asked and runs the rest as the real one does.
mkdir -p "$T/fbin" "$T/cpu"; echo 0-7 >"$T/cpu/online"; echo disabled >"$T/scx"
for c in 0 1 2 3 4 5 6 7; do mkdir -p "$T/cpu/cpu$c"; echo $([ $c -lt 4 ] && echo 284 || echo 1024) >"$T/cpu/cpu$c/cpu_capacity"; done
cat >"$T/fbin/uclampset" <<EOF
#!/bin/sh
echo "uclampset \$*" >>"$T/fast.log"
[ "\$3" = -a ] && exit 0
shift 2; exec "\$@"
EOF
chmod +x "$T/fbin/uclampset"
FAST=(RETROFORGE_CPU_ROOT="$T/cpu" RETROFORGE_SCX_STATE="$T/scx" PATH="$T/fbin:$PATH")
fresh_log; reset_run; rm -f "$T/fast.log"
direct "${FAST[@]}" -- run 1145360
[ "$RC" = 0 ] && [ -f "$T/ran.args" ] && [ ! -e "$T/fast.log" ] && ok "Off, the default: the launch runs as Steam ran it, no uclamp" || bad "rc=$RC fast=$(cat "$T/fast.log" 2>&1)"
direct -- game 1145360 set cpus on
[ "$RC" = 0 ] && python3 -c 'import json, sys; assert json.loads(sys.argv[1])["settings"]["cpus"] == "on"' "$OUT" \
  && ok "game set cpus on: saved" || bad "rc=$RC out=$OUT err=$ERR"
direct -- game 1145360 set cpus off
[ "$RC" = 2 ] && ok "cpus is on or default, nothing else" || bad "rc=$RC err=$ERR"
fresh_log; reset_run; rm -f "$T/fast.log"
direct "${FAST[@]}" -- run 1145360
[ "$RC" = 0 ] && grep -q '^uclampset -m 285 /bin/sh -c ' "$T/fast.log" && grep -qx "AppId=1145360" "$T/ran.args" \
  && ok "On: the launch starts under uclampset -m 285 (just above the little cores), the rest as Steam ran it" \
  || bad "rc=$RC fast=$(cat "$T/fast.log" 2>&1) args=$(cat "$T/ran.args" 2>&1)"
grep -q "app 1145360: prefers fast cores 4,5,6,7 (uclamp.min 285)" <<<"$ERR" && ok "and says so" || bad "err=$ERR"
rm -f "$T/fast.log"
direct "${FAST[@]}" -- fastcores 1145360 4242 4343
[ "$RC" = 0 ] && grep -qx "uclampset -m 285 -a -p 4242" "$T/fast.log" && grep -qx "uclampset -m 285 -a -p 4343" "$T/fast.log" \
  && ok "fastcores: the kept client's game, every thread of each process given" || bad "rc=$RC fast=$(cat "$T/fast.log" 2>&1) err=$ERR"
direct -- game 1145360 set cpus default
rm -f "$T/fast.log"
direct "${FAST[@]}" -- fastcores 1145360 4242
[ "$RC" = 0 ] && [ ! -e "$T/fast.log" ] && ok "fastcores for a game without the choice: nothing" || bad "rc=$RC fast=$(cat "$T/fast.log" 2>&1)"
direct -- fastcores 1145360
[ "$RC" = 2 ] && ok "fastcores without a process: usage" || bad "rc=$RC"

CASE="fex: an x86 game's graphics driver"
# Megabonk's folder: two x86 programs (64- and 32-bit, an interpreter each), an x86 library and an
# arm64 program (no), a file that is not executable (no).
MB="$S/steamapps/common/Megabonk"; FX="$S/steamapps/compatdata/3405340/fex-emu"
acf "$S" 3405340 Megabonk 4
elf() {  # elf <file> <bits> <machine> <interp 0|1>: a minimal ELF header and one program header
  mkdir -p "$(dirname "$1")"
  python3 - "$@" <<'PY'
import struct, sys
path, bits, machine, interp = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4] == "1"
ident = b"\x7fELF" + bytes([2 if bits == 64 else 1, 1, 1]) + bytes(9)
if bits == 64:
    head = ident + struct.pack("<HHIQQQIHHHHHH", 2, machine, 1, 0, 64, 0, 0, 64, 56, 1, 0, 0, 0)
    ph = struct.pack("<IIQQQQQQ", 3 if interp else 1, 4, 0, 0, 0, 0, 0, 1)
else:
    head = ident + struct.pack("<HHIIIIIHHHHHH", 2, machine, 1, 0, 52, 0, 0, 52, 32, 1, 0, 0, 0)
    ph = struct.pack("<IIIIIIII", 3 if interp else 1, 0, 0, 0, 0, 0, 4, 1)
open(path, "wb").write(head + ph)
PY
  chmod +x "$1"
}
elf "$MB/Megabonk.x86_64" 64 62 1; elf "$MB/bin/tool32" 32 3 1; elf "$MB/UnityPlayer.so" 64 62 0
elf "$MB/arm/native" 64 183 1; elf "$MB/data/plain" 64 62 1; chmod -x "$MB/data/plain"
mkdir -p "$FX/AppConfig"; echo '{"ThunksDB": {"GL": 0}}' >"$FX/AppConfig/Steam_3405340_tool32.json"
direct -- fex 3405340
cfg() { python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); print(json.dumps(d.get("ThunksDB")), "ours" if d.get("RetroForge") else "theirs")' "$FX/AppConfig/Steam_3405340_$1.json" 2>&1; }
jget() { python3 -c 'import json, sys; d = json.load(open(sys.argv[1]))
for k in sys.argv[2:]: d = d.get(k, {}) if isinstance(d, dict) else {}
print(d if d != {} else "")' "$@" 2>&1; }
M="$FX/AppConfig/Steam_3405340_Megabonk.x86_64.json"
# x86 Mesa by default: FEX's thunks hand some games' callbacks to the host's driver as x86 code (Parking
# Garage Rally Circuit, verbose Godot: SIGILL on both thunks)
[ "$RC" = 0 ] && [ ! -e "$FX/ThunksDB.json" ] && [ ! -e "$FX/retroforge-vulkan-icd.json" ] && [ "$(cfg Megabonk.x86_64)" = 'null ours' ] \
  && [ "$(jget "$M" Config TSOEnabled)" = 1 ] && grep -q "through the x86 driver in FEX's guest, FEX TSO on" <<<"$ERR" \
  && ok "x86 Mesa by default: no thunks, only the game's FEX TSO (Valve's hint) in its file" || bad "rc=$RC $(ls "$FX" "$FX/AppConfig") $(cat "$M" 2>&1) err=$ERR"
direct -- game 3405340
python3 -c 'import json, sys; d = json.loads(sys.argv[1]); assert d["x86"] is True and d["settings"]["driver"] == "default" and d["tso_hint"] == "1", d' "$OUT" \
  && ok "game: an x86 game, its driver at its default, Valve's TSO shown" || bad "out=$OUT"
direct -- game 3405340 set driver native; direct -- fex 3405340
[ "$RC" = 0 ] && [ "$(cfg Megabonk.x86_64)" = '{"GL": 1, "Vulkan": 1} ours' ] && [ "$(ls "$FX/AppConfig")" = "$(printf 'Steam_3405340_Megabonk.x86_64.json\nSteam_3405340_tool32.json')" ] \
  && ok "native when chosen: FEX's GL and Vulkan thunks on for each x86 program, by app id and program (not its library, not arm64)" || bad "rc=$RC $(ls "$FX/AppConfig") $(cfg Megabonk.x86_64) err=$ERR"
[ "$(cfg tool32)" = '{"GL": 0} theirs' ] && ok "a file of the player's own is left as it is" || bad "$(cfg tool32)"
[ "$(jget "$M" Config HostEnv)" = "VK_DRIVER_FILES=$FX/retroforge-vulkan-icd.json" ] && [ "$(jget "$M" AppOverrides '*' HostEnv)" = "VK_INSTANCE_LAYERS=" ] \
  && [ "$(jget "$FX/retroforge-vulkan-icd.json" ICD library_path)" = /run/host/usr/lib/libvulkan_freedreno.so ] \
  && ok "the host side gets the device's Turnip (its manifest under /run/host) and none of Steam's x86 layers" || bad "$(cat "$M") $(cat "$FX/retroforge-vulkan-icd.json" 2>&1)"
[ "$(jget "$M" Config TSOEnabled)" = 1 ] && ok "FEX TSO as Valve runs the game on the Steam Frame (its hint: on)" || bad "$(cat "$M")"
python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); o = d["DB"]["GL"]["Overlay"]; assert d["DB"]["GL"]["Library"] == "libGL-guest.so"; assert "/run/gfx/main/usr/lib/libGL.so.1" in o and "/usr/lib/pressure-vessel/overrides/lib/x86_64-linux-gnu/libGL.so.1" in o and "/run/gfx/main/usr/lib32/libGL.so.1" in o; assert not any("@PREFIX_LIB@" in p for p in o)
v = d["DB"]["Vulkan"]; assert v["Library"] == "libvulkan-guest.so"; assert "/usr/lib/x86_64-linux-gnu/libvulkan.so.1" in v["Overlay"]; assert not any("i386" in p or "lib32" in p for p in v["Overlay"]), v' "$FX/ThunksDB.json" \
  && ok "and a thunk database naming the container's own library paths (not @PREFIX_LIB@), Vulkan 64-bit only" || bad "$(head -c 400 "$FX/ThunksDB.json")"
grep -q "app 3405340: GL and Vulkan through the device's own driver" <<<"$ERR" && grep -q "FEX TSO on" <<<"$ERR" && ok "it says so" || bad "err=$ERR"
direct -- fex 3405340
[ "$RC" = 0 ] && [ -z "$ERR" ] && ok "again: nothing to change, nothing said" || bad "rc=$RC err=$ERR"
direct -- game 3405340 set tso off; direct -- fex 3405340
[ "$(jget "$M" Config TSOEnabled)" = 0 ] && ok "the player's TSO choice over Valve's" || bad "$(cat "$M")"
direct -- game 3405340 set tso default
direct -- game 3405340 set driver x86
direct -- fex 3405340
[ "$(ls "$FX/AppConfig")" = "$(printf 'Steam_3405340_Megabonk.x86_64.json\nSteam_3405340_tool32.json')" ] && [ ! -e "$FX/ThunksDB.json" ] \
  && [ ! -e "$FX/retroforge-vulkan-icd.json" ] && [ "$(cfg Megabonk.x86_64)" = 'null ours' ] && [ "$(jget "$M" Config TSOEnabled)" = 1 ] \
  && grep -q "through the x86 driver in FEX's guest, FEX TSO on" <<<"$ERR" \
  && ok "x86 again: our thunk files go, the TSO setting stays (an x86 game has no other way to get it), the player's file kept" || bad "$(ls "$FX" "$FX/AppConfig") $(cat "$M" 2>&1) err=$ERR"
direct -- game 3405340 set driver vulkan
[ "$RC" = 2 ] && ok "set: a driver that is not a choice is refused" || bad "rc=$RC"
rm "$FX/AppConfig/Steam_3405340_tool32.json"; direct -- game 3405340 set driver native; direct -- fex 3405340
[ "$(cfg tool32)" = '{"GL": 1, "Vulkan": 1} ours' ] || bad "tool32: $(cfg tool32)"
direct RETROFORGE_VULKAN_ICD="$T/none.json" -- fex 3405340
[ "$(cfg Megabonk.x86_64)" = '{"GL": 1} ours' ] && [ -z "$(jget "$M" Config HostEnv)" ] && [ ! -e "$FX/retroforge-vulkan-icd.json" ] \
  && python3 -c 'import json, sys; assert "Vulkan" not in json.load(open(sys.argv[1]))["DB"]' "$FX/ThunksDB.json" \
  && ok "no Turnip manifest on the device: GL only, the Vulkan files gone" || bad "$(cat "$M") $(ls "$FX")"
direct -- fex 3405340
rm "$MB/bin/tool32"; direct -- fex 3405340
[ ! -e "$FX/AppConfig/Steam_3405340_tool32.json" ] && [ -e "$FX/AppConfig/Steam_3405340_Megabonk.x86_64.json" ] \
  && ok "a program gone from the game: our file for it goes" || bad "$(ls "$FX/AppConfig")"
rm -rf "$FX"; mkdir -p "$S/steamapps/compatdata/3405340/pfx"
direct -- fex 3405340
[ ! -e "$FX" ] && ok "a game Proton runs (a prefix in its compat data): left alone" || bad "$(ls -R "$FX")"
rm -rf "$S/steamapps/compatdata/3405340"
direct -- fex 1145360
[ "$RC" = 0 ] && [ ! -e "$S/steamapps/compatdata/1145360" ] && ok "a game with no x86 program: nothing" || bad "rc=$RC $(ls "$S/steamapps/compatdata" 2>&1)"
direct -- fex 999
[ "$RC" = 0 ] && ok "a game that is not installed: nothing, exit 0" || bad "rc=$RC err=$ERR"
rm -rf "$MB" "$S/steamapps/appmanifest_3405340.acf" "$GAMES"

CASE="fex: a Proton game's FEX TSO when the client starts it"
US="$S/steamapps/compatdata/1145360/user_settings.py"; mkdir -p "$S/steamapps/compatdata/1145360/pfx"
usv() { python3 -c 'import runpy, sys; print(runpy.run_path(sys.argv[1])["user_settings"]["STEAM_FEX_TSOENABLED"])' "$1" 2>&1; }
direct -- fex 1145360
[ "$RC" = 0 ] && [ "$(usv "$US")" = 0 ] && grep -q "app 1145360: FEX TSO off when Steam starts it" <<<"$ERR" \
  && ok "Valve's hint (Hades: off) in the per-game user_settings.py our Proton reads" || bad "rc=$RC $(cat "$US" 2>&1) err=$ERR"
direct -- fex 1145360
[ -z "$ERR" ] && ok "again: nothing to change, nothing said" || bad "err=$ERR"
direct -- game 1145360 set tso on; direct -- fex 1145360
[ "$(usv "$US")" = 1 ] && ok "the player's choice over Valve's" || bad "$(cat "$US")"
direct -- game 1145360 set tso default
printf 'user_settings = {"PROTON_LOG": "1"}\n' >"$US"; direct -- fex 1145360
[ "$(cat "$US")" = 'user_settings = {"PROTON_LOG": "1"}' ] && ok "a user_settings.py of the player's own is left as it is" || bad "$(cat "$US")"
acf "$S" 4000 Other 4; mkdir -p "$S/steamapps/compatdata/4000/pfx"; O4="$S/steamapps/compatdata/4000/user_settings.py"
direct -- fex 4000
[ ! -e "$O4" ] && ok "no hint, no choice: no file (Proton's own default, on)" || bad "$(cat "$O4")"
direct -- game 4000 set tso off; direct -- fex 4000
[ "$(usv "$O4")" = 0 ] || bad "$(cat "$O4" 2>&1)"
direct -- game 4000 set tso default; direct -- fex 4000
[ ! -e "$O4" ] && grep -q "app 4000: FEX TSO as Proton has it when Steam starts it" <<<"$ERR" \
  && ok "back to default with no hint: our file goes" || bad "$(ls "$S/steamapps/compatdata/4000") err=$ERR"
rm -rf "$S/steamapps/compatdata/1145360" "$S/steamapps/compatdata/4000" "$S/steamapps/appmanifest_4000.acf" "$GAMES"

CASE="graphics API"
LF="$H/.config/protonfixes/localfixes/1145360.py"
apis() { python3 -c 'import json, sys; print(" ".join(json.loads(sys.argv[1])["apis"]))' "$OUT"; }
# A Unity player, its build's API list in Hades_Data (tests/lib-unity-data.py; 2 Direct3D 11, 21 Vulkan).
touch "$GAME/x64Vk/UnityPlayer.dll"; mkdir -p "$GAME/x64Vk/Hades_Data"
python3 "$ROOT/tests/lib-unity-data.py" "$GAME/x64Vk/Hades_Data/globalgamemanagers" 2023 2
direct -- game 1145360
[ "$RC" = 0 ] && [ -z "$(apis)" ] && ok "game: a Unity game built for Direct3D 11 alone offers none (Megabonk)" || bad "rc=$RC out=$OUT err=$ERR"
direct -- game 1145360 set api vulkan
[ "$RC" = 2 ] && [ ! -e "$LF" ] && ok "set: Vulkan refused when the build has none" || bad "rc=$RC"
python3 "$ROOT/tests/lib-unity-data.py" "$GAME/x64Vk/Hades_Data/globalgamemanagers" 2019 2 21
direct -- game 1145360
[ "$RC" = 0 ] && [ "$(apis)" = "d3d11 vulkan" ] && ok "game: one that lists Vulkan offers DirectX 11 and Vulkan" || bad "rc=$RC out=$OUT err=$ERR"
direct -- game 1145360 set api d3d12
[ "$RC" = 2 ] && [ ! -e "$LF" ] && ok "set: DirectX 12 refused without the game's D3D12 folder" || bad "rc=$RC"
direct -- game 1145360 set api vulkan
[ "$RC" = 0 ] && head -n1 "$LF" | grep -q "^# Written by retroforge-steam-direct: this game's graphics API" && grep -qF "ARGS = ['-force-vulkan']" "$LF" \
  && ok "set: saved, and the game's protonfixes local fix carries the flag for launches through the client" || bad "rc=$RC $(cat "$LF" 2>&1)"
fresh_log; reset_run
direct -- run 1145360
[ "$(tail -n1 "$T/ran.args")" = -force-vulkan ] && grep -q "renders with vulkan (-force-vulkan)" <<<"$ERR" \
  && ok "run: without the client, the flag after Steam's own arguments" || bad "args=$(tail -3 "$T/ran.args" | tr '\n' '|') err=$ERR"
PF="$T/pf/protonfixes"; mkdir -p "$PF/gamefixes-steam"; : >"$PF/__init__.py"; : >"$PF/gamefixes-steam/__init__.py"
printf 'import sys\ndef main():\n    sys.argv.append("-own")\n' >"$PF/gamefixes-steam/1145360.py"
fixed="$(python3 -c 'import runpy, sys; lf, pf = sys.argv[1], sys.argv[2]; sys.path.insert(0, pf); sys.argv = ["proton", "waitforexitandrun", "Hades.exe"]; g = runpy.run_path(lf); g["main_with_id"]("1145360"); g["main_with_id"]("1145360"); print(" ".join(sys.argv[2:]))' "$LF" "$T/pf" 2>&1)"
[ "$fixed" = "Hades.exe -own -force-vulkan -own" ] && ok "the local fix runs umu-protonfixes' own fix for the game first, and adds the flag once" || bad "argv: $fixed"
rm -f "$LF"; printf '# mine\n' >"$LF"
direct -- game 1145360 set api default
[ "$(cat "$LF")" = "# mine" ] && ok "a local fix of the player's own is left as it is" || bad "$(cat "$LF")"
rm -f "$LF"; direct -- game 1145360 set api vulkan; direct -- game 1145360 set api default
[ ! -e "$LF" ] && python3 -c 'import json, sys; assert json.load(open(sys.argv[1])) == {}' "$GAMES" \
  && ok "back to default: our local fix goes, nothing kept" || bad "$(ls "$(dirname "$LF")") $(cat "$GAMES")"
rm -f "$GAME/x64Vk/UnityPlayer.dll"; rm -rf "$GAME/x64Vk/Hades_Data" "$T/pf" "$H/.config/protonfixes" "$GAMES"

CASE="run: Steam's game resolution"
mkdir -p "$S/config" "$S/userdata/12345/config"
printf '"users"\n{\n\t"76561197960278073"\n\t{\n\t\t"AccountName"\t\t"x"\n\t\t"MostRecent"\t\t"1"\n\t}\n}\n' >"$S/config/loginusers.vdf"
printf '"UserLocalConfigStore"\n{\n\t"Software"\n\t{\n\t\t"Valve"\n\t\t{\n\t\t\t"Steam"\n\t\t\t{\n\t\t\t\t"apps"\n\t\t\t\t{\n\t\t\t\t\t"1145360"\n\t\t\t\t\t{\n\t\t\t\t\t\t"LastPlayed"\t\t"1792663724"\n\t\t\t\t\t\t"ResolutionOverride2"\t\t"800x450"\n\t\t\t\t\t}\n\t\t\t\t}\n\t\t\t}\n\t\t}\n\t}\n}\n' \
  >"$S/userdata/12345/config/localconfig.vdf"
X="$T/xwayland.json"; echo '{"display": ":1", "id": 1, "width": 1280, "height": 720}' >"$X"
printf '#!/bin/sh\nprintf "%%s\\n" "$@" >"%s"\n' "$T/detached" >"$T/detach"; chmod +x "$T/detach"
size() { python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); print("%dx%d" % (d["width"], d["height"]))' "$X"; }
XENV=(DISPLAY=:1 RETROFORGE_STEAM_XWAYLAND="$X" RETROFORGE_STEAM_DETACH="$T/detach")
fresh_log; reset_run; rm -f "$T/detached"
direct "${XENV[@]}" -- run 1145360
[ "$RC" = 0 ] && [ -f "$T/ran.args" ] && [ "$(size)" = 800x450 ] && grep -q "runs at 800x450, its resolution in Steam (the X server had 1280x720)" <<<"$ERR" \
  && ok "the game's X server gets the resolution Steam runs it at" || bad "rc=$RC size=$(size) err=$ERR"
tail -5 "$T/detached" 2>/dev/null | python3 -c 'import sys; w = sys.stdin.read().split("\n")[:5]; sys.exit(0 if w[0] == "restore-resolution" and w[1].isdigit() and w[2:] == [":1", "1280x720", "800x450"] else 1)' \
  && ok "and a watcher to give its old size back when the launch ends" || bad "detached: $(cat "$T/detached" 2>&1)"
direct "${XENV[@]}" -- restore-resolution 999999 :1 1280x720 800x450
[ "$RC" = 0 ] && [ "$(size)" = 1280x720 ] && ok "restore-resolution: the old size, once the launch has ended" || bad "rc=$RC size=$(size) err=$ERR"
echo '{"display": ":1", "id": 1, "width": 1920, "height": 1080}' >"$X"
direct "${XENV[@]}" -- restore-resolution 999999 :1 1280x720 800x450
[ "$(size)" = 1920x1080 ] && ok "restore-resolution: not over a size something else has set since" || bad "size=$(size)"
echo '{"display": ":1", "id": 1, "width": 1280, "height": 720}' >"$X"
direct "${XENV[@]}" -- game 1145360
python3 -c 'import json, sys; d = json.loads(sys.argv[1]); assert d["steam_resolution"] == "800x450", d' "$OUT" \
  && ok "game: Steam's resolution for it, for the Default row's label" || bad "out=$OUT err=$ERR"
direct "${XENV[@]}" -- game 1145360 set resolution 1000x1
[ "$RC" = 2 ] && ok "set: a size that is not one is refused" || bad "rc=$RC"
direct "${XENV[@]}" -- game 1145360 set resolution 960x540; fresh_log; reset_run; rm -f "$T/detached"
direct "${XENV[@]}" -- run 1145360
[ "$RC" = 0 ] && [ "$(size)" = 960x540 ] && grep -q "runs at 960x540" <<<"$ERR" && ok "the size chosen in Game settings, over Steam's" || bad "rc=$RC size=$(size) err=$ERR"
echo '{"display": ":1", "id": 1, "width": 1280, "height": 720}' >"$X"
direct "${XENV[@]}" -- game 1145360 set resolution 1280x720; fresh_log; reset_run; rm -f "$T/detached"
direct "${XENV[@]}" -- run 1145360
[ "$RC" = 0 ] && [ "$(size)" = 1280x720 ] && [ ! -e "$T/detached" ] && ok "the board's own size chosen: Steam's 800x450 is not used" || bad "rc=$RC size=$(size)"
direct "${XENV[@]}" -- game 1145360 set resolution default
echo '{"display": ":1", "id": 1, "width": 800, "height": 450}' >"$X"; fresh_log; reset_run; rm -f "$T/detached"
direct "${XENV[@]}" -- run 1145360
[ "$RC" = 0 ] && [ ! -e "$T/detached" ] && ok "a server at that size already: nothing to do" || bad "rc=$RC $(cat "$T/detached" 2>&1)"
echo '{"display": ":0", "id": 0, "width": 1280, "height": 720}' >"$X"; fresh_log; reset_run
direct "${XENV[@]}" -- run 1145360
[ "$RC" = 0 ] && [ -f "$T/ran.args" ] && grep -q "runs at the X server's size, not 800x450: :1 is not gamescope's" <<<"$ERR" \
  && ok "not a gamescope X server: the game still starts, and that is said" || bad "rc=$RC err=$ERR"
rm -rf "$S/userdata" "$S/config/loginusers.vdf"; echo '{"display": ":1", "id": 1, "width": 1280, "height": 720}' >"$X"
fresh_log; reset_run; rm -f "$T/detached"
direct "${XENV[@]}" -- run 1145360
[ "$RC" = 0 ] && [ "$(size)" = 1280x720 ] && [ ! -e "$T/detached" ] && ok "Steam's Default: the X server's size stays" || bad "rc=$RC size=$(size)"

CASE="run: Steam's quoting"
reset_run; fresh_log
printf '[2026-10-22 13:00:00] Game process added : AppID 1145360 "%s -title \"Two Words\" --name=caf\xe9", ProcID 1, IP 0.0.0.0:0\n' "$HADES_CMD" >>"$SLOG"
direct -- run 1145360
[ "$(tail -3 "$T/ran.args")" = "$(printf -- '-title\nTwo Words\n--name=caf\xe9')" ] \
  && ok "double quotes inside the logged command, and a byte that is not UTF-8, reach the game unchanged" || bad "args: $(tail -3 "$T/ran.args" 2>&1 | od -c | head -5)"
fresh_log

CASE="run: working folder"
reset_run; logline "$SLOG" "2026-10-22 11:10:00" 1145360 "$(cmdline 1145360 "$SLR" "$PROTON" "$GAME/Odd/x64Vk/Hades.exe")"
mkdir -p "$GAME/Odd/x64Vk"; touch "$GAME/Odd/x64Vk/Hades.exe"
direct -- run 1145360
[ "$(cat "$T/ran.cwd")" = "$GAME/x64" ] && ok "a launch entry's working folder is used even when it is not the executable's" || bad "cwd: $(cat "$T/ran.cwd")"
reset_run; mkdir -p "$GAME/Other"; touch "$GAME/Other/Game.exe"
logline "$SLOG" "2026-10-22 11:20:00" 1145360 "$(cmdline 1145360 "$SLR" "$PROTON" "$GAME/Other/Game.exe")"
direct -- run 1145360
[ "$(cat "$T/ran.cwd")" = "$GAME/Other" ] && ok "with no launch entry for the executable, its own folder" || bad "cwd: $(cat "$T/ran.cwd")"
rm -rf "$S/appcache/appinfo"; reset_run; fresh_log
direct -- run 1145360
[ "$RC" = 0 ] && [ "$(cat "$T/ran.cwd")" = "$GAME/x64Vk" ] && [ -z "$(ran_env STEAM_COMPAT_CONFIG)" ] \
  && ok "without the app cache the game still starts, from its executable's folder" || bad "rc=$RC cwd=$(cat "$T/ran.cwd" 2>&1) err=$ERR"
mkappinfo

CASE="run: SD card"
mkdir -p "$SD/steamapps/common"; mv "$GAME" "$SD/steamapps/common/Hades"; mv "$S/steamapps/appmanifest_1145360.acf" "$SD/steamapps/"
printf '"libraryfolders"\n{\n\t"0"\n\t{\n\t\t"path"\t\t"%s"\n\t}\n\t"1"\n\t{\n\t\t"path"\t\t"%s"\n\t}\n}\n' "$S" "$SD" >"$S/steamapps/libraryfolders.vdf"
: >"$SLOG"; rm -rf "$CACHE"; reset_run
logline "$SLOG" "2026-10-22 12:00:00" 1145360 "$(cmdline 1145360 "$SLR" "$PROTON" "$SD/steamapps/common/Hades/x64Vk/Hades.exe")"
direct -- run 1145360
[ "$RC" = 0 ] && [ "$(ran_env STEAM_COMPAT_DATA_PATH)" = "$SD/steamapps/compatdata/1145360" ] \
  && [ "$(ran_env STEAM_COMPAT_INSTALL_PATH)" = "$SD/steamapps/common/Hades" ] \
  && [ "$(ran_env STEAM_COMPAT_LIBRARY_PATHS)" = "$S/steamapps:$SD/steamapps" ] && [ "$(cat "$T/ran.cwd")" = "$SD/steamapps/common/Hades/x64Vk" ] \
  && ok "a game on an SD card: its prefix there, both libraries shared" || bad "rc=$RC err=$ERR env=$(grep STEAM_COMPAT "$T/ran.env" 2>&1)"
ln -s "$SD" "$T/sdlink"; reset_run
printf '"libraryfolders"\n{\n\t"0"\n\t{\n\t\t"path"\t\t"%s"\n\t}\n\t"1"\n\t{\n\t\t"path"\t\t"%s"\n\t}\n}\n' "$S" "$T/sdlink" >"$S/steamapps/libraryfolders.vdf"
direct -- run 1145360
[ "$RC" = 0 ] && [ "$(ran_env STEAM_COMPAT_INSTALL_PATH)" = "$T/sdlink/steamapps/common/Hades" ] \
  && [ "$(cat "$T/ran.cwd")" = "$T/sdlink/steamapps/common/Hades/x64Vk" ] \
  && ok "a library Steam names through a link, the command through the real path: the same game" || bad "rc=$RC err=$ERR cwd=$(cat "$T/ran.cwd" 2>&1)"
mv "$SD/steamapps/common/Hades" "$GAME"; mv "$SD/steamapps/appmanifest_1145360.acf" "$S/steamapps/"; rm -f "$S/steamapps/libraryfolders.vdf"

CASE="run: refused"
reset_run; fresh_log; acf "$S" 1145360 Hades 6
direct -- run 1145360
grep -q "has an update waiting" <<<"$ERR" && ok "a queued update is said when the game starts" || bad "err=$ERR"
acf "$S" 1145360 Hades 4; reset_run
direct -- run 268910
[ "$RC" = 1 ] && [ ! -e "$T/ran.args" ] && ok "a game it cannot start: exit 1, nothing run" || bad "rc=$RC"

# ================================================================================================
# The wrapper. The bootstrap is stubbed: it puts a fake client where the real one goes, which records
# that it ran. The helper is the real one, against the fake Steam above.
W="$T/w"; mkdir -p "$W/bin"
cat >"$W/client" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >"$W/client.args"; echo "dbus: \${DBUS_SESSION_BUS_ADDRESS-unset}" >>"$W/client.args"
EOF
cat >"$W/bootstrap" <<EOF
#!/usr/bin/env bash
mkdir -p "\$RETROFORGE_STEAM_ROOT/steamrtarm64"; cp "$W/client" "\$RETROFORGE_STEAM_ROOT/steamrtarm64/steam"
echo "\$RETROFORGE_STEAM_ROOT/steamrtarm64/steam"
EOF
# The kept client: keep-running is on unless $W/keep.state says off; systemd-run fails unless
# $W/sdrun-ok, and then starts the unit, which signs in (a line in Steam's connection log) unless
# $W/no-signin; systemctl reports the unit active while $W/unit-active is there.
cat >"$W/keep" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$W/keep.calls"; [ "\$1" = status ] && cat "$W/keep.state" 2>/dev/null || echo on
EOF
cat >"$W/bin/systemd-run" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$W/sdrun.calls"; [ -e "$W/sdrun-ok" ] || exit 1
touch "$W/unit-active"
[ -e "$W/no-signin" ] || echo "[2026-10-25 01:35:03] [Logged On, 4, 7] [U:1:1] RecvMsgClientLogOnResponse() : processing complete" >>"$S/logs/connection_log.txt"
EOF
cat >"$W/bin/systemctl" <<EOF
#!/usr/bin/env bash
case "\$*" in *is-active*) [ -e "$W/unit-active" ] ;; esac
EOF
chmod +x "$W/bin/systemctl"
cat >"$W/stub-direct" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$W/direct.calls"
case "\$1" in check|run) [ -n "\${STUB_ACCEPT:-}" ] && exit 0 ;; esac
exit 1
EOF
cat >"$W/guest" <<EOF
#!/usr/bin/env bash
echo "\$1" >>"$W/guest.calls"
EOF
printf '#!/usr/bin/env bash\necho "$*" >>"%s/proton.calls"\n' "$W" >"$W/proton"
chmod +x "$W/client" "$W/bootstrap" "$W/keep" "$W/bin/systemd-run" "$W/stub-direct" "$W/guest" "$W/proton"
# The real helper, as the image installs it: executable (/usr/bin/steam runs it only then).
cp "$DIRECT" "$W/direct"; chmod +x "$W/direct"
mkdir -p "$W/../lib/retroforge"; ln -sfn "$(cd "$(dirname "$DIRECT")/../lib/retroforge/python" && pwd)" "$W/../lib/retroforge/python"  # its modules, beside it as in the image
# The x86 guest is on, its helper a stub that records its calls (test-steam-x86-guest.sh has the rest).
WENV=(env -u RETROFORGE_STEAM_KEPT -u PROTON_DXVK_SAREK -u RETROFORGE_STEAM_X86_GUEST "${DENV[@]:1}" PATH="$W/bin:$PATH"
      RETROFORGE_STEAM_BOOTSTRAP="$W/bootstrap" RETROFORGE_STEAM_X86_GUEST_HELPER="$W/guest"
      RETROFORGE_STEAM_X86_GUEST_DIR="$W/fex-guest" RETROFORGE_STEAM_KEEP_CLI="$W/keep"
      RETROFORGE_STEAM_DIRECT_CLI="$W/direct" RETROFORGE_STEAM_PROTON_CLI="$W/proton")
wrap() {  # wrap [VAR=value...] -- args...
  local -a vars=()
  while [ "$1" != -- ]; do vars+=("$1"); shift; done; shift
  rm -f "$W"/*.calls "$W/client.args"; reset_run
  WOUT="$("${WENV[@]}" "${vars[@]}" bash "$WRAP" "$@" 2>"$W/err")"; WRC=$?
  WERR="$(cat "$W/err")"
}
fresh_log; rm -f "$CONF"

CASE="wrapper: a game"
wrap DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/0/bus" -- -gamepadui -steamos3 -steampal -steamdeck -silent steam://rungameid/1145360
[ "$WRC" = 0 ] && [ -f "$T/ran.args" ] && [ ! -e "$W/client.args" ] && ok "OGUI's launch of a game Steam started before: the game, and no client" \
  || bad "rc=$WRC client=$(cat "$W/client.args" 2>&1) err=$WERR"
grep -qx status "$W/keep.calls" 2>/dev/null && [ ! -e "$W/sdrun.calls" ] \
  && ok "keep-running on, but Steam has no remembered sign-in: no client beside it" || bad "keep: $(cat "$W/keep.calls" 2>&1) sdrun: $(cat "$W/sdrun.calls" 2>&1)"
[ ! -e "$W/guest.calls" ] && ok "nor the x86 guest (no FEX game starts this way)" || bad "guest: $(cat "$W/guest.calls")"
[ ! -e "$W/proton.calls" ] && ok "nor our ARMv8.0 Proton (the client's, with updates in the background)" \
  || bad "proton: $(cat "$W/proton.calls")"
[ -z "$(ran_env PROTON_DXVK_SAREK)" ] && ok "no PROTON_DXVK_SAREK from the wrapper" || bad "sarek=$(ran_env PROTON_DXVK_SAREK)"
[ -f "$T/ran.env" ] && ! grep -q "^DBUS_SESSION_BUS_ADDRESS=" "$T/ran.env" && ok "a D-Bus address that is not ours is dropped first (bwrap fails on it)" || bad "dbus: $(grep DBUS "$T/ran.env" 2>&1)"
[ "$(cat "$T/ran.cwd")" = "$GAME/x64Vk" ] && ok "as Steam started it" || bad "cwd: $(cat "$T/ran.cwd")"
reset_run; echo 7 >"$T/game.rc"
"${WENV[@]}" bash "$WRAP" -silent steam://rungameid/1145360 2>/dev/null; WRC=$?
[ "$WRC" = 7 ] && ok "the game's exit status is the launch's" || bad "rc=$WRC"

CASE="wrapper: beside the kept client"
mkdir -p "$S/config"; printf '"users"\n{\n\t"1"\n\t{\n\t\t"RememberPassword"\t\t"1"\n\t}\n}\n' >"$S/config/loginusers.vdf"
reset_beside() { rm -f "$W/unit-active" "$W/sdrun-ok" "$W/no-signin" "$W/keep.state" "$S/logs/connection_log.txt"; rm -rf "$CACHE"; }
reset_beside; touch "$W/sdrun-ok"
wrap -- -gamepadui -steamos3 -steampal -steamdeck -silent steam://rungameid/1145360
grep -q -- "--unit=retroforge-steam" "$W/sdrun.calls" 2>/dev/null && grep -q -- "--setenv=OGUI_ID=Steam" "$W/sdrun.calls" \
  && ok "Steam signed in from before: the kept client is started as the user unit" || bad "sdrun: $(cat "$W/sdrun.calls" 2>&1)"
grep -q -- "$WRAP -gamepadui -steamos3 -steampal -steamdeck -silent$" "$W/sdrun.calls" \
  && ok "with the launch's arguments but the game's URI: the client does not start the game" || bad "sdrun: $(cat "$W/sdrun.calls" 2>&1)"
grep -qx minimal "$W/keep.calls" && [ -f "$T/ran.args" ] && [ ! -e "$W/client.args" ] \
  && ok "it signs in, goes minimal, and the game starts without the client, beside it" || bad "keep: $(cat "$W/keep.calls") rc=$WRC err=$WERR"
grep -q 'Stardew/x.exe' "$CACHE/413150.json" 2>/dev/null && ok "every game's last launch is kept before that client starts" || bad "kept: $(ls "$CACHE" 2>&1)"
reset_beside; touch "$W/unit-active"
wrap -- -silent steam://rungameid/1145360
[ ! -e "$W/sdrun.calls" ] && grep -qx minimal "$W/keep.calls" && [ -f "$T/ran.args" ] \
  && ok "the kept client already runs: it is only made minimal" || bad "sdrun: $(cat "$W/sdrun.calls" 2>&1) keep: $(cat "$W/keep.calls")"
reset_beside; touch "$W/sdrun-ok" "$W/no-signin"
wrap RETROFORGE_STEAM_SIGNIN_WAIT=1 -- -silent steam://rungameid/1145360
grep -q "Steam did not sign in within 1 s: app 1145360 starts without it" <<<"$WERR" && grep -qx minimal "$W/keep.calls" && [ -f "$T/ran.args" ] \
  && ok "no sign-in within RETROFORGE_STEAM_SIGNIN_WAIT s: the game starts anyway, and it is said" || bad "rc=$WRC err=$WERR"
reset_beside; touch "$W/sdrun-ok"; echo off >"$W/keep.state"
wrap -- -silent steam://rungameid/1145360
[ ! -e "$W/sdrun.calls" ] && ! grep -qx minimal "$W/keep.calls" && [ -f "$T/ran.args" ] \
  && ok "keep-running off: the game alone, as before" || bad "sdrun: $(cat "$W/sdrun.calls" 2>&1) keep: $(cat "$W/keep.calls")"
reset_beside

CASE="wrapper: started in the background after boot"   # retroforge-session, RETROFORGE_STEAM_PRESTART=1
reset_beside; touch "$W/sdrun-ok"
wrap RETROFORGE_STEAM_PRESTART=1 -- -gamepadui -steamos3 -steampal -steamdeck -silent
[ "$WRC" = 0 ] && grep -q -- "--unit=retroforge-steam" "$W/sdrun.calls" 2>/dev/null \
  && grep -q -- "$WRAP -gamepadui -steamos3 -steampal -steamdeck -silent$" "$W/sdrun.calls" \
  && ok "Steam signed in from before: the kept client starts as the user unit, as a launch's would" || bad "rc=$WRC sdrun: $(cat "$W/sdrun.calls" 2>&1) err=$WERR"
grep -qx minimal "$W/keep.calls" && [ ! -e "$W/client.args" ] && [ ! -e "$T/ran.args" ] \
  && ok "it signs in and is left minimal; nothing runs here, no game" || bad "keep: $(cat "$W/keep.calls") client: $(cat "$W/client.args" 2>&1)"
! grep -q -- "--setenv=RETROFORGE_STEAM_PRESTART" "$W/sdrun.calls" && ok "the unit does not carry RETROFORGE_STEAM_PRESTART into Steam" \
  || bad "sdrun: $(cat "$W/sdrun.calls")"
grep -q "starting the kept Steam in the background" <<<"$WERR" && ok "and it is said" || bad "err=$WERR"
reset_beside; touch "$W/sdrun-ok" "$W/unit-active"
wrap RETROFORGE_STEAM_PRESTART=1 -- -gamepadui -steamos3 -steampal -steamdeck -silent
[ "$WRC" = 0 ] && [ ! -e "$W/sdrun.calls" ] && ! grep -qx minimal "$W/keep.calls" && [ ! -e "$W/client.args" ] \
  && ok "the kept client already runs (a game or Steam's UI opened first): left as it is" || bad "rc=$WRC sdrun: $(cat "$W/sdrun.calls" 2>&1) keep: $(cat "$W/keep.calls")"
reset_beside; touch "$W/sdrun-ok"; echo off >"$W/keep.state"
wrap RETROFORGE_STEAM_PRESTART=1 -- -gamepadui -steamos3 -steampal -steamdeck -silent
[ "$WRC" = 0 ] && [ ! -e "$W/sdrun.calls" ] && [ ! -e "$W/client.args" ] && ok "keep-running off: nothing" || bad "rc=$WRC sdrun: $(cat "$W/sdrun.calls" 2>&1)"
reset_beside; touch "$W/sdrun-ok"; rm -f "$S/config/loginusers.vdf"
wrap RETROFORGE_STEAM_PRESTART=1 -- -gamepadui -steamos3 -steampal -steamdeck -silent
[ "$WRC" = 0 ] && [ ! -e "$W/sdrun.calls" ] && [ ! -e "$W/client.args" ] && ok "no remembered sign-in: nothing" || bad "rc=$WRC sdrun: $(cat "$W/sdrun.calls" 2>&1)"
reset_beside

CASE="wrapper: through Steam"
wrap -- -gamepadui -steamos3 -steampal -steamdeck -silent steam://rungameid/268910
[ "$WRC" = 0 ] && grep -qx "steam://rungameid/268910" "$W/client.args" && [ ! -e "$T/ran.args" ] \
  && grep -q "app 268910 starts through Steam" <<<"$WERR" && ok "a game Steam never started here: the client, with the launch's arguments, and why" \
  || bad "rc=$WRC client=$(cat "$W/client.args" 2>&1) err=$WERR"
grep -q status "$W/keep.calls" 2>/dev/null && grep -qx start "$W/guest.calls" 2>/dev/null \
  && ok "and the kept-client path and the x86 guest are taken as before" || bad "keep: $(cat "$W/keep.calls" 2>&1) guest: $(cat "$W/guest.calls" 2>&1)"
grep -qx apply "$W/proton.calls" 2>/dev/null \
  && ok "and our ARMv8.0 Proton is applied before the client starts" || bad "proton: $(cat "$W/proton.calls" 2>&1)"
grep -q 'x64Vk/Hades.exe' "$CACHE/1145360.json" 2>/dev/null && grep -q 'Stardew/x.exe' "$CACHE/413150.json" 2>/dev/null \
  && ok "every game's last launch is kept before the client starts (it may rotate its log)" || bad "kept: $(ls "$CACHE" 2>&1)"
wrap RETROFORGE_STEAM_DIRECT=off -- -silent steam://rungameid/1145360
grep -qx "steam://rungameid/1145360" "$W/client.args" && [ ! -e "$T/ran.args" ] && ! grep -q retroforge-steam-direct <<<"$WERR" \
  && ok "the setting off: the client, and nothing said" || bad "client=$(cat "$W/client.args" 2>&1) err=$WERR"

CASE="wrapper: not a game"
WENV+=(RETROFORGE_STEAM_DIRECT_CLI="$W/stub-direct")
asked() { grep -q '^check' "$W/direct.calls" 2>/dev/null; }   # remember runs before every client start
wrap -- -gamepadui -steamos3 -steampal -steamdeck steam://install/1145360
! asked && grep -qx "steam://install/1145360" "$W/client.args" && grep -qx remember "$W/direct.calls" \
  && ok "an install: the client, the helper not asked (only told to keep the launches)" || bad "direct: $(cat "$W/direct.calls" 2>&1)"
wrap -- -gamepadui -steamos3 -steampal -steamdeck
! asked && [ -e "$W/client.args" ] && ok "Steam's own UI: the client" || bad "direct: $(cat "$W/direct.calls" 2>&1)"
wrap -- steam://rungameid/12345x
! asked && ok "a rungameid that is not a number: not asked" || bad "direct: $(cat "$W/direct.calls")"
wrap RETROFORGE_STEAM_KEPT=1 -- -silent steam://rungameid/1145360
! asked && grep -qx "steam://rungameid/1145360" "$W/client.args" \
  && ok "the kept client's own run (inside its unit) is the client" || bad "direct: $(cat "$W/direct.calls" 2>&1)"
wrap -- -silent steam://rungameid/1145360
[ "$(cat "$W/direct.calls")" = "$(printf 'check 1145360\nfex 1145360\nremember')" ] && grep -qx "steam://rungameid/1145360" "$W/client.args" \
  && ok "a game the helper refuses: asked once (and to set its graphics driver), then the client" || bad "direct: $(cat "$W/direct.calls" 2>&1)"
mkdir -p "$S/steamapps/compatdata/1145360/pfx"
wrap -- -silent steam://rungameid/1145360
[ "$(cat "$W/direct.calls")" = "$(printf 'check 1145360\nfex 1145360\nremember')" ] \
  && ok "a game Proton runs (a prefix in its compat data), through the client: asked (its FEX TSO for our Proton)" || bad "direct: $(cat "$W/direct.calls" 2>&1)"
wrap STUB_ACCEPT=1 -- -silent steam://rungameid/1145360
grep -qx "check 1145360" "$W/direct.calls" && ! grep -q "^fex" "$W/direct.calls" \
  && ok "the same game without the client: not asked (its launch sets TSO itself; Python's start is ~0.2 s)" || bad "direct: $(cat "$W/direct.calls" 2>&1)"
rm -rf "$S/steamapps/compatdata/1145360"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

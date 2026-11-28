#!/usr/bin/env bash
# Offline test for /usr/bin/retroforge-steam-fex: the branch of Steam's FEX tool, which runs x86 Linux
# games (Apps > Steam Client > "FEX for Linux games").
#
#   tests/test-steam-fex.sh
#
# WHY THIS EXISTS. Each rule below fails as a FEX the player did not choose, a download Steam puts off
# by hours, or a row that shows what is not installed:
#   status: nothing before Steam has installed the tool; then the branch its manifest names (public when
#     it names none), the installed tool's own FEX version, and the branches on offer (Stable, Beta,
#     Bleeding edge, each with the day Valve last built it; not the ones that name Stable's build, nor a
#     locked one); a tool put on another branch in Steam shows that one; and whether Steam is still to
#     install the branch;
#   set: only a branch on offer; through the running client's own call (SteamClient.Apps
#     .JoinAppContentBeta, "" for public as Steam's page passes it), a frozen web helper woken for it
#     and frozen again; it waits for Steam's install and prints the new status, or says Steam is still
#     at it; the branch it is on already asks nothing;
#   never: while Steam runs a game (exit 3), or with no client running (exit 4): the manifest is not
#     written, since Steam puts off a branch written there by hours (MANGMI Air X, 2026-11-28).
# The client's DevTools port is tests/lib-steam-devtools.py, whose `client` here does what the client
# does with the call: it writes the branch to the tool's manifest and installs its build.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT/rootfs/overlay/usr/bin/retroforge-steam-fex"
LIBRARY="$ROOT/rootfs/overlay/usr/lib/retroforge/steam-library"
DEVLIB="$ROOT/rootfs/overlay/usr/lib/retroforge/steam-install-app"
for f in "$CLI" "$LIBRARY" "$DEVLIB" "$ROOT/tests/lib-steam-devtools.py"; do [ -f "$f" ] || { echo "missing: $f" >&2; exit 1; }; done

PASS=0; FAIL=0; CASE=""
ok()  { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }

T="$(mktemp -d)" && [ -d "$T" ] || { echo "mktemp -d failed" >&2; exit 1; }
SERVER=""
trap '[ -n "$SERVER" ] && kill "$SERVER" 2>/dev/null; rm -rf "$T"' EXIT

H="$T/home"; S="$H/.local/share/Steam"; ACF="$S/steamapps/appmanifest_3127680.acf"; FEX="$S/steamapps/common/FEX-Emu"
mkdir -p "$S/steamapps" "$T/proc" "$T/run" "$T/dev" "$H/.steam"

# The tool as Steam installs it: manifest <branch|-> <buildid> <StateFlags> <FEX version>
manifest() {
  mkdir -p "$FEX"; printf 'FEX describe\t%s\nFEX bash\t8f92e80d\n' "$4" >"$FEX/VERSIONS.txt"
  { printf '"AppState"\n{\n\t"appid"\t\t"3127680"\n\t"name"\t\t"FEX"\n\t"StateFlags"\t\t"%s"\n\t"installdir"\t\t"FEX-Emu"\n\t"buildid"\t\t"%s"\n' "$3" "$2"
    printf '\t"InstalledDepots"\n\t{\n\t\t"3127682"\n\t\t{\n\t\t\t"manifest"\t\t"6259845671378816321"\n\t\t}\n\t}\n\t"UserConfig"\n\t{\n'
    [ "$1" = - ] || printf '\t\t"BetaKey"\t\t"%s"\n' "$1"
    printf '\t}\n\t"MountedConfig"\n\t{\n'
    [ "$1" = - ] || printf '\t\t"BetaKey"\t\t"%s"\n' "$1"
    printf '\t}\n}\n'; } >"$ACF"
}
# The app cache: the tool's branches as the client has them (MANGMI Air X, 2026-11-28), and a locked one.
python3 - "$T/apps.json" <<'PY' && python3 "$ROOT/tests/lib-steam-appinfo.py" shards "$S" "$T/apps.json"
import json, sys
apps = {3127680: {"appinfo": {"appid": 3127680, "common": {"name": "FEX", "type": "Tool"}, "depots": {"branches": {
    "public": {"buildid": 24136555, "timeupdated": 1783642605},
    "beta": {"buildid": 26467101, "description": "Beta", "timeupdated": 1793907349},
    "bleeding-edge": {"buildid": 26982779, "description": "latest build", "timeupdated": 1795812455},
    "gamma": {"buildid": 24136555, "description": "testing", "timeupdated": 1783642605},
    "previous": {"buildid": 24136555, "description": "Archived version", "timeupdated": 1783642605},
    "internal": {"buildid": 27000000, "description": "locked", "pwdrequired": 1, "timeupdated": 1795812455}}}}}}
json.dump(apps, open(sys.argv[1], "w"))
PY

# retroforge-steam-keep: records its calls; `full` prints $T/keep.full (woke: the web helper was frozen).
printf '#!/usr/bin/env bash\necho "$*" >>"%s/keep.calls"\n[ "$1" = full ] && cat "%s/keep.full" 2>/dev/null\nexit 0\n' "$T" "$T" >"$T/keep"; chmod +x "$T/keep"

# What the client does with the page's call, by $T/dev/do: apply (the branch in the manifest, its build
# installed), slow (the branch in the manifest, its build still to install), ignore (nothing), nofn
# (SteamClient not there yet).
cat >"$T/dev/client" <<EOF
#!/usr/bin/env python3
import json, re, sys
do = open("$T/dev/do").read().strip()
m = re.search(r'JoinAppContentBeta\((\d+), ("(?:[^"\\\\\\\\]|\\\\\\\\.)*")\)', open(sys.argv[1]).read())
if do == "nofn" or not m:
    print("nofn"); sys.exit(0)
name = json.loads(m.group(2))
open("$T/dev/calls", "a").write(f"{m.group(1)} [{name}]\n")
builds = {"public": ("24136555", "FEX-2607-76-g37265b1"), "beta": ("26467101", "FEX-2611"), "bleeding-edge": ("26982779", "FEX-2611-112-gd663eb8")}
branch = name or "public"
if do in ("apply", "slow") and branch in builds:
    text = open("$ACF").read()
    text = re.sub(r'("BetaKey"\s+)"[^"]*"', lambda k: k.group(1) + '"' + branch + '"', text)
    if '"BetaKey"' not in text:
        text = text.replace('"UserConfig"\n\t{\n', '"UserConfig"\n\t{\n\t\t"BetaKey"\t\t"' + branch + '"\n')
    if do == "apply":
        text = re.sub(r'("buildid"\s+)"\d+"', lambda k: k.group(1) + '"' + builds[branch][0] + '"', text)
        text = re.sub(r'("StateFlags"\s+)"\d+"', lambda k: k.group(1) + '"4"', text)
        open("$FEX/VERSIONS.txt", "w").write("FEX describe\t" + builds[branch][1] + "\n")
    else:
        text = re.sub(r'("StateFlags"\s+)"\d+"', lambda k: k.group(1) + '"1030"', text)
    open("$ACF", "w").write(text)
print("ok")
EOF
chmod +x "$T/dev/client"; echo apply >"$T/dev/do"; : >"$T/dev/mode"
python3 "$ROOT/tests/lib-steam-devtools.py" "$T/dev" & SERVER=$!
for _ in $(seq 100); do [ -s "$T/dev/port" ] && break; sleep 0.05; done
[ -s "$T/dev/port" ] || { echo "the stand-in DevTools port did not start" >&2; exit 1; }

DENV=(env -u RETROFORGE_STEAM_ROOT -u XDG_DATA_HOME -u http_proxy -u HTTP_PROXY HOME="$H" XDG_RUNTIME_DIR="$T/run"
      RETROFORGE_PROC="$T/proc" RETROFORGE_STEAM_LIBRARY="$LIBRARY" RETROFORGE_STEAM_KEEP_CLI="$T/keep"
      RETROFORGE_STEAM_DEVTOOLS_LIB="$DEVLIB" RETROFORGE_STEAM_DEVTOOLS="http://127.0.0.1:$(cat "$T/dev/port")"
      RETROFORGE_STEAM_DEVTOOLS_WAIT=1 RETROFORGE_STEAM_TOOL_WAIT=0.6 RETROFORGE_STEAM_FEX_WAIT=1)
fex() {  # fex args...: OUT, ERR, RC
  OUT="$("${DENV[@]}" python3 "$CLI" "$@" 2>"$T/err")"; RC=$?
  ERR="$(cat "$T/err")"
}
show() { python3 -c 'import json, sys; d = json.loads(sys.argv[1]); print(d.get("branch"), "|", d.get("version"), "|", "; ".join(b["name"] + "=" + b["label"] for b in d.get("branches", [])), "|", d.get("other", ""), "|", d.get("updating"))' "$OUT"; }
client() { echo 7780 >"$H/.steam/steam.pid"; mkdir -p "$T/proc/7780"; echo steam >"$T/proc/7780/comm"; }   # a client runs
no_client() { rm -rf "$T/proc/7780"; rm -f "$H/.steam/steam.pid"; }
calls() { cat "$1" 2>/dev/null | tr '\n' ';'; }
reset() { rm -f "$T/keep.calls" "$T/keep.full" "$T/dev/calls"; echo apply >"$T/dev/do"; : >"$T/dev/mode"; }
OFFER="public=Stable (10 Jul 2026); beta=Beta (5 Nov 2026); bleeding-edge=Bleeding edge (27 Nov 2026)"

# ================================================================================================
CASE="status"
fex status
[ "$RC" = 0 ] && [ "$OUT" = '{"installed": false}' ] && ok "before Steam has installed its FEX tool: not installed" || bad "rc=$RC out=$OUT err=$ERR"
manifest beta 26467101 4 FEX-2611
fex status
[ "$RC" = 0 ] && [ "$(show)" = "beta | FEX-2611 | $OFFER |  | False" ] \
  && ok "the manifest's branch, the tool's own FEX version, and Stable, Beta and Bleeding edge with the day of each build" || bad "rc=$RC $(show 2>&1) err=$ERR"
manifest - 24136555 4 FEX-2607-76-g37265b1
fex status
[ "$(show)" = "public | FEX-2607-76-g37265b1 | $OFFER |  | False" ] && ok "a manifest that names no branch is on public (Stable)" || bad "$(show 2>&1)"
manifest gamma 24136555 4 FEX-2607-76-g37265b1
fex status
[ "$(show)" = "gamma | FEX-2607-76-g37265b1 | $OFFER | testing (10 Jul 2026) | False" ] \
  && ok "a branch chosen in Steam that is not offered (gamma, which names Stable's build) is shown by Steam's name for it" || bad "$(show 2>&1)"
grep -q "internal" <<<"$OUT" && bad "a locked branch is offered: $OUT" || ok "a locked branch is not offered"
manifest beta 24136555 4 FEX-2607-76-g37265b1
fex status
[ "$(show)" = "beta | FEX-2607-76-g37265b1 | $OFFER |  | True" ] && ok "the branch's build is not the one installed: Steam is still to install it" || bad "$(show 2>&1)"
manifest beta 26467101 1030 FEX-2611
fex status
[ "$(show)" = "beta | FEX-2611 | $OFFER |  | True" ] && ok "the tool's files are changing (StateFlags): the same" || bad "$(show 2>&1)"
manifest beta 26467101 4 FEX-2611
mv "$S/appcache" "$T/appcache.away"
fex status
[ "$RC" = 0 ] && [ "$(show)" = "beta | FEX-2611 |  | beta | False" ] && ok "no app cache: the branch it is on, and none to choose" || bad "rc=$RC $(show 2>&1)"
mv "$T/appcache.away" "$S/appcache"

CASE="set"
client; reset; echo woke >"$T/keep.full"; manifest beta 26467101 4 FEX-2611
fex set bleeding-edge
[ "$RC" = 0 ] && [ "$(calls "$T/dev/calls")" = "3127680 [bleeding-edge];" ] && [ "$(show)" = "bleeding-edge | FEX-2611-112-gd663eb8 | $OFFER |  | False" ] \
  && ok "the running client joins the branch (SteamClient.Apps.JoinAppContentBeta), and the status after Steam's install is printed" \
  || bad "rc=$RC dev=$(calls "$T/dev/calls") $(show 2>&1) err=$ERR"
grep -qE '^full [0-9]+;minimal [0-9]+;$' <<<"$(calls "$T/keep.calls")" && ok "a frozen web helper is woken for it and frozen again" || bad "keep=$(calls "$T/keep.calls")"
grep -q "Steam's FEX tool is on bleeding-edge: FEX-2611-112-gd663eb8" <<<"$ERR" && ok "and it says what is installed now" || bad "err=$ERR"
reset
fex set public
[ "$RC" = 0 ] && [ "$(calls "$T/dev/calls")" = "3127680 [];" ] && [ "$(show)" = "public | FEX-2607-76-g37265b1 | $OFFER |  | False" ] \
  && ok "Stable is the call with no name, as Steam's own page makes it" || bad "rc=$RC dev=$(calls "$T/dev/calls") $(show 2>&1)"
grep -qE '^full [0-9]+;$' <<<"$(calls "$T/keep.calls")" && ok "a web helper that was awake is left awake" || bad "keep=$(calls "$T/keep.calls")"
reset
fex set public
[ "$RC" = 0 ] && [ ! -e "$T/dev/calls" ] && [ ! -e "$T/keep.calls" ] && grep -q "^public | " <<<"$(show)" && ok "the branch it is on already: nothing is asked" || bad "rc=$RC dev=$(calls "$T/dev/calls")"
reset; echo slow >"$T/dev/do"
fex set beta
[ "$RC" = 0 ] && [ "$(show)" = "beta | FEX-2607-76-g37265b1 | $OFFER |  | True" ] && grep -q "Steam is still installing it" <<<"$ERR" \
  && ok "a download that outlasts the wait: the branch is Steam's to finish, and the status says it is still at it" || bad "rc=$RC $(show 2>&1) err=$ERR"
reset
fex set beta
[ "$RC" = 0 ] && [ "$(calls "$T/dev/calls")" = "3127680 [beta];" ] && [ "$(show)" = "beta | FEX-2611 | $OFFER |  | False" ] \
  && ok "the same branch while Steam is still to install it is asked for again" || bad "rc=$RC dev=$(calls "$T/dev/calls") $(show 2>&1)"
cp "$ACF" "$T/before.acf"
for name in gamma internal nonsense ""; do
  reset; fex set "$name"
  [ "$RC" = 2 ] && [ ! -e "$T/dev/calls" ] && cmp -s "$ACF" "$T/before.acf" || bad "set '$name': rc=$RC dev=$(calls "$T/dev/calls")"
done
ok "a branch that is not on offer is refused (one that names Stable's build, a locked one)"
reset; echo ignore >"$T/dev/do"
fex set bleeding-edge
[ "$RC" = 1 ] && [ -z "$OUT" ] && cmp -s "$ACF" "$T/before.acf" && grep -q "Steam did not put its FEX tool on bleeding-edge" <<<"$ERR" \
  && ok "a client that does not take the call: the manifest is not written for it, and it says so" || bad "rc=$RC out=$OUT err=$ERR"
reset; echo nopage >"$T/dev/mode"
fex set bleeding-edge
[ "$RC" = 1 ] && cmp -s "$ACF" "$T/before.acf" && grep -q "no DevTools page" <<<"$ERR" && ok "no DevTools page from the client: the same" || bad "rc=$RC err=$ERR"
fex; [ "$RC" = 2 ] || bad "no arguments: rc=$RC"
fex set; [ "$RC" = 2 ] || bad "set without a branch: rc=$RC"
fex get beta; [ "$RC" = 2 ] && ok "anything else is a usage error" || bad "rc=$RC"

CASE="never"
reset; mkdir -p "$T/proc/8200"; echo reaper >"$T/proc/8200/comm"
printf '%s\0SteamLaunch\0AppId=3405340\0--\0x\0' "$S/steamrtarm64/reaper" >"$T/proc/8200/cmdline"
fex set bleeding-edge
[ "$RC" = 3 ] && [ ! -e "$T/dev/calls" ] && [ ! -e "$T/keep.calls" ] && cmp -s "$ACF" "$T/before.acf" && grep -q "Steam is running a game" <<<"$ERR" \
  && ok "while Steam runs a game: exit 3, and nothing is asked of the client" || bad "rc=$RC err=$ERR keep=$(calls "$T/keep.calls")"
rm -rf "$T/proc/8200"; no_client; reset
fex set bleeding-edge
[ "$RC" = 4 ] && [ ! -e "$T/dev/calls" ] && cmp -s "$ACF" "$T/before.acf" && grep -q "no Steam client runs" <<<"$ERR" \
  && ok "no client running: exit 4, and the manifest is not written (Steam would put the download off by hours)" || bad "rc=$RC err=$ERR"
fex status
[ "$RC" = 0 ] && grep -q "^beta | FEX-2611 | " <<<"$(show)" && ok "status needs no client" || bad "rc=$RC $(show 2>&1)"
rm -f "$ACF"; client; reset
fex set beta
[ "$RC" = 1 ] && grep -q "has not installed its FEX tool yet" <<<"$ERR" && ok "set before Steam has installed the tool: it says so" || bad "rc=$RC err=$ERR"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

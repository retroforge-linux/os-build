#!/usr/bin/env bash
# Offline test for /usr/bin/retroforge-steam-proton (Steam's Proton on the boards where Valve's is the
# wrong tool: ARMv8.0 CPUs, GPUs that need DXVK-Sarek) and the pin /usr/lib/retroforge/steam-compat-tools
# takes for the CPU.
#
#   tests/test-steam-proton.sh
#
# Rules: a CPU with LSE atomics whose GPU runs upstream DXVK changes nothing; on ARMv8.0 Proton-CachyOS
# ARMv8.0 is installed in the background, and once it is, it becomes entry "0" of config.vdf's
# CompatToolMapping while the client is not running, and the own entry of each installed game Steam
# would start with a Proton (a Windows-only one, and one with a Linux build that Valve maps to a Proton
# all the same, in its list of games or in the game's Deck test result: started by the client with
# Valve's Proton, Hollow Knight died on the Adreno 610) unless the game is set to another tool (a game
# set to the Valve-based ARMv8.0 builds offered before moves to it); a game Valve leaves on its Linux
# build is Steam's; the rest of config.vdf stays byte for byte; a missing section is created; the
# games' platforms and Valve's mappings come from the client's app cache, the current client's shards
# or an older client's appinfo.vdf, and one it cannot read leaves the default alone; a GPU that needs
# DXVK-Sarek on a CPU with LSE atomics gets Proton-CachyOS's arm64 build by the same rules; there is no
# channel; steam-compat-tools takes proton-cachyos-armv8.pin on ARMv8.0.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT/rootfs/overlay/usr/bin/retroforge-steam-proton"
HELPER="$ROOT/rootfs/overlay/usr/lib/retroforge/steam-compat-tools"
LIBRARY="$ROOT/rootfs/overlay/usr/lib/retroforge/steam-library"
for f in "$CLI" "$HELPER" "$LIBRARY"; do [ -f "$f" ] || { echo "missing: $f" >&2; exit 1; }; done

PASS=0; FAIL=0; CASE=""
ok()  { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }

T="$(mktemp -d)" && [ -d "$T" ] || { echo "mktemp -d failed" >&2; exit 1; }
CLIENT=""
trap '[ -n "$CLIENT" ] && kill "$CLIENT" 2>/dev/null; rm -rf "$T"' EXIT

S="$T/home/.local/share/Steam"; VDF="$S/config/config.vdf"; TOOLS="$S/compatibilitytools.d"
printf 'processor\t: 0\nFeatures\t: fp asimd evtstrm aes pmull sha1 sha2 crc32 cpuid\n' >"$T/v80"
printf 'processor\t: 0\nFeatures\t: fp asimd aes pmull sha1 sha2 crc32 atomics fphp cpuid\n' >"$T/v82"
printf '#!/bin/sh\necho "$@" >>"%s/started"\n' "$T" >"$T/start"; chmod +x "$T/start"

vdf() {  # a config.vdf like the client's, with Steam's own default and one game's tool
  mkdir -p "${VDF%/*}"
  cat >"$VDF" <<'EOF'
"InstallConfigStore"
{
	"Software"
	{
		"Valve"
		{
			"Steam"
			{
				"AutoUpdateWindowEnabled"		"0"
				"CompatToolMapping"
				{
					"0"
					{
						"name"		"proton-experimental-arm64"
						"config"		""
						"priority"		"75"
					}
					"1145360"
					{
						"name"		"proton_11_arm64"
						"config"		""
						"priority"		"250"
					}
				}
			}
		}
	}
}
EOF
}
tool() { mkdir -p "$TOOLS/$1"; : >"$TOOLS/$1/.retroforge-pin"; : >"$TOOLS/$1/proton"; : >"$TOOLS/$1/compatibilitytool.vdf"; }
SAREK=off  # a GPU that runs upstream DXVK, until a case says otherwise
run() {  # run <cpuinfo> <args>: OUT, ERR, RC
  rm -f "$T/started"
  OUT="$(HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" XDG_DATA_HOME="$T/home/.local/share" XDG_RUNTIME_DIR="$T/run" \
         RETROFORGE_STEAM_ROOT="$S" RETROFORGE_CPUINFO="$1" RETROFORGE_STEAM_SAREK="$SAREK" RETROFORGE_STEAM_COMPAT_TOOLS="$T/helper" \
         RETROFORGE_STEAM_PROTON_START="$T/start" RETROFORGE_STEAM_LIBRARY="$LIBRARY" python3 "$CLI" "${@:2}" 2>"$T/err")"; RC=$?
  ERR="$(cat "$T/err")"
  for _ in $(seq 20); do [ -e "$T/started" ] && break; sleep 0.05; done
}
default_of() { python3 -c 'import re, sys; t = open(sys.argv[1]).read(); m = re.search(r"\"CompatToolMapping\"\s*\{\s*\"0\"\s*\{\s*\"name\"\s*\"([^\"]*)\"", t); print(m.group(1) if m else "")' "$VDF"; }
others() { grep -v '"name"' "$1"; }  # everything but the tool names
tool_of() {  # tool_of <key>: "name priority" of that CompatToolMapping entry, "" without one
  python3 - "$VDF" "$1" <<'PY2'
import re, sys
m = re.search(r'"CompatToolMapping"\s*\{(.*)', open(sys.argv[1]).read(), re.S)
e = m and re.search(r'"%s"\s*\{\s*"name"\s*"([^"]*)"\s*"config"\s*"[^"]*"\s*"priority"\s*"([^"]*)"' % sys.argv[2], m.group(1))
print(f"{e.group(1)} {e.group(2)}" if e else "")
PY2
}
game() {  # game <appid> <name> <type> <oslist> [<runtime>]: an installed app and its app cache entry, with the
          # runtime its Deck test result recommends (native, or a Proton), when it has one
  mkdir -p "$S/steamapps"
  printf '"AppState"\n{\n\t"appid"\t\t"%s"\n\t"name"\t\t"%s"\n\t"StateFlags"\t\t"4"\n\t"installdir"\t\t"%s"\n}\n' "$1" "$2" "$2" >"$S/steamapps/appmanifest_$1.acf"
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "${5:-}" >>"$T/apps"
}
mapped() { printf '%s\t%s\n' "$1" "$2" >>"$T/maps"; }  # mapped <appid> <tool>: Valve's own mapping of a game, in its list (app 891390)
appinfo() {  # appinfo [format]: the app cache of the games game() listed (shards, or 28: appinfo.vdf v28)
  python3 - "$T/apps" "$T/apps.json" "$T/maps" <<'PY2' && python3 "$ROOT/tests/lib-steam-appinfo.py" "${1:-shards}" "$S" "$T/apps.json"
import json, os, sys
apps = {}
for line in open(sys.argv[1]):
    appid, name, kind, oslist, runtime = line.rstrip("\n").split("\t")
    common = {"name": name, "type": kind, "oslist": oslist}
    if runtime:
        common["steam_deck_compatibility"] = {"category": 3, "configuration": {"recommended_runtime": runtime, "hdr_support": 0}}
    apps[appid] = {"appinfo": {"appid": appid, "common": common}}
if os.path.exists(sys.argv[3]):  # as the client has it: {"appid", "comment", "config", "platform", "tool"} per game
    entries = {}
    for line in open(sys.argv[3]):
        appid, tool = line.rstrip("\n").split("\t")
        entries[appid] = {"appid": int(appid), "comment": "x", "config": "none", "platform": "linux", "tool": tool}
    apps["891390"] = {"appinfo": {"appid": 891390, "common": {"name": "SteamPlay 2.0 Manifests", "type": "Config"},
                                  "extended": {"app_mappings": entries}}}
json.dump(apps, open(sys.argv[2], "w"))
PY2
}


CASE="a CPU with LSE atomics"
vdf; cp "$VDF" "$T/orig"
run "$T/v82" status; [ "$OUT" = steam ] && ok "status: steam" || bad "out=$OUT"
run "$T/v82" apply; [ "$OUT" = steam ] && [ ! -e "$T/started" ] && cmp -s "$VDF" "$T/orig" && ok "apply: nothing installed, config.vdf untouched" || bad "out=$OUT err=$ERR"

CASE="ARMv8.0, nothing installed"
run "$T/v80" status; [ "$OUT" = armv8 ] && ok "status: armv8" || bad "out=$OUT"
run "$T/v80" apply
[ "$OUT" = armv8 ] && grep -qx "$T/helper install" "$T/started" && cmp -s "$VDF" "$T/orig" && grep -q "not installed yet" <<<"$ERR" \
  && ok "the install starts; config.vdf untouched until it is in" || bad "out=$OUT started=$(cat "$T/started" 2>&1) err=$ERR"

CASE="ARMv8.0, installed"
tool proton-cachyos-armv8-retroforge
run "$T/v80" apply
[ "$(default_of)" = proton-cachyos-armv8-retroforge ] && ok "Steam's default is Proton-CachyOS ARMv8.0" || bad "default=$(default_of) err=$ERR"
[ "$(others "$VDF")" = "$(others "$T/orig")" ] && grep -q '"proton_11_arm64"' "$VDF" && ok "the rest kept, the game's own tool too" || bad "$(diff "$T/orig" "$VDF")"
cmp -s "$VDF.before-retroforge-proton" "$T/orig" && ok "the original kept as config.vdf.before-retroforge-proton" || bad "no backup"
cp "$VDF" "$T/once"; run "$T/v80" apply
cmp -s "$VDF" "$T/once" && ok "again: unchanged" || bad "$(diff "$T/once" "$VDF")"

CASE="the client running"
vdf; cp "$VDF" "$T/orig"
mkdir -p "$T/fake/steamrtarm64"; bash -c "exec -a '$S/steamrtarm64/steam' sleep 30" & CLIENT=$!; sleep 0.3
run "$T/v80" apply
cmp -s "$VDF" "$T/orig" && grep -q "client is running" <<<"$ERR" && ok "config.vdf not written while it runs" || bad "err=$ERR"
kill "$CLIENT"; wait "$CLIENT" 2>/dev/null; CLIENT=""

CASE="no CompatToolMapping yet"
printf '"InstallConfigStore"\n{\n\t"Software"\n\t{\n\t\t"Valve"\n\t\t{\n\t\t\t"Steam"\n\t\t\t{\n\t\t\t\t"AutoUpdateWindowEnabled"\t\t"0"\n\t\t\t}\n\t\t}\n\t}\n}\n' >"$VDF"
run "$T/v80" apply
[ "$(default_of)" = proton-cachyos-armv8-retroforge ] && grep -q '"AutoUpdateWindowEnabled"' "$VDF" && ok "the section is created" || bad "$(cat "$VDF")"

CASE="no config.vdf yet"
rm -f "$VDF" "$VDF.before-retroforge-proton"
run "$T/v80" apply
[ "$RC" = 0 ] && [ "$(default_of)" = proton-cachyos-armv8-retroforge ] && [ ! -e "$VDF.before-retroforge-proton" ] \
  && ok "one is written holding only the default (the client reads it at its first start); no backup of nothing" || bad "rc=$RC err=$ERR $(cat "$VDF" 2>&1)"
python3 - "$VDF" <<'PY2' && ok "it is InstallConfigStore > Software > Valve > Steam > CompatToolMapping > 0, nothing else" || bad "$(cat "$VDF")"
import re, sys
t = open(sys.argv[1]).read()
assert re.sub(r"\s+", " ", t).strip() == '"InstallConfigStore" { "Software" { "Valve" { "Steam" { "CompatToolMapping" { "0" { "name" "proton-cachyos-armv8-retroforge" "config" "" "priority" "75" } } } } } }', t
PY2

CASE="each game Steam would start with a Proton"
OURS=proton-cachyos-armv8-retroforge
vdf; rm -f "$T/apps" "$T/maps"
game 1145360 Hades game windows      # the player set proton_11_arm64 (vdf)
game 2000 "Win Game" game windows
game 3000 "Both Game" game "windows,linux" native      # Valve leaves it on its Linux build
game 3050 "Untested Both" game "windows,linux"         # and says nothing about this one
game 3100 "Mapped Game" game "windows,macos,linux" native; mapped 3100 proton-stable   # Valve's list names a Proton (Hollow Knight)
game 3200 "Deck Proton" game "windows,linux" proton-10.0-3RC                           # its Deck test result does (SuperTux)
game 3300 "List Runtime" game "windows,linux" proton-stable; mapped 3300 SteamLinuxRuntime_sniper
game 3400 "Empty Mapping" game "windows,linux" proton-experimental; mapped 3400 ""
game 3500 "Players Linux" game "windows,linux" proton-stable   # the player set its Linux build
game 4000 "Old Pick" game windows    # set to the Valve-based ARMv8.0 experimental build RetroForge offered before
game 4500 "Old Stable" game windows  # and to its stable build
game 5000 Redist tool windows
appinfo
python3 - "$VDF" <<'PY2'
import sys
p = sys.argv[1]; t = open(p).read()
entry = '\t\t\t\t\t"%s"\n\t\t\t\t\t{\n\t\t\t\t\t\t"name"\t\t"%s"\n\t\t\t\t\t\t"config"\t\t""\n\t\t\t\t\t\t"priority"\t\t"250"\n\t\t\t\t\t}\n'
t = t.replace('\t\t\t\t\t"1145360"', entry % ("4000", "proton-armv8-experimental-retroforge")
              + entry % ("4500", "proton-armv8-retroforge") + entry % ("3500", "steamlinuxruntime") + '\t\t\t\t\t"1145360"', 1)
open(p, "w").write(t)
PY2
run "$T/v80" apply
[ "$(default_of)" = proton-cachyos-armv8-retroforge ] && [ "$(tool_of 2000)" = "proton-cachyos-armv8-retroforge 250" ] && grep -q "Win Game" <<<"$ERR" \
  && ok "a Windows game gets it as its own tool" || bad "default=$(default_of) 2000=$(tool_of 2000) err=$ERR"
[ "$(tool_of 3100)" = "$OURS 250" ] && [ "$(tool_of 3200)" = "$OURS 250" ] && grep -q "Mapped Game" <<<"$ERR" && grep -q "Deck Proton" <<<"$ERR" \
  && ok "so does a game with a Linux build that Valve maps to a Proton: in its list of games, or in the game's Deck test result" \
  || bad "3100=$(tool_of 3100) 3200=$(tool_of 3200) err=$ERR"
[ -z "$(tool_of 3000)" ] && [ -z "$(tool_of 3050)" ] && [ -z "$(tool_of 5000)" ] \
  && ok "a game Valve leaves on its Linux build, one it says nothing about and a tool are left to Steam" || bad "3000=$(tool_of 3000) 3050=$(tool_of 3050) 5000=$(tool_of 5000)"
[ -z "$(tool_of 3300)" ] && [ "$(tool_of 3400)" = "$OURS 250" ] \
  && ok "Valve's list counts before the Deck test result (a Linux runtime there: Steam's), and an empty entry in it is none" || bad "3300=$(tool_of 3300) 3400=$(tool_of 3400)"
[ "$(tool_of 3500)" = "steamlinuxruntime 250" ] && ok "one the player set to its Linux build keeps that" || bad "3500=$(tool_of 3500)"
[ "$(tool_of 1145360)" = "proton_11_arm64 250" ] && ok "a game set to another tool keeps it" || bad "1145360=$(tool_of 1145360)"
[ "$(tool_of 4000)" = "proton-cachyos-armv8-retroforge 250" ] && [ "$(tool_of 4500)" = "proton-cachyos-armv8-retroforge 250" ] \
  && ok "games set to the Valve-based ARMv8.0 builds move to it" || bad "4000=$(tool_of 4000) 4500=$(tool_of 4500)"
cp "$VDF" "$T/once"; run "$T/v80" apply
cmp -s "$VDF" "$T/once" && [ -z "$ERR" ] && ok "again: unchanged and quiet" || bad "err=$ERR $(diff "$T/once" "$VDF")"
vdf; appinfo 28; run "$T/v80" apply
[ "$(tool_of 2000)" = "$OURS 250" ] && [ -z "$(tool_of 3000)" ] && [ "$(tool_of 3100)" = "$OURS 250" ] && [ "$(tool_of 3200)" = "$OURS 250" ] \
  && ok "an older client's appinfo.vdf: the same" || bad "2000=$(tool_of 2000) 3000=$(tool_of 3000) 3100=$(tool_of 3100) 3200=$(tool_of 3200) err=$ERR"

CASE="an unreadable app cache"
vdf; printf 'junk' >"$S/appcache/appinfo.vdf"
run "$T/v80" apply
[ "$RC" = 0 ] && [ "$(default_of)" = proton-cachyos-armv8-retroforge ] && [ -z "$(tool_of 2000)" ] && grep -q "could not read" <<<"$ERR" \
  && ok "appinfo.vdf: the default is still set" || bad "rc=$RC default=$(default_of) err=$ERR"
vdf; appinfo; shard="$(grep -l "Win Game" "$S"/appcache/appinfo/appinfo_*.vdf)"; head -c 60 "$shard" >"$T/cut"; mv "$T/cut" "$shard"
run "$T/v80" apply
[ "$RC" = 0 ] && [ "$(default_of)" = proton-cachyos-armv8-retroforge ] && [ -z "$(tool_of 2000)" ] \
  && grep -q "could not read.*appinfo/$(basename "$shard") is cut short" <<<"$ERR" \
  && ok "a shard cut short: the default is still set, the shard named" || bad "rc=$RC default=$(default_of) err=$ERR"
rm -rf "$S/steamapps" "$S/appcache" "$T/maps"

# A kept client that started without our build (Steam open while Steam Client's install ran) is
# restarted by /usr/bin/steam when `pending` says so; apply then runs before it starts again.
CASE="pending"
SET="$T/run/retroforge-steam-proton.set"
rm -rf "$T/run" "$S/steamapps" "$S/appcache" "$T/apps" "$TOOLS/proton-cachyos-armv8-retroforge"; mkdir -p "$T/run"
vdf   # the client's own default, Valve's
run "$T/v82" pending; [ "$RC" = 1 ] && ok "a CPU with LSE atomics: never" || bad "rc=$RC err=$ERR"
run "$T/v80" pending; [ "$RC" = 1 ] && ok "our build not installed yet: no (a restart would not set it)" || bad "rc=$RC err=$ERR"
tool proton-cachyos-armv8-retroforge; cp "$VDF" "$T/before"
run "$T/v80" pending
[ "$RC" = 0 ] && cmp -s "$VDF" "$T/before" && [ ! -e "$T/started" ] \
  && ok "installed, Steam's default not ours: a restart is due (asking writes nothing, starts nothing)" || bad "rc=$RC err=$ERR"
run "$T/v80" apply   # the restarted client's start
[ "$(default_of)" = proton-cachyos-armv8-retroforge ] && grep -qx 0 "$SET" && ok "apply sets it, and notes it for this boot" || bad "default=$(default_of) set=$(cat "$SET" 2>&1)"
run "$T/v80" pending; [ "$RC" = 1 ] && ok "then nothing is due" || bad "rc=$RC"
vdf   # the client put its own default back
run "$T/v80" pending; [ "$RC" = 1 ] && ok "a default the client dropped after it was written: no second restart this boot" || bad "rc=$RC"
game 2000 "Win Game" game windows; appinfo
run "$T/v80" pending; [ "$RC" = 0 ] && ok "a Windows game installed since: due (Valve's recommended Proton would take it)" || bad "rc=$RC err=$ERR"
run "$T/v80" apply; run "$T/v80" pending
[ "$RC" = 1 ] && [ "$(tool_of 2000)" = "proton-cachyos-armv8-retroforge 250" ] && ok "and done once apply gave it its entry" || bad "rc=$RC 2000=$(tool_of 2000)"
game 3100 "Mapped Game" game "windows,linux" native; mapped 3100 proton-stable; appinfo
run "$T/v80" pending; [ "$RC" = 0 ] && ok "a game with a Linux build that Valve maps to a Proton, installed since: due too" || bad "rc=$RC err=$ERR"
run "$T/v80" apply; run "$T/v80" pending
[ "$RC" = 1 ] && [ "$(tool_of 3100)" = "proton-cachyos-armv8-retroforge 250" ] && ok "and done with its entry" || bad "rc=$RC 3100=$(tool_of 3100)"
printf 'junk {' >"$VDF"; rm -f "$SET"
run "$T/v80" pending; [ "$RC" = 1 ] && ok "a config.vdf it cannot edit: no restart (it would not help)" || bad "rc=$RC err=$ERR"
rm -rf "$S/steamapps" "$S/appcache" "$T/apps" "$T/maps"

# The SM4450's Adreno 613, on a CPU with LSE atomics: Valve's Protons carry only upstream DXVK, which
# starts no DirectX game there, so Proton-CachyOS's own arm64 build is Steam's tool, by the same rules.
CASE="a GPU that needs DXVK-Sarek"
ARM64=proton-cachyos-arm64-retroforge; SAREK=on
rm -rf "$T/run" "$TOOLS" "$VDF.before-retroforge-proton"; mkdir -p "$T/run"
vdf; cp "$VDF" "$T/orig"
run "$T/v82" status; [ "$OUT" = arm64 ] && ok "status: arm64" || bad "out=$OUT err=$ERR"
run "$T/v82" apply
[ "$OUT" = arm64 ] && grep -qx "$T/helper install" "$T/started" && cmp -s "$VDF" "$T/orig" && grep -q "$ARM64 is not installed yet" <<<"$ERR" \
  && ok "the install starts; config.vdf untouched until the arm64 build is in" || bad "out=$OUT started=$(cat "$T/started" 2>&1) err=$ERR"
tool proton-cachyos-armv8-retroforge
run "$T/v82" apply; run "$T/v82" pending
[ "$RC" = 1 ] && cmp -s "$VDF" "$T/orig" && ok "the ARMv8.0 rebuild is not this board's build: nothing set, nothing due" || bad "rc=$RC $(diff "$T/orig" "$VDF")"
tool "$ARM64"
game 2000 "Win Game" game windows
game 3000 "Both Game" game "windows,linux" native
game 3100 "Mapped Game" game "windows,linux" native; mapped 3100 proton-stable
appinfo
run "$T/v82" pending; [ "$RC" = 0 ] && cmp -s "$VDF" "$T/orig" && ok "installed, Steam's default not ours: a restart is due here too" || bad "rc=$RC err=$ERR"
run "$T/v82" apply
[ "$(default_of)" = "$ARM64" ] && [ "$(tool_of 2000)" = "$ARM64 250" ] && [ "$(tool_of 3100)" = "$ARM64 250" ] && [ -z "$(tool_of 3000)" ] \
  && ok "Proton-CachyOS arm64 is Steam's default and the tool of each game Steam would start with a Proton" \
  || bad "default=$(default_of) 2000=$(tool_of 2000) 3100=$(tool_of 3100) 3000=$(tool_of 3000) err=$ERR"
[ "$(tool_of 1145360)" = "proton_11_arm64 250" ] && ok "a game set to another tool keeps it there too" || bad "1145360=$(tool_of 1145360)"
SAREK=off; cp "$VDF" "$T/once"
run "$T/v82" apply
[ "$OUT" = steam ] && cmp -s "$VDF" "$T/once" && [ ! -e "$T/started" ] && ok "the same CPU with a GPU that runs upstream DXVK: nothing" || bad "out=$OUT err=$ERR"
rm -rf "$S/steamapps" "$S/appcache" "$T/apps" "$T/maps" "$TOOLS/proton-cachyos-armv8-retroforge"

CASE="usage"
run "$T/v80" set stable; [ "$RC" = 2 ] && ok "set is gone: there is no channel" || bad "rc=$RC out=$OUT"
run "$T/v80"; [ "$RC" = 2 ] && ok "no verb: exit 2" || bad "rc=$RC"

CASE="steam-compat-tools: the CPU's pin"
mkdir -p "$T/pins"
for p in proton-cachyos-armv8 proton-cachyos-arm64; do
  printf 'name: %s\nreleases: http://127.0.0.1:9/none\nasset: %s-*.tar.zst\nsidecar: .sha512\ndir: %s-retroforge\ndisplay_name: x\n' "$p" "$p" "$p" >"$T/pins/$p.pin"
done
for cpu in v80:proton-cachyos-armv8 v82:proton-cachyos-arm64; do
  E="$(HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" RETROFORGE_STEAM_ROOT="$T/s2" RETROFORGE_STEAM_PINS="$T/pins" \
       RETROFORGE_CPUINFO="$T/${cpu%%:*}" RETROFORGE_STEAM_SAREK=off python3 "$HELPER" install 2>&1)"
  grep -q "no ${cpu#*:} is installed" <<<"$E" && ok "${cpu%%:*}: ${cpu#*:}.pin" || bad "${cpu%%:*}: $E"
done
mkdir -p "$T/home/.config/retroforge"; printf 'PROTON_CHANNEL=experimental\n' >"$T/home/.config/retroforge/steam.conf"
E="$(HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" RETROFORGE_STEAM_ROOT="$T/s2" RETROFORGE_STEAM_PINS="$T/pins" \
     RETROFORGE_CPUINFO="$T/v80" RETROFORGE_STEAM_SAREK=off python3 "$HELPER" install 2>&1)"
grep -q "no proton-cachyos-armv8 is installed" <<<"$E" && ok "a leftover PROTON_CHANNEL line is ignored" || bad "$E"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

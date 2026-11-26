#!/usr/bin/env bash
# Offline test for /usr/lib/retroforge/steam-library: the Steam games the RetroForge plugin lists,
# owned and installed, from the signed-in client's own files.
#
#   tests/test-steam-library.sh
#
# WHY THIS EXISTS. The library is the only place a player sees their Steam games without the OGUI
# Steam plugin's second sign-in, and every rule below fails silently as a missing game or a card that
# is not a game: package 0 (every account's Valve freebies) is not the player's; DLC, demos, tools,
# soundtracks are not games; an installed app is told from its manifest; the app cache comes as the
# current client's 256 shards or an older client's appinfo.vdf in three formats, and packageinfo.vdf
# in two; a damaged cache file must still leave the installed games. The app cache is written by
# tests/lib-steam-appinfo.py, packageinfo.vdf by a small encoder of Valve's binary KeyValues here.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOL="$ROOT/rootfs/overlay/usr/lib/retroforge/steam-library"
APPINFO="$ROOT/tests/lib-steam-appinfo.py"
[ -f "$TOOL" ] || { echo "missing: $TOOL" >&2; exit 1; }

PASS=0; FAIL=0; CASE=""
ok()  { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
STEAM="$T/Steam"; SD="$T/sdcard/SteamLibrary"; CACHE="$T/cache"

# mkcache <appinfo format: shards, 29, 28 or 27> <packageinfo version> <spec.json>: the client's
# binary caches. spec: {"apps": {appid: [type, name]}, "packages": {packageid: [appid, ...]}}
mkcache() {
  python3 - "$STEAM/appcache" "$2" "$3" "$T/apps.json" <<'PY' && python3 "$APPINFO" "$1" "$STEAM" "$T/apps.json"
import json, os, struct, sys
out, pv, spec = sys.argv[1], int(sys.argv[2]), json.load(open(sys.argv[3]))
os.makedirs(out, exist_ok=True)

def kv(tree):
    """Binary KeyValues, keys inline."""
    b = b""
    for k, v in tree.items():
        if isinstance(v, dict):
            b += b"\x00" + k.encode() + b"\0" + kv(v) + b"\x08"
        else:
            b += b"\x02" + k.encode() + b"\0" + struct.pack("<i", v)
    return b

json.dump({appid: {"appinfo": {"appid": int(appid), "common": {"name": name, "type": kind, "oslist": "windows"},
                               "extended": {"developer": "x"}}}
           for appid, (kind, name) in spec["apps"].items()}, open(sys.argv[4], "w"))

pmagic = {27: 0x06565527, 28: 0x06565528}[pv]
pbody = struct.pack("<II", pmagic, 1)
for pid, appids in sorted(spec["packages"].items(), key=lambda x: int(x[0])):
    tree = {pid: {"packageid": int(pid), "billingtype": 10, "licensetype": 1, "status": 0,
                  "appids": {str(i): a for i, a in enumerate(appids)}, "depotids": {"0": 1}}}
    pbody += struct.pack("<I", int(pid)) + b"\x33" * 20 + struct.pack("<I", 9) + (struct.pack("<Q", 0) if pv >= 28 else b"") + kv(tree) + b"\x08"
pbody += struct.pack("<I", 0xFFFFFFFF)
open(os.path.join(out, "packageinfo.vdf"), "wb").write(pbody)
PY
}
acf() {  # acf <library> <appid> <name> <StateFlags>
  mkdir -p "$1/steamapps"
  printf '"AppState"\n{\n\t"appid"\t\t"%s"\n\t"universe"\t\t"1"\n\t"name"\t\t"%s"\n\t"StateFlags"\t\t"%s"\n\t"installdir"\t\t"%s"\n\t"UserConfig"\n\t{\n\t\t"name"\t\t"not this"\n\t}\n}\n' \
    "$2" "$3" "$4" "$3" >"$1/steamapps/appmanifest_$2.acf"
}
run() {  # run [args...]: the tool against $STEAM
  OUT="$(env -u RETROFORGE_STEAM_ROOT HOME="$T/home" XDG_DATA_HOME="$T/data" XDG_CACHE_HOME="$CACHE" RETROFORGE_STEAM_ROOT="$STEAM" \
         python3 "$TOOL" "$@" 2>"$T/err")"; RC=$?
  ERR="$(cat "$T/err")"
}
field() { python3 -c 'import json,sys; d=json.loads(sys.argv[1]); exec("print(json.dumps(" + sys.argv[2] + "))")' "$OUT" "$1"; }
names() { field '[g["name"] for g in d["games"]]'; }

cat >"$T/spec.json" <<'EOF'
{"apps": {
   "440": ["game", "Team Fortress 2"], "480": ["game", "Spacewar"],
   "1145360": ["game", "Hades"], "1145350": ["game", "Hades II"], "367520": ["Game", "Hollow Knight"],
   "268910": ["game", "Cuphead"], "1117850": ["dlc", "Cuphead - The Delicious Last Course"],
   "1000": ["demo", "Some Demo"], "2000": ["music", "Hades Soundtrack"],
   "4628740": ["tool", "Proton 11.0 (ARM64)"], "3127680": ["tool", "FEX"],
   "413150": ["game", "Stardew Valley"], "9000": ["application", "Wallpaper Thing"],
   "7777": ["game", "Shared By Family"], "8888": ["demo", "Installed Demo"]},
 "packages": {"0": [440, 480, 4628740], "1001": [1145360, 2000], "1002": [367520, 268910, 1117850],
              "1003": [1000, 9000, 3127680], "1004": [413150], "1005": [1145350]}}
EOF

# ================================================================================================
CASE="no Steam"
run
[ "$RC" = 0 ] && [ "$(field 'd["games"]')" = "[]" ] && [ "$(field 'd["owned_known"]')" = false ] \
  && ok "no client: exit 0, no games, owned not known" || bad "rc=$RC out=$OUT err=$ERR"
run --bogus
[ "$RC" = 2 ] && grep -q "usage: steam-library" <<<"$ERR" && ok "an argument: exit 2" || bad "rc=$RC err=$ERR"

CASE="installed only, client never signed in"
acf "$STEAM" 1145360 Hades 4
acf "$STEAM" 4628740 "Proton 11.0 (ARM64)" 4
acf "$STEAM" 4185400 "Steam Linux Runtime 4.0 - Arm64" 4
acf "$STEAM" 3127680 FEX 4
run
[ "$RC" = 0 ] && [ "$(names)" = '["Hades"]' ] && [ "$(field 'd["owned_known"]')" = false ] \
  && ok "the installed games; Steam's tools told by name while appinfo.vdf is not there" || bad "out=$OUT err=$ERR"
[ "$(field 'd["games"][0]')" = "{\"appid\": 1145360, \"name\": \"Hades\", \"installed\": true, \"dir\": \"$STEAM/steamapps/common/Hades\"}" ] \
  && ok "each game: app id, name, installed, its folder" || bad "$(field 'd["games"][0]')"

CASE="owned (the current client: app cache shards, packageinfo v28)"
mkcache shards 28 "$T/spec.json"
mkdir -p "$STEAM/steamapps"
printf '"libraryfolders"\n{\n\t"0"\n\t{\n\t\t"path"\t\t"%s"\n\t}\n\t"1"\n\t{\n\t\t"path"\t\t"%s/"\n\t}\n}\n' "$STEAM" "$SD" >"$STEAM/steamapps/libraryfolders.vdf"
acf "$SD" 268910 Cuphead 6            # installed, an update pending
acf "$SD" 1145350 "Hades II" 1026      # still downloading
acf "$STEAM" 7777 "Shared By Family" 4 # installed, owned by family: not in the licenses
acf "$STEAM" 8888 "Installed Demo" 4
acf "$STEAM" 9000 "Wallpaper Thing" 4
run
[ "$RC" = 0 ] && [ "$(field 'd["owned_known"]')" = true ] && ok "owned known" || bad "rc=$RC out=$OUT err=$ERR"
[ "$(names)" = '["Cuphead", "Hades", "Hades II", "Hollow Knight", "Installed Demo", "Shared By Family", "Stardew Valley"]' ] \
  && ok "owned games and installed ones, sorted; no package 0, DLC, soundtrack, tool or application" || bad "names: $(names)"
[ "$(field '[g["name"] for g in d["games"] if g["installed"]]')" = '["Cuphead", "Hades", "Installed Demo", "Shared By Family"]' ] \
  && ok "installed: fully installed (update pending too), in any library folder; a download in progress is not" || bad "$OUT"
[ "$(field '[g["dir"] for g in d["games"] if g["name"] == "Cuphead"]')" = "[\"$SD/steamapps/common/Cuphead\"]" ] \
  && ok "an installed game's folder is in its own library" || bad "$OUT"
[ "$(field '[g["dir"] for g in d["games"] if g["name"] == "Stardew Valley"]')" = '[""]' ] \
  && ok "an owned game not installed has no folder" || bad "$OUT"
[ -f "$CACHE/retroforge/steam-library.json" ] && ok "the owned list is cached" || bad "no cache"

CASE="cache"
python3 - "$CACHE/retroforge/steam-library.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["owned"].append({"appid": 4242, "name": "From The Cache"}); json.dump(d, open(p, "w"))
PY
run
grep -q "From The Cache" <<<"$OUT" && ok "the cache is used while the app cache and packageinfo.vdf are unchanged" || bad "$OUT"
python3 - "$T/spec.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["apps"]["5555"] = ["game", "Bought Elsewhere"]; d["packages"]["1006"] = [5555]; json.dump(d, open(p, "w"))
PY
mkcache shards 28 "$T/spec.json"
run
grep -q "Bought Elsewhere" <<<"$OUT" && ! grep -q "From The Cache" <<<"$OUT" \
  && ok "a new license (the client rewrote its caches): read again" || bad "$OUT"
python3 - "$CACHE/retroforge/steam-library.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["owned"].append({"appid": 4242, "name": "From The Cache"}); json.dump(d, open(p, "w"))
PY
stamp() {  # stamp <seconds since the epoch> <path...>: mtime
  python3 -c 'import os, sys; [os.utime(p, (int(sys.argv[1]), int(sys.argv[1]))) for p in sys.argv[2:]]' "$@"
}
shard="$(grep -l "Stardew Valley" "$STEAM"/appcache/appinfo/appinfo_*.vdf)"
cp "$shard" "$T/shard" && stamp 2000000000 "$T/shard" && mv "$T/shard" "$shard"   # as the client writes one: aside, then renamed in
run
! grep -q "From The Cache" <<<"$OUT" && grep -q "Stardew Valley" <<<"$OUT" \
  && ok "one shard rewritten, same size: read again" || bad "$OUT"

CASE="older formats"
for v in "29 28" "28 28" "27 27" "29 27"; do
  rm -rf "$CACHE"; mkcache $v "$T/spec.json"; run
  [ "$RC" = 0 ] && [ "$(field 'len(d["games"])')" = 8 ] && grep -q '"Bought Elsewhere"' <<<"$OUT" \
    && ok "appinfo v${v% *}, packageinfo v${v#* }: the same 8 games" || bad "v$v: rc=$RC $(names) err=$ERR"
done

CASE="an older client's appinfo.vdf next to the shards"
rm -rf "$CACHE"; mkcache 29 28 "$T/spec.json"; mv "$STEAM/appcache/appinfo.vdf" "$T/old.vdf"
python3 - "$T/spec.json" "$T/spec2.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["apps"]["6666"] = ["game", "Only In Shards"]; d["packages"]["1007"] = [6666]; json.dump(d, open(sys.argv[2], "w"))
PY
mkcache shards 28 "$T/spec2.json"; mv "$T/old.vdf" "$STEAM/appcache/appinfo.vdf"
stamp 1700000000 "$STEAM/appcache/appinfo.vdf"
run
[ "$RC" = 0 ] && grep -q '"Only In Shards"' <<<"$OUT" && ok "the shards written since: read" || bad "rc=$RC $(names) err=$ERR"
stamp 1600000000 "$STEAM"/appcache/appinfo/appinfo_*.vdf
run
[ "$RC" = 0 ] && ! grep -q '"Only In Shards"' <<<"$OUT" && [ "$(field 'len(d["games"])')" = 8 ] \
  && ok "appinfo.vdf written last (a client rolled back): it is read" || bad "rc=$RC $(names) err=$ERR"
rm -rf "$STEAM/appcache/appinfo" "$CACHE"; mkdir "$STEAM/appcache/appinfo"
run
[ "$(field 'len(d["games"])')" = 8 ] && ok "an empty shard folder: appinfo.vdf" || bad "$(names) err=$ERR"

CASE="damaged caches"
rm -rf "$CACHE"; mkcache shards 28 "$T/spec.json"
shard="$(grep -l "Stardew Valley" "$STEAM"/appcache/appinfo/appinfo_*.vdf)"
head -c 200 "$shard" >"$T/cut" && mv "$T/cut" "$shard"
run
[ "$RC" = 0 ] && [ "$(field 'd["owned_known"]')" = false ] && grep -q '"Hades"' <<<"$OUT" \
  && grep -q "appinfo/$(basename "$shard") is cut short or damaged" <<<"$ERR" \
  && ok "a shard cut short: names it, lists the installed games only" || bad "rc=$RC out=$OUT err=$ERR"
printf 'XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX' >"$shard"
run
[ "$RC" = 0 ] && grep -q "unknown appinfo/$(basename "$shard") format 0x58585858" <<<"$ERR" && grep -q '"Hades"' <<<"$OUT" \
  && ok "a shard of a format it does not know: says so" || bad "rc=$RC err=$ERR"
rm -rf "$CACHE"; mkcache 29 28 "$T/spec.json"
head -c 300 "$STEAM/appcache/appinfo.vdf" >"$T/cut" && mv "$T/cut" "$STEAM/appcache/appinfo.vdf"
run
[ "$RC" = 0 ] && [ "$(field 'd["owned_known"]')" = false ] && [ "$(field '[g["name"] for g in d["games"] if not g["installed"]]')" = "[]" ] \
  && grep -q "appinfo.vdf is cut short or damaged" <<<"$ERR" \
  && ok "appinfo.vdf cut short: says so, lists the installed games only" || bad "rc=$RC out=$OUT err=$ERR"
printf 'XXXXXXXXXXXXXXXX' >"$STEAM/appcache/packageinfo.vdf"
run
[ "$RC" = 0 ] && grep -q "unknown packageinfo.vdf format" <<<"$ERR" && grep -q '"Hades"' <<<"$OUT" \
  && ok "a format it does not know: says so, the installed games still listed" || bad "rc=$RC err=$ERR"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

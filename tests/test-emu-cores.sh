#!/usr/bin/env bash
# Offline test for the libretro cores retroforge-emu installs with RetroArch (catalog "cores";
# rootfs/overlay/usr/lib/retroforge/python/emu_cores.py; plan retroarch Phase 1).
#
#   tests/test-emu-cores.sh
#
# WHY THIS EXISTS. A core is native code RetroArch dlopens for every ROM card of its system. Two
# kinds reach the player, each with its own way of proving the bytes are the right ones:
#
#   - a GitHub core (armGBA, armN64): a release zip, checked like an AppImage (the pin's digest and size on
#     GitHub, then the bytes' sha256), latest by default, --tested installs the pin;
#   - a buildbot core (Snes9x, Genesis Plus GX): libretro's rolling nightly, no
#     pin possible (latest/ keeps no history); the build is named nightly-<date>-<crc> from
#     latest/.index-extended, and the unpacked .so must have that CRC32.
#
# Either way only ONE member, <core>_libretro.so at the top of the zip, is ever written; a failed
# core changes nothing of what was installed; the previous build stays for rollback; stdout stays
# forward-only N% lines.
#
# HOW: as tests/test-emu.sh -- the shipped retroforge-emu with its seams pointed into a sandbox, curl a
# stub serving a fake GitHub and a fake buildbot. No network.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EMU="$ROOT/rootfs/overlay/usr/bin/retroforge-emu"
[ -f "$EMU" ] || { echo "no retroforge-emu: $EMU" >&2; exit 1; }

PASS=0; FAIL=0; CASE=""
ok()  { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }

W="$(mktemp -d)" && [ -d "$W" ] || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin" "$W/srv/bb" "$W/srv/gh"
BB=https://buildbot.libretro.com/nightly/linux/aarch64/latest

sha() { sha256sum "$1" | cut -d' ' -f1; }
size() { stat -c %s "$1"; }
crc() { python3 -I -c 'import sys,zlib; print("%08x" % zlib.crc32(open(sys.argv[1],"rb").read()))' "$1"; }
# mkzip <zip> <member=content>...: a zip whose members hold the given text
mkzip() {
  python3 -I - "$@" <<'EOF'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    for spec in sys.argv[2:]:
        name, _, body = spec.partition("=")
        z.writestr(name, body)
EOF
}

# --- the fake upstreams ---------------------------------------------------------------------------
printf 'retroarch appimage' > "$W/srv/ra-1.AppImage"
# armGBA-like GitHub core: release v1 and v2, each a zip with the .so and its .info
mkzip "$W/srv/gh/v1.zip" "armgba_libretro.so=armgba one" "armgba_libretro.info=info"
mkzip "$W/srv/gh/v2.zip" "armgba_libretro.so=armgba two, newer" "armgba_libretro.info=info"
# buildbot: the .so bodies of two nightlies of snes9x, one of genesis_plus_gx
printf 'snes9x night one' > "$W/srv/snes9x-1.so"
printf 'snes9x night two!' > "$W/srv/snes9x-2.so"
printf 'genesis night one' > "$W/srv/gpgx-1.so"

# nightly <n>: serve snes9x night <n> (and gpgx night 1) on the buildbot, with a matching index
nightly() {
  mkzip "$W/srv/bb/snes9x_libretro.so.zip" "snes9x_libretro.so=$(cat "$W/srv/snes9x-$1.so")"
  mkzip "$W/srv/bb/genesis_plus_gx_libretro.so.zip" "genesis_plus_gx_libretro.so=$(cat "$W/srv/gpgx-1.so")"
  cat > "$W/srv/index" <<EOF
2026-11-0$1 $(crc "$W/srv/snes9x-$1.so") snes9x_libretro.so.zip
2026-11-01 $(crc "$W/srv/gpgx-1.so") genesis_plus_gx_libretro.so.zip
2026-11-07 00000000 mgba_libretro.so.zip
EOF
}

# ghapi <tag> [digest]: GitHub's answer for the core's release <tag>
ghapi() {
  local z="$W/srv/gh/$1.zip"
  cat > "$W/srv/gh/api-$1.json" <<EOF
{"tag_name": "$1", "draft": false, "published_at": "2026-11-0${1#v}T00:00:00Z", "assets": [
  {"name": "core-$1-x86_64.zip", "size": 1, "digest": "sha256:00", "browser_download_url": "https://github.com/example/core/releases/download/$1/core-$1-x86_64.zip"},
  {"name": "core-$1-aarch64.zip", "size": $(size "$z"), "digest": "sha256:${2:-$(sha "$z")}",
   "browser_download_url": "https://github.com/example/core/releases/download/$1/core-$1-aarch64.zip"}]}
EOF
}
ghapi v1; ghapi v2
newest_core() {  # newest_core <tag>: what /releases/latest and the list say
  cp "$W/srv/gh/api-$1.json" "$W/srv/gh/rel-latest.json"
  printf '[%s]' "$(cat "$W/srv/gh/api-$1.json")" > "$W/srv/gh/rel-list.json"
}
cat > "$W/srv/api-ra-1.json" <<EOF
{"tag_name": "ra-1", "assets": [{"name": "RA-arm64.AppImage", "size": $(size "$W/srv/ra-1.AppImage"),
 "digest": "sha256:$(sha "$W/srv/ra-1.AppImage")",
 "browser_download_url": "https://github.com/example/ra/releases/download/ra-1/RA-arm64.AppImage"}]}
EOF

# catalog [cores-json]: retroarch pinned at ra-1 with the given cores (default: armgba + two buildbot)
catalog() {
  local cores=${1:-'{
    "armgba": {"github": "example/core", "tag": "v1", "tag_pattern": "^v[0-9]+$",
               "asset": "^core-v[0-9]+-aarch64\\.zip$", "sha256": "'"$(sha "$W/srv/gh/v1.zip")"'",
               "size": '"$(size "$W/srv/gh/v1.zip")"'},
    "snes9x": {"buildbot": "snes9x_libretro.so.zip"},
    "genesis_plus_gx": {"buildbot": "genesis_plus_gx_libretro.so.zip"}}'}
  cat > "$W/catalog.json" <<EOF
{"schema": 1, "emulators": {"retroarch": {
  "name": "RetroArch", "author": "libretro", "systems": ["snes"], "github": "example/ra", "tag": "ra-1",
  "asset": "^RA-arm64\\\\.AppImage\$", "sha256": "$(sha "$W/srv/ra-1.AppImage")", "size": $(size "$W/srv/ra-1.AppImage"),
  "homepage": "https://example.org/", "licence": {"name": "GPL-3.0", "url": "https://example.org/COPYING"},
  "cores": $cores}}}
EOF
}

cat > "$W/bin/curl" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$W/curl.log"
out="" url="" wout=""
while [ \$# -gt 0 ]; do
  case \$1 in
    -o|--output) out=\$2; shift 2 ;;
    -w|--write-out) wout=\$2; shift 2 ;;
    https://*|http://*) url=\$1; shift ;;
    *) shift ;;
  esac
done
api() {
  local code=200
  [ -f "\$1" ] || { code=404; set -- /dev/null; }
  cat "\$1"
  [ -n "\$wout" ] && printf '\n%s 59 0' "\$code"
  [ -n "\$wout" ] || [ "\$code" = 200 ] || exit 22
}
serve() {  # serve <file>: as a download (to -o, or stdout)
  [ -f "\$1" ] || exit 22
  if [ -n "\$out" ]; then cp "\$1" "\$out"; else cat "\$1"; fi
}
case \$url in
  https://api.github.com/repos/example/ra/releases/tags/*) api "$W/srv/api-\${url##*/}.json" ;;
  https://github.com/example/ra/releases/download/ra-1/RA-arm64.AppImage) serve "$W/srv/ra-1.AppImage" ;;
  https://api.github.com/repos/example/core/releases/tags/*) api "$W/srv/gh/api-\${url##*/}.json" ;;
  https://api.github.com/repos/example/core/releases/latest) api "$W/srv/gh/rel-latest.json" ;;
  "https://api.github.com/repos/example/core/releases?per_page=30") api "$W/srv/gh/rel-list.json" ;;
  https://github.com/example/core/releases/download/*/core-*-aarch64.zip)
    tag=\${url%/*}; tag=\${tag##*/}; serve "$W/srv/gh/\$tag.zip" ;;
  $BB/.index-extended) [ -f "$W/srv/fail-index" ] && exit 22; serve "$W/srv/index" ;;
  $BB/*.zip) [ -f "$W/srv/fail-bb" ] && exit 56; serve "$W/srv/bb/\${url##*/}" ;;
  *) exit 22 ;;
esac
EOF
chmod +x "$W/bin/curl"

D="$W/emus"; RA="$D/retroarch"
run() {  # run <args...>: sets OUT, ERR, RC
  OUT="$(HOME="$W/home" RETROFORGE_CURL="$W/bin/curl" RETROFORGE_EMU_DIR="$D" RETROFORGE_CATALOG="$W/catalog.json" \
    python3 "$EMU" "$@" 2>"$W/err")"
  RC=$?
  ERR="$(cat "$W/err")"
}
reset() {
  rm -rf "$D" "$W/home" "$W/curl.log" "$W/srv/fail-index" "$W/srv/fail-bb"
  mkdir -p "$D" "$W/home"; nightly 1; newest_core v1; catalog
}
pct_only() {
  awk 'BEGIN{last=-1} !/^[0-9]+%$/ {exit 1} {v=$0+0; if (v < last) exit 1; last=v} END{exit last != 100}' <<<"$OUT"
}
active() {  # active <core>: the build cores/<core>_libretro.so points at, or "-"
  local l="$RA/cores/$1_libretro.so"
  [ -L "$l" ] && [ -f "$l" ] && basename "$(readlink "$l")" .so || echo -
}
body() { cat "$RA/cores/$1_libretro.so" 2>/dev/null; }
leftovers() { find "$RA" -name '*.part' -o -name '.*tmp*' | grep -c . ; }

S1="nightly-2026-11-01-$(crc "$W/srv/snes9x-1.so")"
S2="nightly-2026-11-02-$(crc "$W/srv/snes9x-2.so")"
G1="nightly-2026-11-01-$(crc "$W/srv/gpgx-1.so")"

# =================================================================================================
CASE="install: RetroArch and its cores"
reset
run install retroarch
[ "$RC" = 0 ] && ok "exit 0" || bad "exit $RC: $ERR"
pct_only && ok "stdout is forward-only N% ending at 100" || bad "stdout: $(tr '\n' ' ' <<<"$OUT")"
[ "$(readlink "$RA/current")" = "ra-1.AppImage" ] && ok "the AppImage is current" || bad "current -> $(readlink "$RA/current")"
[ "$(active armgba)" = v1 ] && [ "$(body armgba)" = "armgba one" ] && ok "armgba: the GitHub core v1, its .so bytes" || bad "armgba -> $(active armgba) '$(body armgba)'"
[ "$(active snes9x)" = "$S1" ] && [ "$(body snes9x)" = "snes9x night one" ] && ok "snes9x: buildbot nightly named $S1" || bad "snes9x -> $(active snes9x)"
[ "$(active genesis_plus_gx)" = "$G1" ] && ok "genesis_plus_gx: buildbot nightly" || bad "genesis_plus_gx -> $(active genesis_plus_gx)"
[ ! -e "$RA/cores/armgba_libretro.info" ] && ! find "$RA" -name '*.info' | grep -q . && ok "only the .so is written (the zip's .info is not)" || bad "other members written"
[ "$(readlink "$RA/cores/snes9x_libretro.so")" = "../core-builds/snes9x/$S1.so" ] && ok "cores/<core>_libretro.so is a relative link into core-builds/" || bad "link $(readlink "$RA/cores/snes9x_libretro.so")"
[ "$(leftovers)" = 0 ] && ok "no .part or temp file left" || bad "leftovers: $(find "$RA" -name '*.part' -o -name '.*tmp*')"
grep -q -- "--max-filesize" <(grep "$BB/snes9x" "$W/curl.log") && ok "a buildbot download is size-capped (--max-filesize)" || bad "no size cap on the buildbot download"
grep -q -- "--proto =https" <(grep "$BB/.index-extended" "$W/curl.log") && ok "the index is fetched https-only" || bad "index fetch not https-only"

# =================================================================================================
CASE="install again: nothing new"
run install retroarch
[ "$RC" = 0 ] && pct_only && ok "exit 0, progress to 100" || bad "exit $RC, out $(tr '\n' ' ' <<<"$OUT")"
grep -c "\.zip" "$W/curl.log" | grep -qx 3 && ok "no core downloaded twice (3 zip fetches in all)" || bad "zip fetches: $(grep -c '\.zip' "$W/curl.log")"

# =================================================================================================
CASE="a new nightly and a new GitHub release"
nightly 2; newest_core v2
run install retroarch
[ "$RC" = 0 ] && ok "exit 0" || bad "exit $RC: $ERR"
[ "$(active snes9x)" = "$S2" ] && [ "$(body snes9x)" = "snes9x night two!" ] && ok "snes9x moved to $S2" || bad "snes9x -> $(active snes9x)"
[ -f "$RA/core-builds/snes9x/$S1.so" ] && ok "the previous snes9x build is kept" || bad "previous snes9x build gone"
[ "$(active armgba)" = v2 ] && ok "armgba follows the newest release (v2)" || bad "armgba -> $(active armgba)"
[ "$(active genesis_plus_gx)" = "$G1" ] && ok "genesis_plus_gx unchanged" || bad "genesis_plus_gx -> $(active genesis_plus_gx)"

CASE="list"
run list
python3 -I - "$OUT" "$S1" "$S2" <<'EOF' && ok "list shows each core: installed, previous, tested, source" || bad "list: $OUT"
import json, sys
c = json.loads(sys.argv[1])["emulators"]["retroarch"]["cores"]
assert c["snes9x"] == {"installed": sys.argv[3], "previous": sys.argv[2], "tested": None,
                       "follows_latest": True, "source": "buildbot"}, c["snes9x"]
assert c["armgba"] == {"installed": "v2", "previous": "v1", "tested": "v1",
                       "follows_latest": True, "source": "github"}, c["armgba"]
EOF

CASE="rollback one core"
run rollback retroarch --core=snes9x
[ "$RC" = 0 ] && [ "$(active snes9x)" = "$S1" ] && ok "snes9x back to $S1" || bad "exit $RC, snes9x -> $(active snes9x): $ERR"
[ "$(active armgba)" = v2 ] && [ "$(readlink "$RA/current")" = "ra-1.AppImage" ] && ok "nothing else moved" || bad "other parts moved"
run rollback retroarch --core=mgba
[ "$RC" = 2 ] && ok "a core not in the catalog: exit 2" || bad "exit $RC"
run rollback retroarch --core=../x
[ "$RC" = 2 ] && ok "a path as the core: exit 2" || bad "exit $RC"

CASE="check"
run check retroarch
python3 -I - "$OUT" "$S2" <<'EOF' && ok "check gives each core's newest build" || bad "check: $OUT"
import json, sys
e = json.loads(sys.argv[1])["emulators"]["retroarch"]
assert e["cores"]["snes9x"] == {"latest": sys.argv[2], "error": None}, e["cores"]
assert e["cores"]["armgba"] == {"latest": "v2", "error": None}, e["cores"]
EOF

# =================================================================================================
CASE="--tested"
reset; newest_core v2
run install retroarch --tested
[ "$RC" = 0 ] && ok "exit 0" || bad "exit $RC: $ERR"
[ "$(active armgba)" = v1 ] && ok "armgba: the pin (v1), not the newest (v2)" || bad "armgba -> $(active armgba)"
[ "$(active snes9x)" = "$S1" ] && ok "snes9x (no tested build): the nightly, installed because missing" || bad "snes9x -> $(active snes9x)"
nightly 2
run install retroarch --tested
[ "$(active snes9x)" = "$S1" ] && ok "a later --tested leaves an installed nightly alone" || bad "snes9x -> $(active snes9x)"

# =================================================================================================
CASE="refused: buildbot CRC mismatch"
reset
sed -i "s/^2026-11-01 [0-9a-f]* snes9x/2026-11-01 deadbeef snes9x/" "$W/srv/index"
run install retroarch
[ "$RC" = 4 ] && ok "exit 4" || bad "exit $RC: $ERR"
[ "$(active snes9x)" = - ] && [ ! -d "$RA/core-builds/snes9x" ] || [ -z "$(ls -A "$RA/core-builds/snes9x" 2>/dev/null)" ] && ok "no snes9x build written" || bad "snes9x written: $(ls "$RA/core-builds/snes9x")"
[ "$(leftovers)" = 0 ] && ok "no leftovers" || bad "leftovers"
grep -q "CRC" <<<"$ERR" && ok "stderr says why" || bad "stderr: $ERR"

CASE="refused: CRC mismatch on an update keeps the old build"
reset; run install retroarch
nightly 2; sed -i "s/^2026-11-02 [0-9a-f]* snes9x/2026-11-02 deadbeef snes9x/" "$W/srv/index"
run install retroarch
[ "$RC" = 4 ] && [ "$(active snes9x)" = "$S1" ] && ok "exit 4, snes9x still $S1" || bad "exit $RC, snes9x -> $(active snes9x)"

CASE="refused: the core is not on the buildbot"
reset
sed -i "/snes9x/d" "$W/srv/index"
run install retroarch
[ "$RC" = 3 ] && ok "exit 3 (not available upstream)" || bad "exit $RC: $ERR"

CASE="refused: index unreadable / download fails"
reset; touch "$W/srv/fail-index"
run install retroarch
[ "$RC" = 3 ] && ok "index fetch failed: exit 3" || bad "exit $RC"
reset; touch "$W/srv/fail-bb"
run install retroarch
[ "$RC" = 3 ] && [ "$(leftovers)" = 0 ] && ok "download failed: exit 3, no leftovers" || bad "exit $RC, leftovers $(leftovers)"

CASE="refused: zip without the core at its top"
reset
mkzip "$W/srv/bb/snes9x_libretro.so.zip" "sub/snes9x_libretro.so=snes9x night one"
run install retroarch
[ "$RC" = 4 ] && [ "$(active snes9x)" = - ] && ok "member only in a folder: exit 4, nothing installed" || bad "exit $RC, snes9x -> $(active snes9x)"
reset
mkzip "$W/srv/bb/snes9x_libretro.so.zip" "../snes9x_libretro.so=snes9x night one"
run install retroarch
[ "$RC" = 4 ] && ! [ -e "$RA/snes9x_libretro.so" ] && ! [ -e "$D/snes9x_libretro.so" ] && ok "'../' member: exit 4, nothing written outside" || bad "exit $RC"

CASE="refused: GitHub core digest is not the pin"
reset; ghapi v1 0000000000000000000000000000000000000000000000000000000000000000
run install retroarch --tested
[ "$RC" = 4 ] && [ "$(active armgba)" = - ] && ok "exit 4, armgba not installed" || bad "exit $RC, armgba -> $(active armgba)"
ghapi v1

CASE="refused: bad catalog cores, before any download"
for bad_cores in '{"../x": {"buildbot": "x_libretro.so.zip"}}' \
                 '{"snes9x": {"buildbot": "other_libretro.so.zip"}}' \
                 '{"snes9x": {"buildbot": "snes9x_libretro.so.zip", "url": "https://evil/"}}' \
                 '{"armgba": {"github": "example/core", "tag": "../v1", "asset": "^a$", "sha256": "00", "size": 1}}' \
                 '{"armgba": {"github": "example/core", "tag": "v1", "asset": "^a$"}}' \
                 '{"armgba": {"github": "example/core", "tag": "v1", "tag_pattern": "^v[0-9+$", "asset": "^a$"}}' \
                 '{"armgba": {"github": "../../x", "tag": "v1", "tag_pattern": "^v[0-9]+$", "asset": "^a$"}}' \
                 '[]'; do
  reset; catalog "$bad_cores"
  run install retroarch
  if [ "$RC" = 4 ] && [ ! -e "$W/curl.log" ]; then ok "refused $(tr -d ' \n' <<<"$bad_cores" | cut -c1-60)"; else bad "exit $RC for $bad_cores (curl: $(wc -l < "$W/curl.log" 2>/dev/null))"; fi
done

CASE="a killed install's .part is reused, not left to pile up"
reset
mkdir -p "$RA/core-builds/snes9x"; printf 'half a core' > "$RA/core-builds/snes9x/.snes9x.so.part"
run install retroarch
[ "$RC" = 0 ] && [ "$(leftovers)" = 0 ] && [ "$(active snes9x)" = "$S1" ] && ok "stale part gone, snes9x installed" || bad "exit $RC, leftovers $(leftovers)"

CASE="check: a pinned-only GitHub core answers offline"
reset; catalog '{"armgba": {"github": "example/core", "tag": "v1", "asset": "^core-v[0-9]+-aarch64\\.zip$",
                "sha256": "'"$(sha "$W/srv/gh/v1.zip")"'", "size": '"$(size "$W/srv/gh/v1.zip")"'}}'
run check retroarch
grep -q 'example/core' "$W/curl.log" 2>/dev/null && bad "check asked GitHub for a pinned core" || ok "no GitHub request for the pinned core"
grep -q '"armgba": {"error": null, "latest": "v1"}' <<<"$OUT" && ok "its latest is the pin (v1)" || bad "check: $OUT"

CASE="remove"
reset; run install retroarch; run remove retroarch
[ "$RC" = 0 ] && [ ! -e "$RA" ] && ok "remove deletes the AppImage and every core" || bad "exit $RC"

echo
echo "test-emu-cores: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

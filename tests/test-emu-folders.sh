#!/usr/bin/env bash
# Offline test for the pinned folders retroforge-emu installs with an emulator (catalog "folders":
# RetroArch's shader presets; rootfs/overlay/usr/lib/retroforge/python/emu_folders.py).
#
#   tests/test-emu-folders.sh
#
# WHY THIS EXISTS. A folder goes into the player's home (~/.config/retroarch/shaders/shaders_slang), next
# to what the player keeps there, and is replaced whole when its pin moves:
#
#   - only a folder retroforge-emu unpacked itself (its marker) may ever be replaced or deleted: the
#     player's own shaders_slang, and the presets saved beside it, must survive install, update, remove;
#   - the bytes are the catalog's (sha256): a bad download changes nothing on disk, and says so;
#   - an archive member outside its folder, or a symlink, is never written;
#   - 55 MB are not downloaded again on every core update;
#   - a device that had RetroArch before the folder did must be told it is missing (`list`).
#
# HOW: as tests/test-emu-cores.sh -- the shipped retroforge-emu, its seams in a sandbox, a stub curl.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EMU="$ROOT/rootfs/overlay/usr/bin/retroforge-emu"
[ -f "$EMU" ] || { echo "no retroforge-emu: $EMU" >&2; exit 1; }

PASS=0; FAIL=0; CASE=""
ok()  { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }

W="$(mktemp -d)" && [ -d "$W" ] || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin" "$W/srv"
sha() { sha256sum "$1" | cut -d' ' -f1; }
size() { stat -c %s "$1"; }

# mkzip <zip> <member=content>...: "name=@target" makes a symlink member
mkzip() {
  python3 -I - "$@" <<'EOF'
import stat, sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    for spec in sys.argv[2:]:
        name, _, body = spec.partition("=")
        info = zipfile.ZipInfo(name)
        link = body.startswith("@")
        info.external_attr = ((stat.S_IFLNK | 0o777) if link else (stat.S_IFREG | 0o644)) << 16
        z.writestr(info, body[1:] if link else body)
EOF
}
printf 'retroarch appimage' > "$W/srv/ra-1.AppImage"
mkzip "$W/srv/one.zip" "slang-1/crt/a.slangp=crt one" "slang-1/handheld/b.slangp=lcd"
mkzip "$W/srv/two.zip" "slang-2/crt/a.slangp=crt two" "slang-2/ntsc/c.slangp=ntsc"
mkzip "$W/srv/up.zip" "slang-1/../../evil=x"
mkzip "$W/srv/link.zip" "slang-1/crt/a=@/etc/passwd"
mkzip "$W/srv/tops.zip" "slang-1/a=x" "other/b=x"
cat > "$W/srv/api-ra-1.json" <<EOF
{"tag_name": "ra-1", "assets": [{"name": "RA-arm64.AppImage", "size": $(size "$W/srv/ra-1.AppImage"),
 "digest": "sha256:$(sha "$W/srv/ra-1.AppImage")",
 "browser_download_url": "https://github.com/example/ra/releases/download/ra-1/RA-arm64.AppImage"}]}
EOF

TO=".config/retroarch/shaders/shaders_slang"
folder() {  # folder <zip name> [to] [sha256] [url]
  printf '{"name": "Shader presets", "url": "%s", "sha256": "%s", "size": %s, "to": "%s"}' \
    "${4:-https://example.org/$1.zip}" "${3:-$(sha "$W/srv/$1.zip")}" "$(size "$W/srv/$1.zip")" "${2:-$TO}"
}
catalog() {  # catalog <folders json>
  cat > "$W/catalog.json" <<EOF
{"schema": 1, "emulators": {"retroarch": {
  "name": "RetroArch", "author": "libretro", "systems": ["snes"], "github": "example/ra", "tag": "ra-1",
  "asset": "^RA-arm64\\\\.AppImage\$", "sha256": "$(sha "$W/srv/ra-1.AppImage")", "size": $(size "$W/srv/ra-1.AppImage"),
  "homepage": "https://example.org/", "licence": {"name": "GPL-3.0", "url": "https://example.org/COPYING"},
  "folders": $1}}}
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
case \$url in
  https://api.github.com/repos/example/ra/releases/tags/*)
    cat "$W/srv/api-\${url##*/}.json"; [ -n "\$wout" ] && printf '\n200 59 0' ;;
  https://github.com/example/ra/*) cp "$W/srv/ra-1.AppImage" "\$out" ;;
  https://example.org/*.zip)
    [ -f "$W/srv/fail" ] && exit 56
    cp "$W/home/../emus/retroarch/.progress" "$W/progress-seen" 2>/dev/null
    cp "$W/srv/\${url##*/}" "\$out" ;;
  *) exit 22 ;;
esac
EOF
chmod +x "$W/bin/curl"

D="$W/emus"; RA="$D/retroarch"; H="$W/home"; S="$H/$TO"
run() {
  OUT="$(HOME="$H" RETROFORGE_CURL="$W/bin/curl" RETROFORGE_EMU_DIR="$D" RETROFORGE_CATALOG="$W/catalog.json" \
    python3 "$EMU" "$@" 2>"$W/err")"
  RC=$?
  ERR="$(cat "$W/err")"
}
reset() {
  rm -rf "$D" "$H" "$W/curl.log" "$W/srv/fail" "$W/progress-seen"
  mkdir -p "$D" "$H"; catalog "[$(folder one)]"
}
pct_only() {
  awk 'BEGIN{last=-1} !/^[0-9]+%$/ {exit 1} {v=$0+0; if (v < last) exit 1; last=v} END{exit last != 100}' <<<"$OUT"
}
fetches() { grep -c 'example.org' "$W/curl.log" 2>/dev/null; }
leftovers() { find "$RA" "$H" \( -name '*.part' -o -name '*.retroforge-new' -o -name '*.retroforge-old' -o -name .progress \) 2>/dev/null | tr '\n' ' '; }
field() {  # field <python expr on the retroarch entry of list's output, as e>
  python3 -I -c 'import json,sys; e=json.loads(sys.argv[1])["emulators"]["retroarch"]; print(eval(sys.argv[2]))' "$OUT" "$1"
}
APP=$(size "$W/srv/ra-1.AppImage"); ONE=$(size "$W/srv/one.zip")

# =================================================================================================
CASE="install: RetroArch and its shader presets"
reset; run list
[ "$(field 'e["size"]')" = $((APP + ONE)) ] && ok "list: the size to download counts the folder" || bad "size $(field 'e["size"]')"
run install retroarch
[ "$RC" = 0 ] && pct_only && ok "exit 0, forward-only N% ending at 100" || bad "exit $RC: $ERR $(tr '\n' ' ' <<<"$OUT")"
[ "$(readlink "$RA/current")" = ra-1.AppImage ] && ok "the AppImage is current" || bad "current -> $(readlink "$RA/current")"
[ "$(cat "$S/crt/a.slangp" 2>/dev/null)" = "crt one" ] && [ -f "$S/handheld/b.slangp" ] && [ ! -e "$S/slang-1" ] \
  && ok "unpacked into ~/$TO without the archive's top folder" || bad "tree: $(find "$H" -type f | tr '\n' ' ')"
[ -z "$(leftovers)" ] && ok "no download, staging folder or progress file left" || bad "left: $(leftovers)"
grep -q '^[0-9][0-9]*$' "$W/progress-seen" 2>/dev/null && ok "the overall percentage is in .progress while it downloads" || bad "no .progress during the download"
grep 'example.org' "$W/curl.log" | grep -q -- '--proto =https' && ok "fetched https-only" || bad "not https-only"
run list
[ "$(field 'e["folders"]["Shader presets"]["due"]')" = False ] && [ "$(field 'e["size"]')" = "$APP" ] \
  && ok "list: nothing due, the size is the AppImage's again" || bad "list: $OUT"
[ "$(field 'e["progress"]')" = "$RA/.progress" ] && ok "list: names the progress file" || bad "progress $(field 'e.get("progress")')"

CASE="a progress file a killed install left"
reset; mkdir -p "$RA"; echo 90 > "$RA/.progress"; run install retroarch
[ "$RC" = 0 ] && [ "$(cat "$W/progress-seen" 2>/dev/null)" != 90 ] && [ -z "$(leftovers)" ] && ok "never shown again" || bad "progress $(cat "$W/progress-seen")"
reset; mkdir -p "$RA"; echo 90 > "$RA/.progress"; catalog "[$(folder one)]"; touch "$W/srv/fail"
sed "s/\"sha256\": \"[0-9a-f]*\", \"size\": $APP/\"sha256\": \"$(printf '%064d' 0)\", \"size\": $APP/" -i "$W/catalog.json"
run install retroarch
[ "$RC" = 4 ] && [ ! -e "$RA/.progress" ] && ok "gone after an install that fails early too" || bad "exit $RC: $ERR"
reset; run install retroarch

CASE="install again"
run install retroarch
[ "$RC" = 0 ] && pct_only && [ "$(fetches)" = 1 ] && ok "the same pin is not downloaded again" || bad "exit $RC, $(fetches) fetches"

CASE="the pin moved"
echo mine > "$H/.config/retroarch/shaders/mine.slangp"; catalog "[$(folder two)]"; run list
[ "$(field 'e["folders"]["Shader presets"]["due"]')" = True ] && ok "list: due" || bad "list: $OUT"
run install retroarch
[ "$RC" = 0 ] && [ "$(cat "$S/crt/a.slangp")" = "crt two" ] && [ ! -e "$S/handheld" ] && ok "replaced whole: a file the new pack lacks is gone" \
  || bad "exit $RC: $ERR $(find "$S" -type f | tr '\n' ' ')"
[ "$(cat "$H/.config/retroarch/shaders/mine.slangp")" = mine ] && ok "the player's preset beside it is kept" || bad "the player's preset is gone"
[ -z "$(leftovers)" ] && ok "nothing left over" || bad "left: $(leftovers)"

CASE="remove"
run remove retroarch
[ "$RC" = 0 ] && [ ! -e "$S" ] && [ ! -e "$RA" ] && [ -f "$H/.config/retroarch/shaders/mine.slangp" ] \
  && ok "deletes our folder, keeps the player's preset beside it" || bad "exit $RC: $(find "$H" | tr '\n' ' ')"

# =================================================================================================
CASE="a folder retroforge-emu did not unpack"
reset; mkdir -p "$S"; echo own > "$S/own.slangp"; run list
[ "$(field 'e["folders"]["Shader presets"]["due"]')" = False ] && ok "list: not due" || bad "list: $OUT"
run install retroarch
[ "$RC" = 0 ] && [ "$(cat "$S/own.slangp")" = own ] && [ ! -e "$S/crt" ] && [ -z "$(fetches | grep -v '^0$')" ] && grep -q 'left alone' <<<"$ERR" \
  && ok "left alone with a note, nothing downloaded" || bad "exit $RC: $ERR $(find "$S" | tr '\n' ' ')"
run remove retroarch
[ "$RC" = 0 ] && [ -f "$S/own.slangp" ] && ok "remove leaves it too" || bad "remove deleted the player's folder"
reset; mkdir -p "$H/.config/retroarch/shaders" "$W/elsewhere"; ln -sfn "$W/elsewhere" "$S"; run install retroarch
[ "$RC" = 0 ] && [ -L "$S" ] && [ -z "$(ls -A "$W/elsewhere")" ] && ok "a symlink there is never written through" || bad "exit $RC: $(ls -A "$W/elsewhere")"
reset; run install retroarch; printf 'duckstation\n%064d\n' 0 > "$S/.retroforge-emu"; run remove retroarch
[ -d "$S" ] && ok "another emulator's marker: not ours to delete" || bad "deleted"

CASE="a truncated marker of ours"
reset; run install retroarch; printf 'retroarch\n' > "$S/.retroforge-emu"; run list
[ "$(field 'e["folders"]["Shader presets"]["due"]')" = True ] && ok "list: due" || bad "list: $OUT"
run remove retroarch
[ "$RC" = 0 ] && [ ! -e "$S" ] && ok "remove still deletes it" || bad "exit $RC: left behind"

# =================================================================================================
CASE="failures keep what was there"
reset; run install retroarch; catalog "[$(folder two "$TO" "$(printf '%064d' 0)")]"; run install retroarch
[ "$RC" = 4 ] && [ "$(cat "$S/crt/a.slangp")" = "crt one" ] && [ -z "$(leftovers)" ] \
  && ok "bytes that are not the pin's: exit 4, the old folder stays" || bad "exit $RC: $ERR $(leftovers)"
catalog "[$(folder two)]"; touch "$W/srv/fail"; run install retroarch
[ "$RC" = 3 ] && [ "$(cat "$S/crt/a.slangp")" = "crt one" ] && [ -z "$(leftovers)" ] \
  && ok "no network: exit 3, the old folder stays" || bad "exit $RC: $ERR $(leftovers)"
reset; touch "$W/srv/fail"; run install retroarch
[ "$RC" = 3 ] && [ "$(readlink "$RA/current")" = ra-1.AppImage ] && [ ! -e "$S" ] \
  && ok "first install, the folder fails: RetroArch itself is in place" || bad "exit $RC: $ERR"
rm "$W/srv/fail"; run install retroarch
[ "$RC" = 0 ] && [ -f "$S/crt/a.slangp" ] && ok "... and the next install fetches what is missing" || bad "exit $RC: $ERR"
for z in up link tops; do
  reset; catalog "[$(folder $z)]"; run install retroarch
  [ "$RC" = 4 ] && [ ! -e "$S" ] && [ ! -e "$H/evil" ] && [ -z "$(find "$W" -name evil)" ] && [ -z "$(leftovers)" ] \
    && ok "archive '$z' refused (exit 4), nothing written" || bad "$z: exit $RC: $ERR $(leftovers)"
done
reset; mkdir -p "$H/.config/retroarch/shaders/.shaders_slang.retroforge-new/x" "$H/.config/retroarch/shaders/.shaders_slang.retroforge-old/y"
run install retroarch
[ "$RC" = 0 ] && [ -f "$S/crt/a.slangp" ] && [ -z "$(leftovers)" ] && ok "a killed run's leftovers are cleared" || bad "exit $RC: $ERR $(leftovers)"

# =================================================================================================
CASE="a bad catalog entry is refused before any download"
refused() {  # refused <what> <folders json>
  reset; catalog "$2"; run install retroarch
  [ "$RC" = 4 ] && [ ! -s "$W/curl.log" ] && ok "$1" || bad "$1: exit $RC, curl: $(cat "$W/curl.log" 2>/dev/null)"
  run list; [ "$RC" = 0 ] && ok "$1: list still works" || bad "$1: list exit $RC: $ERR"
}
refused "not a list" '{}'
refused "plain http" "[$(folder one "$TO" "" "http://example.org/one.zip")]"
refused "a path outside the home" "[$(folder one ../x)]"
refused "an absolute path" "[$(folder one /etc/x)]"
refused "the emulators folder" "[$(folder one "../emus/x")]"
refused "a short sha256" "[$(folder one "$TO" abc)]"
refused "an unknown key" '[{"name": "a", "url": "https://example.org/one.zip", "sha256": "'"$(sha "$W/srv/one.zip")"'", "size": 1, "to": "x", "run": "y"}]'
refused "the same folder twice" "[$(folder one),$(folder two)]"
reset; mkdir -p "$H/emulators"; catalog "[$(folder one emulators)]"
OUT="$(HOME="$H" RETROFORGE_CURL="$W/bin/curl" RETROFORGE_EMU_DIR="$H/emulators" RETROFORGE_CATALOG="$W/catalog.json" python3 "$EMU" install retroarch 2>/dev/null)"
[ $? = 4 ] && ok "a folder that holds the emulators" || bad "a folder that holds the emulators was accepted"

echo
echo "test-emu-folders: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

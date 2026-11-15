#!/usr/bin/env bash
# Offline test for /usr/bin/retroforge-emu — the emulator manager the RetroForge plugin drives.
#
#   tests/test-emu.sh
#
# WHY THIS EXISTS. retroforge-emu puts executables from the internet into the player's home and makes
# them what every ROM card runs. Each rule below is what keeps a bad download from becoming the
# emulator, and none of it shows when the download simply works:
#
#   - the pinned release's asset must still be the one RetroForge tested: GitHub's digest and size must
#     equal the catalog's BEFORE anything is fetched (an upstream that re-uploads under the same tag
#     is refused, not installed);
#   - the downloaded bytes must hash to the catalog's sha256, or nothing changes on disk;
#   - every transfer is https only, redirects included (curl --proto/--proto-redir =https);
#   - `current` flips atomically, the previous AppImage stays (a bad update can be rolled back),
#     older ones go;
#   - stdout is a contract: install prints forward-only `N%` lines and list prints JSON, and nothing
#     else, or the plugin misreads it.
#
# HOW: the shipped rootfs/overlay/usr/bin/retroforge-emu runs with its environment seams (RETROFORGE_CURL,
# RETROFORGE_EMU_DIR, RETROFORGE_CATALOG) pointing into a sandbox; curl is a stub that serves a fake GitHub
# API answer and a fake AppImage, and logs every call. No network.
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

# --- the fake upstream ----------------------------------------------------------------------------
# An AppImage is any bytes here; its sha256 and size go into the catalog and the API answer.
mkasset() {  # mkasset <tag> <content>
  printf '%s' "$2" > "$W/srv/$1.AppImage"
}
sha() { sha256sum "$1" | cut -d' ' -f1; }
size() { stat -c %s "$1"; }

# catalog <tag> [sha] [size]: one emulator, dummy, pinned to <tag>.
catalog() {
  local f="$W/srv/$1.AppImage"
  cat > "$W/catalog.json" <<EOF
{"schema": 1, "emulators": {"dummy": {
  "name": "Dummy", "author": "A. Dummy", "systems": ["psx"], "github": "example/dummy", "tag": "$1",
  "asset": "^Dummy-arm64\\\\.AppImage\$", "sha256": "${2:-$(sha "$f")}", "size": ${3:-$(size "$f")},
  "homepage": "https://example.org/", "licence": {"name": "MIT", "url": "https://example.org/LICENSE"}}}}
EOF
}

# api <tag> [digest-sha] [size] [url]: what api.github.com/repos/example/dummy/releases/tags/<tag> says.
api() {
  local f="$W/srv/$1.AppImage"
  cat > "$W/srv/api-$1.json" <<EOF
{"tag_name": "$1", "assets": [
  {"name": "Dummy-x86_64.AppImage", "size": 1, "digest": "sha256:00", "browser_download_url": "https://github.com/example/dummy/releases/download/$1/Dummy-x86_64.AppImage"},
  {"name": "Dummy-arm64.AppImage", "size": ${3:-$(size "$f")}, "digest": "sha256:${2:-$(sha "$f")}",
   "browser_download_url": "${4:-https://github.com/example/dummy/releases/download/$1/Dummy-arm64.AppImage}"}]}
EOF
}

# The curl stub: logs its argv; an API URL gets its JSON and, with -w, "\n<HTTP status>" after it
# and GitHub's x-ratelimit-remaining / -reset (404 when the file is missing; while $W/srv/ratelimit
# exists 403 with none remaining, reset in 10 min; while $W/srv/forbidden exists 403 with some left),
# as retroforge-emu reads them from -w; a download URL gets the asset of the tag in its path (or $W/srv/override
# when it exists, to serve wrong bytes). Exit 22 on anything else.
#   releases/tags/<tag>       -> $W/srv/api-<tag>.json
#   releases/latest           -> $W/srv/rel-latest.json
#   releases?per_page=30      -> $W/srv/rel-list.json
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
api() {  # api <file>: serve it with its status, as curl without --fail does
  local code=200 left=59 reset=\$((\$(date +%s) + 600))
  if [ -f "$W/srv/ratelimit" ]; then code=403 left=0; set -- /dev/null
  elif [ -f "$W/srv/forbidden" ]; then code=403; set -- /dev/null
  elif [ ! -f "\$1" ]; then code=404; set -- /dev/null; fi
  cat "\$1"
  [ -n "\$wout" ] && printf '\n%s %s %s' "\$code" "\$left" "\$reset"
  [ -n "\$wout" ] || [ "\$code" = 200 ] || exit 22
}
case \$url in
  https://api.github.com/repos/example/dummy/releases/tags/*) api "$W/srv/api-\${url##*/}.json" ;;
  https://api.github.com/repos/example/dummy/releases/latest) api "$W/srv/rel-latest.json" ;;
  "https://api.github.com/repos/example/dummy/releases?per_page=30") api "$W/srv/rel-list.json" ;;
  https://github.com/example/dummy/releases/download/*/Dummy-arm64.AppImage)
    tag=\${url%/*}; tag=\${tag##*/}
    src="$W/srv/\$tag.AppImage"; [ -f "$W/srv/override" ] && src="$W/srv/override"
    [ -f "\$src" ] || exit 22
    [ -f "$W/srv/fail-download" ] && exit 56
    cp "\$src" "\${out:?no -o}" ;;
  https://github.com/example/dummy/releases/download/nightly/Dummy-*-arm64.AppImage)
    src="$W/srv/nightly.AppImage"; [ -f "$W/srv/override" ] && src="$W/srv/override"
    [ -f "\$src" ] || exit 22
    cp "\$src" "\${out:?no -o}" ;;
  https://data.example/db)
    [ -f "$W/srv/fail-data" ] && exit 22
    cp "$W/srv/data" "\${out:?no -o}" ;;
  *) exit 22 ;;
esac
EOF
chmod +x "$W/bin/curl"

D="$W/emus"
run() {  # run <args...>: sets OUT, ERR, RC
  OUT="$(HOME="$W/home" RETROFORGE_CURL="$W/bin/curl" RETROFORGE_EMU_DIR="$D" RETROFORGE_CATALOG="$W/catalog.json" \
    python3 "$EMU" "$@" 2>"$W/err")"
  RC=$?
  ERR="$(cat "$W/err")"
}
reset() { rm -rf "$D" "$W/home" "$W/curl.log" "$W/srv/rel-latest.json" "$W/srv/rel-list.json" "$W/srv/ratelimit" "$W/srv/forbidden" "$W/srv/override" "$W/srv/fail-download" "$W/srv/fail-data"; mkdir -p "$D" "$W/home"; }
pct_only() {  # every stdout line is N% and they never go down, ending at 100
  awk 'BEGIN{last=-1} !/^[0-9]+%$/ {exit 1} {v=$0+0; if (v < last) exit 1; last=v} END{exit last != 100}' <<<"$OUT"
}

mkasset v1 "dummy build one"
mkasset v2 "dummy build two, longer"
mkasset v3 "dummy build three"

# =================================================================================================
CASE="bad invocations"
reset; catalog v1; api v1
run;                      [ "$RC" = 2 ] && ok "no command: exit 2" || bad "no command exited $RC"
run install;              [ "$RC" = 2 ] && ok "install with no emulator: exit 2" || bad "exited $RC"
run install nosuch;       [ "$RC" = 2 ] && ok "an emulator not in the catalog: exit 2" || bad "exited $RC"
run install ../dummy;     [ "$RC" = 2 ] && ok "a path as the emulator: exit 2" || bad "exited $RC"
run frobnicate dummy;     [ "$RC" = 2 ] && ok "an unknown command: exit 2" || bad "exited $RC"
[ ! -e "$W/curl.log" ] && ok "bad invocations never touch the network" || bad "curl ran for a bad invocation"

# =================================================================================================
CASE="tags"
# pkgforge-dev's AppImage repos (Dolphin) tag releases as <version>@<date>_<id>.
mkasset "2609@2026-10-01_1" "dummy pkgforge-style build"
reset; catalog "2609@2026-10-01_1"; api "2609@2026-10-01_1"
run install dummy
[ "$RC" = 0 ] && [ "$(readlink "$D/dummy/current")" = "2609@2026-10-01_1.AppImage" ] \
  && ok "a tag with '@' installs as <tag>.AppImage" || bad "the '@' tag install exited $RC: $ERR"
reset; catalog "v1/../x" "$(sha "$W/srv/v1.AppImage")" "$(size "$W/srv/v1.AppImage")"
run install dummy
[ "$RC" = 4 ] && [ ! -e "$W/curl.log" ] && ok "a tag with '/' is refused before any download (exit 4)" \
  || bad "a '/' tag exited $RC (curl ran: $([ -e "$W/curl.log" ] && echo yes || echo no))"

# =================================================================================================
CASE="install"
reset; catalog v1; api v1
run install dummy
[ "$RC" = 0 ] && ok "exit 0" || bad "install exited $RC: $ERR"
[ "$(readlink "$D/dummy/current")" = v1.AppImage ] && ok "current -> v1.AppImage (relative link)" || bad "current is '$(readlink "$D/dummy/current")'"
cmp -s "$D/dummy/v1.AppImage" "$W/srv/v1.AppImage" && ok "the AppImage is the served bytes" || bad "installed file differs"
[ -x "$D/dummy/v1.AppImage" ] && ok "the AppImage is executable" || bad "not executable"
pct_only && ok "stdout is only forward N% lines ending at 100%" || bad "stdout was: $(tr '\n' '|' <<<"$OUT")"
[ -z "$(find "$D" -name '*.part')" ] && ok "no .part file left" || bad "a .part file was left"
grep -q 'api.github.com/repos/example/dummy/releases/tags/v1' "$W/curl.log" \
  && ok "looks the pinned tag up in the GitHub API" || bad "no API lookup of the pinned tag"
dl="$(grep 'Dummy-arm64.AppImage' "$W/curl.log")"
grep -q 'Dummy-x86_64' "$W/curl.log" && bad "fetched the asset the pattern does not match" || ok "fetches only the asset the pattern matches"
[[ $dl == *"--proto =https"* && $dl == *"--proto-redir =https"* ]] \
  && ok "the download is https only, redirects included" || bad "download curl lacks --proto/--proto-redir =https: $dl"
api_line="$(grep 'api.github.com' "$W/curl.log" | head -1)"
[[ $api_line == *"--proto =https"* ]] && ok "the API call is https only" || bad "API curl lacks --proto =https"
[[ $dl == *"--fail"* ]] && ok "curl --fail: an HTTP error is not saved as the AppImage" || bad "download curl lacks --fail"
[[ $api_line == *"--retry-all-errors"* && $dl == *"--retry-all-errors"* ]] \
  && ok "both calls retry every transient error (Wi-Fi drops: curl 55 on HW)" || bad "a curl call lacks --retry-all-errors"

CASE="install again (already current)"
rm -f "$W/curl.log"
run install dummy
[ "$RC" = 0 ] && [ "$OUT" = "100%" ] && ok "prints 100% and exits 0" || bad "rc=$RC out=$OUT"
[ ! -e "$W/curl.log" ] && ok "downloads nothing when the pinned tag is installed" || bad "re-downloaded an installed tag"

# =================================================================================================
CASE="refusals"
# Upstream re-uploaded under the same tag: the API's digest no longer matches the catalog.
reset; catalog v1; api v1 "$(sha "$W/srv/v2.AppImage")"
run install dummy
[ "$RC" = 4 ] && ok "API digest != catalog sha256: exit 4" || bad "exited $RC"
! grep -q 'Dummy-arm64.AppImage' "$W/curl.log" && ok "... and nothing is downloaded" || bad "downloaded despite the digest mismatch"
[ ! -e "$D/dummy/current" ] && ok "... and nothing is installed" || bad "installed despite the digest mismatch"
reset; catalog v1; api v1 "" 999
run install dummy
[ "$RC" = 4 ] && ok "API size != catalog size: exit 4" || bad "exited $RC"
# The served bytes are not the tested ones.
reset; catalog v1; api v1; cp "$W/srv/v3.AppImage" "$W/srv/override"
run install dummy
[ "$RC" = 4 ] && ok "downloaded bytes with the wrong sha256: exit 4" || bad "exited $RC"
[ ! -e "$D/dummy/current" ] && [ -z "$(find "$D" -type f)" ] && ok "... nothing installed, the .part is deleted" || bad "left: $(find "$D")"
# The API points the download somewhere that is not https.
reset; catalog v1; api v1 "" "" "http://github.com/example/dummy/releases/download/v1/Dummy-arm64.AppImage"
run install dummy
[ "$RC" = 4 ] && ok "an http:// download URL is refused: exit 4" || bad "exited $RC"
! grep -q 'http://' "$W/curl.log" && ok "... and never fetched" || bad "fetched an http URL"
# Network failures.
reset; catalog v1; rm -f "$W/srv/api-v1.json"
run install dummy
[ "$RC" = 3 ] && ok "the API lookup fails: exit 3" || bad "exited $RC"
reset; catalog v1; api v1; touch "$W/srv/fail-download"
run install dummy
[ "$RC" = 3 ] && ok "the download fails: exit 3" || bad "exited $RC"
[ -z "$(find "$D" -type f)" ] && ok "... and leaves no file" || bad "left: $(find "$D" -type f)"
grep -qv '^[0-9]*%$' <<<"$OUT" && bad "stdout carried an error message: $OUT" || ok "errors go to stderr, stdout stays parseable"

# =================================================================================================
CASE="update"
reset; catalog v1; api v1; run install dummy
catalog v2; api v2; run install dummy
[ "$RC" = 0 ] && [ "$(readlink "$D/dummy/current")" = v2.AppImage ] && ok "a newer pin installs and current -> v2" || bad "rc=$RC current=$(readlink "$D/dummy/current")"
[ -f "$D/dummy/v1.AppImage" ] && ok "the previous AppImage (v1) is kept for a rollback" || bad "v1 was deleted"
catalog v3; api v3; run install dummy
[ "$(readlink "$D/dummy/current")" = v3.AppImage ] && [ -f "$D/dummy/v2.AppImage" ] && [ ! -e "$D/dummy/v1.AppImage" ] \
  && ok "a third version keeps only current (v3) and previous (v2)" || bad "left: $(ls "$D/dummy" | tr '\n' ' ')"
# A failed update leaves the working install alone.
catalog v1; api v1; cp "$W/srv/v2.AppImage" "$W/srv/override"
run install dummy
[ "$RC" = 4 ] && [ "$(readlink "$D/dummy/current")" = v3.AppImage ] && ok "a failed update keeps current on the working version" || bad "rc=$RC current=$(readlink "$D/dummy/current")"

# =================================================================================================
CASE="data files"
# RPCS3 fetches its per-game config database only from its Qt game list, never with --no-gui:
# the catalog's "data" files are fetched after an install or update instead (HW 2026-10-07).
with_data() {  # with_data <json list>: add "data" to the catalog's dummy entry
  python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); c["emulators"]["dummy"]["data"]=json.loads(sys.argv[2]); json.dump(c, open(sys.argv[1], "w"))' \
    "$W/catalog.json" "$1"
}
DB='[{"url": "https://data.example/db", "to": ".config/dummy/db.dat"}]'
printf 'database one' > "$W/srv/data"
reset; catalog v1; api v1; with_data "$DB"
run install dummy
[ "$RC" = 0 ] && [ "$(cat "$W/home/.config/dummy/db.dat" 2>/dev/null)" = "database one" ] \
  && ok "an install fetches the catalog's data file into the player's home" || bad "data fetch: rc=$RC $ERR"
pct_only && ok "stdout stays N% lines only" || bad "stdout: $OUT"
grep "data.example/db" "$W/curl.log" | grep -q -- "--proto =https" && ok "data downloads are https only too" || bad "data curl args: $(grep data.example "$W/curl.log")"
[ -z "$(find "$W/home" -name '*.retroforge-part')" ] && ok "no partial file left" || bad "a .retroforge-part was left"
: > "$W/curl.log"; printf 'database two' > "$W/srv/data"
run install dummy
[ "$RC" = 0 ] && ! grep -q data.example "$W/curl.log" && [ "$(cat "$W/home/.config/dummy/db.dat")" = "database one" ] \
  && ok "not fetched again while the pin is already current" || bad "refetched on a no-op install"
catalog v2; api v2; with_data "$DB"; touch "$W/srv/fail-data"
run install dummy
[ "$RC" = 0 ] && [ "$(readlink "$D/dummy/current")" = "v2.AppImage" ] && [ "$(cat "$W/home/.config/dummy/db.dat")" = "database one" ] \
  && grep -q "could not fetch ~/.config/dummy/db.dat" <<<"$ERR" \
  && ok "a failed data fetch keeps the previous file, warns, and the update still succeeds" || bad "failed data fetch: rc=$RC $ERR"
rm -f "$W/srv/fail-data"; catalog v3; api v3; with_data "$DB"
run install dummy
[ "$RC" = 0 ] && [ "$(cat "$W/home/.config/dummy/db.dat")" = "database two" ] && ok "an update refreshes it" || bad "update did not refresh: $ERR"
reset; catalog v1; api v1
with_data '[{"url": "http://data.example/db", "to": "a"}, {"url": "https://data.example/db", "to": "../escape"}, {"url": "https://data.example/db", "to": "/abs"}]'
run install dummy
[ "$RC" = 0 ] && [ "$(grep -c "skipping a bad data entry" <<<"$ERR")" = 3 ] && ! grep -q data.example "$W/curl.log" && [ ! -e "$W/escape" ] \
  && ok "plain http, '..' and absolute targets are skipped (never fetched), the install succeeds" || bad "bad entries: rc=$RC $ERR"

# =================================================================================================
CASE="list"
reset; catalog v2; api v2
field() { python3 -c 'import json,sys; e=json.loads(sys.argv[1])["emulators"]["dummy"]; print(json.dumps(e[sys.argv[2]]))' "$OUT" "$1" 2>/dev/null; }
run list
[ "$RC" = 0 ] && python3 -c 'import json,sys; json.loads(sys.argv[1])' "$OUT" 2>/dev/null && ok "prints JSON, exit 0" || bad "rc=$RC out=$OUT"
[ "$(field installed)" = null ] && [ "$(field update)" = false ] && [ "$(field pinned)" = '"v2"' ] \
  && ok "not installed: installed null, pinned v2, no update" || bad "got installed=$(field installed) update=$(field update) pinned=$(field pinned)"
[ "$(field name)" = '"Dummy"' ] && [ "$(field size)" = "$(size "$W/srv/v2.AppImage")" ] && [ "$(field licence)" != null ] \
  && [ "$(field author)" = '"A. Dummy"' ] && [ "$(field homepage)" = '"https://example.org/"' ] \
  && ok "carries name, size, author, homepage and licence for the store screen" || bad "missing store fields"
catalog v1; api v1; run install dummy; catalog v2
run list
[ "$(field installed)" = '"v1"' ] && [ "$(field update)" = true ] && ok "v1 installed, v2 pinned: update true" || bad "got installed=$(field installed) update=$(field update)"
calls_before="$(wc -l < "$W/curl.log")"; run list
[ "$(wc -l < "$W/curl.log")" = "$calls_before" ] && ok "list never touches the network" || bad "list called curl"

# =================================================================================================
CASE="no tested build (nightly)"
# Cemu has no aarch64 release that runs (2.6 predates the AArch64 recompiler): its catalog entry
# follows pkgforge-dev's rolling `nightly` release (user decision 2026-10-07). No sha256 in the
# catalog: GitHub's per-asset digest is required instead and the bytes must match it; the build is
# installed as nightly-<id>, <id> = the asset pattern's capture group (the commit in the file name).
nightly_catalog() {  # nightly_catalog [asset-pattern]
  cat > "$W/catalog.json" <<EOF
{"schema": 1, "emulators": {"dummy": {
  "name": "Dummy", "author": "A. Dummy", "systems": ["psx"], "github": "example/dummy", "tag": "nightly",
  "tag_pattern": "^nightly\$", "asset": "${1:-^Dummy-([0-9a-f]+)-arm64\\\\.AppImage\$}", "size": 1000,
  "homepage": "https://example.org/", "licence": {"name": "MIT", "url": "https://example.org/LICENSE"}}}}
EOF
}
nightly_api() {  # nightly_api <id> <content> [digest]: the nightly release now carries build <id>
  printf '%s' "$2" > "$W/srv/nightly.AppImage"
  local f="$W/srv/nightly.AppImage" digest
  digest="${3-sha256:$(sha "$f")}"
  cat > "$W/srv/api-nightly.json" <<EOF
{"tag_name": "nightly", "assets": [
  {"name": "Dummy-$1-x86_64.AppImage", "size": 1, "digest": "sha256:00", "browser_download_url": "https://github.com/example/dummy/releases/download/nightly/Dummy-$1-x86_64.AppImage"},
  {"name": "Dummy-$1-arm64.AppImage", "size": $(size "$f"), "digest": "$digest",
   "browser_download_url": "https://github.com/example/dummy/releases/download/nightly/Dummy-$1-arm64.AppImage"}]}
EOF
  # The nightly is found in the releases list (GitHub flags it prerelease: not a filter); the
  # repo's /releases/latest is an older stable one that the tag pattern skips.
  python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); r.update(prerelease=True, published_at="2026-10-15T00:00:00Z"); json.dump([r], open(sys.argv[2], "w"))' \
    "$W/srv/api-nightly.json" "$W/srv/rel-list.json"
  printf '{"tag_name": "2.6", "published_at": "2026-01-01T00:00:00Z", "assets": []}' > "$W/srv/rel-latest.json"
}
reset; nightly_catalog; nightly_api abc123 "nightly build abc"
run install dummy
[ "$RC" = 0 ] && [ "$(readlink "$D/dummy/current")" = nightly-abc123.AppImage ] \
  && ok "installs the current nightly as nightly-<commit>.AppImage" || bad "rc=$RC current=$(readlink "$D/dummy/current") $ERR"
cmp -s "$D/dummy/nightly-abc123.AppImage" "$W/srv/nightly.AppImage" && ok "the AppImage is the served bytes" || bad "installed file differs"
pct_only && ok "stdout is only forward N% lines ending at 100%" || bad "stdout was: $(tr '\n' '|' <<<"$OUT")"
: > "$W/curl.log"; run install dummy
[ "$RC" = 0 ] && [ "$OUT" = "100%" ] && grep -q 'api.github.com' "$W/curl.log" && ! grep -q 'download/nightly/' "$W/curl.log" \
  && grep -q "already the latest" <<<"$ERR" \
  && ok "same build again: asks GitHub, downloads nothing, says it is already the latest" || bad "rc=$RC out=$OUT $ERR"
nightly_api def456 "nightly build def, newer"
run install dummy
[ "$RC" = 0 ] && [ "$(readlink "$D/dummy/current")" = nightly-def456.AppImage ] && [ -f "$D/dummy/nightly-abc123.AppImage" ] \
  && ok "a newer nightly installs, the previous one is kept for a rollback" || bad "rc=$RC left: $(ls "$D/dummy" | tr '\n' ' ')"
run list
[ "$(field tested)" = null ] && [ "$(field follows_latest)" = true ] && [ "$(field installed)" = '"nightly-def456"' ] && [ "$(field update)" = false ] \
  && ok "list: no tested build, follows latest, installed nightly-<commit>, update unknown offline (false)" \
  || bad "got tested=$(field tested) follows=$(field follows_latest) installed=$(field installed) update=$(field update)"
# Refusals: no digest to check against, bytes that do not match it.
reset; nightly_catalog; nightly_api abc123 "nightly build abc" ""
run install dummy
[ "$RC" = 4 ] && ! grep -q 'download/nightly/' "$W/curl.log" && [ ! -e "$D/dummy/current" ] \
  && ok "no GitHub digest: exit 4, nothing downloaded" || bad "rc=$RC $ERR"
reset; nightly_catalog; nightly_api abc123 "nightly build abc"; printf 'tampered' > "$W/srv/override"
run install dummy
[ "$RC" = 4 ] && [ -z "$(find "$D" -type f)" ] && ok "bytes that do not hash to GitHub's digest: exit 4, nothing left" || bad "rc=$RC left: $(find "$D" -type f)"
# No capture group: the build is named by its digest.
reset; nightly_catalog '^Dummy-[0-9a-f]+-arm64\\.AppImage$'; nightly_api abc123 "nightly build abc"
run install dummy
want="nightly-$(sha "$W/srv/nightly.AppImage" | cut -c1-12).AppImage"
[ "$RC" = 0 ] && [ "$(readlink "$D/dummy/current")" = "$want" ] && ok "no capture group: named nightly-<sha256 prefix>" || bad "current=$(readlink "$D/dummy/current") want $want: $ERR"
# A pinned-only entry stays pinned: a sha256 is still required without a tag_pattern.
reset; nightly_catalog; python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); del c["emulators"]["dummy"]["tag_pattern"]; json.dump(c, open(sys.argv[1], "w"))' "$W/catalog.json"
nightly_api abc123 "nightly build abc"; run install dummy
[ "$RC" = 4 ] && [ ! -e "$D/dummy/current" ] && ok "no tag_pattern and no sha256: refused (exit 4)" || bad "rc=$RC $ERR"

# =================================================================================================
CASE="unpacked archive"
# PortMaster is a zip, not an AppImage: unpacked into ~/roms/ports/PortMaster (its own default
# through the image's /roms link), version read from its own file, and it updates itself after the
# first install (user decision 2026-10-11). An archive must not be able to write outside its folder.
mkzip() {  # mkzip <name> <version> [extra python lines run with z open]
  python3 - "$W/srv/$1.zip" "$2" "${3:-}" <<'PY'
import sys, zipfile
path, ver, extra = sys.argv[1:4]
def add(z, name, data, mode):
    i = zipfile.ZipInfo(name); i.external_attr = mode << 16; i.create_system = 3
    z.writestr(i, data)
with zipfile.ZipFile(path, "w") as z:
    add(z, "Tool/", b"", 0o40755)
    add(z, "Tool/version", ver + "\n", 0o100644)
    add(z, "Tool/Tool.sh", "#!/bin/sh\necho tool\n", 0o100755)
    add(z, "Tool/lib/data.txt", "data", 0o100644)
    add(z, "Tool/setuid", "x", 0o104755)
    exec(extra)
PY
}
zip_catalog() {  # zip_catalog <name> [self_update true|false]
  local f="$W/srv/$1.zip"
  cat > "$W/catalog.json" <<EOF
{"schema": 1, "emulators": {"tool": {
  "name": "Tool", "author": "A. Tool", "systems": ["ports"], "github": "example/dummy", "tag": "$1",
  "asset": "^Tool\\\\.zip\$", "sha256": "$(sha "$f")", "size": $(size "$f"),
  "unpack": {"to": "roms/ports/Tool", "version": "version"}, "self_update": ${2:-true},
  "homepage": "https://example.org/", "licence": {"name": "MIT", "url": "https://example.org/LICENSE"}}}}
EOF
  cat > "$W/srv/api-$1.json" <<EOF
{"tag_name": "$1", "assets": [{"name": "Tool.zip", "size": $(size "$f"), "digest": "sha256:$(sha "$f")",
   "browser_download_url": "https://github.com/example/dummy/releases/download/$1/Tool.zip"}]}
EOF
}
# The curl stub serves <tag>.zip for .../download/<tag>/Tool.zip.
sed -i 's|^  \*) exit 22 ;;$|  https://github.com/example/dummy/releases/download/*/Tool.zip)\n    tag=${url%/*}; tag=${tag##*/}; cp "'"$W"'/srv/$tag.zip" "${out:?no -o}" ;;\n  *) exit 22 ;;|' "$W/bin/curl"
T="$W/home/roms/ports/Tool"
tfield() { python3 -c 'import json,sys; e=json.loads(sys.argv[1])["emulators"]["tool"]; print(json.dumps(e[sys.argv[2]]))' "$OUT" "$1" 2>/dev/null; }

mkzip 2026.1 2026.1
reset; zip_catalog 2026.1
run install tool
[ "$RC" = 0 ] && [ -f "$T/Tool.sh" ] && [ "$(cat "$T/lib/data.txt")" = data ] \
  && ok "unpacks the archive's top folder into ~/roms/ports/Tool" || bad "rc=$RC $ERR; got: $(find "$W/home" | tr '\n' ' ')"
[ -x "$T/Tool.sh" ] && [ ! -x "$T/lib/data.txt" ] && ok "keeps the archive's executable bits" || bad "modes: $(stat -c '%n %a' "$T/Tool.sh" "$T/lib/data.txt")"
[ "$(stat -c %a "$T/setuid" 2>/dev/null)" = 755 ] && ok "never carries a setuid bit over" || bad "setuid file mode $(stat -c %a "$T/setuid" 2>/dev/null)"
pct_only && ok "stdout is only forward N% lines ending at 100%" || bad "stdout was: $(tr '\n' '|' <<<"$OUT")"
[ -z "$(find "$W/home" "$D" -name '*.part' -o -name '*retroforge-new*')" ] && ok "no download or staging folder left" || bad "left: $(find "$W/home" "$D" -name '*.part' -o -name '*retroforge-new*')"
[ ! -e "$D/tool/current" ] && [ -z "$(find "$D" -name '*.AppImage')" ] && ok "no AppImage layout for an archive" || bad "AppImage layout created"
run list
[ "$(tfield installed)" = '"2026.1"' ] && [ "$(tfield update)" = false ] && [ "$(tfield self_update)" = true ] \
  && ok "list: installed = the archive's own version file, self_update, no update offered" \
  || bad "got installed=$(tfield installed) update=$(tfield update) self_update=$(tfield self_update)"

CASE="unpacked archive: it updates itself"
# PortMaster rewrote its own version file: RetroForge must neither offer nor force a downgrade/update.
printf '2026.9\n' > "$T/version"; mkdir -p "$T/libs"; printf 'runtime' > "$T/libs/godot.squashfs"
mkzip 2026.2 2026.2; zip_catalog 2026.2; : > "$W/curl.log"
run list
[ "$(tfield installed)" = '"2026.9"' ] && [ "$(tfield update)" = false ] && ok "a self-updated version is reported, no update offered" || bad "installed=$(tfield installed) update=$(tfield update)"
run install tool
[ "$RC" = 0 ] && [ "$OUT" = "100%" ] && ! grep -q 'Tool.zip' "$W/curl.log" && [ "$(cat "$T/version")" = 2026.9 ] \
  && ok "install on a self-updating install downloads nothing and changes nothing" || bad "rc=$RC out=$OUT version=$(cat "$T/version")"

CASE="unpacked archive: pinned (no self-update)"
reset; mkzip 2026.1 2026.1; zip_catalog 2026.1 false; run install tool
mkdir -p "$T/libs"; printf 'runtime' > "$T/libs/godot.squashfs"
mkzip 2026.2 2026.2; zip_catalog 2026.2 false
run list
[ "$(tfield update)" = true ] && ok "a newer pin offers an update" || bad "update=$(tfield update)"
run install tool
[ "$RC" = 0 ] && [ "$(cat "$T/version")" = 2026.2 ] && [ -f "$T/libs/godot.squashfs" ] \
  && ok "the update unpacks over the folder and keeps what the tool added (runtimes)" || bad "rc=$RC version=$(cat "$T/version" 2>/dev/null) $ERR"

CASE="unpacked archive: refusals"
refused() {  # refused <what> <zip-name> <extra python>
  mkzip "$2" "$2" "$3"; reset; zip_catalog "$2"
  run install tool
  if [ "$RC" = 4 ] && [ ! -e "$T" ] && [ -z "$(find "$W/home" -mindepth 1 -not -path "$W/home/roms" -not -path "$W/home/roms/ports")" ]; then
    ok "$1: exit 4, nothing installed or left"
  else
    bad "$1: rc=$RC left: $(find "$W/home" -mindepth 1 | tr '\n' ' ') $ERR"
  fi
}
refused "a '..' member" 3.1 'add(z, "Tool/../../escape", "x", 0o100644)'
refused "an absolute member" 3.2 'add(z, "/tmp/abs-escape", "x", 0o100644)'
refused "a symlink member" 3.3 'add(z, "Tool/link", "/etc/passwd", 0o120777)'
refused "a second top-level folder" 3.4 'add(z, "Other/file", "x", 0o100644)'
refused "a version file that is not the pinned tag" 3.5 'add(z, "Tool/version", "9.9\n", 0o100644)'
[ ! -e "$W/escape" ] && [ ! -e /tmp/abs-escape ] && ok "no member was written outside the folder" || bad "an archive member escaped"
mkzip 3.6 3.6; reset; zip_catalog 3.6
python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); c["emulators"]["tool"]["unpack"]["to"]="../outside"; json.dump(c, open(sys.argv[1], "w"))' "$W/catalog.json"
run install tool
[ "$RC" = 4 ] && [ ! -e "$W/curl.log" ] && ok "an unpack target outside the home is refused before any download" || bad "rc=$RC"
# Targets whose Delete would take the home or every emulator with it (security review 2026-10-11).
for to in . emulators/.. ""; do
  zip_catalog 3.6
  python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); c["emulators"]["tool"]["unpack"]["to"]=sys.argv[2]; json.dump(c, open(sys.argv[1], "w"))' "$W/catalog.json" "$to"
  rm -f "$W/curl.log"; run install tool
  [ "$RC" = 4 ] && [ ! -e "$W/curl.log" ] && ok "unpack target '$to' (the home itself) is refused" || bad "target '$to': rc=$RC"
done
reset; zip_catalog 3.6; mkdir -p "$W/home/roms/ports"
python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); c["emulators"]["tool"]["unpack"]["to"]="emus-parent"; json.dump(c, open(sys.argv[1], "w"))' "$W/catalog.json"
OUT="$(HOME="$W/home" RETROFORGE_CURL="$W/bin/curl" RETROFORGE_EMU_DIR="$W/home/emus-parent/emulators" RETROFORGE_CATALOG="$W/catalog.json" python3 "$EMU" install tool 2>&1)"; RC=$?
[ "$RC" = 4 ] && ok "an unpack target that holds the emulators folder is refused" || bad "target above ~/emulators: rc=$RC"
# A symlinked target is never unpacked through, and a stale staging symlink does not block installs.
mkzip 3.7 3.7; reset; zip_catalog 3.7; mkdir -p "$W/home/roms/ports" "$W/elsewhere"; ln -s "$W/elsewhere" "$T"
run install tool
[ "$RC" = 5 ] && [ -z "$(ls -A "$W/elsewhere")" ] && ok "a symlinked target folder is refused, nothing written through it" || bad "symlinked target: rc=$RC, wrote: $(ls -A "$W/elsewhere")"
reset; zip_catalog 3.7; mkdir -p "$W/home/roms/ports"; ln -s /nonexistent "$W/home/roms/ports/.Tool.retroforge-new"
run install tool
[ "$RC" = 0 ] && [ -f "$T/Tool.sh" ] && ok "a stale staging symlink is cleared, the install goes on" || bad "stale staging symlink: rc=$RC $ERR"
refused "an archive of absolute paths only" 3.8 'z.filelist[:] = []; z.NameToInfo.clear(); add(z, "/abs/version", "3.8\n", 0o100644)'

CASE="unpacked archive: remove"
reset; mkzip 2026.1 2026.1; zip_catalog 2026.1; run install tool
mkdir -p "$W/home/roms/ports/agame"; touch "$W/home/roms/ports/Agame.sh"
run remove tool
[ "$RC" = 0 ] && [ ! -e "$T" ] && [ ! -e "$D/tool" ] && ok "removes the unpacked folder" || bad "rc=$RC left: $(ls "$T" 2>&1)"
[ -d "$W/home/roms/ports/agame" ] && [ -f "$W/home/roms/ports/Agame.sh" ] && ok "leaves the ports beside it alone" || bad "touched the ports"
# A folder retroforge-emu did not unpack (no marker) is never deleted, whatever the catalog says.
mkdir -p "$T"; touch "$T/players-own"
run remove tool
[ -f "$T/players-own" ] && ok "a folder without retroforge-emu's marker is left alone" || bad "deleted a folder retroforge-emu did not install"

# =================================================================================================
CASE="one file out of a tarball (extract)"
# DSperate ships a tarball holding its binary: the download is verified as the tarball, then the one
# member the catalog's "extract" regex matches becomes <tag>.AppImage (format "binary").
mktar() {  # mktar <tag> [extra python lines run with t open]
  python3 - "$W/srv/$1.AppImage" "$1" "${2:-}" <<'PY'
import io, sys, tarfile
path, tag, extra = sys.argv[1:4]
def add(t, name, data, mode=0o755):
    i = tarfile.TarInfo(name); i.size = len(data); i.mode = mode
    t.addfile(i, io.BytesIO(data))
with tarfile.open(path, "w:gz") as t:
    add(t, f"tool-{tag}-linux/README.md", b"readme", 0o644)
    add(t, f"tool-{tag}-linux/tool", f"tool binary {tag}".encode(), 0o644)
    add(t, f"tool-{tag}-linux/tool-headless", b"headless")
    exec(extra)
PY
}
extract_catalog() {  # extract_catalog <tag> [regex]
  catalog "$1"; api "$1"
  python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); c["emulators"]["dummy"]["extract"]=sys.argv[2]; json.dump(c, open(sys.argv[1], "w"))' \
    "$W/catalog.json" "${2:-^tool-v[0-9.]+-linux/tool\$}"
}
reset; mktar v7.1; extract_catalog v7.1; run install dummy
[ "$RC" = 0 ] && [ "$(readlink "$D/dummy/current")" = v7.1.AppImage ] && [ "$(cat "$D/dummy/v7.1.AppImage")" = "tool binary v7.1" ] \
  && ok "the matching member becomes v7.1.AppImage and current points at it" || bad "rc=$RC $ERR; got: $(ls -a "$D/dummy" | tr '\n' ' ')"
[ "$(stat -c %a "$D/dummy/v7.1.AppImage" 2>/dev/null)" = 755 ] && ok "it is 0755 whatever the archive said (0644 there)" || bad "mode $(stat -c %a "$D/dummy/v7.1.AppImage" 2>/dev/null)"
[ -z "$(find "$D" -name '.*' -type f)" ] && ok "no .part or .extract file left" || bad "left: $(find "$D" -name '.*' -type f)"
mktar v7.2; extract_catalog v7.2; run install dummy
[ "$RC" = 0 ] && [ "$(readlink "$D/dummy/current")" = v7.2.AppImage ] && [ -f "$D/dummy/v7.1.AppImage" ] \
  && ok "an update keeps the previous build" || bad "rc=$RC $ERR"
run rollback dummy
[ "$RC" = 0 ] && [ "$(readlink "$D/dummy/current")" = v7.1.AppImage ] && ok "rollback goes back to the previous build" || bad "rc=$RC $ERR"
xrefused() {  # xrefused <what> <tag> <extra python> [regex]
  reset; mktar "$2" "$3"; extract_catalog "$2" "${4:-}"; run install dummy
  [ "$RC" = 4 ] && [ ! -e "$D/dummy/current" ] && [ -z "$(find "$D" -name '*.AppImage*')" ] \
    && ok "$1: refused (exit 4), nothing installed" || bad "$1: rc=$RC $ERR; left: $(ls -a "$D/dummy" 2>&1 | tr '\n' ' ')"
}
xrefused "no member matches" v7.3 "" '^nothing$'
xrefused "two members match" v7.4 "" '^tool-v[0-9.]+-linux/tool.*$'
xrefused "the member is a symlink" v7.5 '
i = tarfile.TarInfo("tool-v7.5-linux/tool-link"); i.type = tarfile.SYMTYPE; i.linkname = "/etc/passwd"; t.addfile(i)' '^tool-v[0-9.]+-linux/tool-link$'
reset; printf 'not a tarball' > "$W/srv/v7.6.AppImage"; extract_catalog v7.6; run install dummy
[ "$RC" = 4 ] && [ ! -e "$D/dummy/current" ] && ok "bytes that are not a tar archive: refused (exit 4)" || bad "rc=$RC $ERR"
reset; mktar v7.7; extract_catalog v7.7 '^tool-[('; run install dummy
[ "$RC" = 4 ] && [ ! -e "$W/curl.log" ] && ok "a bad regex is refused before any download" || bad "rc=$RC"
reset; mktar v7.8; extract_catalog v7.8
python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); c["emulators"]["dummy"]["unpack"]={"to":"x","version":"v"}; json.dump(c, open(sys.argv[1], "w"))' "$W/catalog.json"
run install dummy
[ "$RC" = 4 ] && [ ! -e "$W/curl.log" ] && ok "extract with unpack is refused before any download" || bad "rc=$RC"

CASE="latest"
# An entry with "tag_pattern" installs upstream's newest qualifying release, not the pin (plan
# emulator-latest D1-D4); the pin stays as the tested build.
# releases <latest-spec|-> <spec>...: what GitHub answers for /releases/latest (- = 404) and for the
# list (in the order given). <spec> = <tag>:<MM-DD>[:flag,...], flags draft, pre, nodigest,
# noasset, twoassets. The asset is $REL_ASSET (Dummy-arm64.AppImage), served from $W/srv/<tag>.<ext>.
releases() {
  REL_ASSET="${REL_ASSET:-Dummy-arm64.AppImage}" python3 - "$W/srv" "$@" <<'PY'
import hashlib, json, os, sys
srv, latest, specs = sys.argv[1], sys.argv[2], sys.argv[3:]
name = os.environ["REL_ASSET"]
def rel(spec):
    tag, day, *rest = spec.split(":")
    flags = set(rest[0].split(",")) if rest else set()
    f = os.path.join(srv, tag + (".zip" if name.endswith(".zip") else ".AppImage"))
    data = open(f, "rb").read() if os.path.exists(f) else b"x"
    a = {"name": name, "size": len(data),
         "browser_download_url": f"https://github.com/example/dummy/releases/download/{tag}/{name}"}
    if "nodigest" not in flags:
        a["digest"] = "sha256:" + hashlib.sha256(data).hexdigest()
    assets = [] if "noasset" in flags else [a, dict(a)] if "twoassets" in flags else [a]
    return {"tag_name": tag, "draft": "draft" in flags, "prerelease": "pre" in flags,
            "published_at": f"2026-{day}T00:00:00Z", "assets": assets}
json.dump([rel(s) for s in specs], open(os.path.join(srv, "rel-list.json"), "w"))
lp = os.path.join(srv, "rel-latest.json")
if latest == "-":
    if os.path.exists(lp):
        os.unlink(lp)
else:
    json.dump(rel(latest), open(lp, "w"))
PY
}
set_field() {  # set_field <emulator> <key> <json|DELETE>: edit the catalog's entry
  python3 -c 'import json,sys; p,emu,k,v=sys.argv[1:]; c=json.load(open(p)); e=c["emulators"][emu]
if v == "DELETE": e.pop(k, None)
else: e[k] = json.loads(v)
json.dump(c, open(p, "w"))' "$W/catalog.json" "$@"
}
latest_catalog() { catalog v1; set_field dummy tag_pattern '"^v[0-9]+$"'; }
current() { readlink "$D/dummy/current"; }
mkasset latest "rolling build"

reset; latest_catalog; releases "v1:01-01" "v1:01-01" "v3:03-01" "v2:02-01"
run install dummy
[ "$RC" = 0 ] && [ "$(current)" = v3.AppImage ] && ok "installs the newest release by date (v3), not the pin (v1)" || bad "rc=$RC current=$(current) $ERR"
cmp -s "$D/dummy/v3.AppImage" "$W/srv/v3.AppImage" && pct_only && ok "the served bytes, stdout N% lines only" || bad "bytes or stdout: $OUT"
grep -q 'releases/latest' "$W/curl.log" && grep -q 'releases?per_page=30' "$W/curl.log" \
  && ok "asks both /releases/latest and the releases list" || bad "API calls: $(grep api.github "$W/curl.log")"
grep 'api.github.com' "$W/curl.log" | grep -v -- '--proto =https' | grep -q . && bad "an API call is not https only" || ok "every API call is https only"
run list
[ "$(field tested)" = '"v1"' ] && [ "$(field installed)" = '"v3"' ] && [ "$(field follows_latest)" = true ] && [ "$(field update)" = false ] \
  && ok "list: tested v1, installed v3, follows_latest, no offline update" \
  || bad "tested=$(field tested) installed=$(field installed) follows=$(field follows_latest) update=$(field update)"
: > "$W/curl.log"; run install dummy
[ "$RC" = 0 ] && [ "$OUT" = "100%" ] && ! grep -q 'download/' "$W/curl.log" && grep -q "already the latest" <<<"$ERR" \
  && ok "the newest already installed: downloads nothing, says so" || bad "rc=$RC out=$OUT $ERR"

newest() {  # newest <want-tag> <what> <releases args...>: a fresh install picks <want-tag>
  local want=$1 what=$2; shift 2
  reset; latest_catalog; releases "$@"; run install dummy
  [ "$RC" = 0 ] && [ "$(current)" = "$want.AppImage" ] && ok "$what" || bad "$what: rc=$RC current=$(current) $ERR"
}
newest v3 "the newest only in /releases/latest (RPCS3's list is sorted by tag name)" "v3:03-01" "v1:01-01" "v2:02-01"
newest v2 "no /releases/latest (404): the list alone" - "v2:02-01" "v1:01-01"
newest v2 "a draft is skipped" - "v3:03-01:draft" "v2:02-01"
newest v3 "a prerelease is NOT skipped: the tag pattern decides (Cemu's nightlies)" - "v3:03-01:pre" "v2:02-01"
newest v2 "a tag the pattern does not match is skipped (DuckStation's rolling 'latest')" "latest:04-01" "latest:04-01" "v2:02-01"
newest v2 "a release without a matching asset is skipped" - "v3:03-01:noasset" "v2:02-01"
newest v2 "a release with two matching assets is skipped" - "v3:03-01:twoassets" "v2:02-01"
reset; latest_catalog; releases - "v3:03-01:noasset" "latest:04-01"; run install dummy
[ "$RC" = 4 ] && ! grep -q 'download/' "$W/curl.log" && [ ! -e "$D/dummy/current" ] \
  && ok "no release qualifies: exit 4, nothing downloaded" || bad "rc=$RC $ERR"
reset; latest_catalog; releases - "v3:03-01:nodigest" "v2:02-01"; run install dummy
[ "$RC" = 4 ] && ! grep -q 'download/' "$W/curl.log" && [ ! -e "$D/dummy/current" ] \
  && ok "the newest has no GitHub digest: exit 4, no fallback to an older one" || bad "rc=$RC current=$(current) $ERR"
reset; latest_catalog; releases - "v3:03-01"; cp "$W/srv/v1.AppImage" "$W/srv/override"; run install dummy
[ "$RC" = 4 ] && [ -z "$(find "$D" -type f)" ] && ok "bytes that do not hash to GitHub's digest: exit 4, nothing left" || bad "rc=$RC left: $(find "$D" -type f)"
reset; latest_catalog; releases - "v3:03-01"; touch "$W/srv/ratelimit"; run install dummy
[ "$RC" = 6 ] && grep -Eq "try again in (9|10) min" <<<"$ERR" \
  && ok "GitHub's rate limit used up (403, none remaining): exit 6, not a network fault, says when" || bad "rc=$RC $ERR"
reset; latest_catalog; releases - "v3:03-01"; touch "$W/srv/forbidden"; run install dummy
[ "$RC" = 3 ] && ok "a 403 with requests remaining is not the rate limit: exit 3" || bad "rc=$RC $ERR"
reset; latest_catalog; set_field dummy tag_pattern '"(["'; run install dummy
[ "$RC" = 4 ] && [ ! -e "$W/curl.log" ] && ok "a bad tag_pattern is refused before any network" || bad "rc=$RC"

# =================================================================================================
CASE="install --tested"
reset; latest_catalog; api v1; releases - "v3:03-01"; run install dummy
run install dummy --tested
[ "$RC" = 0 ] && [ "$(current)" = v1.AppImage ] && [ -f "$D/dummy/v3.AppImage" ] \
  && ok "installs the pin over a newer build, which is kept as previous" || bad "rc=$RC current=$(current) $ERR"
grep -q 'releases/tags/v1' "$W/curl.log" && ok "through the pinned tag's lookup (digest + size == catalog)" || bad "no pinned lookup"
run list
[ "$(field installed)" = '"v1"' ] && [ "$(field previous)" = '"v3"' ] && ok "list: installed v1, previous v3" || bad "installed=$(field installed) previous=$(field previous)"
: > "$W/curl.log"; run install dummy --tested
[ "$RC" = 0 ] && [ "$OUT" = "100%" ] && [ ! -s "$W/curl.log" ] && ok "the pin already installed: nothing asked, nothing downloaded" || bad "rc=$RC out=$OUT"
reset; nightly_catalog; run install dummy --tested
[ "$RC" = 2 ] && [ ! -e "$W/curl.log" ] && ok "an entry with no tested build (nightly): exit 2, no network" || bad "rc=$RC"
reset; latest_catalog; run install --tested;  [ "$RC" = 2 ] && ok "--tested with no emulator: exit 2" || bad "rc=$RC"
run install dummy --newest;                   [ "$RC" = 2 ] && ok "an unknown flag: exit 2" || bad "rc=$RC"

# =================================================================================================
CASE="rollback"
reset; latest_catalog; releases - "v2:02-01"; run install dummy
run rollback dummy
[ "$RC" = 2 ] && [ "$(current)" = v2.AppImage ] && ok "nothing to go back to (first install): exit 2, current unchanged" || bad "rc=$RC current=$(current)"
releases - "v3:03-01" "v2:02-01"; run install dummy
: > "$W/curl.log"; run rollback dummy
[ "$RC" = 0 ] && [ "$(current)" = v2.AppImage ] && [ -f "$D/dummy/v3.AppImage" ] && ok "back to v2, v3 kept" || bad "rc=$RC current=$(current) $ERR"
[ ! -s "$W/curl.log" ] && [ -z "$OUT" ] && ok "offline, nothing on stdout" || bad "curl ran or stdout: $OUT"
run list
[ "$(field installed)" = '"v2"' ] && [ "$(field previous)" = '"v3"' ] && ok "list: installed v2, previous v3" || bad "installed=$(field installed) previous=$(field previous)"
run rollback dummy
[ "$RC" = 0 ] && [ "$(current)" = v3.AppImage ] && [ -f "$D/dummy/v2.AppImage" ] && ok "a second rollback toggles back to v3" || bad "rc=$RC current=$(current)"
reset; latest_catalog; run rollback dummy
[ "$RC" = 2 ] && [ ! -e "$D/dummy" ] && ok "not installed: exit 2, creates nothing" || bad "rc=$RC"
run rollback ../dummy; [ "$RC" = 2 ] && ok "a path as the emulator: exit 2" || bad "rc=$RC"
reset; mkzip 2026.1 2026.1; zip_catalog 2026.1; run install tool; run rollback tool
[ "$RC" = 2 ] && [ -f "$T/Tool.sh" ] && ok "an unpacked folder has no rollback: exit 2, left alone" || bad "rc=$RC"

# =================================================================================================
CASE="check"
cfield() { python3 -c 'import json,sys; e=json.loads(sys.argv[1])["emulators"]["dummy"]; print(json.dumps(e[sys.argv[2]]))' "$OUT" "$1" 2>/dev/null; }
calls() { grep -c 'api.github.com' "$W/curl.log" 2>/dev/null || true; }
reset; latest_catalog; releases "v1:01-01" "v1:01-01" "v3:03-01" "v2:02-01"
run check
[ "$RC" = 0 ] && [ "$(cfield latest)" = '"v3"' ] && [ "$(cfield error)" = null ] && ok "JSON: latest v3, no error" || bad "rc=$RC out=$OUT $ERR"
[ -f "$W/home/.cache/retroforge/emu-check.json" ] && ! grep -q 'download/' "$W/curl.log" && ok "cached, nothing downloaded" || bad "no cache, or a download"
: > "$W/curl.log"; run check dummy
[ "$(cfield latest)" = '"v3"' ] && [ "$(calls)" = 0 ] && ok "within the hour: answered from the cache, no GitHub call" || bad "latest=$(cfield latest) calls=$(calls)"
run check dummy --refresh
[ "$(calls)" -gt 0 ] && ok "--refresh asks GitHub again" || bad "--refresh used the cache"
python3 -c 'import json,sys,time; p=sys.argv[1]; c=json.load(open(p)); c["dummy"]["at"]=time.time()-4000; json.dump(c, open(p,"w"))' "$W/home/.cache/retroforge/emu-check.json"
: > "$W/curl.log"; run check
[ "$(calls)" -gt 0 ] && [ "$(cfield latest)" = '"v3"' ] && ok "an answer older than an hour is asked again" || bad "stale cache used"
: > "$W/curl.log"; set_field dummy tag_pattern '"^v[12]$"'; run check
[ "$(calls)" -gt 0 ] && [ "$(cfield latest)" = '"v2"' ] && ok "a catalog (OTA) with another tag_pattern is asked again" || bad "latest=$(cfield latest) calls=$(calls)"
reset; latest_catalog; releases - "v3:03-01"; run install dummy
: > "$W/curl.log"; run check
[ "$(cfield latest)" = '"v3"' ] && [ "$(calls)" = 0 ] && ok "an install leaves its answer in the cache" || bad "latest=$(cfield latest) calls=$(calls)"
reset; latest_catalog; run check
[ "$RC" = 0 ] && [ "$(cfield latest)" = null ] && [ "$(cfield error)" != null ] && ok "GitHub fails: latest null, the error reported, exit 0" || bad "rc=$RC out=$OUT"
releases - "v3:03-01"; : > "$W/curl.log"; run check
[ "$(calls)" -gt 0 ] && [ "$(cfield latest)" = '"v3"' ] && ok "a failure is not cached: the next check asks again" || bad "latest=$(cfield latest) calls=$(calls)"
reset; latest_catalog; releases - "v3:03-01"; touch "$W/srv/ratelimit"; run check
[ "$(cfield latest)" = null ] && grep -q "try again in" <<<"$(cfield error)" && ok "rate limited: reported as the error, never as a version" || bad "out=$OUT"
reset; catalog v2; run check
[ "$(cfield latest)" = '"v2"' ] && [ ! -e "$W/curl.log" ] && ok "a pinned-only entry: its pin, no network" || bad "out=$OUT"
run check nosuch; [ "$RC" = 2 ] && ok "an emulator not in the catalog: exit 2" || bad "rc=$RC"
run check dummy --tested; [ "$RC" = 2 ] && ok "an unknown flag: exit 2" || bad "rc=$RC"

# =================================================================================================
CASE="unpacked archive: latest first install"
# PortMaster (D6): the first install takes upstream's newest, then PortMaster updates itself.
reset; mkzip 2026.1 2026.1; mkzip 2026.4 2026.4; zip_catalog 2026.1; set_field tool tag_pattern '"^2026\\.[0-9]+$"'
REL_ASSET=Tool.zip releases - "2026.4:04-01" "2026.1:01-01"
run install tool
[ "$RC" = 0 ] && [ "$(cat "$T/version")" = 2026.4 ] && ok "the first install unpacks the newest release (2026.4), not the pin" || bad "rc=$RC version=$(cat "$T/version" 2>/dev/null) $ERR"
: > "$W/curl.log"; run install tool
[ "$RC" = 0 ] && [ ! -s "$W/curl.log" ] && ok "installed: it updates itself, retroforge-emu asks nothing" || bad "rc=$RC"
reset; mkzip 2026.5 2026.1; zip_catalog 2026.1; set_field tool tag_pattern '"^2026\\.[0-9]+$"'
REL_ASSET=Tool.zip releases - "2026.5:05-01"
run install tool
[ "$RC" = 4 ] && [ ! -e "$T" ] && ok "an archive whose version file is not the tag being installed: exit 4" || bad "rc=$RC"

# =================================================================================================
CASE="remove"
reset; catalog v1; api v1; run install dummy
catalog v2; api v2; run install dummy
run remove dummy
[ "$RC" = 0 ] && [ ! -e "$D/dummy" ] && ok "removes the emulator's folder (every version)" || bad "rc=$RC left: $(ls "$D/dummy" 2>&1)"
run remove dummy
[ "$RC" = 0 ] && ok "removing what is not installed is not an error" || bad "exited $RC"
mkdir -p "$D/other"; touch "$D/other/keep"
run remove dummy
[ -f "$D/other/keep" ] && ok "other emulators are left alone" || bad "touched another emulator"

# =================================================================================================
# Steam Client: not a catalog entry. `list` adds it from steam-install status, and its install is
# steam-install's (progress lines and exit status passed through). There is no Steam CLI any more:
# an entry an older steam-install still reports (steam-cli) is not listed, and cannot be installed.
CASE="steam"
reset; catalog v1; api v1
cat >"$W/bin/steam-install" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$W/steam.log"
case "\$1" in
  status) echo '{"steam-client": {"installed": "1791918634", "size": 2212495360, "progress": "/c/p-client"},
                 "steam-cli": {"installed": null, "size": 46137344, "progress": "/c/p-cli"}}' ;;
  install) echo 50%; echo 100%; exit "\${FAKE_STEAM_RC:-0}" ;;
esac
EOF
chmod +x "$W/bin/steam-install"; rm -f "$W/steam.log"
srun() { RETROFORGE_STEAM_INSTALL="$W/bin/steam-install" run "$@"; }
srun list
python3 - "$OUT" <<'PY' && ok "list adds Steam Client (kind steam, Valve, progress file) beside the emulators, and no Steam CLI" || bad "rc=$RC out=$OUT err=$ERR"
import json, sys
e = json.loads(sys.argv[1])["emulators"]
c = e["steam-client"]
assert "dummy" in e and "steam-cli" not in e
assert c["kind"] == "steam" and c["name"] == "Steam Client"
assert c["installed"] == "1791918634" and c["progress"] == "/c/p-client"
assert c["author"] == "Valve" and c["licence"]["name"] == "Steam Subscriber Agreement"
assert c["self_update"] is True and c["update"] is False and c["tested"] is None and c["systems"] == []
PY
run list
! grep -q steam-client <<<"$OUT" && ok "no steam-install in the image: no Steam entries" || bad "$OUT"
srun install steam-client
[ "$RC" = 0 ] && pct_only && grep -qx "install client" "$W/steam.log" && ok "install steam-client: steam-install install client, its progress on stdout" || bad "rc=$RC out=$OUT log=$(cat "$W/steam.log")"
FAKE_STEAM_RC=3 srun install steam-client
[ "$RC" = 3 ] && ok "install steam-client: its exit status (3) is ours" || bad "rc=$RC"
rm -f "$W/steam.log"; srun install steam-cli
[ "$RC" != 0 ] && ! grep -q "install cli" "$W/steam.log" 2>/dev/null && ok "install steam-cli: refused, steam-install not run" || bad "rc=$RC log=$(cat "$W/steam.log" 2>&1)"
for args in "check steam-client" "rollback steam-client" "remove steam-client" "install steam-client --tested"; do
  srun $args
  [ "$RC" = 2 ] && grep -q "Steam updates itself" <<<"$ERR" && ok "$args: exit 2" || bad "$args: rc=$RC err=$ERR"
done

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
# Offline test for /usr/bin/steam and /usr/lib/retroforge/steam-bootstrap: how the image provides the
# `steam` the OpenGamepadUI Steam plugin launches games with.
#
#   tests/test-steam.sh
#
# WHY THIS EXISTS. Neither is exercised before a player picks a Steam game, and each rule below fails
# as a game that never starts, a black screen, a half-set-up client that looks ready, or a ~631 MB
# surprise download:
#   the pin (steam.pin): names CHANNELS, not versions; the client channel is a steamdeck_ line,
#     because the plugin starts the client with -steamdeck.
#   bootstrap, client:
#   - reads steam_client_<client_channel>_linuxarm64 and installs Valve's arm64 client binaries,
#     refusing them unless the manifest's sha256 matches;
#   - writes package/beta = the channel when it installs the client and when the file is missing,
#     and otherwise leaves it to the client;
#   - unpacks Valve's zips correctly: '\' separators, no execute bits in the zip, Unix symlinks;
#   - a failed download leaves no half-set-up client and no temp files, and never touches the
#     player's other files in the Steam folder;
#   - refuses a zip path or symlink that leaves its folder;
#   - downloads no Steam Runtime, and removes the one earlier builds installed.
#   wrapper:
#   - runs steamrtarm64/steam raw on the host (no runtime container: games' pressure-vessel cannot
#     start nested in it) with the plugin's arguments, from steamrtarm64 with its own libraries first
#     on LD_LIBRARY_PATH, and starts it again on exit 42 (after an update);
#   - points ~/.steam/steam and ~/.steam/root at the client, and the links Valve's steam.sh makes;
#   - drops a D-Bus address that is not ours, and the STEAM_RUNTIME variables;
#   - a failed bootstrap is exit 1 without running anything.
#   kept running in the background (retroforge-steam-keep, the wrapper's "Kept running" block): on
#   by default; the first launch starts the client as a user unit with the launch's environment
#   (OGUI_ID=Steam, not the game's), later ones hand their arguments to it, and a game's launch lasts
#   exactly as long as Steam's own reaper for that app id (never OGUI's reaper, which takes the same
#   arguments), so OGUI neither returns to its menu early nor waits forever. Exit from OGUI's menu ends
#   the game's processes, not Steam; a kept client turned off mid-game stops when the game ends;
#   without a user manager Steam runs with the launch, as when off.
#   minimal: the kept client's web helper is stopped (TERM, KILL only when it ignores that) and the one
#   the client starts again frozen, and nothing it had started yet lives; frozen already, nothing is
#   stopped; a launch that needs Steam's UI holds it running (Steam's UI until OGUI closes it, a game
#   until it has run a while), a hold of a launch that is gone does not.
#   sweep: with no client running, the shared memory earlier clients left in /dev/shm goes, before the
#   wrapper starts a client; segments a process maps or holds open, other files, and everything
#   while a client runs, stay.
#   Steam Client's install (steam-install) through the wrapper: the client's update runs in the
#   install's own process tree, its lines on the install's bar, never as the kept unit; and not at
#   all while a client runs (Steam opened during the install), which updates itself: handed to the
#   kept client, the install waited on it for an hour. While the install holds its lock, the wrapper
#   starts nothing but the install's own run of the client.
# Valve's servers are replaced by file:// URLs: $CDN for the client.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BOOT="$ROOT/rootfs/overlay/usr/lib/retroforge/steam-bootstrap"
WRAP="$ROOT/rootfs/overlay/usr/bin/steam"
PIN_REAL="$ROOT/rootfs/overlay/usr/share/retroforge/steam/steam.pin"
for f in "$BOOT" "$WRAP" "$PIN_REAL"; do [ -f "$f" ] || { echo "missing: $f" >&2; exit 1; }; done

PASS=0; FAIL=0; CASE=""
ok()  { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }

T="$(mktemp -d)" && [ -d "$T" ] || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$T"' EXIT

mode() { python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$1"; }
sha()  { python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }
zeros() { printf '0%.0s' {1..64}; }

CDN="$T/cdn"; mkdir -p "$CDN"            # media.steampowered.com/client
DATA="$T/home/.local/share"
STEAM_ROOT="$DATA/Steam"
CLIENT="$STEAM_ROOT/steamrtarm64/steam"
BETA="$STEAM_ROOT/package/beta"
OLD_RT="$DATA/retroforge/steam-runtime"   # where earlier builds kept the Steam Runtime
PIN="$T/steam.pin"
CHAN=steamdeck_rftest

mkpin() {  # mkpin [extra lines...]
  { printf '# a test pin\nclient_channel: %s\n' "$CHAN"
    [ $# -gt 0 ] && printf '%s\n' "$@"
  } >"$PIN"
}
mkclient() {  # mkclient <zip> [extra member] : the client binaries as Valve zips them
  python3 - "$1" "${2:-}" <<'PY'
import stat, sys, zipfile
path, extra = sys.argv[1:3]
def add(z, name, data=b"", mode=stat.S_IFREG | 0o666, system=0):
    i = zipfile.ZipInfo(name); i.create_system = system; i.external_attr = mode << 16
    z.writestr(i, data)
with zipfile.ZipFile(path, "w") as z:
    add(z, "steamrtarm64\\libs/", mode=stat.S_IFDIR)
    add(z, "steamrtarm64/builddate.txt", b"Oct 13 2026\n")
    add(z, "steamrtarm64/steam", b"\x7fELF arm64 steam\n")
    add(z, "steamrtarm64/steamwebhelper.sh", b"#!/bin/bash\nexec ./steamwebhelper\n")
    add(z, "steamrtarm64\\libs\\libcurl.so", b"libcurl.so.4.8.0", stat.S_IFLNK | 0o755, 3)
    add(z, "steamrtarm64/libs/libcurl.so.4.8.0", b"\x7fELF arm64 libcurl\n")
    if extra:
        add(z, extra, b"evil\n")
PY
}
mkmanifest() {  # mkmanifest <client zip> [sha2] [channel]: a channel's manifest, with a decoy package first
  local file="bins_linuxarm64_linuxarm64.zip.$(basename "$1")"
  cp "$1" "$CDN/$file"
  cat >"$CDN/steam_client_${3:-$CHAN}_linuxarm64" <<EOF
"linuxarm64"
{
	"version"		"1791918634"
	"bins_sdk_linuxarm64_linuxarm64"
	{
		"file"		"bins_sdk_linuxarm64_linuxarm64.zip.decoy"
		"size"		"1"
		"sha2"		"0000000000000000000000000000000000000000000000000000000000000000"
	}
	"bins_linuxarm64_linuxarm64"
	{
		"file"		"$file"
		"size"		"$(wc -c <"$1" | tr -d ' ')"
		"sha2"		"${2:-$(sha "$1")}"
	}
}
EOF
}
boot() {  # boot [VAR=value...]: `steam-bootstrap --install`, as steam-install runs it
  OUT="$(env -u RETROFORGE_STEAM_PROGRESS HOME="$T/home" XDG_DATA_HOME="$DATA" \
         RETROFORGE_STEAM_PIN="$PIN" RETROFORGE_STEAM_CDN="file://$CDN" "$@" python3 "$BOOT" --install 2>"$T/err")"; RC=$?
  ERR="$(cat "$T/err")"
}
bootn() {  # bootn [VAR=value...]: plain `steam-bootstrap`, as /usr/bin/steam runs it on every start
  OUT="$(env -u RETROFORGE_STEAM_PROGRESS HOME="$T/home" XDG_DATA_HOME="$DATA" \
         RETROFORGE_STEAM_PIN="$PIN" RETROFORGE_STEAM_CDN="file://$CDN" "$@" python3 "$BOOT" 2>"$T/err")"; RC=$?
  ERR="$(cat "$T/err")"
}
leftovers() { find "$DATA" -name '.retroforge-bootstrap-*' | head -3; }

# ================================================================================================
CASE="the real pin"
python3 - "$PIN_REAL" <<'PY' && ok "a channel only: a steamdeck_ client line, no version, no runtime" \
  || bad "the image's steam.pin is malformed"
import re, sys
t = open(sys.argv[1]).read()
field = lambda k: (re.search(rf"^{k}:[ \t]*(\S+)", t, re.M) or [None, None])[1]
# -steamdeck (the plugin's flag) keeps a steamdeck_ line; any other gets repointed at ~631 MB.
assert re.fullmatch(r"steamdeck_[a-z0-9_]+", field("client_channel") or ""), field("client_channel")
for k in ("version", "url", "sha256"):
    assert field(k) is None, f"{k} pins a version"
for k in ("runtime_base", "runtime_channel", "runtime_snapshot"):
    assert field(k) is None, f"{k}: the client runs without a Steam Runtime"
PY

CASE="fresh card, not installed"
mkpin
mkclient "$T/client.zip"; mkmanifest "$T/client.zip"
bootn
[ "$RC" = 10 ] && [ -z "$OUT" ] && grep -q "Steam Client is not installed: install it from Main menu > Emulators > Steam Client" <<<"$ERR" \
  && ok "without --install: exit 10, says where Steam Client is installed" || bad "rc=$RC out=$OUT err=$ERR"
[ ! -e "$STEAM_ROOT/steamrtarm64" ] && ok "and downloads nothing" || bad "$(ls -la "$STEAM_ROOT" 2>&1 | head)"
OUT="$(python3 "$BOOT" --bogus 2>"$T/err")"; RC=$?
[ "$RC" = 2 ] && grep -q "usage: steam-bootstrap \[--install\]" "$T/err" && ok "an unknown argument: exit 2" || bad "rc=$RC $(cat "$T/err")"

CASE="fresh card"
boot RETROFORGE_STEAM_PROGRESS=1
[ "$RC" = 0 ] && [ "$OUT" = "$CLIENT" ] && ok "exit 0, prints the client's path" || bad "rc=$RC out=$OUT err=$ERR"
[ -f "$CLIENT" ] && [ "$(mode "$CLIENT")" = 755 ] \
  && ok "the client binary is in place, 0755 although the zip says 0666" || bad "steam: $(ls -la "$STEAM_ROOT/steamrtarm64" 2>&1)"
[ "$(mode "$STEAM_ROOT/steamrtarm64/steamwebhelper.sh")" = 755 ] && [ "$(mode "$STEAM_ROOT/steamrtarm64/builddate.txt")" = 644 ] \
  && ok "#! scripts 0755, data 0644" || bad "modes: sh=$(mode "$STEAM_ROOT/steamrtarm64/steamwebhelper.sh") txt=$(mode "$STEAM_ROOT/steamrtarm64/builddate.txt")"
[ -d "$STEAM_ROOT/steamrtarm64/libs" ] && [ "$(readlink "$STEAM_ROOT/steamrtarm64/libs/libcurl.so")" = libcurl.so.4.8.0 ] \
  && ok "'\\' separators become folders, and link entries become symlinks" || bad "libs: $(ls -la "$STEAM_ROOT/steamrtarm64/libs" 2>&1)"
[ -z "$(find "$STEAM_ROOT" -name '*\\*')" ] && ok "no file has a '\\' in its name" || bad "$(find "$STEAM_ROOT" -name '*\\*')"
[ "$(cat "$BETA" 2>/dev/null)" = "$CHAN" ] && ok "package/beta names the pinned channel" || bad "beta: $(cat "$BETA" 2>&1)"
[ -z "$(leftovers)" ] && ok "no temporary folders left" || bad "left: $(leftovers)"
[ ! -e "$OLD_RT" ] && ok "no Steam Runtime is downloaded" || bad "$(ls -la "$OLD_RT")"
grep -q "Steam client from $CHAN" <<<"$ERR" && ok "says on stderr what it downloads, and from which channel" || bad "stderr: $ERR"
CZ="$(wc -c <"$T/client.zip" | tr -d ' ')"
grep -qx "steam-bootstrap: progress $CZ $CZ" <<<"$ERR" && [ "$(grep -c "^steam-bootstrap: progress " <<<"$ERR")" -ge 1 ] \
  && ok "RETROFORGE_STEAM_PROGRESS=1: progress lines, ending at the download's total" || bad "stderr: $ERR"
bootn
[ "$RC" = 0 ] && [ "$OUT" = "$CLIENT" ] && ok "installed: a plain start (steam's) prints the client's path" || bad "rc=$RC out=$OUT err=$ERR"
! grep -q "progress" <<<"$ERR" && ok "and no progress lines without the variable" || bad "stderr: $ERR"

CASE="installed, offline"
mv "$CDN" "$CDN.off"
bootn
[ "$RC" = 0 ] && [ "$OUT" = "$CLIENT" ] && [ -z "$ERR" ] && ok "a start reads nothing from the network, and says nothing" || bad "rc=$RC out=$OUT err=$ERR"
boot
[ "$RC" = 0 ] && [ "$OUT" = "$CLIENT" ] && [ -z "$ERR" ] && ok "nor does --install once the client is there" || bad "rc=$RC out=$OUT err=$ERR"
mv "$CDN.off" "$CDN"

CASE="a Steam Runtime from an earlier build"
mkdir -p "$OLD_RT/3c.0.20260824.1/steam-runtime-steamrt-arm64"
printf '#!/bin/sh\n' >"$OLD_RT/3c.0.20260824.1/steam-runtime-steamrt-arm64/run"
bootn
[ "$RC" = 0 ] && [ "$OUT" = "$CLIENT" ] && [ ! -e "$OLD_RT" ] && grep -q "removed $OLD_RT: the client runs without it now" <<<"$ERR" \
  && ok "removed on the next start, and said so" || bad "rc=$RC out=$OUT err=$ERR $(ls -la "$OLD_RT" 2>&1)"
bootn
[ "$RC" = 0 ] && [ -z "$ERR" ] && ok "and nothing said after that" || bad "rc=$RC err=$ERR"

CASE="package/beta"
echo steamdeck_publicbeta >"$BETA"   # the client repointed itself
boot
[ "$RC" = 0 ] && [ "$(cat "$BETA")" = steamdeck_publicbeta ] && ok "left alone when present: the client owns it" || bad "rc=$RC beta=$(cat "$BETA") err=$ERR"
rm -f "$BETA"
bootn
[ "$RC" = 0 ] && [ "$(cat "$BETA" 2>/dev/null)" = "$CHAN" ] && ok "written again when missing, without a client download" \
  || bad "rc=$RC beta=$(cat "$BETA" 2>&1) err=$ERR"

CASE="the pin"
printf '# a test pin\n' >"$PIN"
boot
[ "$RC" = 1 ] && [ -z "$OUT" ] && grep -q "needs client_channel" <<<"$ERR" && ok "a pin without client_channel: exit 1" || bad "rc=$RC out=$OUT err=$ERR"
printf 'client_channel: ../evil\n' >"$PIN"
boot
[ "$RC" = 1 ] && grep -q "not a client channel" <<<"$ERR" && ok "a channel that is not a line name is refused" || bad "rc=$RC err=$ERR"
mkpin

CASE="client channel"
rm -rf "$STEAM_ROOT"; rm -f "$CDN"/steam_client_*
mkmanifest "$T/client.zip" "" steamdeck_otherline
boot
[ "$RC" = 1 ] && grep -q "steam_client_${CHAN}_linuxarm64" <<<"$ERR" && [ ! -e "$STEAM_ROOT/steamrtarm64" ] \
  && ok "only the pinned channel's manifest is read; a missing one is an error naming it" || bad "rc=$RC err=$ERR"
CHAN=steamdeck_otherline; mkpin
boot
[ "$RC" = 0 ] && [ -x "$STEAM_ROOT/steamrtarm64/steam" ] && [ "$(cat "$BETA" 2>/dev/null)" = steamdeck_otherline ] \
  && ok "steam_client_<channel>_linuxarm64 is built from the pin, and package/beta follows it" || bad "rc=$RC beta=$(cat "$BETA" 2>&1) err=$ERR"
CHAN=steamdeck_rftest; mkpin; mkmanifest "$T/client.zip"

CASE="client download, bad checksum"
rm -rf "$STEAM_ROOT/steamrtarm64"
mkdir -p "$STEAM_ROOT/steamapps/common/Game"; echo data >"$STEAM_ROOT/steamapps/common/Game/data"
mkclient "$T/client.zip"; mkmanifest "$T/client.zip" "$(printf 'f%.0s' {1..64})"
boot
[ "$RC" = 1 ] && grep -q "sha256 mismatch" <<<"$ERR" && ok "refused (exit 1)" || bad "rc=$RC err=$ERR"
[ ! -e "$STEAM_ROOT/steamrtarm64" ] && ok "no half-set-up client left" || bad "steamrtarm64 exists"
[ -f "$STEAM_ROOT/steamapps/common/Game/data" ] && ok "the player's games are untouched" || bad "games gone"
[ -z "$(leftovers)" ] && ok "no temporary folders left" || bad "left: $(leftovers)"

CASE="leftover from a failed attempt"
mkdir -p "$STEAM_ROOT/steamrtarm64"; echo stale >"$STEAM_ROOT/steamrtarm64/builddate.txt"
echo steamdeck_publicbeta >"$BETA"
mkmanifest "$T/client.zip"
boot
[ "$RC" = 0 ] && [ -x "$STEAM_ROOT/steamrtarm64/steam" ] && ! grep -q stale "$STEAM_ROOT/steamrtarm64/builddate.txt" \
  && ok "a steamrtarm64/ without the client is replaced" || bad "rc=$RC err=$ERR"
[ "$(cat "$BETA")" = "$CHAN" ] && ok "installing the client sets package/beta to the channel" || bad "beta: $(cat "$BETA")"
[ -f "$STEAM_ROOT/steamapps/common/Game/data" ] && ok "the player's games are untouched" || bad "games gone"

CASE="manifest without the package"
rm -rf "$STEAM_ROOT/steamrtarm64"
printf '"linuxarm64"\n{\n\t"version"\t\t"1"\n}\n' >"$CDN/steam_client_${CHAN}_linuxarm64"
boot
[ "$RC" = 1 ] && grep -q "lists no bins_linuxarm64_linuxarm64" <<<"$ERR" && ok "an error that names the package" || bad "rc=$RC err=$ERR"

CASE="unsafe zip"
mkclient "$T/evil.zip" "../../escaped"; mkmanifest "$T/evil.zip"
boot
[ "$RC" = 1 ] && grep -q "unsafe path" <<<"$ERR" && ok "a path leaving the folder is refused" || bad "rc=$RC err=$ERR"
[ -z "$(find "$T" -name escaped)" ] && [ ! -e "$STEAM_ROOT/steamrtarm64" ] && ok "and nothing was written" || bad "$(find "$T" -name escaped)"

CASE="offline on a fresh card"
rm -rf "$CDN" "$DATA"
boot
[ "$RC" = 1 ] && [ -z "$OUT" ] && grep -q "could not download" <<<"$ERR" && ok "exit 1, says what it could not fetch" || bad "rc=$RC out=$OUT err=$ERR"

# ================================================================================================
# The wrapper, with the bootstrap stubbed: it puts a fake client where the real one is, and that
# records how it was called.
W="$T/w"; mkdir -p "$W"
cat >"$W/client" <<EOF
#!/usr/bin/env bash
n=\$(( \$(cat "$W/count" 2>/dev/null || echo 0) + 1 )); echo "\$n" >"$W/count"
{ echo "args: \$*"; echo "cwd: \$PWD"; echo "dbus: \${DBUS_SESSION_BUS_ADDRESS-unset}"; echo "rt: \${STEAM_RUNTIME-unset}"
  echo "ld: \${LD_LIBRARY_PATH-unset}"; echo "core: \$(ulimit -c)"; } >"$W/call\$n"
codes=(\$(cat "$W/codes")); c="\${codes[\$((n-1))]:-0}"
[ -e "$W/say" ] && cat "$W/say"   # the real client's lines, for steam-install's cases
if [ "\$c" = S ]; then   # S: run until TERMed, like the real client
  trap 'echo term >"$W/term"; exit 143' TERM; echo \$\$ >"$W/runpid"
  while :; do sleep 0.1; done
fi
exit "\$c"
EOF
cat >"$W/bootstrap" <<EOF
#!/usr/bin/env bash
[ -e "$W/boot-fails" ] && { echo "steam-bootstrap: no network" >&2; exit 1; }
mkdir -p "\$RETROFORGE_STEAM_ROOT/steamrtarm64"
cp "$W/client" "\$RETROFORGE_STEAM_ROOT/steamrtarm64/steam"; echo "\$RETROFORGE_STEAM_ROOT/steamrtarm64/steam"
EOF
chmod +x "$W/client" "$W/bootstrap"
# The x86 guest and the DXVK-Sarek block have their own suites (test-steam-x86-guest.sh,
# test-steam-compat-tools.sh). Here they would reach the real helpers, and on a device start real
# downloads into the test's home (1.4 GB): RETROFORGE_STEAM_X86_GUEST=0 turns the guest off. Starting a
# game without the client
# has its own suite too (test-steam-direct.sh): RETROFORGE_STEAM_DIRECT_CLI names no such file, so every
# launch here goes to the client.
# Keeping Steam running: the real retroforge-steam-keep, over a fake /proc ($P: a process is its
# folder there) and stub systemctl, systemd-run and kill in $W/bin. Off for the wrapper unless a case
# turns it on (it is on by default).
KEEP="$ROOT/rootfs/overlay/usr/bin/retroforge-steam-keep"
P="$W/proc"; SHMD="$W/shm"; mkdir -p "$P" "$W/bin" "$SHMD"
unset RETROFORGE_STEAM_KEEP RETROFORGE_STEAM_KEPT XDG_CONFIG_HOME OGUI_ID
cat >"$W/bin/systemctl" <<EOF
#!/usr/bin/env bash
echo "systemctl \$*" >>"$W/sysd.log"
case "\$*" in
  *is-active*retroforge-fexserver-*) [ -e "$W/fexunit-active" ] ;;
  *is-active*) [ -e "$W/unit-active" ] ;;
  *" stop "*) rm -f "$W/unit-active" ;;
esac
EOF
cat >"$W/bin/systemd-run" <<EOF
#!/usr/bin/env bash
case "\$*" in *--unit=retroforge-fexserver-*) printf '%s\n' "\$@" >"$W/fexrun.args"; touch "$W/fexunit-active"; exit 0 ;; esac
printf '%s\n' "\$@" >"$W/sdrun.args"
[ -e "$W/sdrun-fails" ] && { echo "Failed to connect to bus: No medium found" >&2; exit 1; }
touch "$W/unit-active"
EOF
cat >"$W/bin/fakekill" <<EOF
#!/usr/bin/env bash
sig=\$1; shift; echo "\$sig \$*" >>"$W/kills"
if [ "\$sig" = -TERM ]; then for p in "\$@"; do rm -rf "$P/\${p:?}"; done; fi
EOF
cat >"$W/bin/prlimit" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$W/prlimit.args"
EOF
chmod +x "$W/bin/systemctl" "$W/bin/systemd-run" "$W/bin/fakekill" "$W/bin/prlimit"
fakeproc() {  # fakeproc <pid> <ppid> <comm> <argv...>
  local pid=$1 ppid=$2 comm=$3; shift 3
  mkdir -p "$P/$pid"; echo "$comm" >"$P/$pid/comm"; printf '%s\0' "$@" >"$P/$pid/cmdline"
  echo "$pid ($comm) S $ppid $pid $pid 0 -1" >"$P/$pid/stat"
}
gone() { rm -rf "${P:?}/${1:?}"; }
until_true() { local _; for _ in $(seq 60); do eval "$1" && return 0; sleep 0.1; done; return 1; }
WENV=(env -u RETROFORGE_STEAM_ROOT -u XDG_DATA_HOME -u LD_LIBRARY_PATH HOME="$W/home" RETROFORGE_STEAM_BOOTSTRAP="$W/bootstrap"
      RETROFORGE_CPUINFO="$W/cpuinfo" RETROFORGE_STEAM_X86_GUEST=0 RETROFORGE_STEAM_DIRECT_CLI="$W/no-direct-cli"
      PATH="$W/bin:$PATH" RETROFORGE_STEAM_KEEP_CLI="$KEEP" RETROFORGE_PROC="$P" RETROFORGE_STEAM_KEEP_KILL="$W/bin/fakekill"
      RETROFORGE_STEAM_KEEP=off XDG_RUNTIME_DIR="$W/run" RETROFORGE_SHM="$SHMD")
KENV=(env HOME="$W/home" PATH="$W/bin:$PATH" RETROFORGE_PROC="$P" RETROFORGE_STEAM_KEEP_KILL="$W/bin/fakekill" XDG_RUNTIME_DIR="$W/run"
      RETROFORGE_SHM="$SHMD")
wrap() {  # wrap <exit codes of successive runs> [args...]
  echo "$1" >"$W/codes"; shift; rm -f "$W/count" "$W"/call*
  WOUT="$("${WENV[@]}" RETROFORGE_STEAM_KEEP="${RETROFORGE_STEAM_KEEP:-off}" bash "$WRAP" "$@" 2>"$W/err")"; WRC=$?
  WERR="$(cat "$W/err")"
}
WROOT="$W/home/.local/share/Steam"

CASE="wrapper: launch"
touch "$W/mybus"
DBUS_SESSION_BUS_ADDRESS="unix:path=$W/mybus" STEAM_RUNTIME=1 wrap 0 -gamepadui -silent steam://rungameid/42
[ "$WRC" = 0 ] && grep -qx "args: -noverifyfiles -gamepadui -silent steam://rungameid/42" "$W/call1" \
  && ok "runs steamrtarm64/steam itself, no runtime container, with the plugin's arguments and -noverifyfiles" \
  || bad "rc=$WRC $(cat "$W/call1" 2>&1) $WERR"
grep -qx "cwd: $WROOT/steamrtarm64" "$W/call1" && ok "from steamrtarm64 in the Steam folder (XDG default)" || bad "$(grep cwd "$W/call1")"
grep -qx "ld: $WROOT/steamrtarm64:$WROOT/steamrtarm64/video" "$W/call1" \
  && ok "LD_LIBRARY_PATH is the client's own libraries (libav*, libvpx)" || bad "$(grep ld: "$W/call1")"
[ "$(readlink "$W/home/.steam/steam")" = "$WROOT" ] && [ "$(readlink "$W/home/.steam/root")" = "$WROOT" ] \
  && ok "~/.steam/steam and ~/.steam/root point at it" || bad "links: $(ls -la "$W/home/.steam")"
grep -qx "dbus: unix:path=$W/mybus" "$W/call1" && ok "our own D-Bus address is kept" || bad "$(grep dbus "$W/call1")"
grep -qx "rt: unset" "$W/call1" && ok "STEAM_RUNTIME is unset" || bad "$(grep rt: "$W/call1")"
( ulimit -c unlimited 2>/dev/null; wrap 0 -gamepadui -silent steam://rungameid/42 )
grep -qx "core: 0" "$W/call1" && ok "no core files from the client or what it starts, whatever the session's limit" \
  || bad "$(grep core: "$W/call1")"
CCONF="$W/home/.config/retroforge/game-core-dumps.conf"; mkdir -p "$(dirname "$CCONF")"; echo "GAME_CORE_DUMPS=on" >"$CCONF"
( ulimit -c unlimited 2>/dev/null; wrap 0 -gamepadui -silent steam://rungameid/42 )
grep -qx "core: unlimited" "$W/call1" && ok "Settings > General > Game crash dumps on: the session's core limit" \
  || bad "Game crash dumps on: $(grep core: "$W/call1")"
rm -f "$CCONF"
[ -z "$WERR" ] && ok "nothing on stderr" || bad "stderr: $WERR"
[ "$(readlink "$W/home/.steam/bin64")" = "$WROOT/ubuntu12_64" ] && [ "$(readlink "$W/home/.steam/bin32")" = "$WROOT/ubuntu12_32" ] \
  && ok "~/.steam/bin64 and bin32 point at ubuntu12_64 and ubuntu12_32 (the overlay's preload paths)" || bad "links: $(ls -la "$W/home/.steam")"
[ "$(readlink "$W/home/.steam/sdkarm64")" = "$WROOT/linuxarm64" ] \
  && ok "~/.steam/sdkarm64 points at linuxarm64 (every game launches through its steam-launch-wrapper)" || bad "links: $(ls -la "$W/home/.steam")"

CASE="wrapper: Steam Client not installed"
cp "$W/bootstrap" "$W/bootstrap.real"
printf '#!/usr/bin/env bash\necho "steam-bootstrap: Steam Client is not installed: install it from Main menu > Emulators > Steam Client" >&2\nexit 10\n' >"$W/bootstrap"
wrap 0 steam://rungameid/42
[ "$WRC" = 1 ] && [ ! -e "$W/count" ] && ok "exit 1, the client is not started" || bad "rc=$WRC runs=$(cat "$W/count" 2>/dev/null)"
[ "$(grep -c . <<<"$WERR")" = 1 ] && grep -q "Main menu > Emulators > Steam Client" <<<"$WERR" \
  && ok "the bootstrap's one line says where to install it, and nothing more" || bad "stderr: $WERR"
mv "$W/bootstrap.real" "$W/bootstrap"

CASE="wrapper: LD_LIBRARY_PATH set"
echo 0 >"$W/codes"; rm -f "$W/count" "$W"/call*
"${WENV[@]}" LD_LIBRARY_PATH=/opt/x bash "$WRAP" 2>"$W/err"   # WENV unsets it, so it goes after
grep -qx "ld: $WROOT/steamrtarm64:$WROOT/steamrtarm64/video:/opt/x" "$W/call1" \
  && ok "the client's libraries come first, the caller's stay after them" || bad "$(grep ld: "$W/call1")"

CASE="wrapper: foreign D-Bus"
DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/0/bus" wrap 0
grep -qx "dbus: unset" "$W/call1" && ok "a bus socket that is not ours is dropped" || bad "$(grep dbus "$W/call1")"

CASE="wrapper: client checksums"
wrap 0 -steamdeck -exitsteam
grep -qx "args: -steamdeck -exitsteam" "$W/call1" \
  && ok "Steam Client's install (-exitsteam) still verifies the files it installed: no -noverifyfiles" \
  || bad "$(cat "$W/call1" 2>&1)"
wrap 0 -verifyfiles steam://rungameid/1
grep -qx "args: -verifyfiles steam://rungameid/1" "$W/call1" && ok "nor a run asked to verify (-verifyfiles)" \
  || bad "$(cat "$W/call1" 2>&1)"

CASE="wrapper: update restart"
wrap "42 42 7" steam://rungameid/1
[ "$(cat "$W/count")" = 3 ] && [ "$WRC" = 7 ] && ok "exit 42 starts the client again; the final status is returned" || bad "runs=$(cat "$W/count") rc=$WRC"
grep -qx "args: -noverifyfiles steam://rungameid/1" "$W/call3" && ok "with the same arguments" || bad "$(cat "$W/call3")"

CASE="wrapper: stopped by a signal"
echo S >"$W/codes"; rm -f "$W/count" "$W"/call* "$W/term" "$W/runpid"
"${WENV[@]}" bash "$WRAP" steam://rungameid/1 2>"$W/err" &
wpid=$!
for _ in $(seq 50); do [ -s "$W/runpid" ] && break; sleep 0.1; done
kill -TERM "$wpid"; wait "$wpid"; WRC=$?
[ -e "$W/term" ] && ok "a TERM to the wrapper reaches the client" || bad "the client never got TERM"
[ "$WRC" = 143 ] && [ "$(cat "$W/count")" = 1 ] && ok "and the wrapper exits with its status, without restarting" \
  || bad "rc=$WRC runs=$(cat "$W/count")"
pid="$(cat "$W/runpid" 2>/dev/null)"
[ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null && ok "nothing is left running" || { bad "client still running"; kill "$pid" 2>/dev/null; }

CASE="wrapper: bootstrap fails"
touch "$W/boot-fails"
wrap 0
[ "$WRC" = 1 ] && [ ! -e "$W/count" ] && grep -q "could not be set up" <<<"$WERR" && ok "exit 1, nothing run" || bad "rc=$WRC err=$WERR"
rm -f "$W/boot-fails"

CASE="wrapper: ~/.steam/steam is a real folder"
rm -f "$W/home/.steam/steam"; mkdir -p "$W/home/.steam/steam"
wrap 0
[ -d "$W/home/.steam/steam" ] && [ ! -L "$W/home/.steam/steam" ] && grep -q "leaving it alone" <<<"$WERR" \
  && ok "left alone, and said so" || bad "$(ls -la "$W/home/.steam")"
rmdir "$W/home/.steam/steam"

CASE="wrapper: SIGILL"
echo "Features	: fp asimd evtstrm crc32 cpuid" >"$W/cpuinfo"
wrap 132
[ "$WRC" = 132 ] && grep -q "kernel/patches/0025" <<<"$WERR" && ok "on a CPU without LSE it names the kernel patch" || bad "rc=$WRC err=$WERR"
echo "Features	: fp asimd evtstrm aes crc32 atomics fphp" >"$W/cpuinfo"
wrap 132
! grep -q "0025" <<<"$WERR" && ok "with LSE it does not" || bad "err=$WERR"

CASE="wrapper: the client fails"
wrap 1
[ "$WRC" = 1 ] && grep -q "the client exited with status 1" <<<"$WERR" && ok "a failed start is said" || bad "rc=$WRC err=$WERR"
wrap 0
! grep -q "exited with status" <<<"$WERR" && ok "a clean exit says nothing" || bad "err=$WERR"

# ================================================================================================
# Keeping Steam running between games.
CONF="$W/home/.config/retroforge/steam.conf"
STEAM_REAPER="$WROOT/linuxarm64/reaper"
SLOG="$WROOT/logs/console_log.txt"   # Steam's own log: one line per step of a launch
reset_keep() {
  rm -f "$W/unit-active" "$W/sdrun.args" "$W/sdrun-fails" "$W/kills" "$W/sysd.log" "$W/count" "$W"/call* "$CONF" "$SLOG" "$WROOT/logs/webhelper.txt" "$W/fexrun.args" "$W/fexunit-active"
  rm -rf "$W/run/retroforge-steam-follow"
  local d; for d in "$P"/*; do [ -d "$d" ] && gone "${d##*/}"; done
  echo 0 >"$W/codes"
}
step() {  # step <appid> <step> [stamp]: a line of Steam's log, now unless stamped
  mkdir -p "${SLOG%/*}"
  printf '[%s] GameAction [AppID %s, ActionID 1] : LaunchApp changed task to %s with ""\n' "${3:-$(date '+%F %T')}" "$1" "$2" >>"$SLOG"
}
bg_wrap() {  # bg_wrap [VAR=value...] -- args...: the wrapper in the background, as OGUI's launch
  local -a vars=()
  while [ "$1" != -- ]; do vars+=("$1"); shift; done; shift
  "${WENV[@]}" "${vars[@]}" bash "$WRAP" "$@" 2>"$W/err" &
  wpid=$!
}
finish() { until_true '! kill -0 "$wpid" 2>/dev/null'; wait "$wpid"; WRC=$?; }

CASE="keep: the setting"
reset_keep
out="$("${KENV[@]}" bash "$KEEP" status 2>"$W/kerr")"
[ "$out" = on ] && grep -q "the default" "$W/kerr" && ok "on by default" || bad "out=$out $(cat "$W/kerr")"
mkdir -p "${CONF%/*}"; printf '# mine\nDXVK_SAREK=on\n' >"$CONF"
out="$("${KENV[@]}" bash "$KEEP" on 2>"$W/kerr")"
[ "$out" = on ] && grep -qx "KEEP_RUNNING=on" "$CONF" && grep -qx "DXVK_SAREK=on" "$CONF" && grep -qx "# mine" "$CONF" \
  && ok "on is saved beside the DXVK-Sarek setting, which stays" || bad "out=$out conf=$(cat "$CONF")"
[ "$("${KENV[@]}" bash "$KEEP" status 2>/dev/null)" = on ] && ok "and read back" || bad "status after on"
[ "$("${KENV[@]}" RETROFORGE_STEAM_KEEP=off bash "$KEEP" status 2>/dev/null)" = off ] \
  && ok "RETROFORGE_STEAM_KEEP overrides the file" || bad "override ignored"
"${KENV[@]}" bash "$KEEP" sideways >/dev/null 2>&1; [ $? = 2 ] && ok "a bad invocation is exit 2" || bad "bad invocation"

CASE="keep: Steam's launches"
reset_keep
fakeproc 4242 1 reaper "$STEAM_REAPER" SteamLaunch AppId=42 -- "$WROOT/linuxarm64/steam-launch-wrapper" -- game
fakeproc 4343 1 reaper "$STEAM_REAPER" SteamLaunch AppId=43 -- game
fakeproc 5000 1 reaper /usr/share/opengamepadui/reaper SteamLaunch AppId=42 -- env steam steam://rungameid/42
fakeproc 5100 1 reaper "$STEAM_REAPER" SteamLaunch -- game AppId=42
fakeproc 5200 1 bash bash -c "reaper SteamLaunch AppId=42"
[ "$("${KENV[@]}" bash "$KEEP" games 42)" = 4242 ] \
  && ok "app 42's launch is Steam's reaper with AppId=42, not OGUI's reaper with the same arguments" \
  || bad "games 42: $("${KENV[@]}" bash "$KEEP" games 42 | tr '\n' ' ')"
[ "$("${KENV[@]}" bash "$KEEP" games | sort | tr '\n' ' ')" = "4242 4343 " ] \
  && ok "without an app id, every Steam launch; an AppId= after -- (the game's own argument) is none" \
  || bad "games: $("${KENV[@]}" bash "$KEEP" games | tr '\n' ' ')"

CASE="keep: ending a launch"
fakeproc 4244 4242 steam-launch-wr x; fakeproc 4245 4244 "game (main)" x; fakeproc 4300 1 other x
"${KENV[@]}" bash "$KEEP" end 42 2>"$W/kerr"
[ "$(cat "$W/kills" 2>/dev/null)" = "-TERM 4242 4244 4245" ] \
  && ok "TERM to Steam's reaper and everything under it, a command name with spaces and parens too" \
  || bad "kills: $(cat "$W/kills" 2>&1) $(cat "$W/kerr")"
[ -d "$P/4300" ] && [ -d "$P/4343" ] && [ -d "$P/5000" ] && ok "nothing else: another game, OGUI's reaper" || bad "$(ls "$P")"

CASE="keep: pausing a launch"
reset_keep
PQ="$W/run/retroforge-steam-pause"
fakeproc 4242 1 reaper "$STEAM_REAPER" SteamLaunch AppId=42 -- "$WROOT/linuxarm64/steam-launch-wrapper" -- game
fakeproc 4244 4242 steam-launch-wr x; fakeproc 4245 4244 "game (main)" x
fakeproc 4343 1 reaper "$STEAM_REAPER" SteamLaunch AppId=43 -- game
fakeproc 5000 1 reaper /usr/share/opengamepadui/reaper SteamLaunch AppId=42 -- env steam steam://rungameid/42
"${KENV[@]}" bash "$KEEP" pause 42 2>"$W/kerr"; rc=$?
[ "$rc" = 0 ] && [ "$(cat "$W/kills" 2>/dev/null)" = "-STOP 4242 4244 4245" ] \
  && ok "pause STOPs Steam's reaper and everything under it, not another game or OGUI's reaper" \
  || bad "rc=$rc kills: $(cat "$W/kills" 2>&1) $(cat "$W/kerr")"
rm -f "$W/kills"
"${KENV[@]}" bash "$KEEP" resume 42 2>"$W/kerr"; rc=$?
[ "$rc" = 0 ] && [ "$(cat "$W/kills" 2>/dev/null)" = "-CONT 4242 4244 4245" ] && [ ! -e "$PQ/42" ] \
  && ok "resume CONTs the same processes and clears the request" \
  || bad "rc=$rc kills: $(cat "$W/kills" 2>&1) $(ls "$PQ" 2>&1) $(cat "$W/kerr")"
rm -f "$W/kills"
"${KENV[@]}" bash "$KEEP" pause 44 2>"$W/kerr"; rc=$?
[ "$rc" = 1 ] && [ ! -e "$W/kills" ] && [ ! -e "$PQ/44" ] \
  && ok "exit 1 for an app with no launch running, and nothing is signalled" \
  || bad "rc=$rc kills: $(cat "$W/kills" 2>&1) $(ls "$PQ" 2>&1)"
# OGUI starts both in the background: hold the lock while a pause and then a resume are asked for.
exec 8>>"$PQ/lock"; flock 8
"${KENV[@]}" bash "$KEEP" pause 42 2>/dev/null & p1=$!
until_true '[ "$(cat "$PQ/42" 2>/dev/null)" = STOP ]'
"${KENV[@]}" bash "$KEEP" resume 42 2>/dev/null & p2=$!
until_true '[ "$(cat "$PQ/42" 2>/dev/null)" = CONT ]'
flock -u 8; exec 8>&-
wait "$p1" "$p2"
[ "$(cat "$W/kills" 2>/dev/null)" = "-CONT 4242 4244 4245" ] && [ ! -e "$PQ/42" ] \
  && ok "a pause and a resume started together end in the state asked for last, whichever ran first" \
  || bad "kills: $(cat "$W/kills" 2>&1) $(ls "$PQ" 2>&1)"

CASE="keep: games started from Steam's UI"
reset_keep
FQ="$W/run/retroforge-steam-follow"
fakeproc 4242 1 reaper "$STEAM_REAPER" SteamLaunch AppId=42 -- game
fakeproc 4244 4242 "game (main)" x
fakeproc 4343 1 reaper "$STEAM_REAPER" SteamLaunch AppId=43 -- game
fakeproc 4345 4343 "game (main)" x
fakeproc 6000 1 bash bash /usr/bin/steam steam://rungameid/42   # OGUI's launch of 42, still running
"${KENV[@]}" bash "$KEEP" follow 42 6000 2>"$W/kerr" && "${KENV[@]}" bash "$KEEP" follow 43 6999 2>>"$W/kerr"
[ "$(cat "$FQ/6000" 2>/dev/null)" = 42 ] && ok "follow records the app id under the launch's PID" || bad "$(ls "$FQ" 2>&1) $(cat "$W/kerr")"
[ "$("${KENV[@]}" bash "$KEEP" games ui | tr '\n' ' ')" = "4343 " ] && [ ! -e "$FQ/6999" ] \
  && ok "ui: the launches no live launch follows (a record of a gone launch does not count, and goes)" \
  || bad "games ui: $("${KENV[@]}" bash "$KEEP" games ui | tr '\n' ' ') $(ls "$FQ" 2>&1)"
"${KENV[@]}" bash "$KEEP" pause ui 2>"$W/kerr"; rc=$?
[ "$rc" = 0 ] && [ "$(cat "$W/kills" 2>/dev/null)" = "-STOP 4343 4345" ] && grep -q "paused the games started from Steam's UI (app 43)" "$W/kerr" \
  && ok "pause ui STOPs those, not the game OGUI follows" || bad "rc=$rc kills: $(cat "$W/kills" 2>&1) $(cat "$W/kerr")"
rm -f "$W/kills"
"${KENV[@]}" bash "$KEEP" resume ui 2>"$W/kerr"; rc=$?
[ "$rc" = 0 ] && [ "$(cat "$W/kills" 2>/dev/null)" = "-CONT 4343 4345" ] && ok "resume ui CONTs them" || bad "rc=$rc kills: $(cat "$W/kills" 2>&1)"
rm -f "$W/kills"
"${KENV[@]}" bash "$KEEP" end ui 2>"$W/kerr"
[ "$(cat "$W/kills" 2>/dev/null)" = "-TERM 4343 4345" ] && [ -d "$P/4242" ] && [ -d "$P/4244" ] \
  && ok "end ui ends them; the followed game runs on" || bad "kills: $(cat "$W/kills" 2>&1) $(cat "$W/kerr")"
rm -f "$W/kills"
"${KENV[@]}" bash "$KEEP" pause ui 2>"$W/kerr"; rc=$?
[ "$rc" = 1 ] && [ ! -e "$W/kills" ] && [ ! -s "$W/kerr" ] && ok "none left: exit 1, no signal and no line (asked at every menu over Steam's UI)" \
  || bad "rc=$rc kills: $(cat "$W/kills" 2>&1) err: $(cat "$W/kerr")"
"${KENV[@]}" bash "$KEEP" follow 42 x >/dev/null 2>&1; rc1=$?
"${KENV[@]}" bash "$KEEP" end uix >/dev/null 2>&1; rc2=$?
[ "$rc1" = 2 ] && [ "$rc2" = 2 ] && ok "a bad PID or app id is exit 2" || bad "follow rc=$rc1 end rc=$rc2"

CASE="keep: a launch's steps"
reset_keep
since="$(date '+%F %T')"
[ "$("${KENV[@]}" RETROFORGE_STEAM_ROOT="$WROOT" bash "$KEEP" launch 42 "$since")" = unknown ] \
  && ok "unknown without Steam's log" || bad "no log: $("${KENV[@]}" RETROFORGE_STEAM_ROOT="$WROOT" bash "$KEEP" launch 42 "$since")"
step 42 Completed "2020-01-01 00:00:00"; step 42 ProcessingInstallScript; step 43 Completed
echo "[$(date '+%F %T')] GameAction [AppID 42, ActionID 1] : LaunchApp waiting for user response to ShowLaunchOption \"\"" >>"$SLOG"
[ "$("${KENV[@]}" RETROFORGE_STEAM_ROOT="$WROOT" bash "$KEEP" launch 42 "$since")" = ProcessingInstallScript ] \
  && ok "the last step of that app since the launch: an earlier launch's Completed and another app's do not count" \
  || bad "launch 42: $("${KENV[@]}" RETROFORGE_STEAM_ROOT="$WROOT" bash "$KEEP" launch 42 "$since") $(cat "$SLOG")"
[ -z "$("${KENV[@]}" RETROFORGE_STEAM_ROOT="$WROOT" bash "$KEEP" launch 44 "$since")" ] \
  && ok "nothing before Steam has picked a launch up" || bad "launch 44"

CASE="keep: off stops an idle kept Steam"
reset_keep; touch "$W/unit-active"
fakeproc 4343 1 reaper "$STEAM_REAPER" SteamLaunch AppId=43 -- game
"${KENV[@]}" bash "$KEEP" off >/dev/null 2>"$W/kerr"
[ -e "$W/unit-active" ] && grep -q "stops when it ends" "$W/kerr" && ok "not while it runs a game" || bad "$(cat "$W/sysd.log") $(cat "$W/kerr")"
gone 4343
"${KENV[@]}" bash "$KEEP" off >/dev/null 2>&1
[ ! -e "$W/unit-active" ] && grep -q "stop retroforge-steam.service" "$W/sysd.log" && ok "stopped once it runs none" || bad "$(cat "$W/sysd.log")"

CASE="keep: off"
reset_keep
wrap 0 -gamepadui -silent steam://rungameid/42
[ "$(cat "$W/count")" = 1 ] && [ ! -e "$W/sdrun.args" ] && [ "$WRC" = 0 ] \
  && ok "the client runs with the launch, as before; no unit" || bad "rc=$WRC runs=$(cat "$W/count" 2>&1) $WERR"

CASE="keep: a game, Steam not running"
reset_keep
bg_wrap RETROFORGE_STEAM_KEEP=on OGUI_ID=Hades DISPLAY=:1 ENABLE_MESA_VRAM_REPORT_LIMIT=1 VK_VRAM_REPORT_LIMIT_HEAP_SIZE=512 \
  VK_VRAM_REPORT_LIMIT_DEVICE_ID=6010000 -- -gamepadui -silent steam://rungameid/42
until_true '[ -s "$W/sdrun.args" ]'
A="$(cat "$W/sdrun.args" 2>/dev/null)"
grep -qx -- "--setenv=ENABLE_MESA_VRAM_REPORT_LIMIT=1" <<<"$A" && grep -qx -- "--setenv=VK_VRAM_REPORT_LIMIT_HEAP_SIZE=512" <<<"$A" \
  && grep -qx -- "--setenv=VK_VRAM_REPORT_LIMIT_DEVICE_ID=6010000" <<<"$A" \
  && ok "with the shell's VRAM report limit, which its games get (mesa patch 0025)" || bad "systemd-run: $A"
grep -qx -- "--user" <<<"$A" && grep -qx -- "--unit=retroforge-steam" <<<"$A" && grep -qx -- "--collect" <<<"$A" \
  && ok "starts the user unit retroforge-steam.service" || bad "systemd-run: $A"
grep -qx -- "--setenv=OGUI_ID=Steam" <<<"$A" && ! grep -q -- "--setenv=OGUI_ID=Hades" <<<"$A" \
  && ok "its OGUI_ID is Steam (Steam's UI launches find its windows), not the game's" || bad "systemd-run: $A"
grep -qx -- "--setenv=DISPLAY=:1" <<<"$A" && grep -qx -- "--setenv=RETROFORGE_STEAM_KEPT=1" <<<"$A" \
  && ok "with the launch's environment, and marked as the kept client" || bad "systemd-run: $A"
[ "$(tail -4 <<<"$A" | tr '\n' ' ')" = "$WRAP -gamepadui -silent steam://rungameid/42 " ] \
  && ok "running this wrapper with the launch's arguments" || bad "command: $(tail -4 <<<"$A" | tr '\n' ' ')"
[ ! -e "$W/count" ] && ok "the client is not run under OGUI's launch" || bad "runs=$(cat "$W/count")"
# As Hades on the Pocket FIT (2026-10-22): the install scripts under one reaper, then the game
# under another.
step 42 Completed "2020-01-01 00:00:00"; step 42 ProcessingInstallScript
fakeproc 4241 1 reaper "$STEAM_REAPER" SteamLaunch AppId=42 -- install-script
sleep 1.5; gone 4241; sleep 2.2
kill -0 "$wpid" 2>/dev/null && ok "the install scripts' reaper ending is not the game ending" || bad "exited after the install scripts: $(cat "$W/err")"
step 42 Completed; fakeproc 4242 1 reaper "$STEAM_REAPER" SteamLaunch AppId=42 -- game
sleep 2.2
kill -0 "$wpid" 2>/dev/null && ok "once Steam has created the game's process, the launch lasts while its reaper runs" || bad "exited early: $(cat "$W/err")"
gone 4242
finish
[ "$WRC" = 0 ] && [ -e "$W/unit-active" ] && ok "and ends with it, exit 0; Steam keeps running" || bad "rc=$WRC $(cat "$W/err")"

CASE="FEX: the game's FEXServer first"
reset_keep; touch "$W/unit-active"
mkdir -p "$W/fex/usr/bin" "$WROOT/steamapps/compatdata/42/fex-emu/AppConfig"; : >"$WROOT/steamapps/compatdata/42/fex-emu/Config.json"
FAC="$WROOT/steamapps/compatdata/42/fex-emu/AppConfig"; echo '{"Config": {"Multiblock": "1"}}' >"$FAC/bash.json"
printf '#!/bin/sh\n' >"$W/fex/usr/bin/FEXServer"; chmod +x "$W/fex/usr/bin/FEXServer"
fakeproc 4242 1 reaper "$STEAM_REAPER" SteamLaunch AppId=42 -- game
bg_wrap RETROFORGE_STEAM_KEEP=on RETROFORGE_STEAM_FEX="$W/fex" -- -gamepadui -silent steam://rungameid/42
until_true '[ -e "$W/call1" ]'
A="$(cat "$W/fexrun.args" 2>/dev/null)"
grep -qx -- "--unit=retroforge-fexserver-42" <<<"$A" && grep -qx -- "--setenv=STEAM_COMPAT_DATA_PATH=$WROOT/steamapps/compatdata/42" <<<"$A" \
  && grep -qx -- "--setenv=FEX_PORTABLE=1" <<<"$A" && grep -qx -- "--user" <<<"$A" && grep -qx -- "SuccessExitStatus=1" <<<"$A" \
  && [ "$(tail -4 <<<"$A" | tr '\n' ' ')" = "$W/fex/usr/bin/FEXServer -f -p 60 " ] \
  && ok "a game FEX's tool has set up: its FEXServer starts first, a user unit, 60 s after its last client" || bad "$A"
[ -e "$W/fexunit-active" ] && [ -e "$W/call1" ] && ok "and the launch still goes to the kept client" || bad "$(cat "$W/call1" 2>&1)"
[ "$(ls "$FAC" | wc -l)" = 54 ] && [ "$(cat "$FAC/x86_64-linux-gnu-capsule-capture-libs.json")" = '{"Config": {"Multiblock": "0"}}' ] \
  && [ "$(cat "$FAC/ld-linux-x86-64.so.2.json")" = '{"Config": {"Multiblock": "0"}}' ] \
  && ok "the runtime's x86 helpers run without Multiblock, a file each in the game's FEX folder" || bad "$(ls "$FAC")"
[ "$(cat "$FAC/bash.json")" = '{"Config": {"Multiblock": "1"}}' ] && ok "one already there (the player's own) is left as it is" || bad "$(cat "$FAC/bash.json")"
kill -TERM "$wpid"; wait "$wpid"
rm -f "$W/fexrun.args" "$W/count" "$W"/call*
bg_wrap RETROFORGE_STEAM_KEEP=on RETROFORGE_STEAM_FEX="$W/fex" -- -gamepadui -silent steam://rungameid/42
until_true '[ -e "$W/call1" ]'
[ ! -e "$W/fexrun.args" ] && ok "one already running is left as it is" || bad "started again: $(cat "$W/fexrun.args")"
kill -TERM "$wpid"; wait "$wpid"
reset_keep; touch "$W/unit-active"; printf 'FEX describe\tFEX-2607\nFEX bash\t1cc4b93\n' >"$W/fex/VERSIONS.txt"
bg_wrap RETROFORGE_STEAM_KEEP=on RETROFORGE_STEAM_FEX="$W/fex" -- -gamepadui -silent steam://rungameid/42
until_true '[ -e "$W/call1" ]'
[ -e "$W/fexrun.args" ] && ok "FEX-2607 (the tool's public branch): its FEXServer starts first" || bad "not started: $(cat "$W/err")"
kill -TERM "$wpid"; wait "$wpid"
# From FEX 2611, Steam's FEX server manager deletes the server's socket at the session's end: one of
# ours stayed up, unreachable, and the next launch could not connect
reset_keep; touch "$W/unit-active"; rm -r "$FAC"; printf 'FEX describe\tFEX-2611.1\nFEX bash\t8f92e80\n' >"$W/fex/VERSIONS.txt"
bg_wrap RETROFORGE_STEAM_KEEP=on RETROFORGE_STEAM_FEX="$W/fex" -- -gamepadui -silent steam://rungameid/42
until_true '[ -e "$W/call1" ]'
[ ! -e "$W/fexrun.args" ] && ok "FEX 2611 on: none (Steam's FEX server manager runs the server and deletes its socket)" || bad "started: $(cat "$W/fexrun.args")"
[ "$(cat "$FAC/ld-linux-x86-64.so.2.json" 2>/dev/null)" = '{"Config": {"Multiblock": "0"}}' ] \
  && ok "and the runtime's helpers still run without Multiblock" || bad "$(ls "$FAC" 2>&1)"
kill -TERM "$wpid"; wait "$wpid"
rm -f "$W/fex/VERSIONS.txt"
reset_keep; touch "$W/unit-active"; rm -f "$WROOT/steamapps/compatdata/42/fex-emu/Config.json"; rm -r "$FAC"
bg_wrap RETROFORGE_STEAM_KEEP=on RETROFORGE_STEAM_FEX="$W/fex" -- -gamepadui -silent steam://rungameid/42
until_true '[ -e "$W/call1" ]'
[ ! -e "$W/fexrun.args" ] && [ ! -e "$FAC" ] && ok "a game FEX's tool has not set up (a native one, Proton, a first launch): none, nor files" || bad "$(cat "$W/fexrun.args"; ls "$FAC")"
kill -TERM "$wpid"; wait "$wpid"
reset_keep; touch "$W/unit-active"; : >"$WROOT/steamapps/compatdata/42/fex-emu/Config.json"
bg_wrap RETROFORGE_STEAM_KEEP=on RETROFORGE_STEAM_FEX="$W/fex" -- -gamepadui -steamos3 steam://open/bigpicture
until_true '[ -e "$W/call1" ]'
[ ! -e "$W/fexrun.args" ] && [ ! -e "$FAC" ] && ok "nor for Steam's UI" || bad "$(cat "$W/fexrun.args"; ls "$FAC")"
kill -TERM "$wpid"; wait "$wpid"
gone 4242; rm -rf "$WROOT/steamapps/compatdata/42/fex-emu"

CASE="keep: a game, Steam kept"   # and no Steam log: the first reaper seen is the game's
reset_keep; touch "$W/unit-active"
fakeproc 4242 1 reaper "$STEAM_REAPER" SteamLaunch AppId=42 -- game
bg_wrap RETROFORGE_STEAM_KEEP=on -- -gamepadui -silent steam://rungameid/42
until_true '[ -e "$W/call1" ]'
grep -qx "args: -gamepadui -silent steam://rungameid/42" "$W/call1" && grep -qx "cwd: $WROOT/steamrtarm64" "$W/call1" \
  && grep -qx "ld: $WROOT/steamrtarm64:$WROOT/steamrtarm64/video" "$W/call1" && [ ! -e "$W/sdrun.args" ] \
  && ok "the launch's arguments are handed to the kept client (a second client process), no new unit" || bad "$(cat "$W/call1" 2>&1)"
sleep 0.5
[ "$(cat "$W/run/retroforge-steam-follow/$wpid" 2>/dev/null)" = 42 ] \
  && ok "the launch follows app 42, so Steam's UI never takes it for a game started from it" || bad "follow: $(ls "$W/run/retroforge-steam-follow" 2>&1)"
kill -TERM "$wpid"; wait "$wpid"; WRC=$?
[ "$WRC" = 143 ] && [ "$(cat "$W/kills" 2>/dev/null)" = "-TERM 4242" ] && [ -e "$W/unit-active" ] \
  && ok "Exit from OGUI's menu (TERM) ends the game's launch, not Steam" || bad "rc=$WRC kills=$(cat "$W/kills" 2>&1) $(cat "$W/sysd.log")"

CASE="keep: Steam does not start the game"
reset_keep; touch "$W/unit-active"
fakeproc 5000 1 reaper /usr/share/opengamepadui/reaper SteamLaunch AppId=42 -- env steam
bg_wrap RETROFORGE_STEAM_KEEP=on RETROFORGE_STEAM_LAUNCH_WAIT=1 -- steam://rungameid/42
finish
[ "$WRC" = 1 ] && grep -q "did not start app 42 within 1 s" "$W/err" \
  && ok "gives up after RETROFORGE_STEAM_LAUNCH_WAIT s, and says where to look (OGUI's own reaper is not the game)" || bad "rc=$WRC $(cat "$W/err")"
reset_keep; touch "$W/unit-active"
bg_wrap RETROFORGE_STEAM_KEEP=on -- steam://rungameid/42
until_true '[ -e "$W/call1" ]'; rm -f "$W/unit-active"
finish
[ "$WRC" = 1 ] && grep -q "stopped before it started app 42" "$W/err" && ok "or as soon as the kept Steam stops" || bad "rc=$WRC $(cat "$W/err")"
reset_keep; touch "$W/unit-active"
bg_wrap RETROFORGE_STEAM_KEEP=on -- steam://rungameid/42
until_true '[ -e "$W/call1" ]'; step 42 Failed
finish
[ "$WRC" = 1 ] && grep -q "could not start app 42" "$W/err" && ok "or when Steam refuses the launch" || bad "rc=$WRC $(cat "$W/err")"

CASE="keep: launched again while it runs"
reset_keep; touch "$W/unit-active"
fakeproc 4242 1 reaper "$STEAM_REAPER" SteamLaunch AppId=42 -- game
bg_wrap RETROFORGE_STEAM_KEEP=on -- steam://rungameid/42
until_true '[ -e "$W/call1" ]'; step 42 Failed   # AppError_16
sleep 2.2
kill -0 "$wpid" 2>/dev/null && ok "Steam refuses it (the game already runs): the launch follows the running game" || bad "exited: $(cat "$W/err")"
gone 4242
finish
[ "$WRC" = 0 ] && ok "and ends with it" || bad "rc=$WRC $(cat "$W/err")"

CASE="keep: the kept client's core limit, at each launch handed to it"
for want in 0 unlimited; do
  reset_keep; touch "$W/unit-active"; rm -f "$W/prlimit.args"
  mkdir -p "$W/home/.steam"; fakeproc 7100 1 steam "$WROOT/steamrtarm64/steam"; echo 7100 >"$W/home/.steam/steam.pid"
  [ "$want" = unlimited ] && echo "GAME_CORE_DUMPS=on" >"$CCONF"
  fakeproc 4242 1 reaper "$STEAM_REAPER" SteamLaunch AppId=42 -- game
  bg_wrap RETROFORGE_STEAM_KEEP=on -- steam://rungameid/42
  until_true '[ -e "$W/call1" ]'
  grep -qx -- "--pid 7100 --core=$want:" "$W/prlimit.args" 2>/dev/null \
    && ok "set to $want (soft) before the client gets the launch: its game inherits Game crash dumps" \
    || bad "prlimit: $(cat "$W/prlimit.args" 2>&1)"
  gone 4242; finish; gone 7100; rm -f "$W/home/.steam/steam.pid" "$CCONF"
done

CASE="keep: turned off during a game"
reset_keep; touch "$W/unit-active"
fakeproc 4242 1 reaper "$STEAM_REAPER" SteamLaunch AppId=42 -- game
bg_wrap RETROFORGE_STEAM_KEEP=off -- steam://rungameid/42
until_true '[ -e "$W/call1" ]'
[ ! -e "$W/sdrun.args" ] && ok "a kept client still gets the launch" || bad "a unit was started"
gone 4242
finish
[ "$WRC" = 0 ] && [ ! -e "$W/unit-active" ] && ok "and is stopped when the game ends" || bad "rc=$WRC $(cat "$W/sysd.log" 2>&1)"

CASE="keep: Steam's UI"
reset_keep; touch "$W/unit-active"
bg_wrap RETROFORGE_STEAM_KEEP=on -- -gamepadui -steamos3 -steampal -steamdeck
until_true '[ -e "$W/call1" ]'
grep -qx "args: -gamepadui -steamos3 -steampal -steamdeck" "$W/call1" && ok "handed to the kept client" || bad "$(cat "$W/call1" 2>&1)"
sleep 1.2
kill -0 "$wpid" 2>/dev/null && ok "and stays while it runs" || bad "exited: $(cat "$W/err")"
rm -f "$W/unit-active"
finish
[ "$WRC" = 0 ] && ok "until it stops" || bad "rc=$WRC"
reset_keep; touch "$W/unit-active"
bg_wrap RETROFORGE_STEAM_KEEP=on -- -gamepadui
until_true '[ -e "$W/call1" ]'; sleep 0.3
kill -TERM "$wpid"; wait "$wpid"; WRC=$?
[ "$WRC" = 143 ] && [ -e "$W/unit-active" ] && [ ! -e "$W/kills" ] && ok "or OGUI stops it: Steam keeps running" || bad "rc=$WRC $(cat "$W/kills" 2>&1)"
reset_keep; touch "$W/unit-active"
fakeproc 4242 1 reaper "$STEAM_REAPER" SteamLaunch AppId=42 -- game
fakeproc 4343 1 reaper "$STEAM_REAPER" SteamLaunch AppId=43 -- game
fakeproc 6000 1 bash bash /usr/bin/steam steam://rungameid/42
"${KENV[@]}" bash "$KEEP" follow 42 6000
bg_wrap RETROFORGE_STEAM_KEEP=on -- -gamepadui steam://open/bigpicture
until_true '[ -e "$W/call1" ]'; sleep 0.3
kill -TERM "$wpid"; wait "$wpid"; WRC=$?
[ "$WRC" = 143 ] && [ "$(cat "$W/kills" 2>/dev/null)" = "-TERM 4343" ] && [ -d "$P/4242" ] && [ -e "$W/unit-active" ] \
  && ok "Exit with a game started from Steam's UI ends that game, not one OGUI follows, nor Steam" \
  || bad "rc=$WRC kills: $(cat "$W/kills" 2>&1) $(cat "$W/err")"

CASE="keep: no user manager"
reset_keep; touch "$W/sdrun-fails"
RETROFORGE_STEAM_KEEP=on wrap 0 -silent steam://rungameid/42
[ "$WRC" = 0 ] && [ "$(cat "$W/count")" = 1 ] && grep -qx "args: -noverifyfiles -silent steam://rungameid/42" "$W/call1" \
  && grep -q "could not start Steam as the user unit" <<<"$WERR" && ok "the client runs with the launch, and it is said" || bad "rc=$WRC $WERR"

CASE="keep: inside the unit"
reset_keep; touch "$W/unit-active"
RETROFORGE_STEAM_KEEP=on RETROFORGE_STEAM_KEPT=1 wrap 0 -silent steam://rungameid/42
[ "$WRC" = 0 ] && [ "$(cat "$W/count")" = 1 ] && ! grep -q "handing" <<<"$WERR" \
  && ok "the unit's own run is the client itself, not a hand-over to itself" || bad "rc=$WRC $WERR"

# Minimal: a client (7000, named in ~/.steam/steam.pid) with its web helper (7100) and two of the
# helper's children. parkkill stands in for kill: KILL takes a process away, and so does TERM unless
# $W/term-ignored exists; ending a helper makes the client start another (pid + 100) that has already
# started a child of its own; STOP and CONT set its state.
cat >"$W/bin/parkkill" <<EOF
#!/usr/bin/env bash
sig=\$1; shift; echo "\$sig \$*" >>"$W/kills"
for p in "\$@"; do
  case "\$sig" in
    -TERM|-KILL)
      [ "\$sig" = -TERM ] && [ -e "$W/term-ignored" ] && continue
      if grep -qaF steamwebhelper "$P/\$p/cmdline" 2>/dev/null && [ "\$(cut -d' ' -f4 "$P/\$p/stat")" = 7000 ] \\
         && [ ! -e "$W/no-restart" ]; then
        n=\$((p + 100)); mkdir -p "$P/\$n" "$P/\$((n + 1))"
        echo steamwebhelper >"$P/\$n/comm"; printf '%s\0' "$WROOT/steamrtarm64/steamwebhelper" >"$P/\$n/cmdline"
        echo "\$n (steamwebhelper) S 7000 \$n \$n 0 -1" >"$P/\$n/stat"
        echo steamwebhelper >"$P/\$((n + 1))/comm"; printf '%s\0' "$WROOT/steamrtarm64/steamwebhelper" --type=zygote >"$P/\$((n + 1))/cmdline"
        echo "\$((n + 1)) (steamwebhelper) S \$n \$n \$n 0 -1" >"$P/\$((n + 1))/stat"
        [ -d "$P/7000/task/7000" ] && echo "\$n 7050" >"$P/7000/task/7000/children"
      fi
      rm -rf "$P/\${p:?}" ;;
    -STOP) printf 'State:\tT (stopped)\n' >"$P/\$p/status" ;;
    -CONT) printf 'State:\tS (sleeping)\n' >"$P/\$p/status" ;;
  esac
done
EOF
chmod +x "$W/bin/parkkill"
MENV=("${KENV[@]}" RETROFORGE_STEAM_KEEP_KILL="$W/bin/parkkill" RETROFORGE_STEAM_PARK_WAIT=2 RETROFORGE_STEAM_TERM_WAIT=1)
reset_minimal() {
  reset_keep; rm -rf "$W/run" "$W/no-restart" "$W/term-ignored"
  mkdir -p "$W/home/.steam"; echo 7000 >"$W/home/.steam/steam.pid"
  fakeproc 7000 1 steam "$WROOT/steamrtarm64/steam" -gamepadui
  fakeproc 7100 7000 steamwebhelper "$WROOT/steamrtarm64/steamwebhelper"
  fakeproc 7101 7100 steamwebhelper "$WROOT/steamrtarm64/steamwebhelper" --type=zygote
  fakeproc 7102 7101 steamwebhelper "$WROOT/steamrtarm64/steamwebhelper" --type=renderer
  fakeproc 7050 7000 steam-launch-wrapper "$WROOT/linuxarm64/steam-launch-wrapper" -- game
}
state_of() { sed -n 's/^State:[[:space:]]*\(.\).*/\1/p' "$P/$1/status" 2>/dev/null; }

CASE="keep: minimal"
reset_minimal
"${MENV[@]}" bash "$KEEP" minimal 2>"$W/kerr"; RC=$?
[ "$RC" = 0 ] && [ "$(state_of 7200)" = T ] && grep -qx -- "-TERM 7100" "$W/kills" && grep -qx -- "-STOP 7200" "$W/kills" \
  && ! grep -qx -- "-KILL 7100" "$W/kills" \
  && ok "the web helper is stopped with TERM, and the one the client starts again frozen" || bad "rc=$RC kills=$(cat "$W/kills" 2>&1) $(cat "$W/kerr")"
grep -qx -- "-KILL 7201" "$W/kills" && [ ! -e "$P/7201" ] && ok "with what it had started already" || bad "kills=$(cat "$W/kills")"
[ -e "$P/7050" ] && ! grep -q 7050 "$W/kills" && ok "the client's other children (a game) are left alone" || bad "kills=$(cat "$W/kills")"
grep -q "client stays signed in" "$W/kerr" && ok "and it is said" || bad "$(cat "$W/kerr")"
: >"$W/kills"
"${MENV[@]}" bash "$KEEP" minimal 2>/dev/null; RC=$?
[ "$RC" = 0 ] && [ ! -s "$W/kills" ] && ok "frozen already: nothing is stopped" || bad "rc=$RC kills=$(cat "$W/kills")"
out="$("${MENV[@]}" bash "$KEEP" full 2>/dev/null)"
[ ! -e "$P/7200" ] && grep -qx -- "-KILL 7200" "$W/kills" && ! grep -q -- "-CONT 7200" "$W/kills" && [ "$out" = woke ] \
  && ok "full: the frozen helper is killed, not let go on, and it says it woke Steam's UI" || bad "out=$out kills=$(cat "$W/kills")"
[ -e "$P/7300" ] && [ "$(state_of 7300)" != T ] && ok "the one the client starts instead runs (Steam's UI comes back)" || bad "state 7300: $(state_of 7300)"
out="$("${MENV[@]}" bash "$KEEP" full 2>/dev/null)"
[ -z "$out" ] && [ -e "$P/7300" ] && ok "full again: nothing to wake, nothing killed, nothing said" || bad "out=$out"
: >"$W/kills"
"${MENV[@]}" bash "$KEEP" minimal 2>/dev/null
[ "$(state_of 7400)" = T ] && grep -qx -- "-TERM 7300" "$W/kills" && ok "minimal again after it ran: stopped and frozen anew" || bad "kills=$(cat "$W/kills")"

CASE="keep: minimal, the kernel's list of children"
reset_minimal; mkdir -p "$P/7000/task/7000"; echo "7100 7050" >"$P/7000/task/7000/children"
fakeproc 7400 7000 steamwebhelper "$WROOT/steamrtarm64/steamwebhelper"   # not in the list
"${MENV[@]}" bash "$KEEP" minimal 2>/dev/null; RC=$?
[ "$RC" = 0 ] && [ "$(state_of 7200)" = T ] && grep -qx -- "-TERM 7100" "$W/kills" && ! grep -q 7400 "$W/kills" \
  && ok "read from /proc/<client>/task/*/children when the kernel has it, not by scanning every process" || bad "rc=$RC kills=$(cat "$W/kills" 2>&1)"

CASE="keep: minimal, a helper that ignores TERM"
reset_minimal; touch "$W/term-ignored"
"${MENV[@]}" bash "$KEEP" minimal 2>"$W/kerr"; RC=$?
[ "$RC" = 0 ] && [ "$(state_of 7200)" = T ] && grep -qx -- "-TERM 7100" "$W/kills" && grep -qx -- "-KILL 7100" "$W/kills" \
  && grep -q "web helper 7100 still up 1 s after TERM: killed" "$W/kerr" \
  && ok "killed once TERM_WAIT s have passed, and it is said" || bad "rc=$RC kills=$(cat "$W/kills" 2>&1) $(cat "$W/kerr")"

CASE="keep: minimal, a frozen helper that still has children"
reset_minimal; printf 'State:\tT (stopped)\n' >"$P/7100/status"
"${MENV[@]}" bash "$KEEP" minimal 2>/dev/null
[ "$(sed -n '1p' "$W/kills")" = "-CONT 7100" ] && [ "$(sed -n '2p' "$W/kills")" = "-TERM 7100" ] && [ "$(state_of 7200)" = T ] \
  && ok "let go on before the TERM, which a frozen process would not act on" || bad "kills=$(cat "$W/kills" 2>&1)"

CASE="keep: holds"
reset_minimal; fakeproc 4444 1 bash /usr/bin/steam -gamepadui
"${MENV[@]}" bash "$KEEP" full 4444 2>/dev/null
"${MENV[@]}" bash "$KEEP" minimal 2>/dev/null
[ ! -e "$W/kills" ] && [ -e "$P/7100" ] && ok "a live launch's hold keeps Steam's UI running" || bad "kills=$(cat "$W/kills")"
"${MENV[@]}" bash "$KEEP" minimal 4444 2>/dev/null
[ "$(state_of 7200)" = T ] && ok "until that launch lets go of it (minimal PID)" || bad "kills=$(cat "$W/kills" 2>&1)"
reset_minimal; fakeproc 4444 1 bash /usr/bin/steam -gamepadui
"${MENV[@]}" bash "$KEEP" full 4444 2>/dev/null; gone 4444
"${MENV[@]}" bash "$KEEP" minimal 2>/dev/null
[ "$(state_of 7200)" = T ] && [ ! -e "$W/run/retroforge-steam-full/4444" ] && ok "the hold of a launch that is gone counts for nothing, and goes" || bad "$(ls "$W/run/retroforge-steam-full" 2>&1)"
"${MENV[@]}" bash "$KEEP" minimal 4a 2>/dev/null; [ $? = 2 ] && ok "a PID that is not a number is a bad invocation" || bad "minimal 4a"

CASE="keep: minimal, no client"
reset_minimal; rm -f "$W/home/.steam/steam.pid"
"${MENV[@]}" bash "$KEEP" minimal 2>/dev/null; RC=$?
[ "$RC" = 0 ] && [ ! -e "$W/kills" ] && ok "no client running: nothing to do" || bad "rc=$RC kills=$(cat "$W/kills" 2>&1)"
reset_minimal; touch "$W/no-restart"
"${MENV[@]}" bash "$KEEP" minimal 2>"$W/kerr"; RC=$?
[ "$RC" = 1 ] && grep -q "did not start its web helper again within 2 s" "$W/kerr" \
  && ok "a client that does not start its helper again: exit 1, and it is said" || bad "rc=$RC $(cat "$W/kerr")"

# Sweep: four of Steam's segments in a stand-in /dev/shm, one mapped by process 8000 and one open in
# process 8100, beside a file of someone else's and one that is not Steam's.
SU=$(id -u)
reset_sweep() {
  reset_keep; rm -f "$W/home/.steam/steam.pid" "$SHMD"/*
  local n; for n in a1 b2 c3 d4; do head -c 4096 /dev/zero >"$SHMD/u$SU-Shm_$n"; done
  echo x >"$SHMD/u$((SU + 1))-Shm_e5"; echo x >"$SHMD/other"
  fakeproc 8000 1 steamwebhelper x; echo "7f00-7f01 rw-s 00000000 00:1a 77 $SHMD/u$SU-Shm_b2" >"$P/8000/maps"
  fakeproc 8100 1 reaper x; mkdir -p "$P/8100/fd"; ln -s "$SHMD/u$SU-Shm_c3" "$P/8100/fd/5"
}
left() { (cd "$SHMD" && LC_ALL=C ls | tr '\n' ' '); }

CASE="keep: sweep"
reset_sweep
"${KENV[@]}" bash "$KEEP" sweep 2>"$W/kerr"; RC=$?
[ "$RC" = 0 ] && [ "$(left)" = "other u$SU-Shm_b2 u$SU-Shm_c3 u$((SU + 1))-Shm_e5 " ] \
  && ok "no client: the segments no process uses go; mapped, open, someone else's and other files stay" || bad "rc=$RC left=$(left) $(cat "$W/kerr")"
grep -q "removed 2 segments of shared memory" "$W/kerr" && ok "and it is said" || bad "$(cat "$W/kerr")"
"${KENV[@]}" bash "$KEEP" sweep 2>"$W/kerr"
[ ! -s "$W/kerr" ] && ok "nothing left to remove: nothing said" || bad "$(cat "$W/kerr")"
reset_sweep; mkdir -p "$W/home/.steam"; echo 7000 >"$W/home/.steam/steam.pid"; fakeproc 7000 1 steam "$WROOT/steamrtarm64/steam"
"${KENV[@]}" bash "$KEEP" sweep 2>/dev/null
[ "$(left)" = "other u$SU-Shm_a1 u$SU-Shm_b2 u$SU-Shm_c3 u$SU-Shm_d4 u$((SU + 1))-Shm_e5 " ] \
  && ok "a client runs: nothing goes (it maps some of its own again later)" || bad "left=$(left)"
reset_sweep; fakeproc 7000 1 steam "$WROOT/steamrtarm64/steam"
"${KENV[@]}" bash "$KEEP" sweep 2>/dev/null
[ "$(left)" = "other u$SU-Shm_a1 u$SU-Shm_b2 u$SU-Shm_c3 u$SU-Shm_d4 u$((SU + 1))-Shm_e5 " ] \
  && ok "nor while a process called steam runs that steam.pid does not name" || bad "left=$(left)"

CASE="sweep: before the wrapper starts a client"
reset_sweep; gone 8000; gone 8100
wrap 0 -gamepadui
[ "$WRC" = 0 ] && [ "$(cat "$W/count")" = 1 ] && [ "$(left)" = "other u$((SU + 1))-Shm_e5 " ] \
  && ok "what earlier clients left is gone when the client starts" || bad "rc=$WRC left=$(left) $WERR"

# The wrapper's holds: retroforge-steam-keep through keeplog, which records how it is called and
# whether the client had the launch yet ($W/call1).
cat >"$W/bin/keeplog" <<EOF
#!/usr/bin/env bash
case "\$1" in full|minimal) echo "\$1\${2:+ pid} \$([ -e "$W/call1" ] && echo handed || echo first)" >>"$W/keep.calls" ;; esac
exec bash "$KEEP" "\$@"
EOF
chmod +x "$W/bin/keeplog"

CASE="keep: a game through the kept client"
CTL="$WROOT/logs/controller_ui.txt"
reset_keep; rm -f "$W/keep.calls"; touch "$W/unit-active"; mkdir -p "${CTL%/*}"
echo "[2026-10-25 03:16:43] OnFocusWindowChanged to game window type: AppID 42, 42" >"$CTL"   # an earlier run's
bg_wrap RETROFORGE_STEAM_KEEP=on RETROFORGE_STEAM_KEEP_CLI="$W/bin/keeplog" RETROFORGE_STEAM_MINIMAL_DELAY=1 RETROFORGE_STEAM_UNSTICK_WAIT=0 -- steam://rungameid/42
until_true '[ -e "$W/call3" ]'
[ "$(head -1 "$W/keep.calls" 2>/dev/null)" = "full pid first" ] \
  && ok "Steam's UI comes back before the launch is handed over (its dialogs, install scripts, shader prompt)" || bad "keep: $(cat "$W/keep.calls" 2>&1)"
grep -qx "args: steam://forceinputappid/769" "$W/call1" 2>/dev/null && grep -qx "args: steam://forceinputappid/0" "$W/call2" 2>/dev/null \
  && grep -qx "args: steam://rungameid/42" "$W/call3" 2>/dev/null \
  && ok "the game Steam last saw focused: its input goes to Steam's UI and back before the launch (else no controller)" \
  || bad "calls: $(cat "$W"/call1 "$W"/call2 "$W"/call3 2>&1)"
step 42 Completed; fakeproc 4242 1 reaper "$STEAM_REAPER" SteamLaunch AppId=42 -- game
sleep 2.5
! grep -q "^minimal" "$W/keep.calls" && ok "not minimal while Steam has not switched the controller to the game (an earlier run's line does not count)" \
  || bad "keep: $(cat "$W/keep.calls" 2>&1)"
echo "[2026-10-25 03:30:20] OnFocusWindowChanged to game window type: AppID 42, 42" >>"$CTL"
until_true 'grep -q "^minimal pid" "$W/keep.calls"'
kill -0 "$wpid" 2>/dev/null && grep -q "^minimal pid" "$W/keep.calls" \
  && ok "minimal RETROFORGE_STEAM_MINIMAL_DELAY s after it has, the launch still on" || bad "keep: $(cat "$W/keep.calls" 2>&1)"
gone 4242
finish
[ "$WRC" = 0 ] && [ "$(tail -1 "$W/keep.calls")" = "minimal pid handed" ] && [ -e "$W/unit-active" ] \
  && ok "and stays minimal when the game ends" || bad "rc=$WRC keep: $(cat "$W/keep.calls" 2>&1)"

CASE="keep: a game on fast cores"
# steam-direct as a stub: no game starts without the client (check), fastcores recorded.
cat >"$W/bin/directfast" <<EOF
#!/usr/bin/env bash
case "\$1" in check) exit 1 ;; fastcores) echo "\$*" >>"$W/fast.calls" ;; esac
exit 0
EOF
chmod +x "$W/bin/directfast"
GJ="$W/home/.config/retroforge/steam-games.json"; mkdir -p "${GJ%/*}"
echo "[2026-10-25 03:16:43] OnFocusWindowChanged to game window type: AppID 7, 7" >"$CTL"
for choice in none on; do
  reset_keep; rm -f "$W/keep.calls" "$W/fast.calls"; touch "$W/unit-active"
  if [ "$choice" = on ]; then echo '{"42": {"cpus": "on"}}' >"$GJ"; else rm -f "$GJ"; fi
  bg_wrap RETROFORGE_STEAM_KEEP=on RETROFORGE_STEAM_KEEP_CLI="$W/bin/keeplog" RETROFORGE_STEAM_DIRECT_CLI="$W/bin/directfast" \
    RETROFORGE_STEAM_UNSTICK_WAIT=0 RETROFORGE_STEAM_FAST_AGAIN=1 -- steam://rungameid/42
  until_true '[ -e "$W/call1" ]'
  step 42 Completed; fakeproc 4242 1 reaper "$STEAM_REAPER" SteamLaunch AppId=42 -- game
  sleep 3.5
  gone 4242
  finish
  if [ "$choice" = on ]; then
    [ "$(grep -c . "$W/fast.calls" 2>/dev/null)" = 2 ] && [ "$(sort -u "$W/fast.calls")" = "fastcores 42 4242" ] \
      && ok "a choice saved: the game's processes once Steam starts them, and once more after (steam-direct fastcores)" \
      || bad "rc=$WRC fast: $(cat "$W/fast.calls" 2>&1)"
  else
    [ ! -e "$W/fast.calls" ] && ok "no game with the choice: steam-direct is not even started for it" || bad "fast: $(cat "$W/fast.calls")"
  fi
done
rm -f "$GJ"

CASE="keep: another game than the one Steam last saw focused"
reset_keep; rm -f "$W/keep.calls"; touch "$W/unit-active"
echo "[2026-10-25 03:16:43] OnFocusWindowChanged to game window type: AppID 7, 7" >"$CTL"
bg_wrap RETROFORGE_STEAM_KEEP=on RETROFORGE_STEAM_KEEP_CLI="$W/bin/keeplog" RETROFORGE_STEAM_UNSTICK_WAIT=0 -- steam://rungameid/42
until_true '[ -e "$W/call1" ]'
sleep 0.5
grep -qx "args: steam://rungameid/42" "$W/call1" 2>/dev/null && [ ! -e "$W/call2" ] \
  && ok "handed over as it is: the game's window is a change of focus for Steam" || bad "calls: $(cat "$W"/call* 2>&1)"
kill -TERM "$wpid"; wait "$wpid" 2>/dev/null

CASE="keep: a game started without the client, beside the kept one"
# direct CLI stub: every game can start without the client; `run` records what it was asked.
cat >"$W/bin/directstub" <<EOF
#!/usr/bin/env bash
case "\$1" in check|remember|fex) exit 0 ;; run) echo "run \$2" >"$W/direct.run"; exit 0 ;; esac
EOF
chmod +x "$W/bin/directstub"
dwrap() {  # the wrapper with the stub as its direct CLI, the kept client on and running
  echo 0 >"$W/codes"; rm -f "$W/count" "$W"/call*
  "${WENV[@]}" RETROFORGE_STEAM_KEEP=on RETROFORGE_STEAM_DIRECT_CLI="$W/bin/directstub" RETROFORGE_STEAM_KEEP_CLI="$W/bin/keeplog" \
    RETROFORGE_STEAM_UNSTICK_WAIT=0 bash "$WRAP" "$@" >/dev/null 2>"$W/err"; WRC=$?
  WERR="$(cat "$W/err")"
}
reset_keep; rm -f "$W/keep.calls" "$W/direct.run"; touch "$W/unit-active"
echo "[2026-11-26 22:12:33] OnFocusWindowChanged to game window type: AppID 42, 42" >"$CTL"
dwrap steam://rungameid/42
grep -qx "run 42" "$W/direct.run" 2>/dev/null && grep -qx "args: steam://forceinputappid/769" "$W/call1" 2>/dev/null \
  && grep -qx "args: steam://forceinputappid/0" "$W/call2" 2>/dev/null \
  && ok "the game Steam last saw focused: Steam's input goes to its UI and back before the game starts" \
  || bad "rc=$WRC run=$(cat "$W/direct.run" 2>&1) calls: $(cat "$W"/call* 2>&1) err=$WERR"
reset_keep; rm -f "$W/direct.run"; touch "$W/unit-active"
echo "[2026-11-26 22:12:33] OnFocusWindowChanged to game window type: AppID 7, 7" >"$CTL"
dwrap steam://rungameid/42
grep -qx "run 42" "$W/direct.run" 2>/dev/null && [ ! -e "$W/call1" ] \
  && ok "another game: started at once, Steam left alone" || bad "rc=$WRC run=$(cat "$W/direct.run" 2>&1) calls: $(cat "$W"/call* 2>&1)"

CASE="keep: Steam's UI, woken first"
# keep CLI stub: the client was minimal, so `full` wakes its UI.
cat >"$W/bin/keepwoke" <<EOF
#!/usr/bin/env bash
case "\$1" in full) echo woke ;; status) echo on ;; esac
EOF
chmod +x "$W/bin/keepwoke"
WLOG="$WROOT/logs/webhelper.txt"
reset_keep; touch "$W/unit-active"; mkdir -p "${WLOG%/*}"
echo "[2026-11-23 03:29:10] SP BPM_uid0: STARTUP BrowserCreated t=2.875 +0.0ms from create" >"$WLOG"   # an earlier helper's
bg_wrap RETROFORGE_STEAM_KEEP=on RETROFORGE_STEAM_KEEP_CLI="$W/bin/keepwoke" RETROFORGE_STEAM_UI_SETTLE=0 -- -gamepadui steam://open/bigpicture
sleep 1.5
[ ! -e "$W/call1" ] && ok "Steam's UI from a minimal client: not handed over while the UI starts again" || bad "handed over at once: $(cat "$W/call1" 2>&1)"
echo "[2026-11-23 03:32:34] UB-65536: STARTUP BrowserCreated t=0.590 +0.0ms from create" >>"$WLOG"
echo "[2026-10-25 03:44:10] STARTUP SlowJSMethodCall Settings.RegisterForSettingsChanges took 9.4ms" >>"$SLOG"
sleep 1.5
[ ! -e "$W/call1" ] && ok "nor on the helper's first browser, or on the old client's SlowJSMethodCall" || bad "handed over early: $(cat "$W/call1" 2>&1)"
echo "[2026-11-23 03:32:36] SP Desktop_uid0: STARTUP BrowserCreated t=2.875 +0.0ms from create" >>"$WLOG"
until_true '[ -e "$W/call1" ]'
grep -qx "args: -gamepadui steam://open/bigpicture" "$W/call1" 2>/dev/null && ok "but once the new helper has created the UI's main window" || bad "$(cat "$W/call1" 2>&1)"
kill -TERM "$wpid"; wait "$wpid" 2>/dev/null
reset_keep; touch "$W/unit-active"
bg_wrap RETROFORGE_STEAM_KEEP=on RETROFORGE_STEAM_KEEP_CLI="$W/bin/keepwoke" RETROFORGE_STEAM_UI_WAIT=1 RETROFORGE_STEAM_UI_SETTLE=0 -- -gamepadui steam://open/bigpicture
until_true '[ -e "$W/call1" ]'
[ -e "$W/call1" ] && ok "or after RETROFORGE_STEAM_UI_WAIT s without them" || bad "never handed over"
kill -TERM "$wpid"; wait "$wpid" 2>/dev/null
reset_keep; touch "$W/unit-active"
step 42 Completed; fakeproc 4242 1 reaper "$STEAM_REAPER" SteamLaunch AppId=42 -- game
bg_wrap RETROFORGE_STEAM_KEEP=on RETROFORGE_STEAM_KEEP_CLI="$W/bin/keepwoke" -- steam://rungameid/42
sleep 1
[ -e "$W/call1" ] && ok "a game is handed over at once (Steam queues its launch until the UI is up)" || bad "a game waited"
kill -TERM "$wpid"; wait "$wpid" 2>/dev/null

CASE="keep: a Steam page opens Big Picture first"
# OGUI's install of a game: steam://install/<appid>. The running client takes the URL, not -gamepadui, so
# one on its desktop window showed the page as a desktop dialog a gamepad cannot drive.
WLOG="$WROOT/logs/webhelper.txt"
NOINST=(RETROFORGE_STEAM_KEEP=on RETROFORGE_STEAM_KEEP_CLI="$W/bin/keeplog" RETROFORGE_STEAM_INSTALL_APP=/nonexistent RETROFORGE_STEAM_UI_SETTLE=0)
reset_keep; touch "$W/unit-active"; mkdir -p "${WLOG%/*}"
echo "[2026-11-25 09:21:36] SP Desktop_uid0: STARTUP LoadEnd t=2.722 +17.4ms from create" >"$WLOG"
bg_wrap "${NOINST[@]}" -- -gamepadui -steamos3 steam://install/367520
until_true '[ -e "$W/call1" ]'; sleep 1
grep -qx "args: steam://open/bigpicture" "$W/call1" 2>/dev/null && [ ! -e "$W/call2" ] \
  && ok "a client on its desktop window: Big Picture first, the page not yet" || bad "$(cat "$W/call1" "$W/call2" 2>&1)"
echo "[2026-11-25 09:23:43] SP BPM_uid0-'Steam Big ': WasHidden 0: (0, 0) 1280x800" >>"$WLOG"
until_true '[ -e "$W/call2" ]'
grep -qx "args: -gamepadui -steamos3 steam://install/367520" "$W/call2" 2>/dev/null \
  && ok "then the page, once Big Picture's window is up" || bad "$(cat "$W/call2" 2>&1)"
kill -TERM "$wpid"; wait "$wpid" 2>/dev/null
reset_keep; touch "$W/unit-active"
echo "[2026-11-25 09:23:43] SP BPM_uid0-'Steam Big ': WasHidden 0: (0, 0) 1280x800" >"$WLOG"
bg_wrap "${NOINST[@]}" -- -gamepadui -steamos3 steam://install/367520
until_true '[ -e "$W/call1" ]'; sleep 0.5
grep -qx "args: -gamepadui -steamos3 steam://install/367520" "$W/call1" 2>/dev/null && [ ! -e "$W/call2" ] \
  && ok "in Big Picture already: the page at once" || bad "$(cat "$W/call1" "$W/call2" 2>&1)"
kill -TERM "$wpid"; wait "$wpid" 2>/dev/null
reset_keep; touch "$W/unit-active"
echo "[2026-11-25 09:30:00] SP Desktop_uid0: STARTUP LoadEnd t=2.722 +17.4ms from create" >"$WLOG"
bg_wrap "${NOINST[@]}" -- -gamepadui steam://open/bigpicture
until_true '[ -e "$W/call1" ]'; sleep 0.5
grep -qx "args: -gamepadui steam://open/bigpicture" "$W/call1" 2>/dev/null && [ ! -e "$W/call2" ] \
  && ok "Big Picture itself: handed over as it is" || bad "$(cat "$W/call1" "$W/call2" 2>&1)"
kill -TERM "$wpid"; wait "$wpid" 2>/dev/null
rm -f "$WLOG"

CASE="keep: an install through Steam's own install"
# steam-install-app stub: records its argument, exits with installapp.rc (0 silent, 3 Steam's screen, 1 not done)
printf '#!/usr/bin/env bash\necho "$*" >"%s/installapp.args"; exit $(cat "%s/installapp.rc" 2>/dev/null || echo 1)\n' "$W" "$W" >"$W/bin/installapp"
chmod +x "$W/bin/installapp"
INST=(RETROFORGE_STEAM_KEEP=on RETROFORGE_STEAM_KEEP_CLI="$W/bin/keeplog" RETROFORGE_STEAM_INSTALL_APP="$W/bin/installapp" RETROFORGE_STEAM_UI_SETTLE=0 RETROFORGE_STEAM_UI_CLOSE_WAIT=0)
reset_keep; rm -f "$W/keep.calls" "$W/installapp.args"; touch "$W/unit-active"; mkdir -p "${WLOG%/*}"; echo 0 >"$W/installapp.rc"
echo "[2026-11-25 09:41:00] SP BPM_uid0-'Steam Big ': WasHidden 0: (0, 0) 1280x800" >"$WLOG"
bg_wrap "${INST[@]}" -- -gamepadui -steamos3 steam://install/1572920
finish
[ "$WRC" = 0 ] && [ "$(cat "$W/installapp.args" 2>/dev/null)" = 1572920 ] && grep -qx "args: steam://close/bigpicture" "$W/call1" 2>/dev/null \
  && ! grep -q "steam://install" "$W"/call* && grep -q "^minimal" "$W/keep.calls" \
  && ok "Steam installs it by itself: no Install screen, Big Picture closed, minimal again, back to OGUI (exit 0)" || bad "rc=$WRC args=$(cat "$W/installapp.args" 2>&1) $(cat "$W"/call* 2>&1) keep=$(cat "$W/keep.calls" 2>&1)"
[ -e "$WROOT/.cef-enable-remote-debugging" ] && ok "and the client's DevTools flag is in its folder" || bad "no .cef-enable-remote-debugging"
[ -x "$ROOT/rootfs/overlay/usr/lib/retroforge/steam-install-app" ] \
  && ok "the image's steam-install-app is executable (/usr/bin/steam runs it only then)" || bad "steam-install-app is not executable"
reset_keep; rm -f "$W/keep.calls"; touch "$W/unit-active"; echo 3 >"$W/installapp.rc"
echo "[2026-11-25 09:41:00] SP BPM_uid0-'Steam Big ': WasHidden 0: (0, 0) 1280x800" >"$WLOG"
CLOG="$WROOT/logs/content_log.txt"
echo "[2026-11-25 09:00:00] AppID 1572920 state changed : Update Required,Update Queued," >"$CLOG"   # an earlier install's
bg_wrap "${INST[@]}" -- -gamepadui -steamos3 steam://install/1572920
sleep 1.5
kill -0 "$wpid" 2>/dev/null && ! ls "$W"/call* >/dev/null 2>&1 \
  && ok "Steam shows its own screen (a EULA, a folder): the launch stays on it, nothing handed over twice" || bad "$(cat "$W"/call* 2>&1)"
echo "[2026-11-25 09:42:00] AppID 413150 state changed : Update Required,Update Queued," >>"$CLOG"
sleep 1.5
kill -0 "$wpid" 2>/dev/null && ! ls "$W"/call* >/dev/null 2>&1 \
  && ok "another game's download queued: still on Steam's screen" || bad "$(cat "$W"/call* 2>&1)"
echo "[2026-11-25 09:42:05] AppID 1572920 state changed : Update Required,Update Queued," >>"$CLOG"
finish
[ "$WRC" = 0 ] && grep -qx "args: steam://close/bigpicture" "$W/call1" 2>/dev/null && grep -q "^minimal" "$W/keep.calls" \
  && ok "the player answered it and Steam queued the download: Big Picture closed, minimal again, back to OGUI (exit 0)" \
  || bad "rc=$WRC $(cat "$W"/call* 2>&1) keep=$(cat "$W/keep.calls" 2>&1)"
rm -f "$CLOG"
reset_keep; rm -f "$W/keep.calls"; touch "$W/unit-active"; echo 1 >"$W/installapp.rc"
echo "[2026-11-25 09:41:00] SP BPM_uid0-'Steam Big ': WasHidden 0: (0, 0) 1280x800" >"$WLOG"
bg_wrap "${INST[@]}" -- -gamepadui -steamos3 steam://install/1572920
until_true '[ -e "$W/call1" ]'
grep -qx "args: -gamepadui -steamos3 steam://install/1572920" "$W/call1" 2>/dev/null \
  && ok "not done (no DevTools, no manager): the Install page is handed over as before" || bad "$(cat "$W/call1" 2>&1)"
kill -TERM "$wpid"; wait "$wpid" 2>/dev/null
reset_keep; rm -f "$W/keep.calls" "$W/installapp.args"; touch "$W/unit-active"; echo 0 >"$W/installapp.rc"
echo "[2026-11-25 09:41:00] SP BPM_uid0-'Steam Big ': WasHidden 0: (0, 0) 1280x800" >"$WLOG"
bg_wrap RETROFORGE_STEAM_KEEP=off "${INST[@]:1}" -- -gamepadui -steamos3 steam://install/1572920
until_true '[ -e "$W/call1" ]'
[ ! -e "$W/installapp.args" ] && grep -qx "args: -gamepadui -steamos3 steam://install/1572920" "$W/call1" 2>/dev/null \
  && ok "Keep Steam running off (the client stops when its UI is left, and the download with it): Steam's page, as before" || bad "args=$(cat "$W/installapp.args" 2>&1) $(cat "$W/call1" 2>&1)"
kill -TERM "$wpid"; wait "$wpid" 2>/dev/null
rm -f "$WLOG" "$W/installapp.rc" "$W/installapp.args"

CASE="steam-install-app --quiet"
# OGUI's Install in the background: only with Keep Steam running on and the kept client up, the web helper
# woken (full) for it and minimal again whatever happens. A keep stub records how it is called.
IAPP="$ROOT/rootfs/overlay/usr/lib/retroforge/steam-install-app"
QH="$W/quiet"; mkdir -p "$QH/home/.steam" "$QH/proc/4242"
printf '#!/usr/bin/env bash\necho "$*" >>"%s/keep.args"\n[ "$1" = status ] && cat "%s/keep.state"\nexit 0\n' "$QH" "$QH" >"$QH/keep"
chmod +x "$QH/keep"
QENV=(HOME="$QH/home" RETROFORGE_PROC="$QH/proc" RETROFORGE_STEAM_KEEP_CLI="$QH/keep" RETROFORGE_STEAM_DEVTOOLS=http://127.0.0.1:9 RETROFORGE_STEAM_DEVTOOLS_WAIT=0)
echo off >"$QH/keep.state"; echo 4242 >"$QH/home/.steam/steam.pid"; echo steam >"$QH/proc/4242/comm"; rm -f "$QH/keep.args"
env "${QENV[@]}" python3 "$IAPP" --quiet 1572920 2>/dev/null; rc=$?
[ "$rc" = 1 ] && [ "$(cat "$QH/keep.args")" = status ] \
  && ok "Keep Steam running off: not done (exit 1), Steam's UI not woken" || bad "rc=$rc keep: $(cat "$QH/keep.args" 2>&1)"
echo on >"$QH/keep.state"; rm -f "$QH/keep.args" "$QH/proc/4242/comm"
env "${QENV[@]}" python3 "$IAPP" --quiet 1572920 2>/dev/null; rc=$?
[ "$rc" = 1 ] && [ "$(cat "$QH/keep.args")" = status ] \
  && ok "no client running (steam.pid names no live steam): not done, nothing woken" || bad "rc=$rc keep: $(cat "$QH/keep.args" 2>&1)"
echo steam >"$QH/proc/4242/comm"; rm -f "$QH/keep.args"
env "${QENV[@]}" python3 "$IAPP" --quiet 1572920 2>"$QH/err"; rc=$?
mapfile -t KA <"$QH/keep.args"
[ "$rc" = 1 ] && [ "${KA[0]}" = status ] && [[ "${KA[1]}" =~ ^full\ [0-9]+$ ]] && [ "${KA[2]}" = "minimal ${KA[1]#full }" ] \
  && grep -q "no DevTools page" "$QH/err" \
  && ok "the client up: Steam's UI woken, held by the helper and minimal again though Steam's UI never answered (exit 1)" \
  || bad "rc=$rc keep: ${KA[*]} err: $(cat "$QH/err")"
env "${QENV[@]}" python3 "$IAPP" --quiet 2>/dev/null; rc=$?
[ "$rc" = 2 ] && ok "no app id: usage (exit 2)" || bad "rc=$rc"

CASE="keep: Steam's UI holds it"
reset_keep; rm -f "$W/keep.calls"; touch "$W/unit-active"
bg_wrap RETROFORGE_STEAM_KEEP=on RETROFORGE_STEAM_KEEP_CLI="$W/bin/keeplog" RETROFORGE_STEAM_MINIMAL_DELAY=0 -- -gamepadui -steamos3
until_true '[ -e "$W/call1" ]'; sleep 1.2
[ "$(cat "$W/keep.calls")" = "full pid first" ] && ls "$W/run/retroforge-steam-full/$wpid" >/dev/null 2>&1 \
  && ok "Steam's UI, while OGUI shows it: running, held by the launch" || bad "keep: $(cat "$W/keep.calls" 2>&1) $(ls "$W/run/retroforge-steam-full" 2>&1)"
WLOG="$WROOT/logs/webhelper.txt"; mkdir -p "${WLOG%/*}"; : >"$WLOG"
( until_true '[ -e "$W/call2" ]'; sleep 0.5; [ -e "$W/call2" ] && echo "[2026-11-23 06:24:41] SP Desktop_uid0: STARTUP BrowserCreated t=274.983 +0.0ms from create" >>"$WLOG" ) &
kill -TERM "$wpid"; s0=$SECONDS; wait "$wpid"; WRC=$?
[ "$WRC" = 143 ] && [ "$(tail -1 "$W/keep.calls")" = "minimal pid handed" ] && [ ! -e "$W/run/retroforge-steam-full/$wpid" ] \
  && ok "OGUI closes it: minimal again, the hold gone" || bad "rc=$WRC keep: $(cat "$W/keep.calls" 2>&1)"
grep -qx "args: steam://close/bigpicture" "$W/call2" 2>/dev/null && grep -qx "cwd: $WROOT/steamrtarm64" "$W/call2" \
  && ok "first the client leaves Big Picture (a game launch's helper would show it again, over the game)" || bad "$(cat "$W/call2" 2>&1)"
[ $((SECONDS - s0)) -lt 4 ] && ok "and minimal follows once its hidden desktop window is there" || bad "took $((SECONDS - s0)) s"
wait
reset_keep; rm -f "$W/keep.calls"; touch "$W/unit-active"
step 42 Completed; fakeproc 4242 1 reaper "$STEAM_REAPER" SteamLaunch AppId=42 -- game
bg_wrap RETROFORGE_STEAM_KEEP=on RETROFORGE_STEAM_KEEP_CLI="$W/bin/keeplog" -- steam://rungameid/42
until_true '[ -e "$W/call1" ]'; sleep 1.2
kill -TERM "$wpid"; wait "$wpid"
[ ! -e "$W/call2" ] && ok "a game's launch ended from OGUI leaves Steam's UI as it is" || bad "$(cat "$W/call2" 2>&1)"
gone 4242
reset_keep

# ================================================================================================
# Steam Client's install (steam-install install client) with this wrapper for its last stage, the
# client's own update (`steam -steamdeck -exitsteam`). On an ARMv8.0 CPU, so Steam's default Proton
# is applied after it. The other stages and their bar have their own suite (test-steam-install.sh).
INSTALL="$ROOT/rootfs/overlay/usr/lib/retroforge/steam-install"
printf 'processor\t: 0\nFeatures\t: fp asimd evtstrm aes pmull sha1 sha2 crc32 cpuid\n' >"$W/v80"
printf '#!/usr/bin/env bash\necho "$*" >>"%s/proton.log"\n' "$W" >"$W/bin/proton"
printf '#!/usr/bin/env bash\necho "$*" >>"%s/steam-proton.log"; echo armv8\n' "$W" >"$W/bin/steam-proton"
chmod +x "$W/bin/proton" "$W/bin/steam-proton"
inst() {  # inst [VAR=value...]: the install, with an hour's UPDATE_TIMEOUT as 8 s
  local start=$SECONDS
  rm -rf "$W/proton.log" "$W/steam-proton.log" "$W/cache"
  IOUT="$("${WENV[@]}" RETROFORGE_STEAM_ROOT="$WROOT" XDG_CACHE_HOME="$W/cache" RETROFORGE_STEAM_WRAPPER="$WRAP" \
          RETROFORGE_CPUINFO="$W/v80" RETROFORGE_PROTON_CLI="$W/bin/proton" RETROFORGE_STEAM_PROTON_CLI="$W/bin/steam-proton" \
          RETROFORGE_STEAM_UPDATE_TIMEOUT=8 RETROFORGE_STEAM_DONE_GRACE=1 "$@" python3 "$INSTALL" install client 2>"$W/ierr")"; IRC=$?
  IERR="$(cat "$W/ierr")"; ITOOK=$((SECONDS - start))
}

CASE="install: Steam kept, opened during the install"   # MANGMI Air X, 2026-11-21
reset_keep; touch "$W/unit-active"
inst RETROFORGE_STEAM_KEEP=on
[ "$IRC" = 0 ] && [ "$ITOOK" -lt 5 ] && [ "$(tail -1 <<<"$IOUT")" = 100% ] \
  && ok "the install ends at once at 100%, not at UPDATE_TIMEOUT (it waited on the kept client, the bar at 63%)" \
  || bad "rc=$IRC took $ITOOK s out=$(tr '\n' ' ' <<<"$IOUT") err=$IERR"
[ ! -e "$W/call1" ] && ok "no second client process: the update is not handed to the kept client, which ignores -exitsteam" \
  || bad "the client ran: $(cat "$W/call1")"
grep -q "it updates itself" <<<"$IERR" && ok "and it says the running client updates itself" || bad "err=$IERR"
grep -qx apply "$W/steam-proton.log" 2>/dev/null \
  && ok "Steam's default Proton is still applied (retroforge-steam-proton leaves config.vdf alone under a running client)" \
  || bad "apply: $(cat "$W/steam-proton.log" 2>&1)"
[ -e "$W/unit-active" ] && ! grep -q " stop " "$W/sysd.log" 2>/dev/null && ok "the player's Steam keeps running" || bad "$(cat "$W/sysd.log")"

CASE="install: Steam opened during the install, not kept"
reset_keep; mkdir -p "$W/home/.steam"; echo 7000 >"$W/home/.steam/steam.pid"
fakeproc 7000 1 steam "$WROOT/steamrtarm64/steam" -gamepadui
inst
[ "$IRC" = 0 ] && [ "$ITOOK" -lt 5 ] && [ ! -e "$W/call1" ] \
  && ok "a client a launch runs (~/.steam/steam.pid): no update run beside it either" || bad "rc=$IRC took $ITOOK s err=$IERR"
gone 7000; rm -f "$W/home/.steam/steam.pid"

CASE="install: no Steam running"
reset_keep
printf '[ 50%%] Downloading update (500 of 1,000 KB)...\n[2026-11-21 12:00:00] Update complete, launching...\n' >"$W/say"
inst RETROFORGE_STEAM_KEEP=on
[ "$IRC" = 0 ] && grep -qx "args: -steamdeck -exitsteam" "$W/call1" 2>/dev/null && [ ! -e "$W/sdrun.args" ] && [ ! -e "$W/unit-active" ] \
  && ok "the update runs the client here, not as the kept unit (Keep Steam running on)" \
  || bad "rc=$IRC took $ITOOK s systemd-run: $(cat "$W/sdrun.args" 2>&1) err=$IERR"
grep -q "Update complete" <<<"$IERR" && grep -qx "74%" <<<"$IOUT" \
  && ok "its lines reach the install: the bar follows its download (74% at half of it)" || bad "out=$(tr '\n' ' ' <<<"$IOUT")"
rm -f "$W/say"

# Steam started while the install runs (it holds ~/.cache/retroforge/steam-install.lock): $W/held
# exists while a stand-in holds it.
CASE="wrapper: during Steam Client's install"
LOCK="$W/cache/retroforge/steam-install.lock"
reset_keep; rm -rf "$W/cache"; mkdir -p "${LOCK%/*}"
python3 -c 'import fcntl, os, sys, time
f = open(sys.argv[1], "w"); fcntl.flock(f, fcntl.LOCK_EX); open(sys.argv[2], "w").close()
while os.path.exists(sys.argv[2]): time.sleep(0.05)' "$LOCK" "$W/held" &
hp=$!
until_true '[ -e "$W/held" ]'
XDG_CACHE_HOME="$W/cache" wrap 0 -gamepadui steam://open/bigpicture
[ "$WRC" = 1 ] && [ ! -e "$W/count" ] \
  && grep -q "Steam Client is still being installed: Main menu > Emulators > Steam Client shows its progress" <<<"$WERR" \
  && ok "refused while the install holds its lock: exit 1, no client, and it says where the install is" \
  || bad "rc=$WRC runs=$(cat "$W/count" 2>/dev/null) err=$WERR"
XDG_CACHE_HOME="$W/cache" RETROFORGE_STEAM_KEPT=1 wrap 0 -steamdeck -exitsteam
[ "$WRC" = 0 ] && grep -qx "args: -steamdeck -exitsteam" "$W/call1" 2>/dev/null \
  && ok "but the install's own run of the client goes on (RETROFORGE_STEAM_KEPT=1)" || bad "rc=$WRC err=$WERR"
rm -f "$W/held"; wait "$hp"
XDG_CACHE_HOME="$W/cache" wrap 0 -gamepadui
[ "$WRC" = 0 ] && [ -e "$W/call1" ] && ok "once it is done (its lock file left, not held), Steam starts" || bad "rc=$WRC err=$WERR"
rm -rf "$W/cache"

# Where our Proton is Steam's tool: a kept client that started without it (retroforge-steam-proton
# pending) is stopped before it gets a launch, when nothing else uses it, so the launch starts one that
# has it. The helper knows the boards (ARMv8.0 CPUs, GPUs that need DXVK-Sarek): it is asked on every one.
CASE="keep: stop-unused"
reset_keep; rm -rf "$W/run/retroforge-steam-full"; touch "$W/unit-active"
fakeproc 4343 1 reaper "$STEAM_REAPER" SteamLaunch AppId=43 -- game
"${KENV[@]}" bash "$KEEP" stop-unused 2>/dev/null; RC=$?
[ "$RC" = 1 ] && [ -e "$W/unit-active" ] && ok "not while it runs a game: exit 1" || bad "rc=$RC $(cat "$W/sysd.log")"
gone 4343; fakeproc 4444 1 bash /usr/bin/steam -gamepadui
"${KENV[@]}" bash "$KEEP" full 4444 >/dev/null 2>&1
"${KENV[@]}" bash "$KEEP" stop-unused 2>/dev/null; RC=$?
[ "$RC" = 1 ] && [ -e "$W/unit-active" ] && ok "nor while a live launch holds its UI" || bad "rc=$RC $(cat "$W/sysd.log")"
gone 4444
"${KENV[@]}" bash "$KEEP" stop-unused 2>/dev/null; RC=$?
[ "$RC" = 0 ] && [ ! -e "$W/unit-active" ] && grep -q "stop retroforge-steam.service" "$W/sysd.log" \
  && ok "stopped once nothing uses it (a hold of a launch that is gone counts for nothing)" || bad "rc=$RC $(cat "$W/sysd.log")"
"${KENV[@]}" bash "$KEEP" stop-unused 2>/dev/null; RC=$?
[ "$RC" = 0 ] && ok "not running: nothing to stop, exit 0" || bad "rc=$RC"

cat >"$W/bin/proton-pending" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$W/proton.calls"
case "\$1" in pending) [ -e "$W/pending" ] ;; apply) echo armv8 ;; esac
EOF
chmod +x "$W/bin/proton-pending"
PVARS=(RETROFORGE_STEAM_KEEP=on RETROFORGE_CPUINFO="$W/v80" RETROFORGE_STEAM_PROTON_CLI="$W/bin/proton-pending")
CASE="keep: our Proton pending"
reset_keep; rm -f "$W/proton.calls"; touch "$W/unit-active" "$W/pending"
bg_wrap "${PVARS[@]}" -- -gamepadui -steamos3
until_true '[ -s "$W/sdrun.args" ]'
grep -q "stop retroforge-steam.service" "$W/sysd.log" && [ -s "$W/sdrun.args" ] && [ ! -e "$W/call1" ] \
  && ok "the kept client is stopped, and this launch starts a new one (whose run sets the tool first), not handed to the old one" \
  || bad "sysd=$(cat "$W/sysd.log") call1=$(cat "$W/call1" 2>&1) $(cat "$W/err")"
kill -TERM "$wpid"; wait "$wpid" 2>/dev/null
grep -q "starts again with Proton-CachyOS as its tool" "$W/err" && ok "and it is said" || bad "$(cat "$W/err")"
reset_keep; rm -f "$W/proton.calls"; touch "$W/unit-active" "$W/pending"
fakeproc 4343 1 reaper "$STEAM_REAPER" SteamLaunch AppId=43 -- game
bg_wrap "${PVARS[@]}" -- -gamepadui
until_true '[ -e "$W/call1" ]'
[ -e "$W/call1" ] && [ ! -e "$W/sdrun.args" ] && ! grep -q " stop " "$W/sysd.log" \
  && ok "a game running under it: not stopped, the launch handed to it" || bad "sysd=$(cat "$W/sysd.log") $(cat "$W/err")"
kill -TERM "$wpid"; wait "$wpid" 2>/dev/null
reset_keep; rm -f "$W/proton.calls" "$W/pending"; touch "$W/unit-active"
bg_wrap "${PVARS[@]}" -- -gamepadui
until_true '[ -e "$W/call1" ]'
grep -qx pending "$W/proton.calls" 2>/dev/null && [ -e "$W/call1" ] && [ ! -e "$W/sdrun.args" ] \
  && ok "nothing pending: handed over as before" || bad "calls=$(cat "$W/proton.calls" 2>&1) $(cat "$W/err")"
kill -TERM "$wpid"; wait "$wpid" 2>/dev/null
reset_keep; rm -f "$W/proton.calls"; touch "$W/unit-active" "$W/pending"
bg_wrap RETROFORGE_STEAM_KEEP=on RETROFORGE_STEAM_PROTON_CLI="$W/bin/proton-pending" -- -gamepadui -steamos3   # $W/cpuinfo has atomics
until_true '[ -s "$W/sdrun.args" ]'
grep -qx pending "$W/proton.calls" 2>/dev/null && grep -q "stop retroforge-steam.service" "$W/sysd.log" && [ -s "$W/sdrun.args" ] && [ ! -e "$W/call1" ] \
  && ok "a CPU with LSE atomics is asked too (its GPU may need Sarek): a pending tool restarts the client there as well" \
  || bad "calls=$(cat "$W/proton.calls" 2>&1) sysd=$(cat "$W/sysd.log") $(cat "$W/err")"
kill -TERM "$wpid"; wait "$wpid" 2>/dev/null
rm -f "$W/pending" "$W/proton.calls"
reset_keep

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

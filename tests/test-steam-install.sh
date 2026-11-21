#!/usr/bin/env bash
# Offline test for /usr/lib/retroforge/steam-install: Steam Client from Main menu > Emulators
# (through retroforge-emu), with its progress.
#
#   tests/test-steam-install.sh
#
# Every stage it runs is a stand-in here (the bootstrap, the x86 guest helper, /usr/bin/steam), so
# the suite checks steam-install's own job: the order of the
# stages, one forward-only percentage (stdout and the progress file the page reads), the exit
# statuses retroforge-emu's page understands, what "installed" means, and on ARMv8.0 CPUs the
# Proton-CachyOS ARMv8.0 stage and Steam's default. The stages themselves have their own suites
# (test-steam.sh, test-steam-x86-guest.sh, test-steam-compat-tools.sh, test-steam-proton.sh).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOL="$ROOT/rootfs/overlay/usr/lib/retroforge/steam-install"
[ -f "$TOOL" ] || { echo "missing: $TOOL" >&2; exit 1; }

PASS=0; FAIL=0; CASE=""
ok()  { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
H="$T/home"; DATA="$H/.local/share"; CACHE="$T/cache"
STEAM_ROOT="$DATA/Steam"; GUEST="$DATA/retroforge/fex-guest"
PROG_CLIENT="$CACHE/retroforge/steam-install-steam-client.progress"
mkdir -p "$T/bin"

# The bootstrap: --install and RETROFORGE_STEAM_PROGRESS=1 expected; the client download's progress lines.
cat >"$T/bin/bootstrap" <<EOF
#!/usr/bin/env bash
echo "args=\$* progress=\${RETROFORGE_STEAM_PROGRESS-unset}" >>"$T/boot.log"
case "\${FAKE_BOOT:-ok}" in
  sha) echo "steam-bootstrap: sha256 mismatch for https://example/client.zip" >&2; exit 1 ;;
  net) echo "steam-bootstrap: could not download https://example/client.zip: timed out" >&2; exit 1 ;;
esac
for p in "30 110" "80 110" "110 110"; do echo "steam-bootstrap: progress \$p" >&2; done
mkdir -p "$STEAM_ROOT/steamrtarm64"
echo elf >"$STEAM_ROOT/steamrtarm64/steam"
echo "$STEAM_ROOT/steamrtarm64/steam"
EOF
# The x86 guest helper's `fetch`.
cat >"$T/bin/guest" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$T/guest.log"
case "\${FAKE_GUEST:-ok}" in
  space) echo "steam-x86-guest: not enough space in $GUEST: the x86 guest needs 1640 MB free" >&2; exit 1 ;;
  noimage) exit 0 ;;
esac
for p in 10 50 100; do echo "steam-x86-guest: \$p% of 1296 MB" >&2; done
mkdir -p "$GUEST"; echo sqsh >"$GUEST/img.sqsh"; ln -sfn img.sqsh "$GUEST/current"
EOF
# /usr/bin/steam, for the client's own update: records how it was started and the page's progress.
# Its lines are the real client's (bootstrap_log.txt, Pocket FIT, 2026-10-19): "Verification
# complete" at its start, before any download, then the download, then an unpack that prints nothing
# for longer than DONE_GRACE (1 s here; over a minute on hardware), then "Update complete".
cat >"$T/bin/steam" <<EOF
#!/usr/bin/env bash
{ echo "args=\$*"; echo "display=\${DISPLAY-unset} wayland=\${WAYLAND_DISPLAY-unset}"
  echo "progress-file=\$(cat "$PROG_CLIENT" 2>/dev/null)"; } >>"$T/steam.log"
echo "[2026-10-19 10:02:54] Verification complete"
case "\${FAKE_UPD:-ok}" in
  fail) echo "Steam: cannot open display" ; exit 1 ;;
  hang) echo "[2026-10-19 10:06:24] Update complete, launching..."; trap 'exit 143' TERM; while :; do sleep 0.1; done ;;
  current) echo "[2026-10-19 10:08:26] Nothing to do"; trap 'exit 143' TERM; while :; do sleep 0.1; done ;;
esac
for p in "100 of 1,000" "500 of 1,000" "1,000 of 1,000"; do echo "[ 50%] Downloading update (\$p KB)..."; done
echo "[2026-10-19 10:03:09] Extracting package..."
sleep 2
echo "unpack-progress=\$(cat "$PROG_CLIENT" 2>/dev/null)" >>"$T/steam.log"
echo "[2026-10-19 10:06:07] Installing update..."
mkdir -p "$STEAM_ROOT/package"
printf '"linuxarm64"\n{\n\t"version"\t\t"1791918634"\n}\n' >"$STEAM_ROOT/package/steam_client_steamdeck_stable_linuxarm64.installed"
echo "[2026-10-19 10:06:24] Update complete, launching..."
EOF
# retroforge-proton (ARMv8.0 CPUs): `install`, writing steam-compat-tools' progress file as it would;
# records the page's progress when it starts and while its download runs.
cat >"$T/bin/proton" <<EOF
#!/usr/bin/env bash
{ echo "\$*"; echo "progress-file=\$(cat "$PROG_CLIENT" 2>/dev/null)"; } >>"$T/proton.log"
echo proton >>"$T/order.log"
case "\${FAKE_PROTON:-ok}" in
  net) echo "retroforge-proton: steam-compat-tools: could not download proton-cachyos-x-armv8.tar.zst: timed out" >&2; exit 1 ;;
esac
mkdir -p "$DATA/retroforge"
for p in 30 80; do echo \$p >"$DATA/retroforge/steam-compat-tools.progress"; sleep 1.3; done
echo "seen=\$(cat "$PROG_CLIENT" 2>/dev/null)" >>"$T/proton.log"
echo unpacking >"$DATA/retroforge/steam-compat-tools.progress"; sleep 1.3
rm -f "$DATA/retroforge/steam-compat-tools.progress"
EOF
# retroforge-steam-proton: `apply`.
cat >"$T/bin/steam-proton" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$T/steam-proton.log"; echo apply >>"$T/order.log"; echo armv8
EOF
# systemctl: no kept Steam running (a real one, on a device, would skip the update stage).
mkdir -p "$T/path"; printf '#!/bin/sh\nexit 3\n' >"$T/path/systemctl"; chmod +x "$T/path/systemctl"
printf 'processor\t: 0\nFeatures\t: fp asimd evtstrm aes pmull sha1 sha2 crc32 cpuid\n' >"$T/v80"
printf 'processor\t: 0\nFeatures\t: fp asimd aes pmull sha1 sha2 crc32 atomics fphp cpuid\n' >"$T/v82"
chmod +x "$T/bin"/*

ENVS=(env -u DISPLAY -u WAYLAND_DISPLAY -u RETROFORGE_STEAM_X86_GUEST HOME="$H" XDG_DATA_HOME="$DATA" XDG_CACHE_HOME="$CACHE"
      RETROFORGE_STEAM_BOOTSTRAP="$T/bin/bootstrap" RETROFORGE_STEAM_X86_GUEST_HELPER="$T/bin/guest"
      RETROFORGE_STEAM_WRAPPER="$T/bin/steam" RETROFORGE_CPUINFO="$T/v82"
      RETROFORGE_PROTON_CLI="$T/bin/proton" RETROFORGE_STEAM_PROTON_CLI="$T/bin/steam-proton"
      RETROFORGE_STEAM_DONE_GRACE=1 DISPLAY=:1 WAYLAND_DISPLAY=gamescope-0 PATH="$T/path:$PATH")
si() {  # si [VAR=value...] -- <args...>
  local vars=(); while [ $# -gt 0 ] && [ "$1" != -- ]; do vars+=("$1"); shift; done; shift
  OUT="$("${ENVS[@]}" "${vars[@]}" python3 "$TOOL" "$@" 2>"$T/err")"; RC=$?
  ERR="$(cat "$T/err")"
}
reset() { rm -rf "$H" "$CACHE" "$T"/*.log; mkdir -p "$H"; }
field() { python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(json.dumps(d[sys.argv[2]][sys.argv[3]]))' "$OUT" "$1" "$2"; }
forward() {  # stdout is N% lines only, never going back, ending at 100%
  python3 - "$OUT" <<'PY'
import re, sys
lines = sys.argv[1].split("\n")
assert all(re.fullmatch(r"\d+%", l) for l in lines), lines
n = [int(l[:-1]) for l in lines]
assert n == sorted(set(n)) and n[-1] == 100, n
PY
}

# ================================================================================================
CASE="usage"
reset; si -- bogus; [ "$RC" = 2 ] && grep -q "usage: steam-install" <<<"$ERR" && ok "unknown command: exit 2" || bad "rc=$RC $ERR"
si -- install everything; [ "$RC" = 2 ] && ok "unknown component: exit 2" || bad "rc=$RC"
si -- install cli; [ "$RC" = 2 ] && ok "no Steam CLI any more (the library reads the client itself): exit 2" || bad "rc=$RC"

CASE="status, nothing installed"
reset; si -- status
[ "$RC" = 0 ] && [ "$(field steam-client installed)" = null ] && [ "$(python3 -c 'import json,sys; print(sorted(json.loads(sys.argv[1])))' "$OUT")" = "['steam-client']" ] \
  && ok "Steam Client alone, not installed" || bad "rc=$RC out=$OUT"
[ "$(field steam-client progress)" = "\"$PROG_CLIENT\"" ] && ok "the page's progress file, under the cache" || bad "$OUT"
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["steam-client"]["size"] > 1 << 30' "$OUT" \
  && ok "its size for the page: the client with its guest, over 1 GiB" || bad "$OUT"

CASE="install client"
reset; si -- install client
[ "$RC" = 0 ] && forward && ok "exit 0; stdout: forward-only percentages ending at 100%" || bad "rc=$RC out=$OUT err=$ERR"
grep -qx "args=--install progress=1" "$T/boot.log" && ok "the bootstrap ran with --install and RETROFORGE_STEAM_PROGRESS=1" || bad "$(cat "$T/boot.log")"
grep -qx "fetch" "$T/guest.log" && ok "then the x86 guest's fetch, in the foreground" || bad "$(cat "$T/guest.log" 2>&1)"
grep -qx "args=-steamdeck -exitsteam" "$T/steam.log" && ok "then the client's update: steam -steamdeck -exitsteam" || bad "$(cat "$T/steam.log")"
grep -qx "display=unset wayland=unset" "$T/steam.log" && ok "with no display (the updater window has nowhere to go)" || bad "$(grep display "$T/steam.log")"
p="$(sed -n 's/^progress-file=//p' "$T/steam.log")"
[ -n "$p" ] && [ "$p" -ge 50 ] && [ "$p" -le 65 ] && ok "the progress file said $p when the update started (bootstrap and guest done)" || bad "progress file: '$p'"
u="$(sed -n 's/^unpack-progress=//p' "$T/steam.log")"
[ -n "$u" ] && [ "$u" -ge 85 ] && [ "$u" -le 95 ] && ok "and $u while the client unpacked, past the download's end: the bar does not sit still" || bad "unpack progress: '$u'"
! grep -q "did not finish" <<<"$ERR" \
  && ok "the startup 'Verification complete' starts no grace: an unpack longer than DONE_GRACE finishes" || bad "$ERR"
[ ! -e "$PROG_CLIENT" ] && ok "and is removed at the end" || bad "left: $(cat "$PROG_CLIENT")"
grep -q "Steam Client is installed" <<<"$ERR" && ok "says so on stderr" || bad "$ERR"
si -- status
[ "$(field steam-client installed)" = '"1791918634"' ] && ok "status: installed, the client's version from its updater's manifest" || bad "$OUT"

CASE="install client, the update does not finish"
reset; si FAKE_UPD=fail -- install client
[ "$RC" = 0 ] && forward && grep -q "finishes it when Steam is first opened" <<<"$ERR" \
  && ok "the install still succeeds, and says the client finishes its update when first opened" || bad "rc=$RC err=$ERR"
si -- status; [ "$(field steam-client installed)" = '"installed"' ] && ok "installed, no version yet" || bad "$OUT"

CASE="install client, the client keeps running after its update"
reset; start=$SECONDS; si FAKE_UPD=hang -- install client
[ "$RC" = 0 ] && [ $((SECONDS - start)) -lt 20 ] && ok "TERMed DONE_GRACE after 'Update complete' (no hour-long wait)" || bad "rc=$RC took $((SECONDS - start)) s"
reset; start=$SECONDS; si FAKE_UPD=current -- install client
[ "$RC" = 0 ] && [ $((SECONDS - start)) -lt 20 ] && ok "no update ('Nothing to do'): the same grace, no hour-long wait" || bad "rc=$RC took $((SECONDS - start)) s"

CASE="install client, failures"
reset; si FAKE_BOOT=sha -- install client
[ "$RC" = 4 ] && [ ! -e "$PROG_CLIENT" ] && [ ! -e "$T/guest.log" ] && ok "a checksum mismatch: exit 4, nothing after it, no progress file" || bad "rc=$RC err=$ERR"
reset; si FAKE_BOOT=net -- install client; [ "$RC" = 3 ] && ok "a network failure: exit 3" || bad "rc=$RC"
reset; si FAKE_GUEST=space -- install client; [ "$RC" = 5 ] && ok "no room for the x86 guest: exit 5" || bad "rc=$RC err=$ERR"
reset; si FAKE_GUEST=noimage -- install client
[ "$RC" = 3 ] && grep -q "another download of it may still be running" <<<"$ERR" && ok "a fetch that left no image: exit 3, says why" || bad "rc=$RC err=$ERR"
[ ! -e "$T/steam.log" ] && ok "and the client's update is not started" || bad "$(cat "$T/steam.log")"

CASE="install client, the x86 guest off"
reset; si RETROFORGE_STEAM_X86_GUEST=0 -- install client
[ "$RC" = 0 ] && [ ! -e "$T/guest.log" ] && ok "RETROFORGE_STEAM_X86_GUEST=0: no guest download" || bad "rc=$RC"
si RETROFORGE_STEAM_X86_GUEST=0 -- status; [ "$(field steam-client installed)" != null ] && ok "and installed without it" || bad "$OUT"
si -- status; [ "$(field steam-client installed)" = null ] && ok "with the guest on again, not installed (it is missing)" || bad "$OUT"

# ================================================================================================
# ARMv8.0 CPUs: Proton-CachyOS ARMv8.0 is part of the client's install (retroforge-proton install,
# its progress file followed), then Steam's default (retroforge-steam-proton apply) once the client's
# update has written config.vdf.
CASE="ARMv8.0: install client"
reset; si RETROFORGE_CPUINFO="$T/v80" -- install client
[ "$RC" = 0 ] && forward && ok "exit 0; forward-only percentages ending at 100%" || bad "rc=$RC out=$OUT err=$ERR"
grep -qx "install" "$T/proton.log" && ok "retroforge-proton install ran" || bad "$(cat "$T/proton.log" 2>&1)"
p="$(sed -n 's/^progress-file=//p' "$T/proton.log")"
[ -n "$p" ] && [ "$p" -ge 45 ] && [ "$p" -le 60 ] && ok "after the client and its guest (the bar said $p)" || bad "progress file when Proton started: '$p'"
s="$(sed -n 's/^seen=//p' "$T/proton.log")"
[ -n "$s" ] && [ "$s" -gt "$p" ] && ok "the bar moved with its download (then $s)" || bad "start $p, while it downloaded '$s'"
u="$(sed -n 's/^progress-file=//p' "$T/steam.log")"
[ -n "$u" ] && [ "$u" -gt "${s:-0}" ] && ok "before the client's own update ($u when that started)" || bad "update started at '$u'"
grep -qx "apply" "$T/steam-proton.log" && [ "$(head -1 "$T/order.log")" = proton ] && [ "$(tail -1 "$T/order.log")" = apply ] \
  && ok "then retroforge-steam-proton apply, after the update: Steam's default" || bad "order: $(cat "$T/order.log" 2>&1)"
si RETROFORGE_CPUINFO="$T/v80" -- status
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["steam-client"]["size"] > (1296 + 652 + 110 + 400) << 20' "$OUT" \
  && ok "status: its size counts the Proton download" || bad "$OUT"

CASE="ARMv8.0: Proton cannot be installed"
reset; si RETROFORGE_CPUINFO="$T/v80" FAKE_PROTON=net -- install client
[ "$RC" = 3 ] && grep -q "Proton-CachyOS for this CPU (ARMv8.0) could not be installed" <<<"$ERR" && [ ! -e "$T/steam.log" ] \
  && ok "exit 3 (network), before the client's update" || bad "rc=$RC err=$ERR"
[ ! -e "$PROG_CLIENT" ] && ok "no progress file left" || bad "left: $(cat "$PROG_CLIENT")"

CASE="a CPU with LSE atomics"
reset; si RETROFORGE_CPUINFO="$T/v82" -- install client
[ "$RC" = 0 ] && [ ! -e "$T/proton.log" ] && [ ! -e "$T/steam-proton.log" ] \
  && ok "no Proton downloaded, Steam's default left alone" || bad "rc=$RC $(cat "$T/proton.log" "$T/steam-proton.log" 2>&1)"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

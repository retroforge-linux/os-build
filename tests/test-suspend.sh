#!/usr/bin/env bash
# Offline test for /usr/bin/retroforge-suspend's PANEL BLANK path, and for its radio block never
# being restored at a later boot.
#
#   tests/test-suspend.sh
#
# WHY THIS FILE EXISTS, and why it does not run the engine. retroforge-suspend freezes cgroups and
# offlines CPUs; running do_suspend on a workstation would freeze the workstation. So this covers the
# one part that is pure logic and was the actual defect (#41): what happens to the screen when
# gamescope cannot be reached.
#
# THE DEFECT, HW 2026-07-26: entering suspend by any path that is not Steam's own sleep flow left the
# panel LIT for the whole frozen window. retroforge-suspend runs as systemd-suspend.service (root,
# system.slice) and cannot resolve the live gamescope socket from there, so the KMS blank never
# happened -- and `panel()` reported success anyway, so nothing noticed. Steam's client blank was the
# only thing turning the screen off.
#
# HOW IT WORKS: the two functions are extracted from the SHIPPED script by name and sourced into a
# sandbox, with RETROFORGE_BL_GLOB pointed at a fake backlight tree. What runs under test is the text
# that ships; nothing is reimplemented here. The wiring between them (do_suspend falling back,
# do_resume unblanking unconditionally) cannot be executed safely, so it is asserted structurally
# against the same file, and that limit is stated rather than papered over.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUSPEND="$ROOT/rootfs/overlay/usr/bin/retroforge-suspend"
[ -f "$SUSPEND" ] || { echo "no retroforge-suspend: $SUSPEND" >&2; exit 1; }

PASS=0; FAIL=0; CASE=""
ok()  { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT

# Pull the functions out of the shipped file rather than copying them. A rename breaks the extract
# and fails the suite, which is the intended behaviour: this file must not drift into testing a
# private copy of logic that no longer ships.
extract() { sed -n "/^$1() {/,/^}/p" "$SUSPEND"; }
for fn in bl_power panel; do
  [ -n "$(extract "$fn")" ] || { echo "could not extract $fn() from the shipped script" >&2; exit 1; }
done

{ echo 'log() { :; }'; extract bl_power; } > "$W/bl.sh"

# =================================================================================================
CASE="bl_power-writes-every-backlight"
mkdir -p "$W/bl/panel0" "$W/bl/panel1"
echo 0 >"$W/bl/panel0/bl_power"; echo 0 >"$W/bl/panel1/bl_power"
sh -c ". $W/bl.sh; RETROFORGE_BL_GLOB=\"$W/bl/*\"; bl_power 4"
got="$(cat "$W/bl/panel0/bl_power")$(cat "$W/bl/panel1/bl_power")"
[ "$got" = "44" ] && ok "4 (FB_BLANK_POWERDOWN) reaches every device" \
                  || bad "devices read '$got', expected '44'"
sh -c ". $W/bl.sh; RETROFORGE_BL_GLOB=\"$W/bl/*\"; bl_power 0"
got="$(cat "$W/bl/panel0/bl_power")$(cat "$W/bl/panel1/bl_power")"
[ "$got" = "00" ] && ok "0 restores every device" || bad "devices read '$got', expected '00'"

CASE="bl_power-reports-when-it-did-nothing"
# The return value is what decides whether the suspend log says "SLEEPING WITH THE PANEL LIT". A
# fallback that silently no-ops is the same defect as the one this fixes, one layer down.
mkdir -p "$W/empty"
sh -c ". $W/bl.sh; RETROFORGE_BL_GLOB=\"$W/empty/*\"; bl_power 4"
[ $? -ne 0 ] && ok "returns non-zero when no writable bl_power exists" \
             || bad "returned 0 with nothing to write to"

CASE="panel-reports-an-unreachable-gamescope"
# THE ORIGINAL BUG. panel() used to `return 0` when gamescopectl was missing -- "nothing to do" --
# which is indistinguishable from "the screen is off" to every caller. With no gamescopectl on PATH
# it must now FAIL, because that is what arms the fallback.
{ echo 'log() { :; }'; echo 'gs_resolve_display() { return 1; }'; extract panel; } > "$W/panel.sh"
# The interpreter is invoked by ABSOLUTE PATH and PATH is emptied INSIDE it. Emptying PATH for `env`
# instead makes `sh` itself unfindable, and the test then passes on env's 127 -- which it did on the
# first run of this file. A marker on stdout proves the function actually ran.
mkdir -p "$W/nothing"
out="$(env -i RETROFORGE_REST_SCREEN=external /bin/sh -c \
  ". $W/panel.sh; PATH=$W/nothing; panel 1; echo \"rc=\$?\"" 2>/dev/null)"
case "$out" in
  rc=0) bad "reported success with no gamescopectl -- the caller would freeze with the panel lit" ;;
  rc=*) ok "no gamescopectl on PATH is a failure, not a no-op ($out)" ;;
  *)    bad "panel() never ran (output: '${out:-<nothing>}') -- the case proves nothing" ;;
esac

CASE="the-wiring"
# STRUCTURAL, and deliberately so: do_suspend freezes cgroups, so executing it here would freeze the
# machine running the tests. These assert that the two call sites exist at all -- weaker than running
# them, and the honest limit of an offline suite for this file.
if grep -qE '^\s*if panel 1 && wait_panel disabled; then' "$SUSPEND"; then
  ok "the blank waits on the connector only when gamescope actually answered"
else
  bad "do_suspend no longer short-circuits the wait on an unreachable gamescope"
fi
if grep -qE 'bl_power 4' "$SUSPEND"; then
  ok "the suspend path has a backlight fallback"
else
  bad "no bl_power 4 in the suspend path"
fi
# Unconditional on resume: if the blank came from the fallback, gamescope never knew the screen was
# off and nothing else will turn it back on. A woken device stuck dark is worse than one that slept lit.
if grep -qE '^\s*bl_power 0\s*$' "$SUSPEND"; then
  ok "the resume path unblanks the backlight unconditionally"
else
  bad "bl_power 0 is missing or conditional in do_resume -- a wake could stay dark"
fi

CASE="the-radio-block-never-outlives-the-boot"
# HW 2026-10-23, MANGMI Air X: an update was installed while the device slept, it was woken and
# rebooted, and the new slot came up with Wi-Fi soft-blocked. systemd-rfkill had saved power_enter's
# temporary block to /var/lib/systemd/rfkill, and post-install copies the running /var into the new
# slot; losing power or rebooting while asleep ends the same way. So nothing may save or restore
# rfkill state across boots. Structural, like the-wiring: systemd does not run here.
UNITS="$ROOT/rootfs/overlay/etc/systemd/system"
for u in systemd-rfkill.service systemd-rfkill.socket; do
  if [ -L "$UNITS/$u" ] && [ "$(readlink "$UNITS/$u")" = /dev/null ]; then
    ok "$u is masked"
  else
    bad "$u is not masked -- a block saved during sleep comes back at the next boot"
  fi
done
RULE="$ROOT/rootfs/overlay/usr/lib/udev/rules.d/99-zz-retroforge-rfkill.rules"
if grep -qxF 'SUBSYSTEM=="misc", KERNEL=="rfkill", ENV{SYSTEMD_WANTS}=""' "$RULE" 2>/dev/null; then
  ok "udev no longer wants the masked socket"
else
  bad "no rule clearing /dev/rfkill's SYSTEMD_WANTS -- every rfkill uevent logs a masked-unit warning"
fi
# udev applies rules files in strcmp order; ahead of 99-systemd.rules the clear is undone.
first="$(printf '%s\n' "${RULE##*/}" 99-systemd.rules | LC_ALL=C sort | head -n1)"
if [ "$first" = 99-systemd.rules ]; then
  ok "${RULE##*/} runs after 99-systemd.rules"
else
  bad "${RULE##*/} sorts before 99-systemd.rules, so its clear is undone"
fi

CASE="audio-park"
# A kernel suspend parks every sound card on its "off" profile and puts the old profile back on
# resume. The shipped audio_park/audio_unpark run against a stub pa() that plays pactl: it prints two
# cards (one already off) and records what it is asked to set.
for fn in audio_park audio_unpark; do
  [ -n "$(extract "$fn")" ] || { echo "could not extract $fn() from the shipped script" >&2; exit 1; }
done
{
  echo 'log() { :; }'
  echo "AUDIO_STATE=$W/audio-profiles"
  cat <<'STUB'
pa() {
  case "$1" in
    list) printf 'Card #0\n\tName: alsa_card.platform-sound\n\tDriver: alsa\n\tProfiles:\n\t\toff: Off (sinks: 0)\n\t\tHiFi (Headphones, Speaker): x\n\tActive Profile: HiFi (Headphones, Speaker)\nCard #1\n\tName: alsa_card.usb-dongle\n\tActive Profile: off\n' ;;
    set-card-profile) printf '%s|%s\n' "$2" "$3" >> "$PA_LOG" ;;
  esac
}
STUB
  extract audio_park; extract audio_unpark
} > "$W/audio.sh"
: > "$W/pa.log"
sh -c ". $W/audio.sh; PA_LOG=$W/pa.log; audio_park"
[ "$(cat "$W/pa.log")" = 'alsa_card.platform-sound|off' ] \
  && ok "parks the active card on off and leaves a card that is already off alone" \
  || bad "set-card-profile calls: '$(cat "$W/pa.log")'"
[ "$(cat "$W/audio-profiles")" = "$(printf 'alsa_card.platform-sound\tHiFi (Headphones, Speaker)')" ] \
  && ok "records the profile to restore, spaces and all" \
  || bad "state file: '$(cat "$W/audio-profiles")'"
: > "$W/pa.log"
sh -c ". $W/audio.sh; PA_LOG=$W/pa.log; audio_unpark"
[ "$(cat "$W/pa.log")" = 'alsa_card.platform-sound|HiFi (Headphones, Speaker)' ] && [ ! -e "$W/audio-profiles" ] \
  && ok "restores the recorded profile and removes the state file" \
  || bad "restore calls: '$(cat "$W/pa.log")', state file still there: $([ -e "$W/audio-profiles" ] && echo yes || echo no)"
if grep -qE '^\s*audio_park\s*$' "$SUSPEND" && grep -qE '^\s*audio_unpark\s*$' "$SUSPEND"; then
  ok "do_suspend parks and do_resume unparks"
else
  bad "audio_park/audio_unpark are not both called"
fi

CASE="kernel-sleep-mem-mode"
# RETROFORGE_SUSPEND_MODE=mem boards suspend the kernel from kernel_sleep. Run the shipped function
# against a fake /sys/power: libinput is a stub function (the real one would grab this machine's keys)
# and the debounce is 0, so nothing sleeps or blocks.
[ -n "$(extract kernel_sleep)" ] || { echo "could not extract kernel_sleep() from the shipped script" >&2; exit 1; }
{ echo 'log() { :; }'; echo 'find_power_dev() { return 1; }'; echo 'libinput() { :; }'; extract kernel_sleep; } > "$W/ks.sh"
ks() {  # $1 = power dir
  sh -c ". $W/ks.sh; RETROFORGE_POWER_DIR=$1; RETROFORGE_WAKE_DEBOUNCE_MS=0; kernel_sleep; echo \"rc=\$?\""
}
mkdir -p "$W/pw1"; echo 's2idle [deep]' > "$W/pw1/mem_sleep"; : > "$W/pw1/state"
out="$(ks "$W/pw1")"
[ "$out" = rc=0 ] && [ "$(cat "$W/pw1/state")" = mem ] && [ "$(cat "$W/pw1/mem_sleep")" = deep ] \
  && ok "writes mem to state and picks deep where the platform offers it" \
  || bad "got '$out', state '$(cat "$W/pw1/state")', mem_sleep '$(cat "$W/pw1/mem_sleep")'"
mkdir -p "$W/pw2"; echo '[s2idle]' > "$W/pw2/mem_sleep"; : > "$W/pw2/state"
out="$(ks "$W/pw2")"
[ "$out" = rc=0 ] && [ "$(cat "$W/pw2/mem_sleep")" = '[s2idle]' ] \
  && ok "leaves mem_sleep alone when deep is not offered (s2idle)" \
  || bad "got '$out', mem_sleep '$(cat "$W/pw2/mem_sleep")'"
mkdir -p "$W/pw3"
out="$(ks "$W/pw3")"
[ "$out" != rc=0 ] && ok "fails when there is no writable state ($out)" || bad "returned 0 with no state file"
if grep -qE '^\s*kernel_sleep \|\| wait_for_wake\s*$' "$SUSPEND"; then
  ok "a refused kernel suspend falls back to waiting for the power key"
else
  bad "the mem dispatch does not fall back to wait_for_wake"
fi
if grep -qE 'RETROFORGE_SUSPEND_MODE:=.*device-env.*RETROFORGE_SUSPEND_MODE=' "$SUSPEND"; then
  ok "the mode comes from the board profile via device-env"
else
  bad "retroforge-suspend does not read RETROFORGE_SUSPEND_MODE from device-env"
fi

echo
echo "test-suspend.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

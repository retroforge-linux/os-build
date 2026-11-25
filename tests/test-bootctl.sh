#!/usr/bin/env bash
# Offline test for /usr/bin/retroforge-bootctl.
#
#   tests/test-bootctl.sh
#
# WHY THIS FILE EXISTS. bootctl is what tells RAUC that a boot was healthy (mark-good, from
# retroforge-boot-good.service) and that it was not (set-state self bad, from
# retroforge-boot-bad.service). Both run unattended on every boot of every device, so a wrong exit
# status is either a healthy slot that never stops being a trial -- and fails over after three boots
# -- or a unit that re-fires every 30s for the rest of the uptime. Neither needs hardware to catch.
#
# THE CONTRACT IS THE EXIT STATUS, and every legal call exits 0, including no-ops.
#
# HOW IT WORKS: the real, shipped retroforge-bootctl is executed -- not a copy. It exposes the seams
# BOOTINFO, SESSION_MARKER, RAUC, EDITENV, ESP, EFI, GRUBENV and BOOTDIR, documented at the top of
# the tool. `rauc` and `grub-editenv` are stubbed on disk: the rauc stub edits the grubenv the way
# RAUC's grub backend does (bootloaders/grub.c: mark-good sets <slot>_OK=1 _TRY=0, mark-bad _OK=0
# _TRY=0, mark-active also puts the slot first in ORDER) and logs every call; the grub-editenv stub
# keeps the block as plain key=value lines, which is all `list` shows of a real one.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BOOTCTL="$ROOT/rootfs/overlay/usr/bin/retroforge-bootctl"
[ -f "$BOOTCTL" ] || { echo "no retroforge-bootctl: $BOOTCTL" >&2; exit 1; }

PASS=0; FAIL=0; CASE=""; SB=""
OUT=""; RC=0

ok()  { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }

# --- stubs --------------------------------------------------------------------------------------
EDITENV_STUB='#!/usr/bin/env bash
set -u
f="$1"; cmd="$2"; shift 2
case "$cmd" in
  list) [ -f "$f" ] || exit 1; cat "$f" ;;
  set)
    [ -f "$f" ] || exit 1
    for kv in "$@"; do
      k="${kv%%=*}"
      grep -v "^$k=" "$f" > "$f.tmp" || true
      printf "%s\n" "$kv" >> "$f.tmp"
      mv "$f.tmp" "$f"
    done ;;
  *) echo "grub-editenv stub: unknown command $cmd" >&2; exit 2 ;;
esac
'
RAUC_STUB='#!/usr/bin/env bash
set -u
printf "%s\n" "$*" >> "$SB/rauc.log"
[ -e "$SB/rauc.fail" ] && { echo "rauc stub: failing on purpose" >&2; exit 1; }
[ "${1:-}" = status ] || { echo "rauc stub: only status is stubbed" >&2; exit 2; }
verb="${2:-}"; slot="${3:-}"
case "$slot" in
  booted)   name=$(sed -n "s/^slot=//p" "$SB/run/boot") ;;
  rootfs.0) name=A ;;
  rootfs.1) name=B ;;
  *) echo "rauc stub: unknown slot $slot" >&2; exit 1 ;;
esac
[ -n "$name" ] || { echo "rauc stub: no booted slot" >&2; exit 1; }
other=A; [ "$name" = A ] && other=B
e="$SB/esp/EFI/steamos/grubenv"
case "$verb" in
  mark-good)   grub-editenv "$e" set "${name}_OK=1" "${name}_TRY=0" ;;
  mark-bad)    grub-editenv "$e" set "${name}_OK=0" "${name}_TRY=0" ;;
  mark-active) grub-editenv "$e" set "${name}_OK=1" "${name}_TRY=0" "ORDER=$name $other" ;;
  *) echo "rauc stub: unknown verb $verb" >&2; exit 2 ;;
esac
'

# --- sandbox ------------------------------------------------------------------------------------
sandbox() {
  SB="$(mktemp -d)"
  mkdir -p "$SB/bin" "$SB/esp/EFI/steamos" "$SB/efi/EFI/steamos" "$SB/run" "$SB/boot/dtbs"
  printf '%s\n' "$EDITENV_STUB" >"$SB/bin/grub-editenv"
  printf '%s\n' "$RAUC_STUB" >"$SB/bin/rauc"
  chmod +x "$SB/bin/grub-editenv" "$SB/bin/rauc"
  printf 'ORDER=A B\nA_OK=1\nA_TRY=1\nB_OK=1\nB_TRY=0\n' >"$SB/esp/EFI/steamos/grubenv"
  printf 'nd_efi_a=2\nnd_efi_b=3\n' >"$SB/efi/EFI/steamos/parts.env"
  printf 'dtb-one' >"$SB/boot/dtbs/one.dtb"
  printf 'dtb-two' >"$SB/boot/dtbs/two.dtb"
  seed_boot A
}
done_() { chmod -R u+w "$SB" 2>/dev/null; rm -rf "$SB"; }
t() { CASE="$1"; sandbox; }
seed_boot() {  # <slot or ""> -- the initramfs handoff
  if [ -n "$1" ]; then printf 'slot=%s\nsource=partuuid\n' "$1" >"$SB/run/boot"
  else printf 'source=cmdline-fallback\n' >"$SB/run/boot"; fi
}

run() {  # <args...> -- the real bootctl against the sandbox; sets OUT and RC
  OUT="$(env SB="$SB" PATH="$SB/bin:$PATH" \
            BOOTINFO="$SB/run/boot" SESSION_MARKER="$SB/marker" PROC="$SB/proc" \
            RAUC=rauc EDITENV=grub-editenv \
            ESP="$SB/esp" EFI="$SB/efi" BOOTDIR="$SB/boot" \
            bash "$BOOTCTL" "$@" 2>&1)"
  RC=$?
}
envval() { sed -n "s/^$1=//p" "$SB/esp/EFI/steamos/grubenv" | tail -1; }
rauc_calls() { cat "$SB/rauc.log" 2>/dev/null; }

# --- get-current --------------------------------------------------------------------------------
t "get-current"
run get-current
[ "$RC" = 0 ] && [ "$OUT" = A ] && ok "names the booted slot (A)" || bad "rc=$RC out='$OUT'"
seed_boot B; run get-current
[ "$OUT" = B ] && ok "follows the handoff (B)" || bad "out='$OUT'"
seed_boot ""; run get-current
[ "$RC" != 0 ] && ok "a cmdline-fallback boot names no slot (rc=$RC)" || bad "answered '$OUT' for a boot with no slot"
done_

# --- get-primary / get-state: RAUC's rule over the grubenv -------------------------------------
t "get-primary"
run get-primary
[ "$RC" = 0 ] && [ "$OUT" = B ] && ok "A is on a try, so the primary is B" || bad "rc=$RC out='$OUT'"
printf 'ORDER=A B\nA_OK=1\nA_TRY=0\nB_OK=1\nB_TRY=0\n' >"$SB/esp/EFI/steamos/grubenv"
run get-primary
[ "$OUT" = A ] && ok "the first good slot in ORDER" || bad "out='$OUT'"
printf 'ORDER=A B\nA_OK=0\nA_TRY=0\nB_OK=1\nB_TRY=3\n' >"$SB/esp/EFI/steamos/grubenv"
run get-primary
[ "$RC" != 0 ] && ok "no good slot is an error (rc=$RC)" || bad "answered '$OUT' with no good slot"
done_

t "get-state"
run get-state A
[ "$RC" = 0 ] && [ "$OUT" = bad ] && ok "a slot on a try is bad to RAUC" || bad "rc=$RC out='$OUT'"
run get-state B
[ "$OUT" = good ] && ok "OK=1, TRY=0 is good" || bad "out='$OUT'"
run get-state self
[ "$OUT" = bad ] && ok "self resolves to the booted slot" || bad "out='$OUT'"
run get-state C
[ "$RC" != 0 ] && ok "an unknown slot is refused" || bad "accepted slot C"
done_

# --- set-state / set-primary: through RAUC ------------------------------------------------------
t "set-state"
run set-state self bad
[ "$RC" = 0 ] && ok "self bad exits 0" || bad "rc=$RC: $OUT"
[ "$(rauc_calls)" = "status mark-bad booted" ] && ok "asks RAUC to mark the booted slot bad" \
  || bad "rauc saw: $(rauc_calls | tr '\n' ';')"
[ "$(envval A_OK)" = 0 ] && ok "A_OK=0, so the next boot goes to B" || bad "A_OK=$(envval A_OK)"
: >"$SB/rauc.log"
run set-state B good
[ "$(rauc_calls)" = "status mark-good rootfs.1" ] && ok "B good is mark-good rootfs.1" \
  || bad "rauc saw: $(rauc_calls | tr '\n' ';')"
run set-state A sideways
[ "$RC" != 0 ] && ok "a bad state value is refused" || bad "accepted 'sideways'"
touch "$SB/rauc.fail"; run set-state self bad
[ "$RC" != 0 ] && ok "a RAUC failure is not hidden (rc=$RC)" || bad "exited 0 though rauc failed"
done_

t "set-primary"
run set-primary B
[ "$RC" = 0 ] && [ "$(rauc_calls)" = "status mark-active rootfs.1" ] && ok "is rauc status mark-active" \
  || bad "rc=$RC rauc saw: $(rauc_calls | tr '\n' ';')"
[ "$(envval ORDER)" = "B A" ] && ok "B is first in ORDER" || bad "ORDER=$(envval ORDER)"
done_

# --- mark-good ----------------------------------------------------------------------------------
t "mark-good"
run mark-good
[ "$RC" = 0 ] && ok "exits 0" || bad "rc=$RC: $OUT"
[ "$(rauc_calls)" = "status mark-good booted" ] && ok "confirms through rauc status mark-good booted" \
  || bad "rauc saw: $(rauc_calls | tr '\n' ';')"
[ "$(envval A_OK)" = 1 ] && [ "$(envval A_TRY)" = 0 ] && ok "the trial is over (A_OK=1, A_TRY=0)" \
  || bad "A_OK=$(envval A_OK) A_TRY=$(envval A_TRY)"
# The ESP is finished from the running system, after the verdict.
cmp -s "$SB/efi/EFI/steamos/parts.env" "$SB/esp/EFI/steamos/parts.env" \
  && ok "copies parts.env onto the ESP" || bad "the ESP has no copy of parts.env"
[ -f "$SB/esp/dtbs/qcom/one.dtb" ] && [ -f "$SB/esp/dtbs/qcom/two.dtb" ] \
  && ok "copies OpenABL's Device model DTBs to \\dtbs\\qcom" || bad "\\dtbs\\qcom is incomplete"
done_

t "mark-good keeps the saved board as it is"
printf 'saved_entry=mangmi-air-x-mq66\n' >>"$SB/esp/EFI/steamos/grubenv"
run mark-good
[ "$RC" = 0 ] && [ "$(envval saved_entry)" = mangmi-air-x-mq66 ] && [ -z "$(envval rf_board_ok)" ] \
  && ok "saved_entry is kept and nothing else is recorded for it" \
  || bad "rc=$RC saved_entry=$(envval saved_entry) rf_board_ok=$(envval rf_board_ok)"
done_

t "mark-good on a degraded boot"
seed_boot ""
run mark-good --require-marker
[ "$RC" = 0 ] && ok "a boot with no slot exits 0" || bad "rc=$RC: $OUT"
printf '%s' "$OUT" | grep -q 'nothing to confirm' && ok "and says there is nothing to confirm" || bad "out='$OUT'"
[ -z "$(rauc_calls)" ] && ok "and never asks RAUC" || bad "rauc saw: $(rauc_calls | tr '\n' ';')"
done_

t "mark-good --require-marker"
run mark-good --require-marker
[ "$RC" != 0 ] && ok "no session marker: refuses (rc=$RC)" || bad "confirmed without a session"
[ -z "$(rauc_calls)" ] && ok "and RAUC was never asked" || bad "rauc saw: $(rauc_calls | tr '\n' ';')"
touch "$SB/marker"; run mark-good --require-marker
[ "$RC" = 0 ] && [ "$(rauc_calls)" = "status mark-good booted" ] && ok "with the marker: confirms" \
  || bad "rc=$RC rauc saw: $(rauc_calls | tr '\n' ';')"
done_

t "mark-good --wait"
run mark-good --wait soon
[ "$RC" != 0 ] && ok "a non-number is refused" || bad "accepted --wait soon"
( env SB="$SB" PATH="$SB/bin:$PATH" BOOTINFO="$SB/run/boot" SESSION_MARKER="$SB/marker" \
      RAUC=rauc EDITENV=grub-editenv ESP="$SB/esp" EFI="$SB/efi" BOOTDIR="$SB/boot" \
      bash "$BOOTCTL" mark-good --wait 30 >"$SB/wait.out" 2>&1 &
  pid=$!
  sleep 1
  kill -TERM "$pid" 2>/dev/null
  wait "$pid"; echo $? >"$SB/wait.rc" )
[ "$(cat "$SB/wait.rc" 2>/dev/null)" = 0 ] && ok "a signal during the wait exits 0" \
  || bad "rc=$(cat "$SB/wait.rc" 2>/dev/null): $(cat "$SB/wait.out")"
grep -q 'not confirming, not demoting' "$SB/wait.out" && ok "and says it gave no verdict" || bad "out: $(cat "$SB/wait.out")"
[ -z "$(rauc_calls)" ] && ok "and RAUC was never asked" || bad "rauc saw: $(rauc_calls | tr '\n' ';')"
done_

# --same-session: the marker holds gamescope's PID; $SB/proc/<pid> stands in for a running one.
bg_mark() {  # <args...> -- mark-good in the background, its output in $SB/bg.out, its rc in $SB/bg.rc
  ( env SB="$SB" PATH="$SB/bin:$PATH" BOOTINFO="$SB/run/boot" SESSION_MARKER="$SB/marker" PROC="$SB/proc" \
        RAUC=rauc EDITENV=grub-editenv ESP="$SB/esp" EFI="$SB/efi" BOOTDIR="$SB/boot" \
        bash "$BOOTCTL" mark-good "$@" >"$SB/bg.out" 2>&1; echo $? >"$SB/bg.rc" ) &
  BG=$!
}
t "mark-good --same-session"
run mark-good --require-marker --same-session
[ "$RC" != 0 ] && [ -z "$(rauc_calls)" ] && ok "no marker: refuses, RAUC never asked" || bad "rc=$RC rauc: $(rauc_calls)"
echo 4242 >"$SB/marker"; run mark-good --require-marker --same-session
[ "$RC" != 0 ] && [ -z "$(rauc_calls)" ] && ok "a marker whose gamescope is gone: refuses" || bad "rc=$RC rauc: $(rauc_calls)"
mkdir -p "$SB/proc/4242"; run mark-good --require-marker --same-session --wait 1
[ "$RC" = 0 ] && [ "$(rauc_calls)" = "status mark-good booted" ] && ok "the same running session after the wait: confirms" \
  || bad "rc=$RC rauc: $(rauc_calls | tr '\n' ';') $OUT"
done_

t "mark-good --same-session, a restart during the wait"
mkdir -p "$SB/proc/4242"; echo 4242 >"$SB/marker"
bg_mark --require-marker --same-session --wait 1
sleep 0.4; mkdir -p "$SB/proc/4343"; echo 4343 >"$SB/marker"; rm -r "$SB/proc/4242"
wait "$BG"
[ "$(cat "$SB/bg.rc")" = 0 ] && [ "$(rauc_calls)" = "status mark-good booted" ] \
  && ok "the new session is waited for, then confirmed" || bad "rc=$(cat "$SB/bg.rc") rauc: $(rauc_calls) $(cat "$SB/bg.out")"
grep -q "restarted during the 1s re-check (gamescope 4242, now 4343)" "$SB/bg.out" && ok "and it says so" || bad "out: $(cat "$SB/bg.out")"
done_

t "mark-good --same-session, the session gone during the wait"
mkdir -p "$SB/proc/4242"; echo 4242 >"$SB/marker"
bg_mark --require-marker --same-session --wait 1
sleep 0.4; rm -f "$SB/marker"; rm -r "$SB/proc/4242"
wait "$BG"
[ "$(cat "$SB/bg.rc")" != 0 ] && [ -z "$(rauc_calls)" ] && ok "refuses (rc=$(cat "$SB/bg.rc")), so OnFailure= demotes" \
  || bad "rc=$(cat "$SB/bg.rc") rauc: $(rauc_calls)"
grep -q "ended during the 1s re-check" "$SB/bg.out" && ok "and it says the session ended" || bad "out: $(cat "$SB/bg.out")"
done_

t "mark-good when RAUC fails"
touch "$SB/rauc.fail"
run mark-good
[ "$RC" != 0 ] && ok "a failed confirmation is a failure (rc=$RC), so OnFailure= demotes" || bad "exited 0"
[ ! -f "$SB/esp/EFI/steamos/parts.env" ] && ok "and the ESP is not touched" || bad "finished the ESP without a verdict"
done_

t "mark-good when the ESP cannot be finished"
chmod a-w "$SB/esp"
run mark-good
chmod u+w "$SB/esp"
[ "$RC" = 0 ] && ok "still exits 0: the verdict stands" || bad "rc=$RC: $OUT"
[ "$(rauc_calls)" = "status mark-good booted" ] && ok "and the boot was confirmed" || bad "rauc saw: $(rauc_calls | tr '\n' ';')"
printf '%s' "$OUT" | grep -q 'could not finish the ESP' && ok "and it says the ESP was left as it was" || bad "out='$OUT'"
done_

# --- status / usage -----------------------------------------------------------------------------
t "status"
run status
[ "$RC" = 0 ] && ok "exits 0" || bad "rc=$RC"
printf '%s' "$OUT" | grep -q 'ORDER=A B' && printf '%s' "$OUT" | grep -q 'A_TRY=1' \
  && ok "shows RAUC's slot state" || bad "out='$OUT'"
printf '%s\n' "$OUT" | grep -q '^next boot:   B$' && ok "and what boots next" || bad "out='$OUT'"
done_

t "usage"
run --help
[ "$RC" = 2 ] && printf '%s' "$OUT" | grep -q 'mark-good' && ok "--help prints the header" || bad "rc=$RC"
run frobnicate
[ "$RC" = 1 ] && ok "an unknown command exits 1" || bad "rc=$RC"
done_

# --- the shipped units call what this tool dispatches -------------------------------------------
CASE="units"
UNITS="$ROOT/rootfs/overlay/usr/lib/systemd/system"
grep -qx 'ExecStart=/usr/bin/retroforge-bootctl mark-good --require-marker --same-session --wait 10' "$UNITS/retroforge-boot-good.service" \
  && ok "boot-good runs mark-good --require-marker --same-session --wait 10" || bad "boot-good's ExecStart changed"
grep -qx 'ExecStart=/usr/bin/retroforge-bootctl set-state self bad' "$UNITS/retroforge-boot-bad.service" \
  && ok "boot-bad runs set-state self bad" || bad "boot-bad's ExecStart changed"

echo
echo "test-bootctl.sh: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

#!/usr/bin/env bash
# Offline test for the /var check in image/initramfs/init (fsck_var / fsck_log): e2fsck -p before
# /var is mounted, -p -f after a replayed journal, -f -y when damage is left (exit 4), and a mount
# that runs whatever the result.
#
#   tests/test-initramfs-fsck.sh
#
# WHY: nothing else checks /var (systemd-fsck only sees fstab mounts), and the init runs on a device
# with no console, so a wrong exit-code branch is either damage that is never repaired or a boot
# that stops. Plus static checks that mkinitramfs ships e2fsck, that the check sits on the /var
# mount's own branch, and that the cmdline carries fsck.repair=yes for /home.
#
# HOW: the two functions are cut out of the shipped init and sourced, with log/warn writing to a
# file and the splash directory moved into a sandbox. e2fsck is a stub on PATH whose exit code per
# mode comes from $SB/rc-p, $SB/rc-pf and $SB/rc-y, which prints preen's "recovering journal" line
# when $SB/replay exists, and which records the splash status it saw.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INIT="$ROOT/image/initramfs/init"
MKI="$ROOT/image/mkinitramfs.sh"
GRUB="$ROOT/boot/gen-grub-cfg.sh"

PASS=0; FAIL=0; CASE=""; SB=""
ok()  { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }

funcs=$(sed -n '/^fsck_log() {/,/^}/p; /^fsck_var() {/,/^}/p' "$INIT")
[ -n "$funcs" ] || { echo "no fsck_log/fsck_var in $INIT" >&2; exit 1; }

sandbox() {  # <rc for -p> [rc for -f -y] [lines of -p output] [rc for -p -f]
  SB="$(mktemp -d)"
  mkdir -p "$SB"/{bin,run/retroforge/splash}
  printf 'Starting RetroForge\n' >"$SB/run/retroforge/splash/status"
  : >"$SB/kmsg"; : >"$SB/calls"
  printf '%s\n' "$1" >"$SB/rc-p"; printf '%s\n' "${2:-0}" >"$SB/rc-y"
  printf '%s\n' "${3:-1}" >"$SB/lines-p"; printf '%s\n' "${4:-0}" >"$SB/rc-pf"
  cat >"$SB/bin/e2fsck" <<EOF
#!/bin/bash
echo "e2fsck \$*" >>"$SB/calls"
case " \$* " in
  *" -y "*) mode=y ;;
  *" -f "*) mode=pf ;;
  *)        mode=p ;;
esac
dev=\${*: -1}
if [ "\$mode" = y ]; then echo "status during -y: \$(cat "$SB/run/retroforge/splash/status")" >>"$SB/calls"; fi
[ "\$mode" = p ] && [ -e "$SB/replay" ] && echo "\$dev: recovering journal"
n=1; [ "\$mode" = p ] && n=\$(cat "$SB/lines-p")
for i in \$(seq 1 "\$n"); do echo "\$dev: \$mode line \$i"; done
exit \$(cat "$SB/rc-\$mode")
EOF
  chmod +x "$SB/bin/e2fsck"
}

run() {  # source the functions into a subshell and call fsck_var on a fake device
  (
    PATH="$SB/bin:$PATH"
    log()  { printf 'info %s\n' "$*" >>"$SB/kmsg"; }
    warn() { printf 'err %s\n' "$*" >>"$SB/kmsg"; }
    eval "${funcs//\/run\/retroforge\/splash/$SB/run/retroforge/splash}"
    fsck_var /dev/sda6
  )
}

calls() { grep -c '^e2fsck ' "$SB/calls"; }

# =================================================================================================
CASE="clean /var"
sandbox 0
run; rc=$?
[ "$rc" -eq 0 ] && ok "returns 0" || bad "returned $rc"
[ "$(calls)" -eq 1 ] && grep -q '^e2fsck -p /dev/sda6$' "$SB/calls" && ok "one e2fsck -p on the var device" || bad "calls: $(cat "$SB/calls")"
grep -q '^info e2fsck: /dev/sda6: p line 1$' "$SB/kmsg" && ! grep -q '^err ' "$SB/kmsg" \
  && ok "its output logged at info, no error lines" || bad "kmsg: $(cat "$SB/kmsg")"
rm -rf "$SB"

CASE="preen fixed it (exit 1)"
sandbox 1
run
[ "$(calls)" -eq 1 ] && ok "no -y pass" || bad "calls: $(cat "$SB/calls")"
grep -q '^err e2fsck -p on /var (/dev/sda6) exited 1$' "$SB/kmsg" && ok "the fix is logged as an error line" || bad "kmsg: $(cat "$SB/kmsg")"
rm -rf "$SB"

CASE="preen refuses (exit 4), -f -y repairs"
sandbox 4 1
run; rc=$?
[ "$rc" -eq 0 ] && ok "returns 0, so the mount still runs" || bad "returned $rc"
[ "$(sed -n 1p "$SB/calls")" = "e2fsck -p /dev/sda6" ] && [ "$(grep '^e2fsck ' "$SB/calls" | sed -n 2p)" = "e2fsck -f -y /dev/sda6" ] \
  && ok "-p, then -f -y on the same device" || bad "calls: $(cat "$SB/calls")"
grep -q '^status during -y: Repairing system storage$' "$SB/calls" && ok "the splash says it is repairing during -y" || bad "calls: $(cat "$SB/calls")"
[ "$(cat "$SB/run/retroforge/splash/status")" = "Starting RetroForge" ] && ok "the splash status is put back after" || bad "status: $(cat "$SB/run/retroforge/splash/status")"
grep -q '^err e2fsck -f -y on /var (/dev/sda6) exited 1$' "$SB/kmsg" && ok "the -y result is logged" || bad "kmsg: $(cat "$SB/kmsg")"
rm -rf "$SB"

CASE="-f -y cannot fix it either"
sandbox 4 4
run; rc=$?
[ "$rc" -eq 0 ] && [ "$(calls)" -eq 2 ] && ok "returns 0 after one -y pass (the mount decides)" || bad "rc=$rc calls: $(cat "$SB/calls")"
grep -q '^err e2fsck -f -y on /var (/dev/sda6) exited 4$' "$SB/kmsg" && ok "logged" || bad "kmsg: $(cat "$SB/kmsg")"
rm -rf "$SB"

CASE="journal replayed, full check clean"
sandbox 1 0 1 0
: >"$SB/replay"
run; rc=$?
[ "$rc" -eq 0 ] && [ "$(calls)" -eq 2 ] && [ "$(grep '^e2fsck ' "$SB/calls" | sed -n 2p)" = "e2fsck -p -f /dev/sda6" ] \
  && ok "-p, then -p -f, no -y" || bad "rc=$rc calls: $(cat "$SB/calls")"
grep -q '^err /var (/dev/sda6) was not cleanly unmounted; checking all of it$' "$SB/kmsg" \
  && grep -q '^err e2fsck: /dev/sda6: recovering journal$' "$SB/kmsg" && ok "the unclean stop is logged with preen's output" || bad "kmsg: $(cat "$SB/kmsg")"
grep -q '^info e2fsck: /dev/sda6: pf line 1$' "$SB/kmsg" && ! grep -q 'exited' "$SB/kmsg" \
  && ok "the clean full check is logged at info" || bad "kmsg: $(cat "$SB/kmsg")"
rm -rf "$SB"

CASE="journal replayed, full check finds damage"
sandbox 1 1 1 4
: >"$SB/replay"
run
[ "$(calls)" -eq 3 ] && [ "$(grep '^e2fsck ' "$SB/calls" | sed -n 3p)" = "e2fsck -f -y /dev/sda6" ] \
  && ok "-p, -p -f, then -f -y" || bad "calls: $(cat "$SB/calls")"
grep -q '^err e2fsck -p -f on /var (/dev/sda6) exited 4$' "$SB/kmsg" && ok "the full check's result is the one logged" || bad "kmsg: $(cat "$SB/kmsg")"
rm -rf "$SB"

CASE="no replay, no full check"
sandbox 1
run
! grep -q -- '-p -f' "$SB/calls" && ok "preen alone when the journal was clean" || bad "calls: $(cat "$SB/calls")"
rm -rf "$SB"

CASE="operational error (exit 8)"
sandbox 8
run; rc=$?
[ "$rc" -eq 0 ] && [ "$(calls)" -eq 1 ] && ok "no -y pass on an e2fsck that could not run" || bad "rc=$rc calls: $(cat "$SB/calls")"
rm -rf "$SB"

CASE="exit 12 (uncorrected + operational)"
sandbox 12 0
run
[ "$(calls)" -eq 2 ] && ok "bit 4 alone decides the -y pass" || bad "calls: $(cat "$SB/calls")"
rm -rf "$SB"

CASE="long output"
sandbox 1 0 55
run
[ "$(grep -c '^err e2fsck: /dev/sda6: p line' "$SB/kmsg")" -eq 40 ] && grep -q '^err e2fsck: 15 more lines not logged$' "$SB/kmsg" \
  && ok "40 lines logged, then a count of the rest" || bad "kmsg: $(wc -l <"$SB/kmsg") lines"
rm -rf "$SB"

CASE="no e2fsck in the initramfs"
sandbox 0
rm "$SB/bin/e2fsck"
( PATH="$SB/bin"
  log()  { printf 'info %s\n' "$*" >>"$SB/kmsg"; }
  warn() { printf 'err %s\n' "$*" >>"$SB/kmsg"; }
  eval "$funcs"
  fsck_var /dev/sda6 ); rc=$?
[ "$rc" -eq 0 ] && grep -q '^err no e2fsck in the initramfs; /var mounted unchecked$' "$SB/kmsg" \
  && ok "warns and returns 0" || bad "rc=$rc kmsg: $(cat "$SB/kmsg")"
rm -rf "$SB"

# =================================================================================================
CASE="init, mkinitramfs and the cmdline"
bins=$(sed -n 's/^BINS=(\(.*\))$/\1/p' "$MKI")
[[ " $bins " == *" e2fsck "* ]] && ok "mkinitramfs ships e2fsck" || bad "BINS: $bins"
grep -qE '^elif fsck_var "\$VARDEV"; ! mount -t ext4 "\$VARDEV" "\$SYSROOT/var"; then$' "$INIT" \
  && ok "the check runs on the /var mount's own branch, right before it" || bad "no fsck_var before the /var mount"
cmdline=$(sed -n 's/^BOOT_CMDLINE="\(.*\)"$/\1/p' "$GRUB")
[[ " $cmdline " == *" fsck.repair=yes "* ]] && ok "the kernel cmdline carries fsck.repair=yes (/home, ESP)" || bad "BOOT_CMDLINE: $cmdline"

echo
echo "test-initramfs-fsck: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

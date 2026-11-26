#!/usr/bin/env bash
# The initramfs starts the ADSP itself for a root on USB on a board whose USB-C port the ADSP runs
# (image/initramfs/init, usb_root_adsp), then watches the drive and finds it again if a dock reset
# drops it. This runs that function against a fake /sys with mount, the loader and modprobe stubbed,
# and checks the system side: the loader unit runs through the wrapper, which only adds overrides
# when the initramfs already ran the pass.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INIT="$ROOT/image/initramfs/init"
pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }

FN=$(sed -n '/^ADSP_SETTLE_S=/,/^}/p' "$INIT")
[ -n "$FN" ] || { echo "FAIL: usb_root_adsp not found in the init"; exit 1; }
if grep -qx 'usb_root_adsp' "$INIT"; then ok; else bad "the init does not call usb_root_adsp"; fi

# <usb:yes|no> <glink:yes|no> <drop at sleep N (0 = never)> <USB-C port registered: running|offline>
run_case() {
  local usb=$1 glink=$2 dropat=$3 adsp=$4 d
  T=$(mktemp -d); mkdir -p "$T/root/usr/bin" "$T/sys/block/sdi" "$T/sys/class/block" "$T/proc/dynamic_debug"
  : >"$T/calls"
  if [ "$usb" = yes ]; then d="$T/sys/devices/platform/soc/a600000.usb/xhci-hcd.1.auto/usb2/2-1/2-1:1.0/host1/target1:0:0/1:0:0:0/block/sdi/sdi4"
  else d="$T/sys/devices/platform/soc/1d84000.ufshc/host0/target0:0:0/0:0:0:0/block/sdi/sdi4"; fi
  mkdir -p "$d"; ln -s "$d" "$T/sys/class/block/sdi4"
  if [ "$glink" = yes ]; then
    mkdir -p "$T/sys/firmware/devicetree/base/pmic-glink"
    printf 'qcom,pmic-glink' >"$T/sys/firmware/devicetree/base/pmic-glink/compatible"
  fi
  if [ "$adsp" = running ]; then mkdir -p "$T/sys/class/typec/port0"; fi
  printf '#!/bin/sh\necho loader >>"%s/calls"\n' "$T" >"$T/root/usr/bin/msm-firmware-loader.sh"
  printf '#!/bin/sh\necho "modprobe $*" >>"%s/calls"\n' "$T" >"$T/root/usr/bin/modprobe"
  chmod +x "$T/root/usr/bin/msm-firmware-loader.sh" "$T/root/usr/bin/modprobe"
  (
    SYSROOT=$T/root ROOTDEV=/dev/sdi4 ROOTSPEC=PARTUUID=abc ROOTFSTYPE=btrfs SLEEPS=0
    log()  { echo "log $*" >>"$T/calls"; }
    warn() { echo "warn $*" >>"$T/calls"; }
    mount()  { echo "mount $*" >>"$T/calls"; }
    umount() { echo "umount $*" >>"$T/calls"; }
    resolve() { echo "resolve $*" >>"$T/calls"; printf /dev/sdj4; }
    sleep() { SLEEPS=$((SLEEPS + 1)); if [ "$dropat" -gt 0 ] && [ "$SLEEPS" -eq "$dropat" ]; then rm -rf "$T/sys/block/sdi"; fi; }
    eval "$(printf '%s\n' "$FN" | sed "s#/sys/#$T/sys/#g; s#/proc/#$T/proc/#g")"
    usb_root_adsp
  )
  CALLS=$(cat "$T/calls"); rm -rf "$T"
}

run_case yes no 0 running
check "no pmic-glink: nothing runs" '! grep -qE "^(loader|modprobe|umount|mount)" <<<"$CALLS"'
run_case no yes 0 running
check "root not on USB: nothing runs" '! grep -qE "^(loader|modprobe|umount|mount)" <<<"$CALLS"'

run_case yes yes 0 running
check "loader runs" 'grep -qx loader <<<"$CALLS"'
check "modprobe loads the PAS driver from the root" 'grep -q "^modprobe -d .*/root qcom_q6v5_pas$" <<<"$CALLS"'
check "root unmounted after modprobe" '[ "$(grep -n "^umount" <<<"$CALLS" | cut -d: -f1)" -gt "$(grep -n "^modprobe" <<<"$CALLS" | cut -d: -f1)" ]'
check "root stays: mounted again from the same device" 'grep -q "^mount -t btrfs -o ro /dev/sdi4 " <<<"$CALLS" && ! grep -q "^resolve" <<<"$CALLS"'
check "root stays: logged" 'grep -q "stayed through the ADSP start" <<<"$CALLS"'

run_case yes yes 3 running
check "drop: warned" 'grep -q "^warn root drive dropped" <<<"$CALLS"'
check "drop: root found again by its spec" 'grep -qx "resolve PARTUUID=abc" <<<"$CALLS"'
check "drop: mounted from the new device" 'grep -q "^mount -t btrfs -o ro /dev/sdj4 " <<<"$CALLS"'

run_case yes yes 0 offline
check "no USB-C port: warned after 10 s" 'grep -q "^warn the USB-C port was not registered within 10 s" <<<"$CALLS"'
check "no USB-C port: root still mounted again" 'grep -q "^mount -t btrfs -o ro /dev/sdi4 " <<<"$CALLS"'

# The system side.
W="$ROOT/rootfs/overlay/usr/lib/retroforge/msm-firmware-loader-boot"
D="$ROOT/rootfs/overlay/usr/lib/systemd/system/msm-firmware-loader.service.d/20-retroforge-initramfs.conf"
check "wrapper is executable" '[ -x "$W" ]'
check "drop-in runs the wrapper" 'grep -qx "ExecStart=/usr/lib/retroforge/msm-firmware-loader-boot" "$D" && grep -qx "ExecStart=" "$D"'
check "wrapper runs the loader when /run has no loader mount" 'grep -qF "mountpoint -q \"\$BASEDIR\" || exec /usr/bin/msm-firmware-loader.sh" "$W"'

echo "test-initramfs-usb-adsp: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

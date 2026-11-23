#!/usr/bin/env bash
# Test for /usr/lib/retroforge/steam-x86-guest-kernel, its two units and 50-retroforge-x86-guest.rules:
# root mounting a user's x86 guest with the kernel's squashfs and overlayfs.
#
#   tests/test-steam-x86-guest-kernel.sh
#
# WHY THIS EXISTS. The helper runs as root on paths and a file the user controls. Each rule below
# fails as an overlay mounted onto /etc through a symlink, a setuid program or device node from an
# image that works, a mount another user can make, or an x86 game that loses our Mesa:
#   rule: start of mount@<user> and release@<user>, for that user's active local wheel session only;
#   units: oneshot, root, no namespace of their own (the mounts have to be the user's);
#   helper (needs root, loop devices, squashfs, overlayfs and mksquashfs; skipped otherwise):
#   - the image on a read-only loop device, squashfs and overlay read-only, nosuid, nodev;
#   - with our Mesa: our files over the guest's, the folders our Mesa marks opaque show only ours,
#     and the markers themselves do not show; without it: the guest as it is;
#   - refused: a symlink anywhere below the home (fex-guest, root, the image, the request), an image
#     that is not the user's or not a regular file (a FIFO does not hang it), a name with a slash,
#     root, a user that does not exist;
#   - release takes down its own overlay and the image, and leaves anything else mounted there alone,
#     the user's own FUSE mount included (root cannot even stat that one);
#   - a second mount replaces the first; the layers that stand in for our Mesa's markers are made once,
#     so an overlay a game still holds after a lazy release keeps them.
# A user of its own (useradd) holds the home, so it runs in a throwaway container:
#   docker run --rm --privileged -v "$PWD:/src:ro" debian:trixie bash -c \
#     'apt-get update -qq && apt-get install -y -qq python3 squashfs-tools nodejs >/dev/null && bash /src/tests/test-steam-x86-guest-kernel.sh'
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$ROOT/rootfs/overlay/usr/lib/retroforge/steam-x86-guest-kernel"
RULE="$ROOT/rootfs/overlay/usr/share/polkit-1/rules.d/50-retroforge-x86-guest.rules"
UNITS="$ROOT/rootfs/overlay/usr/lib/systemd/system"
for f in "$HELPER" "$RULE" "$UNITS/retroforge-x86-guest-mount@.service" "$UNITS/retroforge-x86-guest-release@.service"; do
  [ -f "$f" ] || { echo "missing: $f" >&2; exit 1; }
done

PASS=0; FAIL=0; SKIP=0; CASE=""
ok()   { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }
skip() { SKIP=$((SKIP+1)); printf '  skip %s -- %s\n' "$CASE" "$1"; }
finish() { printf '%s: %d passed, %d failed, %d skipped\n' "${0##*/}" "$PASS" "$FAIL" "$SKIP"; [ "$FAIL" -eq 0 ]; exit; }

# ================================================================================================
CASE="the polkit rule"
if ! command -v node >/dev/null; then
  skip "no node to evaluate the rule"
else
  verdicts="$(node - "$RULE" <<'JS'
const fs = require("fs");
let rule;
global.polkit = { Result: { YES: "yes", NO: "no" }, addRule: f => { rule = f; } };
eval(fs.readFileSync(process.argv[2], "utf8"));
const ask = (id, unit, verb, user = "player", active = true, wheel = true, local = true) =>
  rule({ id, lookup: k => ({ unit, verb })[k] }, { user, active, local, isInGroup: g => g === "wheel" && wheel }) || "pass";
const M = "org.freedesktop.systemd1.manage-units";
const MO = "retroforge-x86-guest-mount@player.service", RE = "retroforge-x86-guest-release@player.service";
console.log([
  ask(M, MO, "start"), ask(M, RE, "start"),
  ask(M, "retroforge-x86-guest-mount@other.service", "start"), ask(M, "retroforge-x86-guest-mount@root.service", "start"),
  ask(M, "retroforge-x86-guest-mount@.service", "start"), ask(M, MO, "stop"), ask(M, RE, "restart"),
  ask(M, MO, "start", "player", false), ask(M, MO, "start", "player", true, false), ask(M, MO, "start", "player", true, true, false),
  ask("org.freedesktop.systemd1.manage-unit-files", MO, "enable"), ask(M, "sshd.service", "start"),
].join(" "));
JS
)"
  [ "$verdicts" = "yes yes pass pass pass pass pass pass pass pass pass pass" ] \
    && ok "start of mount@ and release@ with the subject's own name, active local wheel session, nothing else" \
    || bad "verdicts (mount release other-user root template stop restart inactive non-wheel ssh enable sshd): $verdicts"
fi

CASE="the units"
for u in mount release; do
  f="$UNITS/retroforge-x86-guest-$u@.service"
  grep -qx 'Type=oneshot' "$f" && grep -qx "ExecStart=/usr/lib/retroforge/steam-x86-guest-kernel $u %i" "$f" \
    && ! grep -qE '^(User|DynamicUser|Private[A-Za-z]*|Protect[A-Za-z]*|MountFlags|RootDirectory|NoNewPrivileges)=' "$f" \
    && ! grep -q '^\[Install\]' "$f" \
    && ok "$u@: oneshot, steam-x86-guest-kernel $u %i as root, no namespace of its own, no [Install]" || bad "$u@: $(cat "$f")"
done

# ---- the helper itself ---------------------------------------------------------------------------
CASE="helper"
why=""
[ "$(id -u)" = 0 ] || why="not root"
[ -z "$why" ] && [ ! -e /dev/loop-control ] && why="no /dev/loop-control"
[ -z "$why" ] && ! command -v mksquashfs >/dev/null && why="no mksquashfs (squashfs-tools)"
[ -z "$why" ] && ! command -v useradd >/dev/null && why="no useradd"
if [ -z "$why" ]; then
  for fs in squashfs overlay; do
    grep -qw "$fs" /proc/filesystems || modprobe "$fs" 2>/dev/null || true
    grep -qw "$fs" /proc/filesystems || why="no $fs in this kernel"
  done
fi
[ -n "$why" ] && { skip "$why: the mounts are not tested here"; finish; }

U=rfx86test
T="$(mktemp -d)"
RUN="$T/run"
cleanup() {
  for m in $(awk -v t="$T" 'index($5, t) == 1 { print $5 }' /proc/self/mountinfo | sort -r); do umount -l "$m" 2>/dev/null; done
  for m in $(awk -v h="/home/$U" 'index($5, h) == 1 { print $5 }' /proc/self/mountinfo | sort -r); do umount -l "$m" 2>/dev/null; done
  userdel -r "$U" >/dev/null 2>&1
  rm -rf "$T"
}
trap cleanup EXIT
userdel -r "$U" >/dev/null 2>&1
useradd -m "$U" || { bad "useradd $U failed"; finish; }
HOME_U="$(getent passwd "$U" | cut -d: -f6)"
G="$HOME_U/.local/share/retroforge/fex-guest"
as_user() { su -s /bin/sh "$U" -c "$1"; }
as_user "mkdir -p '$G/root'"

# The guest: a provider, two drivers and one ICD of its own, a setuid copy of sh, a device node.
mkdir -p "$T/guest/usr/lib/dri" "$T/guest/usr/share/vulkan/icd.d" "$T/guest/usr/bin"
echo '{"graphics_provider_v0":{}}' >"$T/guest/graphics_provider.json"
echo guest >"$T/guest/usr/lib/dri/radeonsi_dri.so"; echo guest >"$T/guest/usr/lib/dri/msm_dri.so"
echo guest >"$T/guest/usr/share/vulkan/icd.d/radeon_icd.json"
echo guest >"$T/guest/usr/lib/libvulkan_freedreno.so"; echo guest >"$T/guest/usr/lib/libc.so.6"
cp /bin/sh "$T/guest/usr/bin/suidsh"; chmod 4755 "$T/guest/usr/bin/suidsh"
mksquashfs "$T/guest" "$T/img.sqsh" -quiet -noappend -all-root -p 'usr/zero c 666 root root 1 5' >/dev/null \
  || { bad "mksquashfs failed"; finish; }
IMG=fex-rootfs-archlinux-2026-08-11-23350f949fc1413d.sqsh
cp "$T/img.sqsh" "$G/$IMG"; chown "$U:" "$G/$IMG"
# Our Mesa, as rootfs/lib-assemble-x86-mesa.sh lays it out.
MESA="$T/x86-mesa"
mkdir -p "$MESA/root/usr/lib/dri" "$MESA/root/usr/share/vulkan/icd.d"
echo ours >"$MESA/root/usr/lib/dri/msm_dri.so"; echo ours >"$MESA/root/usr/lib/libvulkan_freedreno.so"
echo ours >"$MESA/root/usr/share/vulkan/icd.d/freedreno_icd.x86_64.json"
: >"$MESA/root/usr/lib/dri/.wh..wh..opq"; : >"$MESA/root/usr/share/vulkan/icd.d/.wh..wh..opq"

req() { as_user "printf 'image=%s\nmesa=%s\n' '$1' '$2' >'$G/.kernel-request'"; }
helper() { RETROFORGE_X86_GUEST_RUN="$RUN" RETROFORGE_X86_MESA="$MESA" python3 "$HELPER" "$@" 2>"$T/err"; RC=$?; ERR="$(cat "$T/err")"; }
# mnt <mountpoint>: "<fstype> <source> <mount options> <super options>" of the top mount there
mnt() { awk -v m="$1" '$5 == m { for (i = 7; $i != "-"; i++); r = $(i+1) " " $(i+2) " " $6 " " $(i+3) } END { print r }' /proc/self/mountinfo; }
ours_on() { mnt "$G/root" | grep -q '^overlay rf-x86-guest '; }
BASE="$RUN/$(id -u "$U")/base"
nothing_on() { [ -z "$(mnt "$G/root")" ] && [ -z "$(mnt "$BASE")" ]; }

CASE="mount, with our Mesa"
req "$IMG" 1
helper mount "$U"
[ "$RC" = 0 ] && ours_on && ok "an overlay, source rf-x86-guest, on fex-guest/root" || bad "rc=$RC err=$ERR mount: $(mnt "$G/root")"
o="$(mnt "$G/root")"; b="$(mnt "$BASE")"; flags=1
for opt in ro nosuid nodev; do
  [[ ",$(cut -d' ' -f3 <<<"$o")," == *",$opt,"* ]] && [[ ",$(cut -d' ' -f3 <<<"$b")," == *",$opt,"* ]] || { flags=0; bad "no $opt: overlay '$o' base '$b'"; }
done
[ "$flags" = 1 ] && ok "overlay and base: ro, nosuid, nodev"
[[ "$b" == "squashfs /dev/loop"* ]] && loop="$(cut -d' ' -f2 <<<"$b")" && [ "$(cat "/sys/block/${loop#/dev/}/ro")" = 1 ] \
  && ok "the image: squashfs on a read-only loop device ($loop)" || bad "base: $b"
L="$RUN/$(id -u "$U")/layers"
[[ "$(cut -d' ' -f4 <<<"$o")" == *"lowerdir=$L/mask:$MESA/root:$L/opaque:$BASE"* ]] \
  && ok "lowerdir=<layers>/mask:<our Mesa>:<layers>/opaque:<base>" || bad "overlay: $o"
LINO="$(stat -c %i "$L")"
R="$G/root"
[ -f "$R/graphics_provider.json" ] && [ "$(cat "$R/usr/lib/libvulkan_freedreno.so")" = ours ] && [ "$(cat "$R/usr/lib/libc.so.6")" = guest ] \
  && ok "the guest's provider and libraries, our Mesa's files over theirs" || bad "$(ls -R "$R" | head -20)"
[ "$(ls -A "$R/usr/lib/dri")" = msm_dri.so ] && [ "$(cat "$R/usr/lib/dri/msm_dri.so")" = ours ] \
  && [ "$(ls -A "$R/usr/share/vulkan/icd.d")" = freedreno_icd.x86_64.json ] \
  && ok "the marked folders show only ours, and no marker" || bad "dri: $(ls -A "$R/usr/lib/dri") icd: $(ls -A "$R/usr/share/vulkan/icd.d")"
[ "$(stat -c %a "$R/usr/bin/suidsh")" = 4755 ] && ! as_user "'$R/usr/bin/suidsh' -c 'test \$(id -u) = 0'" \
  && ok "the image's setuid sh runs as the user (nosuid)" || bad "suidsh: $(stat -c %a "$R/usr/bin/suidsh")"
! head -c1 "$R/usr/zero" >/dev/null 2>&1 && ok "the image's device node does not open (nodev)" || bad "usr/zero opened"
as_user "test -r '$R/graphics_provider.json' && test -x '$R/usr/bin/suidsh'" && ok "the user reads the tree" || bad "the user cannot read it"
grep -q "mounted $IMG on $U's fex-guest/root (/dev/loop[0-9]*, with our x86 Mesa over it)" <<<"$ERR" && ok "and says so" || bad "stderr: $ERR"

CASE="mount again"
helper mount "$U"
[ "$RC" = 0 ] && ours_on && [ "$(awk -v m="$G/root" '$5 == m' /proc/self/mountinfo | wc -l)" = 1 ] \
  && [ "$(awk -v m="$BASE" '$5 == m' /proc/self/mountinfo | wc -l)" = 1 ] && ok "replaces the first: one overlay, one image" || bad "rc=$RC err=$ERR"

CASE="release"
helper release "$U"
[ "$RC" = 0 ] && nothing_on && ok "the overlay and the image are gone" || bad "rc=$RC err=$ERR root: $(mnt "$G/root") base: $(mnt "$BASE")"
sleep 0.2
[ -z "$(losetup -j "$G/$IMG" 2>/dev/null)" ] && ok "the loop device freed itself" || bad "losetup: $(losetup -j "$G/$IMG")"
helper release "$U"
[ "$RC" = 0 ] && ok "nothing mounted: release is a no-op" || bad "rc=$RC err=$ERR"

CASE="mount after a release"
helper mount "$U"
[ "$RC" = 0 ] && ours_on && [ "$(stat -c %i "$L")" = "$LINO" ] && [ "$(ls -A "$R/usr/lib/dri")" = msm_dri.so ] \
  && ok "the same layers, not made again (an overlay a game still holds keeps them)" || bad "rc=$RC err=$ERR layers $(stat -c %i "$L") vs $LINO"
helper release "$U"

CASE="mount, without our Mesa"
req "$IMG" 0
helper mount "$U"
[ "$RC" = 0 ] && ours_on && [ "$(ls "$R/usr/lib/dri" | tr '\n' ' ')" = "msm_dri.so radeonsi_dri.so " ] \
  && [ "$(cat "$R/usr/lib/libvulkan_freedreno.so")" = guest ] && ok "the guest as it is" || bad "rc=$RC err=$ERR dri: $(ls "$R/usr/lib/dri")"
grep -q "with our x86 Mesa" <<<"$ERR" && bad "says our Mesa: $ERR" || ok "and does not say our Mesa"
helper release "$U"

CASE="something else mounted there"
mount -t tmpfs -o size=1m rfother "$G/root"
helper release "$U"
[ "$RC" = 1 ] && [ "$(mnt "$G/root" | cut -d' ' -f1-2)" = "tmpfs rfother" ] && ok "release leaves it alone, exit 1" || bad "rc=$RC err=$ERR $(mnt "$G/root")"
req "$IMG" 1
helper mount "$U"
[ "$RC" = 1 ] && [ "$(mnt "$G/root" | cut -d' ' -f1-2)" = "tmpfs rfother" ] && [ -z "$(mnt "$BASE")" ] && ok "mount refuses, mounts nothing" || bad "rc=$RC err=$ERR"
umount "$G/root"
if command -v squashfuse >/dev/null && [ -e /dev/fuse ]; then
  as_user "squashfuse '$G/$IMG' '$G/root'"
  helper release "$U"
  [ "$RC" = 1 ] && grep -q "something else is mounted" <<<"$ERR" && [ "$(mnt "$G/root" | cut -d' ' -f1)" = fuse.squashfuse ] \
    && ok "the user's own squashfuse, which root cannot stat: left alone, exit 1" || bad "rc=$RC err=$ERR $(mnt "$G/root")"
  helper mount "$U"
  [ "$RC" = 1 ] && [ "$(mnt "$G/root" | cut -d' ' -f1)" = fuse.squashfuse ] && [ -z "$(mnt "$BASE")" ] && ok "and mount refuses" || bad "rc=$RC err=$ERR"
  as_user "fusermount3 -u '$G/root' 2>/dev/null || fusermount -u '$G/root'"
else
  skip "no squashfuse or /dev/fuse: a FUSE mount there is not tried"
fi

ours_anywhere() {  # mounts under the test's folders or the test user's home
  awk -v t="$T" -v h="$HOME_U" 'index($5, t) == 1 || index($5, h) == 1' /proc/self/mountinfo
}
refused() {  # refused <what>: mount exits 1 and mounts nothing anywhere new
  helper mount "$U"
  [ "$RC" = 1 ] && nothing_on && [ -z "$(ours_anywhere)" ] \
    && ok "refused: $1 ($ERR)" || bad "$1: rc=$RC err=$ERR mounts: $(ours_anywhere)"
}
CASE="symlinks"
mkdir -p "$T/elsewhere"; chown "$U:" "$T/elsewhere"
as_user "rmdir '$G/root' && ln -s '$T/elsewhere' '$G/root'"
refused "fex-guest/root is a symlink"
[ -z "$(mnt "$T/elsewhere")" ] && ok "nothing on its target" || bad "mounted on the target: $(mnt "$T/elsewhere")"
as_user "rm '$G/root' && mkdir '$G/root'"
as_user "mv '$G' '$G.real' && ln -s '$G.real' '$G'"
refused "fex-guest is a symlink"
as_user "rm '$G' && mv '$G.real' '$G'"
as_user "ln -s '$G/$IMG' '$G/link.sqsh'"; req link.sqsh 1
refused "the image is a symlink"
as_user "rm '$G/link.sqsh' '$G/.kernel-request'"
as_user "printf 'image=$IMG\nmesa=1\n' >'$G/request.real' && ln -s '$G/request.real' '$G/.kernel-request'"
refused "the request is a symlink"
as_user "rm '$G/.kernel-request' '$G/request.real'"

CASE="other refusals"
req "../$IMG" 1; refused "a name with a slash"
cp "$T/img.sqsh" "$G/rootowned.sqsh"; req rootowned.sqsh 1; refused "an image that is not the user's"
rm -f "$G/rootowned.sqsh"
as_user "mkfifo '$G/fifo.sqsh'"; req fifo.sqsh 1
RETROFORGE_X86_GUEST_RUN="$RUN" RETROFORGE_X86_MESA="$MESA" timeout 10 python3 "$HELPER" mount "$U" 2>"$T/err"; RC=$?; ERR="$(cat "$T/err")"
[ "$RC" = 1 ] && nothing_on && ok "a FIFO named .sqsh: refused, without hanging ($ERR)" || bad "rc=$RC err=$ERR"
as_user "rm '$G/fifo.sqsh'"
req "$IMG" 2; refused "mesa=2"
req "$IMG" 1
helper mount root
[ "$RC" = 1 ] && grep -q "not for root" <<<"$ERR" && ok "refused for root" || bad "rc=$RC err=$ERR"
helper mount rf-no-such-user
[ "$RC" = 1 ] && grep -q "no user" <<<"$ERR" && ok "refused for a user that does not exist" || bad "rc=$RC err=$ERR"
helper bogus "$U"
[ "$RC" = 64 ] && ok "usage: exit 64" || bad "rc=$RC"

CASE="after all that"
helper mount "$U"
[ "$RC" = 0 ] && ours_on && [ "$(ls -A "$R/usr/lib/dri")" = msm_dri.so ] && ok "a good request still mounts" || bad "rc=$RC err=$ERR"
helper release "$U"
nothing_on && ok "and releases" || bad "left: $(mnt "$G/root") $(mnt "$BASE")"

finish

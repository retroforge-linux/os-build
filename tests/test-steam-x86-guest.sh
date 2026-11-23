#!/usr/bin/env bash
# Offline test for /usr/lib/retroforge/steam-x86-guest and its block in /usr/bin/steam: the x86 guest
# (FEX's ArchLinux RootFS) that gives x86 Steam games a GPU driver under Valve's FEX tool.
#
#   tests/test-steam-x86-guest.sh
#
# WHY THIS EXISTS. None of it runs before a player picks an x86 game, and each rule below fails as a
# game with no GPU driver, a 1.4 GB download that never finishes, a dead mount in the home, or a
# `steam` that waits minutes before the client starts:
#   helper, a fixed pin (version + url + sha256):
#   - downloads the pinned image, refuses it unless the sha256 matches, renames it into place, and
#     resumes a download that was cut short (Range) instead of starting over;
#   - one fetch at a time; a bump keeps the old image (and mounts it) until the new one is in place,
#     and removes it only once it is not mounted either;
#   helper, a channel (FEX's RootFS_links.json + distro + type):
#   - takes the entry the pin selects, and only that one, from a links file shaped like FEX's;
#     refuses it unless its XXH3-64 (xxhsum) matches, a hash without leading zeros included;
#   - a channel move: the new image becomes current once it is in place and checked; a mounted old
#     one stays mounted and on disk until the last steam is gone;
#   - offline, or a links file it cannot use: nothing changes, the installed image is still mounted;
#   - without xxhsum nothing is installed unchecked; the part is kept and checked next time;
#   both:
#   - mounts with squashfuse, TERM and INT ignored, never twice; replaces a dead mount;
#   - releases only when no `steam` holds the users lock, and an inherited copy of that lock in the
#     helper itself does not count;
#   - `start` leaves a holder outside the caller's process tree that ignores TERM, and releases once
#     the caller is gone, SIGKILL included;
#   - a download that finishes while Steam runs is mounted then, and not when Steam is gone.
#   the kernel's mounts (steam-x86-guest-kernel, root's, through retroforge-x86-guest-mount@<user>):
#   - asked for first, with the image and our Mesa named in fex-guest/.kernel-request; FUSE only when
#     the unit is refused (an SSH login), fails or mounts nothing, and it says why;
#   - released through retroforge-x86-guest-release@<user>, never with fusermount; the holder too;
#   - RETROFORGE_X86_GUEST_KERNEL=0: FUSE only. tests/test-steam-x86-guest-kernel.sh tests root's half.
#   wrapper:
#   - the client starts without waiting for the download, which goes on detached after `steam` exits;
#   - with a channel, every start checks it in the background; a move is mounted once no steam has the old one;
#   - STEAM_COMPAT_GRAPHICS_PROVIDER and ~/.steam/sdk32, sdk64 are set up;
#   - mounted before the client starts, released when the last `steam` exits, never by a second one;
#   - RETROFORGE_STEAM_X86_GUEST=0 turns all of it off.
# squashfuse, fusermount3 and systemctl are stubs that edit a fake mount table, as in test-portmaster.sh;
# systemctl refuses unless a case says otherwise ($T/kernel-mode), as for an SSH login. FEX's
# server is a local HTTP server that honours Range and can be slowed down or cut off. xxhsum is the
# real one (Debian/Arch package xxhash; the image has it) when installed, else a stand-in.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$ROOT/rootfs/overlay/usr/lib/retroforge/steam-x86-guest"
WRAP="$ROOT/rootfs/overlay/usr/bin/steam"
PIN_REAL="$ROOT/rootfs/overlay/usr/share/retroforge/steam/x86-guest.pin"
for f in "$HELPER" "$WRAP" "$PIN_REAL"; do [ -f "$f" ] || { echo "missing: $f" >&2; exit 1; }; done

PASS=0; FAIL=0; SKIP=0; CASE=""
ok()   { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }
skip() { SKIP=$((SKIP+1)); printf '  skip %s -- %s\n' "$CASE" "$1"; }

T="$(mktemp -d)" && [ -d "$T" ] || { echo "mktemp -d failed" >&2; exit 1; }
cleanup() {
  pkill -f "$T/" 2>/dev/null
  pkill -f "$HELPER" 2>/dev/null
  rm -rf "$T"
}
trap cleanup EXIT

sha() { python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }
until_true() {  # until_true <tenths> <command...>: poll for up to <tenths>/10 s
  local n="$1"; shift
  for _ in $(seq "$n"); do "$@" && return 0; sleep 0.1; done
  "$@"
}
quiet() { ! pgrep -f "$HELPER" >/dev/null; }   # no holder or fetch left
settle() { until_true 100 quiet || echo "  (helper processes still running: $(pgrep -af "$HELPER"))"; }

# ---- stubs: squashfuse / fusermount3 on a fake mount table ---------------------------------------
mkdir -p "$T/stub"
cat >"$T/stub/squashfuse" <<EOF
#!/bin/bash
echo "squashfuse \$*" >>"$T/calls"
awk '/^SigIgn:/ { print \$2 }' /proc/\$\$/status >"$T/sigign"
case \$(basename "\$1") in bad*) exit 1 ;; esac
echo "squashfuse \$(printf '%s' "\$2" | sed 's/ /\\\\040/g') fuse.squashfuse ro,nosuid,nodev 0 0" >>"$T/mounts"
echo '{"graphics_provider_v0":{}}' >"\$2/graphics_provider.json"
echo "\$1" >"\$2/.image"
EOF
cat >"$T/stub/fusermount" <<EOF
#!/bin/bash
echo "fusermount \$*" >>"$T/calls"
m="\${!#}"; e="\$(printf '%s' "\$m" | sed 's/ /\\\\040/g')"
M="\$e" awk '\$2 != ENVIRON["M"]' "$T/mounts" >"$T/mounts.new" && mv "$T/mounts.new" "$T/mounts"
rm -f "\$m/graphics_provider.json" "\$m/.image" "\$m/.payload"
EOF
# fuse-overlayfs -o lowerdir=<payload>:<base> <root>: the base's provider and image show through,
# .payload names the layer on top. $T/overlay-fails makes it fail.
cat >"$T/stub/fuse-overlayfs" <<EOF
#!/bin/bash
echo "fuse-overlayfs \$*" >>"$T/calls"
awk '/^SigIgn:/ { print \$2 }' /proc/\$\$/status >"$T/sigign-ovl"
[ -e "$T/overlay-fails" ] && { echo "fuse-overlayfs: cannot mount" >&2; exit 1; }
lower="\${2#lowerdir=}"; top="\${lower%%:*}"; base="\${lower#*:}"; m="\$3"
echo "fuse-overlayfs \$(printf '%s' "\$m" | sed 's/ /\\\\040/g') fuse.fuse-overlayfs ro,nosuid,nodev 0 0" >>"$T/mounts"
cp "\$base/graphics_provider.json" "\$base/.image" "\$m/"; echo "\$top" >"\$m/.payload"
EOF
chmod +x "$T/stub/"*
: >"$T/mounts"
# No x86 Mesa payload unless a case gives one (the image's /usr/lib/retroforge/x86-mesa is not used).
export RETROFORGE_MOUNTS="$T/mounts" RETROFORGE_SQUASHFUSE="$T/stub/squashfuse" RETROFORGE_FUSERMOUNT="$T/stub/fusermount" \
       RETROFORGE_FUSE_OVERLAYFS="$T/stub/fuse-overlayfs" RETROFORGE_X86_MESA="$T/no-x86-mesa"

# ---- xxhsum: the real one when installed; else a stand-in with its output and another 64-bit hash --
if XXHSUM_REAL="$(command -v xxhsum)"; then
  export RETROFORGE_XXHSUM="$XXHSUM_REAL"
else
  cat >"$T/stub/xxhsum" <<'EOF'
#!/bin/bash
echo "XXH3_$(python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest()[:16])')  stdin"
EOF
  chmod +x "$T/stub/xxhsum"
  export RETROFORGE_XXHSUM="$T/stub/xxhsum"
fi
xxh3() { "$RETROFORGE_XXHSUM" -H3 <"$1" | sed -E 's/^XXH3 \(.*\) = //; s/^XXH3_//; s/[[:space:]].*//'; }

# ---- FEX's server: Range, and $SRV/.delay (seconds, mid-body) / $SRV/.mode (range|full|cut) ---------
SRV="$T/srv"; mkdir -p "$SRV"
cat >"$T/server.py" <<'PY'
import http.server, os, sys, time
root, portfile, logf = sys.argv[1:4]
def setting(name, default):
    try:
        return open(os.path.join(root, name)).read().strip()
    except OSError:
        return default
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        path = os.path.join(root, self.path.lstrip("/"))
        rng, mode = self.headers.get("Range"), setting(".mode", "range")
        with open(logf, "a") as f:
            f.write(f"GET {self.path} range={rng}\n")
        if not os.path.isfile(path):
            self.send_error(404)
            return
        data = open(path, "rb").read()
        start = 0
        if rng and mode != "full":
            start = int(rng.split("=")[1].split("-")[0])
            if start >= len(data):
                self.send_response(416)
                self.end_headers()
                return
            self.send_response(206)
            self.send_header("Content-Range", f"bytes {start}-{len(data) - 1}/{len(data)}")
        else:
            self.send_response(200)
        body = data[start:]
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        half = len(body) // 2
        self.wfile.write(body[:half])
        self.wfile.flush()
        if mode == "cut":
            self.close_connection = True
            return
        time.sleep(float(setting(".delay", "0")))
        self.wfile.write(body[half:])
    def log_message(self, *args):
        pass
srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
with open(portfile + ".tmp", "w") as f:
    f.write(str(srv.server_address[1]))
os.rename(portfile + ".tmp", portfile)
srv.serve_forever()
PY
python3 "$T/server.py" "$SRV" "$T/port" "$T/requests" &
until_true 50 test -s "$T/port" || { echo "the test server did not start" >&2; exit 1; }
URL="http://127.0.0.1:$(cat "$T/port")"

mkimage() {  # mkimage <file> <seed>: 300 kB of bytes
  python3 -c 'import random,sys; random.seed(sys.argv[2]); open(sys.argv[1],"wb").write(random.randbytes(300000))' "$1" "$2"
}
PIN="$T/x86-guest.pin"
mkpin() {  # mkpin <version> <file on the server> [sha256]
  printf 'name: fex-rootfs-archlinux\nversion: %s\nurl: %s/%s\nsha256: %s\n' \
    "$1" "$URL" "$2" "${3:-$(sha "$SRV/$2")}" >"$PIN"
}
export RETROFORGE_STEAM_X86_GUEST_PIN="$PIN"

GUEST="$T/data dir/fex-guest"   # a space: /proc/mounts writes it \040
MNT="$GUEST/root"
helper() {  # helper <cmd>: RC, ERR
  RETROFORGE_STEAM_X86_GUEST_DIR="$GUEST" python3 "$HELPER" "$@" 2>"$T/err"; RC=$?
  ERR="$(cat "$T/err")"
}
calls() { grep -c "^$1 " "$T/calls" 2>/dev/null; }
reset_calls() { : >"$T/calls"; : >"$T/requests"; }
in_table() {  # in_table <dir>: is it in the fake mount table (awk -v would decode \040 itself)
  M="$1" awk '{ gsub(/\\040/, " ", $2) } $2 == ENVIRON["M"] { f = 1 } END { exit !f }' "$T/mounts"
}
is_mounted() { in_table "$MNT"; }
not_mounted() { ! is_mounted; }
leftovers() { find "$GUEST" -name '.*.part' 2>/dev/null; }
holdlock() {  # holdlock <file> sh|ex: one process that holds the lock until killed; LOCKPID
  rm -f "$T/locked"
  python3 -c 'import fcntl,sys,time
f = open(sys.argv[1], "a"); fcntl.flock(f, fcntl.LOCK_SH if sys.argv[2] == "sh" else fcntl.LOCK_EX)
open(sys.argv[3], "w").close(); time.sleep(600)' "$1" "$2" "$T/locked" &
  LOCKPID=$!
  until_true 50 test -e "$T/locked"
}
unlock() { kill "$LOCKPID"; wait "$LOCKPID" 2>/dev/null; }

# systemctl --no-ask-password start retroforge-x86-guest-{mount,release}@<user>.service: root's
# steam-x86-guest-kernel, on the fake mount table. $T/kernel-mode: fail (refused, the default), ok, or
# broken (succeeds and mounts nothing). The mount copies the request to $T/request.
cat >"$T/stub/systemctl" <<EOF
#!/bin/bash
echo "systemctl \$*" >>"$T/calls"
mode="\$(cat "$T/kernel-mode" 2>/dev/null || echo fail)"; unit="\${!#}"
[ "\$mode" = fail ] && { echo "Failed to start \$unit: Interactive authentication required." >&2; exit 1; }
m="$MNT"; e="\$(printf '%s' "\$m" | sed 's/ /\\\\040/g')"
case "\$unit" in
  retroforge-x86-guest-mount@*)
    [ "\$mode" = broken ] && exit 0
    cp "$GUEST/.kernel-request" "$T/request"
    echo "rf-x86-guest \$e overlay ro,nosuid,nodev 0 0" >>"$T/mounts"
    echo '{"graphics_provider_v0":{}}' >"\$m/graphics_provider.json" ;;
  retroforge-x86-guest-release@*)
    E="\$e" awk '!(\$2 == ENVIRON["E"] && \$3 == "overlay")' "$T/mounts" >"$T/mounts.new" && mv "$T/mounts.new" "$T/mounts"
    rm -f "\$m/graphics_provider.json" ;;
esac
EOF
chmod +x "$T/stub/systemctl"
export RETROFORGE_SYSTEMCTL="$T/stub/systemctl"
KUSER="$(python3 -c 'import os, pwd; print(pwd.getpwuid(os.getuid()).pw_name)' 2>/dev/null)"
kernel_on() { M="$MNT" awk '{ gsub(/\\040/, " ", $2) } $2 == ENVIRON["M"] && $3 == "overlay" { f = 1 } END { exit !f }' "$T/mounts"; }

# ================================================================================================
CASE="the real pin"
python3 - "$PIN_REAL" <<'PY' && ok "a channel: FEX's RootFS_links.json, its arch squashfs entry, no fixed version" || bad "the image's x86-guest.pin is malformed"
import re, sys
t = open(sys.argv[1]).read()
f = {k: (m.group(1) if (m := re.search(rf"^{k}:[ \t]*(\S+)", t, re.M)) else None)
     for k in ("name", "channel", "distro", "type", "version", "url", "sha256")}
assert f["name"] == "fex-rootfs-archlinux", f
assert f["channel"] == "https://rootfs.fex-emu.gg/RootFS_links.json", f
assert (f["distro"], f["type"]) == ("arch", "squashfs"), f
assert not (f["version"] or f["url"] or f["sha256"]), f
PY
# The image checks FEX's hash with xxhsum, so the package that has it must stay on the image.
grep -qE '^PKGS=\(.* xxhash[ )]' "$ROOT/rootfs/customize-base.sh" && grep -q '^xxhash ' "$ROOT/rootfs/manifest.lock" \
  && ok "xxhash (xxhsum) is in PKGS and in manifest.lock" || bad "xxhash is not declared in PKGS, or not locked"
if [ -n "$XXHSUM_REAL" ]; then
  [ "$(printf '' | xxh3 /dev/stdin)" = 2d06800538d394c2 ] && ok "xxhsum -H3 is XXH3-64 (the empty input's published value)" || bad "xxhsum -H3: $(printf '' | xxh3 /dev/stdin)"
else
  skip "xxhsum is not installed: the channel cases use a stand-in hash"
fi

CASE="mount, nothing downloaded"
mkimage "$SRV/v1.sqsh" one; mkpin 2026-01-01 v1.sqsh; reset_calls
helper mount
[ "$RC" = 2 ] && [ "$(calls squashfuse)" = 0 ] && not_mounted && ok "exit 2 (start a fetch), nothing mounted" || bad "rc=$RC err=$ERR"

CASE="fetch"
reset_calls
helper fetch
IMG1="$GUEST/fex-rootfs-archlinux-2026-01-01.sqsh"
[ "$RC" = 0 ] && cmp -s "$IMG1" "$SRV/v1.sqsh" && ok "the image is in place as <name>-<version>.sqsh" || bad "rc=$RC err=$ERR $(ls -A "$GUEST")"
[ -z "$(leftovers)" ] && ok "no partial download left" || bad "left: $(leftovers)"
grep -q "downloading the x86 guest" <<<"$ERR" && grep -q "100% of" <<<"$ERR" && ok "says what it downloads, with progress" || bad "stderr: $ERR"
not_mounted && [ "$(calls squashfuse)" = 0 ] && ok "no steam running: not mounted" || bad "mounted: $(cat "$T/mounts")"

CASE="fetch, already there"
reset_calls
helper fetch
[ "$RC" = 0 ] && [ ! -s "$T/requests" ] && ok "no download at all" || bad "rc=$RC requests: $(cat "$T/requests")"

CASE="mount"
reset_calls
helper mount
[ "$RC" = 0 ] && is_mounted && [ -f "$MNT/graphics_provider.json" ] && ok "mounted on fex-guest/root, graphics_provider.json there" || bad "rc=$RC err=$ERR mounts: $(cat "$T/mounts")"
grep -qxF "squashfuse $IMG1 $MNT" "$T/calls" && ok "squashfuse <image> <root>" || bad "calls: $(cat "$T/calls")"
ign=$((16#$(cat "$T/sigign")))
(( ign & (1 << 14) )) && (( ign & (1 << 1) )) && ok "squashfuse starts with TERM and INT ignored" || bad "SigIgn=$(cat "$T/sigign")"

CASE="mount, already mounted"
reset_calls
helper mount
[ "$RC" = 0 ] && [ "$(calls squashfuse)" = 0 ] && [ "$(grep -c fuse.squashfuse "$T/mounts")" = 1 ] && ok "never mounted twice" || bad "rc=$RC calls: $(cat "$T/calls")"

CASE="release, steam running"
holdlock "$GUEST/.users.lock" sh; reset_calls
helper release
[ "$RC" = 0 ] && is_mounted && [ "$(calls fusermount)" = 0 ] && ok "left mounted while a steam holds the users lock" || bad "rc=$RC calls: $(cat "$T/calls")"
unlock

CASE="release, inherited lock"
# A helper that inherited the only copy of the lock (exec'd from a holder) must not count itself.
( exec 9>>"$GUEST/.users.lock"; flock -s 9; RETROFORGE_STEAM_X86_GUEST_DIR="$GUEST" exec python3 "$HELPER" release ) 2>"$T/err"
not_mounted && grep -qF -- "-u -z $MNT" "$T/calls" && ok "released (lazily): the helper's own inherited copy is closed first" || bad "mounts: $(cat "$T/mounts") calls: $(cat "$T/calls")"

CASE="dead mount"
helper mount; rm -f "$MNT/graphics_provider.json"; reset_calls   # squashfuse killed: ENOTCONN
helper mount
[ "$RC" = 0 ] && [ "$(calls fusermount)" = 1 ] && [ "$(calls squashfuse)" = 1 ] && [ -f "$MNT/graphics_provider.json" ] \
  && ok "released and mounted again" || bad "rc=$RC err=$ERR calls: $(cat "$T/calls")"
grep -q "dead mount" <<<"$ERR" && ok "and said so" || bad "stderr: $ERR"
helper release

CASE="our x86 Mesa over the guest"
MESA_T="$T/x86-mesa"; BASE_T="$GUEST/base"
mkdir -p "$MESA_T/root/usr/lib"; echo ours >"$MESA_T/root/usr/lib/libvulkan_freedreno.so"
printf 'snapshot=2025-12-01\nmesa=26.2.4-retroforge1\n' >"$MESA_T/payload.conf"
reset_calls
RETROFORGE_X86_MESA="$MESA_T" helper mount
[ "$RC" = 0 ] && in_table "$BASE_T" && is_mounted && [ -f "$MNT/graphics_provider.json" ] && [ "$(cat "$MNT/.payload" 2>/dev/null)" = "$MESA_T/root" ] \
  && ok "the guest on fex-guest/base, our x86 Mesa over it on fex-guest/root, the provider still there" || bad "rc=$RC err=$ERR mounts: $(cat "$T/mounts")"
grep -qxF "squashfuse $IMG1 $BASE_T" "$T/calls" && grep -qxF "fuse-overlayfs -o lowerdir=$MESA_T/root:$BASE_T $MNT" "$T/calls" \
  && ok "squashfuse <image> <base>, then fuse-overlayfs lowerdir=<payload>:<base> <root> (read-only: no upper)" || bad "calls: $(cat "$T/calls")"
ign=$((16#$(cat "$T/sigign-ovl" 2>/dev/null || echo 0)))
(( ign & (1 << 14) )) && (( ign & (1 << 1) )) && ok "fuse-overlayfs starts with TERM and INT ignored too" || bad "SigIgn=$(cat "$T/sigign-ovl" 2>&1)"
grep -q "with our x86 Mesa over it" <<<"$ERR" && ok "and said so" || bad "stderr: $ERR"
reset_calls
RETROFORGE_X86_MESA="$MESA_T" helper release
not_mounted && ! in_table "$BASE_T" && [ "$(head -n 1 "$T/calls")" = "fusermount -u -z $MNT" ] && [ "$(calls fusermount)" = 2 ] \
  && ok "release: the overlay first, then the base" || bad "mounts: $(cat "$T/mounts") calls: $(cat "$T/calls")"

CASE="our x86 Mesa, a guest older than its snapshot"
printf 'snapshot=2026-06-01\n' >"$MESA_T/payload.conf"; reset_calls
RETROFORGE_X86_MESA="$MESA_T" helper mount
[ "$RC" = 0 ] && is_mounted && [ "$(calls fuse-overlayfs)" = 0 ] && grep -qxF "squashfuse $IMG1 $MNT" "$T/calls" \
  && ok "mounted as it is, on fex-guest/root" || bad "rc=$RC calls: $(cat "$T/calls")"
grep -q "predates the payload's snapshot 2026-06-01" <<<"$ERR" && ok "and says why" || bad "stderr: $ERR"
helper release

CASE="our x86 Mesa, the overlay fails"
printf 'snapshot=2025-12-01\n' >"$MESA_T/payload.conf"; touch "$T/overlay-fails"; reset_calls
RETROFORGE_X86_MESA="$MESA_T" helper mount
[ "$RC" = 1 ] && not_mounted && ! in_table "$BASE_T" && ok "exit 1, and the base is released again" || bad "rc=$RC mounts: $(cat "$T/mounts")"
rm -f "$T/overlay-fails"

CASE="kernel: mount"
if [ -z "$KUSER" ]; then
  echo ok >"$T/kernel-mode"; reset_calls
  helper mount
  [ "$RC" = 0 ] && is_mounted && [ "$(calls systemctl)" = 0 ] && [ "$(calls squashfuse)" = 1 ] && grep -q "has no name" <<<"$ERR" \
    && ok "uid $(id -u) has no name for the unit: FUSE, and it says why" || bad "rc=$RC err=$ERR calls: $(cat "$T/calls")"
  helper release
  skip "uid $(id -u) has no user name here: the kernel cases need one"
else
  echo ok >"$T/kernel-mode"; reset_calls; rm -f "$T/request"
  helper mount
  [ "$RC" = 0 ] && kernel_on && [ -f "$MNT/graphics_provider.json" ] && [ "$(calls squashfuse)" = 0 ] \
    && ok "root's kernel mount, no squashfuse" || bad "rc=$RC err=$ERR calls: $(cat "$T/calls") mounts: $(cat "$T/mounts")"
  grep -qxF "systemctl --no-ask-password start retroforge-x86-guest-mount@$KUSER.service" "$T/calls" \
    && ok "systemctl --no-ask-password start retroforge-x86-guest-mount@<user>.service" || bad "calls: $(cat "$T/calls")"
  [ "$(cat "$T/request" 2>/dev/null)" = "$(printf 'image=%s\nmesa=0' "$(basename "$IMG1")")" ] \
    && ok "the request: image=<the image's file name>, mesa=0 (no payload)" || bad "request: $(cat "$T/request" 2>&1)"
  grep -q "mounted $(basename "$IMG1") on $MNT (the kernel's squashfs and overlayfs)" <<<"$ERR" && ok "and says so" || bad "stderr: $ERR"
  [ "$(cat "$GUEST/.mounted")" = "$IMG1" ] && ok ".mounted names the image" || bad ".mounted: $(cat "$GUEST/.mounted")"

  CASE="kernel: mounted already"
  reset_calls
  helper mount
  [ "$RC" = 0 ] && [ ! -s "$T/calls" ] && ok "nothing asked again" || bad "rc=$RC calls: $(cat "$T/calls")"

  CASE="kernel: release"
  reset_calls
  helper release
  [ "$RC" = 0 ] && not_mounted && [ "$(cat "$T/calls")" = "systemctl --no-ask-password start retroforge-x86-guest-release@$KUSER.service" ] \
    && ok "released by root's release unit, no fusermount" || bad "rc=$RC err=$ERR calls: $(cat "$T/calls")"

  CASE="kernel: with our x86 Mesa"
  printf 'snapshot=2025-12-01\n' >"$MESA_T/payload.conf"; reset_calls
  RETROFORGE_X86_MESA="$MESA_T" helper mount
  [ "$RC" = 0 ] && kernel_on && [ "$(calls squashfuse)" = 0 ] && [ "$(calls fuse-overlayfs)" = 0 ] \
    && [ "$(sed -n 2p "$T/request")" = mesa=1 ] && ok "mesa=1 in the request, no FUSE at all" || bad "rc=$RC request: $(cat "$T/request") calls: $(cat "$T/calls")"
  grep -q "with our x86 Mesa over it (the kernel's squashfs and overlayfs)" <<<"$ERR" && ok "and says so" || bad "stderr: $ERR"
  RETROFORGE_X86_MESA="$MESA_T" helper release
  not_mounted && ! in_table "$BASE_T" && ok "released" || bad "mounts: $(cat "$T/mounts")"

  CASE="kernel: refused"
  echo fail >"$T/kernel-mode"; reset_calls
  helper mount
  [ "$RC" = 0 ] && is_mounted && ! kernel_on && [ "$(calls systemctl)" = 1 ] && [ "$(calls squashfuse)" = 1 ] \
    && ok "an SSH login, say: squashfuse instead" || bad "rc=$RC calls: $(cat "$T/calls")"
  grep -q "Interactive authentication required" <<<"$ERR" && grep -q "mounting with FUSE instead" <<<"$ERR" && ok "and says why" || bad "stderr: $ERR"
  reset_calls
  helper release
  not_mounted && [ "$(calls systemctl)" = 0 ] && [ "$(calls fusermount)" = 1 ] && ok "a FUSE mount: released with fusermount, root not asked" || bad "calls: $(cat "$T/calls")"

  CASE="kernel: the unit mounts nothing"
  echo broken >"$T/kernel-mode"; reset_calls
  helper mount
  [ "$RC" = 0 ] && is_mounted && ! kernel_on && [ "$(calls squashfuse)" = 1 ] && ok "squashfuse after the wait" || bad "rc=$RC err=$ERR calls: $(cat "$T/calls")"
  grep -q "did not mount" <<<"$ERR" && ok "and says so" || bad "stderr: $ERR"
  helper release

  CASE="kernel: turned off"
  echo ok >"$T/kernel-mode"; reset_calls
  RETROFORGE_X86_GUEST_KERNEL=0 helper mount
  [ "$RC" = 0 ] && is_mounted && [ "$(calls systemctl)" = 0 ] && [ "$(calls squashfuse)" = 1 ] && ok "RETROFORGE_X86_GUEST_KERNEL=0: squashfuse, root not asked" || bad "rc=$RC calls: $(cat "$T/calls")"
  helper release

  CASE="kernel: the holder releases"
  sleep 600 & FAKESTEAM=$!; reset_calls
  helper start "$FAKESTEAM"
  [ "$RC" = 0 ] && kernel_on && ok "start: root's mount" || bad "rc=$RC err=$ERR"
  kill -KILL "$FAKESTEAM"; wait "$FAKESTEAM" 2>/dev/null
  until_true 50 not_mounted && grep -qxF "systemctl --no-ask-password start retroforge-x86-guest-release@$KUSER.service" "$T/calls" \
    && ok "its steam gone: released by root's unit" || bad "mounts: $(cat "$T/mounts") calls: $(cat "$T/calls")"
  settle
fi
echo fail >"$T/kernel-mode"

CASE="start"
sleep 600 & FAKESTEAM=$!; reset_calls
helper start "$FAKESTEAM"
[ "$RC" = 0 ] && is_mounted && ok "mounted for the caller" || bad "rc=$RC err=$ERR"
HOLD="$(pgrep -f "steam-x86-guest start $FAKESTEAM")"
# As a container's PID 1 (docker run ... bash -c '...; bash tests/...' execs into it), every orphan is ours.
[ -n "$HOLD" ] && [ "$(ps -o sid= -p "$HOLD" | tr -d ' ')" != "$(ps -o sid= -p $$ | tr -d ' ')" ] \
  && { [ $$ = 1 ] || [ "$(ps -o ppid= -p "$HOLD" | tr -d ' ')" != $$ ]; } && ok "a holder is left, in its own session, not our child" || bad "holder: '$HOLD' $(ps -o pid,ppid,sid,args -p "${HOLD:-1}")"
kill -TERM $HOLD 2>/dev/null; sleep 0.3
[ -n "$HOLD" ] && kill -0 $HOLD 2>/dev/null && is_mounted && ok "it ignores TERM (OGUI's Exit), the mount stays" || bad "the holder died of TERM"
holdlock "$GUEST/.users.lock" sh   # a second steam
kill -KILL "$FAKESTEAM"; wait "$FAKESTEAM" 2>/dev/null
until_true 50 sh -c "! kill -0 $HOLD 2>/dev/null"
! kill -0 $HOLD 2>/dev/null && is_mounted && ok "its steam SIGKILLed: the holder goes, another steam keeps the mount" || bad "holder=$HOLD mounts: $(cat "$T/mounts")"
unlock
sleep 600 & FAKESTEAM=$!
helper start "$FAKESTEAM"
kill -KILL "$FAKESTEAM"; wait "$FAKESTEAM" 2>/dev/null
until_true 50 not_mounted && ok "the last steam SIGKILLed: released" || bad "mounts: $(cat "$T/mounts")"

CASE="fetch, bad checksum"
mkimage "$SRV/v2.sqsh" two; mkpin 2026-02-01 v2.sqsh "$(printf '0%.0s' {1..64})"; reset_calls
helper fetch
[ "$RC" = 1 ] && grep -q "sha256 mismatch" <<<"$ERR" && ok "refused (exit 1)" || bad "rc=$RC err=$ERR"
[ ! -e "$GUEST/fex-rootfs-archlinux-2026-02-01.sqsh" ] && [ -z "$(leftovers)" ] && ok "nothing half-downloaded left" || bad "$(ls -A "$GUEST")"
[ -f "$IMG1" ] && ok "the old image is kept" || bad "old image gone"

CASE="bump, not downloaded yet"
mkpin 2026-02-01 v2.sqsh; reset_calls
helper mount
[ "$RC" = 2 ] && grep -qxF "squashfuse $IMG1 $MNT" "$T/calls" && ok "exit 2, and the old image is mounted meanwhile" || bad "rc=$RC calls: $(cat "$T/calls")"

CASE="download cut short"
echo cut >"$SRV/.mode"; reset_calls
helper fetch
PART="$GUEST/.fex-rootfs-archlinux-2026-02-01.sqsh.part"
[ "$RC" = 1 ] && grep -q "cut short" <<<"$ERR" && [ "$(wc -c <"$PART")" = 150000 ] && ok "exit 1, the 150 kB it got kept for later" || bad "rc=$RC err=$ERR part=$(wc -c <"$PART" 2>&1)"
[ -f "$IMG1" ] && ok "the old image is still there" || bad "old image gone"

CASE="resume"
echo range >"$SRV/.mode"; reset_calls
helper fetch
IMG2="$GUEST/fex-rootfs-archlinux-2026-02-01.sqsh"
grep -q "range=bytes=150000-" "$T/requests" && ok "asks for the rest only (Range: bytes=150000-)" || bad "requests: $(cat "$T/requests")"
[ "$RC" = 0 ] && cmp -s "$IMG2" "$SRV/v2.sqsh" && [ "$(readlink "$GUEST/current")" = "$(basename "$IMG2")" ] \
  && ok "the joined image is in place, and current" || bad "rc=$RC err=$ERR current=$(readlink "$GUEST/current")"
[ -z "$(leftovers)" ] && ok "no partial download left" || bad "$(leftovers)"
is_mounted && grep -qxF "$IMG1" "$MNT/.image" && [ -f "$IMG1" ] \
  && ok "the old image stays mounted, and on disk, for the last steam to release" || bad "unmounted or removed under a running game: $(ls -A "$GUEST")"
helper release
not_mounted && [ ! -e "$IMG1" ] && [ -f "$IMG2" ] && ok "released: then the old image is removed" || bad "rc=$RC err=$ERR $(ls -A "$GUEST")"

CASE="server without Range"
mkimage "$SRV/v3.sqsh" three; mkpin 2026-03-01 v3.sqsh
head -c 1000 "$SRV/v1.sqsh" >"$GUEST/.fex-rootfs-archlinux-2026-03-01.sqsh.part"
echo full >"$SRV/.mode"; reset_calls
helper fetch
[ "$RC" = 0 ] && cmp -s "$GUEST/fex-rootfs-archlinux-2026-03-01.sqsh" "$SRV/v3.sqsh" && ok "a 200 to a Range request starts over" || bad "rc=$RC err=$ERR"
echo range >"$SRV/.mode"

CASE="stale partial of another version"
head -c 1000 "$SRV/v1.sqsh" >"$GUEST/.fex-rootfs-archlinux-2026-01-01.sqsh.part"
mkimage "$SRV/v4.sqsh" four; mkpin 2026-04-01 v4.sqsh
helper fetch
[ "$RC" = 0 ] && [ -z "$(leftovers)" ] && [ "$(cd "$GUEST" && ls -- *.sqsh)" = fex-rootfs-archlinux-2026-04-01.sqsh ] \
  && ok "removed; only the pinned image is left" || bad "rc=$RC $(ls -A "$GUEST")"

CASE="one fetch at a time"
mkimage "$SRV/v5.sqsh" five; mkpin 2026-05-01 v5.sqsh; reset_calls
holdlock "$GUEST/.fetch.lock" ex
helper fetch
[ "$RC" = 0 ] && [ ! -s "$T/requests" ] && ok "a second fetch exits 0 at once" || bad "rc=$RC requests: $(cat "$T/requests")"
unlock

CASE="download done while steam runs"
holdlock "$GUEST/.users.lock" sh; reset_calls
helper fetch
[ "$RC" = 0 ] && is_mounted && grep -q "fex-rootfs-archlinux-2026-05-01.sqsh" "$MNT/.image" && ok "mounted as soon as it is in place" || bad "rc=$RC err=$ERR"
unlock
helper release
not_mounted && ok "and released by the last steam" || bad "$(cat "$T/mounts")"

CASE="offline"
mkpin 2026-06-01 missing.sqsh "$(printf 'a%.0s' {1..64})"
helper fetch
[ "$RC" = 1 ] && grep -q "could not download" <<<"$ERR" && ok "exit 1, says what it could not fetch" || bad "rc=$RC err=$ERR"
settle

# ================================================================================================
# A channel: FEX's RootFS_links.json (here on the same server, or a file://), of which the pin's
# distro and type select one entry. Its Hash is an XXH3-64, checked with xxhsum.
LINKS="$SRV/RootFS_links.json"
mklinks() {  # mklinks <links file> <url of the ArchLinux SquashFS> <hash>: shaped like FEX's, with neighbours
  python3 - "$@" <<'PY'
import json, sys
out, url, h = sys.argv[1:4]
e = lambda m, v, u, h, t: {"DistroMatch": m, "DistroVersion": v, "URL": u, "Hash": h, "Type": t}
links = {"v1": {
    "Fedora 44 (SquashFS)": e("fedora", "44", url.replace("ArchLinux", "Fedora_44"), "fda4aaeab0fa69ba", "squashfs"),
    "ArchLinux (EroFS)": e("arch", "rolling", url.rsplit(".", 1)[0] + ".ero", "82c0c5f15edf59d2", "erofs"),
    "ArchLinux (SquashFS)": e("arch", "rolling", url, h, "squashfs"),
}}
with open(out + ".new", "w") as f:
    json.dump(links, f, indent=4)
PY
  mv "$1.new" "$1"
}
mkchan() {  # mkchan <links file url>: a channel pin
  printf 'name: fex-rootfs-archlinux\nchannel: %s\ndistro: arch\ntype: squashfs\n' "$1" >"$PIN"
}
publish() {  # publish <date> <seed>: FEX publishes a new ArchLinux SquashFS; SQ, H, and CIMG (its name here)
  mkdir -p "$SRV/ArchLinux/$1"; SQ="$SRV/ArchLinux/$1/ArchLinux.sqsh"
  mkimage "$SQ" "$2"; H="$(xxh3 "$SQ")"
  mklinks "$LINKS" "$URL/ArchLinux/$1/ArchLinux.sqsh" "$H"
  CIMG="$GUEST/fex-rootfs-archlinux-$1-$H.sqsh"
}
cur() { readlink "$GUEST/current"; }
FIXED_IMG="$GUEST/fex-rootfs-archlinux-2026-05-01.sqsh"   # the fixed pin's, from above

CASE="channel: the switch from a fixed pin"
publish 2026-09-01 c1; C1="$CIMG"; mkchan "$URL/RootFS_links.json"; reset_calls
helper mount
[ "$RC" = 0 ] && grep -qxF "$FIXED_IMG" "$MNT/.image" && [ ! -s "$T/requests" ] \
  && ok "mount never asks the network: the image fetched last (the fixed pin's) is mounted" || bad "rc=$RC err=$ERR requests: $(cat "$T/requests")"
helper release

CASE="channel: resolution"
reset_calls
helper fetch
[ "$RC" = 0 ] && cmp -s "$C1" "$SQ" && ok "the arch squashfs entry, downloaded as <name>-<dated directory>-<xxh3>.sqsh" || bad "rc=$RC err=$ERR $(ls -A "$GUEST")"
grep -q "^GET /RootFS_links.json " "$T/requests" && ! grep -qE '\.ero |Fedora' "$T/requests" \
  && ok "it read the links file, and took neither the EroFS nor the Fedora entry" || bad "requests: $(cat "$T/requests")"
[ "$(cur)" = "$(basename "$C1")" ] && [ ! -e "$FIXED_IMG" ] && [ -z "$(leftovers)" ] \
  && ok "it is current; the fixed pin's image, not mounted, is removed" || bad "current=$(cur) $(ls -A "$GUEST")"

CASE="channel: unchanged"
reset_calls
helper fetch
[ "$RC" = 0 ] && [ "$(grep -c . "$T/requests")" = 1 ] && grep -q "^GET /RootFS_links.json " "$T/requests" && [ -z "$ERR" ] \
  && ok "only the links file is read, quietly" || bad "rc=$RC err=$ERR requests: $(cat "$T/requests")"

CASE="channel: start"
sleep 600 & FAKESTEAM=$!; reset_calls
helper start "$FAKESTEAM"
[ "$RC" = 0 ] && is_mounted && grep -qxF "$C1" "$MNT/.image" && ok "the installed image is mounted at once" || bad "rc=$RC err=$ERR"
until_true 50 grep -q "^GET /RootFS_links.json " "$T/requests" && ok "and the channel is checked in the background" || bad "requests: $(cat "$T/requests")"
until_true 50 sh -c "! pgrep -f '$HELPER fetch' >/dev/null"

CASE="channel: it moves while steam runs"
publish 2026-10-01 c2; C2="$CIMG"; reset_calls
helper fetch
[ "$RC" = 0 ] && cmp -s "$C2" "$SQ" && [ "$(cur)" = "$(basename "$C2")" ] && ok "the new image is downloaded, checked and made current" || bad "rc=$RC err=$ERR current=$(cur)"
grep -qxF "$C1" "$MNT/.image" && [ -f "$C1" ] && ok "the old one stays mounted, and on disk, while steam runs" || bad "$(ls -A "$GUEST") image: $(cat "$MNT/.image" 2>&1)"
kill -KILL "$FAKESTEAM"; wait "$FAKESTEAM" 2>/dev/null
until_true 50 not_mounted && until_true 20 test ! -e "$C1" && [ -f "$C2" ] && ok "steam gone: released, then the old image is removed" || bad "mounts: $(cat "$T/mounts") $(ls -A "$GUEST")"
helper mount
[ "$RC" = 0 ] && grep -qxF "$C2" "$MNT/.image" && ok "the next start mounts the new one" || bad "rc=$RC err=$ERR"
helper release

CASE="channel: it moves, nothing mounted"
publish 2026-11-01 c3; C3="$CIMG"
helper fetch
[ "$RC" = 0 ] && [ -f "$C3" ] && [ ! -e "$C2" ] && [ "$(cur)" = "$(basename "$C3")" ] && ok "the old image is removed as soon as the new one is in place" || bad "rc=$RC err=$ERR $(ls -A "$GUEST")"

CASE="channel: hash mismatch"
publish 2026-12-01 c4; mklinks "$LINKS" "$URL/ArchLinux/2026-12-01/ArchLinux.sqsh" 123456789abcdef0
helper fetch
[ "$RC" = 1 ] && grep -q "xxh3 mismatch" <<<"$ERR" && ok "refused (exit 1)" || bad "rc=$RC err=$ERR"
! ls "$GUEST"/*2026-12-01* >/dev/null 2>&1 && [ -z "$(leftovers)" ] && [ "$(cur)" = "$(basename "$C3")" ] && [ -f "$C3" ] \
  && ok "nothing of it is kept; the installed image stays current" || bad "current=$(cur) $(ls -A "$GUEST")"

CASE="channel: offline"
DEAD="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
mkchan "http://127.0.0.1:$DEAD/RootFS_links.json"
helper fetch
[ "$RC" = 1 ] && grep -q "could not read the x86 guest channel" <<<"$ERR" && grep -qF "keeping $(basename "$C3")" <<<"$ERR" \
  && ok "exit 1: says so, and that it keeps what is installed" || bad "rc=$RC err=$ERR"
[ "$(cur)" = "$(basename "$C3")" ] && [ "$(cd "$GUEST" && ls -- *.sqsh)" = "$(basename "$C3")" ] && ok "nothing removed, nothing changed" || bad "$(ls -A "$GUEST")"
helper mount
[ "$RC" = 0 ] && grep -qxF "$C3" "$MNT/.image" && ok "and a steam still gets it mounted" || bad "rc=$RC err=$ERR"
helper release

CASE="channel: a links file it cannot use"
mkchan "$URL/RootFS_links.json"
bad_links() {  # bad_links <what> <links file content>
  printf '%s' "$2" >"$LINKS"; reset_calls
  helper fetch
  [ "$RC" = 1 ] && grep -q "is not a links file this can use" <<<"$ERR" && [ "$(cur)" = "$(basename "$C3")" ] \
    && [ "$(grep -c . "$T/requests")" = 1 ] && ok "$1: refused, nothing downloaded or changed" || bad "$1: rc=$RC err=$ERR requests: $(cat "$T/requests")"
}
ARCH='"DistroMatch": "arch", "Type": "squashfs"'
GOOD="\"URL\": \"$URL/ArchLinux/2026-11-01/ArchLinux.sqsh\""
bad_links "not JSON" '<html>503 Service Unavailable</html>'
bad_links "no v1" '{"v2": {}}'
bad_links "v1 a list" '{"v1": []}'
bad_links "no arch squashfs entry" "{\"v1\": {\"ArchLinux (EroFS)\": {\"DistroMatch\": \"arch\", \"Type\": \"erofs\", $GOOD, \"Hash\": \"1\"}}}"
bad_links "two arch squashfs entries" "{\"v1\": {\"a\": {$ARCH, $GOOD, \"Hash\": \"1\"}, \"b\": {$ARCH, $GOOD, \"Hash\": \"2\"}}}"
bad_links "a Hash that is not hex" "{\"v1\": {\"a\": {$ARCH, $GOOD, \"Hash\": \"xyz\"}}}"
bad_links "a Hash over 64 bits" "{\"v1\": {\"a\": {$ARCH, $GOOD, \"Hash\": \"123456789abcdef01\"}}}"
bad_links "no URL" "{\"v1\": {\"a\": {$ARCH, \"Hash\": \"1\"}}}"
bad_links "a URL neither https nor the channel's scheme" "{\"v1\": {\"a\": {$ARCH, \"URL\": \"file://$SRV/v1.sqsh\", \"Hash\": \"1\"}}}"

CASE="channel: a hash without leading zeros"
mkdir -p "$SRV/ArchLinux/2027-01-01"; SQ="$SRV/ArchLinux/2027-01-01/ArchLinux.sqsh"
for i in $(seq 300); do mkimage "$SQ" "zero$i"; H="$(xxh3 "$SQ")"; [ "${H:0:1}" = 0 ] && break; done
mklinks "$LINKS" "$URL/ArchLinux/2027-01-01/ArchLinux.sqsh" "${H#"${H%%[!0]*}"}"
Z="$GUEST/fex-rootfs-archlinux-2027-01-01-$H.sqsh"
helper fetch
[ "${H:0:1}" = 0 ] && [ "$RC" = 0 ] && cmp -s "$Z" "$SQ" \
  && ok "accepted: $H written as ${H#"${H%%[!0]*}"}, as FEX writes them; the file is named with all 16 digits" || bad "rc=$RC err=$ERR hash=$H"

CASE="channel: no xxhsum"
publish 2027-02-01 c5; C5="$CIMG"; P5="$GUEST/.$(basename "$C5").part"; reset_calls
RETROFORGE_XXHSUM="$T/nowhere/xxhsum" helper fetch
[ "$RC" = 1 ] && grep -q "could not check" <<<"$ERR" && [ ! -e "$C5" ] && [ "$(cur)" = "$(basename "$Z")" ] \
  && ok "exit 1: nothing is installed unchecked" || bad "rc=$RC err=$ERR current=$(cur) $(ls -A "$GUEST")"
cmp -s "$P5" "$SQ" && ok "the downloaded part is kept" || bad "part: $(ls -la "$P5" 2>&1)"
reset_calls
helper fetch
grep -q "range=bytes=300000-" "$T/requests" && [ "$RC" = 0 ] && cmp -s "$C5" "$SQ" && [ "$(cur)" = "$(basename "$C5")" ] \
  && ok "the next fetch checks it without downloading it again (416), and installs it" || bad "rc=$RC err=$ERR requests: $(cat "$T/requests")"

CASE="channel: file:// links file and image"
mkdir -p "$T/mirror/ArchLinux/2027-03-01"; SQ="$T/mirror/ArchLinux/2027-03-01/ArchLinux.sqsh"
mkimage "$SQ" c6; H="$(xxh3 "$SQ")"
mklinks "$T/mirror/RootFS_links.json" "file://$SQ" "$H"; mkchan "file://$T/mirror/RootFS_links.json"; reset_calls
helper fetch
[ "$RC" = 0 ] && cmp -s "$GUEST/fex-rootfs-archlinux-2027-03-01-$H.sqsh" "$SQ" && [ ! -s "$T/requests" ] \
  && ok "a file:// channel may name file:// images" || bad "rc=$RC err=$ERR"

CASE="a pin with both a channel and a url"
echo "url: $URL/v1.sqsh" >>"$PIN"
helper fetch
[ "$RC" = 1 ] && grep -q "either channel, distro and type or version, url and sha256" <<<"$ERR" && ok "refused" || bad "rc=$RC err=$ERR"
settle

# ================================================================================================
# The wrapper, with the bootstrap stubbed and the real helper: a fake client records how it was
# started.
W="$T/w"; mkdir -p "$W/rt"
WHOME="$W/home"; WROOT="$WHOME/.local/share/Steam"; WGUEST="$WHOME/.local/share/retroforge/fex-guest"
cat >"$W/rt/run" <<EOF
#!/usr/bin/env bash
n=\$(( \$(cat "$W/count" 2>/dev/null || echo 0) + 1 )); echo "\$n" >"$W/count"
{
  echo "provider: \${STEAM_COMPAT_GRAPHICS_PROVIDER-unset}"
  [ -f "$WGUEST/root/graphics_provider.json" ] && echo "mounted: yes" || echo "mounted: no"
  ls "$WGUEST"/*.sqsh >/dev/null 2>&1 && echo "image: yes" || echo "image: no"
  echo "mounted image: \$(cat "$WGUEST/root/.image" 2>/dev/null)"
} >"$W/call\$n"
codes=(\$(cat "$W/codes")); c="\${codes[\$((n-1))]:-0}"
if [ "\$c" = S ]; then
  trap 'exit 143' TERM; echo \$\$ >"$W/runpid"
  while :; do sleep 0.1; done
fi
exit "\$c"
EOF
cat >"$W/bootstrap" <<EOF
#!/usr/bin/env bash
mkdir -p "\$RETROFORGE_STEAM_ROOT/steamrtarm64"; echo "$W/rt/run"
EOF
cat >"$W/helper" <<EOF
#!/usr/bin/env bash
echo "helper \$*" >>"$T/calls"
exec python3 "$HELPER" "\$@"
EOF
chmod +x "$W/rt/run" "$W/bootstrap" "$W/helper"
# RETROFORGE_STEAM_DIRECT_CLI names no such file (test-steam-direct.sh): every launch here goes to the
# client.
WENV=(env -u RETROFORGE_STEAM_ROOT -u XDG_DATA_HOME -u RETROFORGE_STEAM_X86_GUEST -u STEAM_COMPAT_GRAPHICS_PROVIDER
      -u RETROFORGE_STEAM_X86_GUEST_DIR HOME="$WHOME" RETROFORGE_STEAM_BOOTSTRAP="$W/bootstrap"
      RETROFORGE_STEAM_X86_GUEST_HELPER="$W/helper" RETROFORGE_CPUINFO=/dev/null
      RETROFORGE_STEAM_DIRECT_CLI="$W/no-direct-cli")
w_mounted() { in_table "$WGUEST/root"; }
w_unmounted() { ! w_mounted; }
wrap() {  # wrap <exit codes of successive runs> [args...]
  echo "$1" >"$W/codes"; shift; rm -f "$W/count" "$W"/call*
  "${WENV[@]}" bash "$WRAP" "$@" >"$W/out" 2>"$W/err"; WRC=$?
  WERR="$(cat "$W/err")"
}
start_bg() {  # start_bg: a wrapper whose client runs until TERMed; WPID
  echo S >"$W/codes"; rm -f "$W/count" "$W"/call* "$W/runpid"
  "${WENV[@]}" bash "$WRAP" steam://rungameid/1 >/dev/null 2>"$W/err" &
  WPID=$!
  until_true 100 test -s "$W/runpid"
}
image_there() { ls "$WGUEST"/*.sqsh >/dev/null 2>&1; }

CASE="wrapper: first start"
mkimage "$SRV/w.sqsh" wrapper; mkpin 2026-07-01 w.sqsh
echo 3 >"$SRV/.delay"; reset_calls
wrap 0 steam://rungameid/42
[ "$WRC" = 0 ] && grep -qx "image: no" "$W/call1" && ok "the client starts at once, before the download is done" || bad "rc=$WRC $(cat "$W/call1" 2>&1) $WERR"
grep -qx "provider: unset" "$W/call1" && ok "no STEAM_COMPAT_GRAPHICS_PROVIDER yet: pressure-vessel would abort a container on the missing file" || bad "$(cat "$W/call1")"
grep -q "the x86 guest is not in place yet" "$W/err" && ok "and says x86 games get it from the next start" || bad "stderr: $(cat "$W/err")"
[ "$(readlink "$WHOME/.steam/sdk64")" = "$WROOT/linux64" ] && [ "$(readlink "$WHOME/.steam/sdk32")" = "$WROOT/linux32" ] \
  && ok "~/.steam/sdk64 and sdk32 point at the client's linux64 and linux32" || bad "links: $(ls -la "$WHOME/.steam")"
grep -q "^helper start [0-9]" "$T/calls" && ok "steam ran the helper's start with its PID" || bad "calls: $(cat "$T/calls")"
! image_there && ok "steam is gone, the download is not done yet" || bad "the wrapper waited for the download"
until_true 100 image_there && cmp -s "$WGUEST/fex-rootfs-archlinux-2026-07-01.sqsh" "$SRV/w.sqsh" \
  && ok "the detached download finishes after steam exits" || bad "no image: $(ls -A "$WGUEST")"
settle
w_unmounted && ok "and is not mounted with no steam running" || bad "mounts: $(cat "$T/mounts")"
grep -q "downloading the x86 guest" "$W/err" && grep -q "the x86 guest is in place" "$W/err" && ok "its log goes to steam's stderr" || bad "stderr: $(cat "$W/err")"
echo 0 >"$SRV/.delay"

CASE="wrapper: downloaded"
reset_calls
wrap 0 steam://rungameid/42
grep -qx "mounted: yes" "$W/call1" && ok "mounted before the client starts" || bad "$(cat "$W/call1" 2>&1) $WERR"
grep -qx "provider: $WGUEST/root/graphics_provider.json" "$W/call1" && ok "STEAM_COMPAT_GRAPHICS_PROVIDER=<guest>/root/graphics_provider.json" || bad "$(cat "$W/call1")"
! grep -q "not in place yet" <<<"$WERR" && ok "and no word about the guest missing" || bad "stderr: $WERR"
settle
[ ! -s "$T/requests" ] && ok "no download" || bad "requests: $(cat "$T/requests")"
w_unmounted && grep -qF "fusermount -u -z $WGUEST/root" "$T/calls" && ok "released (lazily) once steam exits" || bad "mounts: $(cat "$T/mounts") calls: $(cat "$T/calls")"

CASE="wrapper: a second steam"
reset_calls
start_bg
w_mounted && ok "the first steam mounted it" || bad "not mounted: $(cat "$W/err")"
wrap 0 steam://rungameid/2
second="$(grep "^helper start" "$T/calls" | tail -1 | cut -d' ' -f3)"
until_true 50 sh -c "! pgrep -f 'steam-x86-guest start $second' >/dev/null"
[ "$(calls squashfuse)" = 1 ] && ok "the second does not mount again" || bad "calls: $(cat "$T/calls")"
w_mounted && ok "and leaves it mounted when it exits" || bad "the second steam unmounted the first one's guest"
kill -TERM "$WPID"; wait "$WPID"
until_true 50 w_unmounted && ok "the first releases it when it exits" || bad "mounts: $(cat "$T/mounts")"
settle

CASE="wrapper: download done while steam runs"
rm -f "$WGUEST"/*.sqsh; mkimage "$SRV/w2.sqsh" wrapper2; mkpin 2026-08-01 w2.sqsh
echo 1 >"$SRV/.delay"; reset_calls
start_bg
grep -qx "mounted: no" "$W/call1" && grep -qx "provider: unset" "$W/call1" && ok "steam starts with nothing mounted and no provider" || bad "$(cat "$W/call1" 2>&1)"
until_true 100 w_mounted && ok "mounted when the download finishes, while steam runs" || bad "mounts: $(cat "$T/mounts") err: $(cat "$W/err")"
kill -TERM "$WPID"; wait "$WPID"
until_true 50 w_unmounted && ok "released when steam exits" || bad "mounts: $(cat "$T/mounts")"
echo 0 >"$SRV/.delay"
settle

CASE="wrapper: dead mount from a killed squashfuse"
RETROFORGE_STEAM_X86_GUEST_DIR="$WGUEST" python3 "$HELPER" mount 2>/dev/null
rm -f "$WGUEST/root/graphics_provider.json"; reset_calls
wrap 0
grep -qx "mounted: yes" "$W/call1" && [ "$(calls squashfuse)" = 1 ] && ok "replaced before the client starts" || bad "$(cat "$W/call1") calls: $(cat "$T/calls")"
until_true 50 w_unmounted && ok "and released after" || bad "mounts: $(cat "$T/mounts")"
settle

CASE="wrapper: a channel"
WOLD="$WGUEST/fex-rootfs-archlinux-2026-08-01.sqsh"   # the fixed pin's, from above: current, not mounted
mkdir -p "$SRV/ArchLinux/2027-04-01"; SQ="$SRV/ArchLinux/2027-04-01/ArchLinux.sqsh"; mkimage "$SQ" wrapper3; H="$(xxh3 "$SQ")"
mklinks "$LINKS" "$URL/ArchLinux/2027-04-01/ArchLinux.sqsh" "$H"; mkchan "$URL/RootFS_links.json"
WNEW="$WGUEST/fex-rootfs-archlinux-2027-04-01-$H.sqsh"; reset_calls
start_bg
grep -qx "mounted image: $WOLD" "$W/call1" && ok "steam starts at once, with the installed image mounted" || bad "$(cat "$W/call1" 2>&1) $(cat "$W/err")"
until_true 100 test -f "$WNEW" && ok "the channel's newer image arrives in the background while steam runs" || bad "$(ls -A "$WGUEST") err: $(cat "$W/err")"
grep -qxF "$WOLD" "$WGUEST/root/.image" && [ -f "$WOLD" ] && ok "the running steam keeps the old one" || bad "$(cat "$WGUEST/root/.image" 2>&1) $(ls -A "$WGUEST")"
kill -TERM "$WPID"; wait "$WPID"
until_true 50 w_unmounted && until_true 20 test ! -e "$WOLD" && ok "steam gone: released, then the old image is removed" || bad "mounts: $(cat "$T/mounts") $(ls -A "$WGUEST")"
settle
wrap 0 steam://rungameid/3
grep -qx "mounted image: $WNEW" "$W/call1" && ok "the next steam has the new one" || bad "$(cat "$W/call1" 2>&1) $WERR"
settle

CASE="wrapper: opted out"
rm -rf "$WGUEST" "$WHOME/.steam"; reset_calls
echo 0 >"$W/codes"; rm -f "$W/count" "$W"/call*
"${WENV[@]}" RETROFORGE_STEAM_X86_GUEST=0 bash "$WRAP" >/dev/null 2>"$W/err"
grep -qx "provider: unset" "$W/call1" && ok "RETROFORGE_STEAM_X86_GUEST=0: no STEAM_COMPAT_GRAPHICS_PROVIDER" || bad "$(cat "$W/call1")"
[ ! -s "$T/calls" ] && [ ! -e "$WGUEST" ] && ok "no helper run, no download, nothing created" || bad "calls: $(cat "$T/calls") $(ls -A "$WGUEST" 2>&1)"
[ -L "$WHOME/.steam/sdk64" ] && ok "the sdk links are still made" || bad "$(ls -la "$WHOME/.steam")"

CASE="wrapper: ~/.steam/sdk64 is a real folder"
rm -f "$WHOME/.steam/sdk64"; mkdir -p "$WHOME/.steam/sdk64"
wrap 0
[ -d "$WHOME/.steam/sdk64" ] && [ ! -L "$WHOME/.steam/sdk64" ] && grep -q "sdk64 is a directory, not a link; leaving it alone" <<<"$WERR" \
  && ok "left alone, and said so" || bad "$(ls -la "$WHOME/.steam")"
settle

echo
echo "$PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]

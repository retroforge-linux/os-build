#!/usr/bin/env bash
# Offline test for what Steam Remote Play needs from the image: the way into Steam's UI (Open on Main
# menu > Emulators > Steam Client), Valve's Steam Input udev rules, and the video codec links.
#
#   tests/test-steam-remoteplay.sh
#
# WHY THIS EXISTS. Each of these fails silently on a device:
#   - the way in: the Apps page's Open on Steam Client (apps_page.gd) launches `steam` with
#     the Steam plugin's flags and steam://open/bigpicture. A steam://rungameid/ launch is treated as
#     one game and Steam is SIGTERMed once only its own windows remain, which would end a Remote Play
#     stream; -steamframe/-deckard switch on Frame-only paths. There is no Steam library card (removed
#     2026-10-18: Steam is installed and opened from Emulators).
#   - Valve's rules must stay verbatim below their header (the header names the upstream blob), or a
#     hand edit hides behind "Valve's file".
#   - the codec links must name iris's encoder (every SoC), and a decoder on the SM6115 only:
#     /dev/video-dec0 puts the Steam UI's video on the hardware, slower and hotter than the CPU on
#     SM8250/8550/8650, but on the SM6115 it spares the weak cores (SM4450 unmeasured, no link).
#   - udev syntax is checked with `udevadm verify` where the host has it (systemd >= 255).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PAGE="$ROOT/apps/ogui-retroforge-plugin/plugin/apps_page.gd"
INPUT="$ROOT/rootfs/overlay/usr/lib/udev/rules.d/60-steam-input.rules"
CODEC="$ROOT/rootfs/overlay/usr/lib/udev/rules.d/70-retroforge-video-codec.rules"
for f in "$PAGE" "$INPUT" "$CODEC"; do [ -f "$f" ] || { echo "missing: $f" >&2; exit 1; }; done

PASS=0; FAIL=0; SKIP=0; CASE=""
ok()   { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }
skip() { SKIP=$((SKIP+1)); printf '  skip %s -- %s\n' "$CASE" "$1"; }
# The git blob id of stdin ("blob <size>\0" + content, sha1), without git: the suite also runs from
# exports and containers where there is no usable repository.
blob_id() {
  local tmp; tmp="$(mktemp)"; cat >"$tmp"
  { printf 'blob %d\0' "$(wc -c <"$tmp" | tr -d ' ')"; cat "$tmp"; } \
    | { sha1sum 2>/dev/null || shasum -a 1; } | cut -c1-40
  rm -f "$tmp"
}

# ================================================================================================
CASE="the way in"
# The steam-client branch of _open(): its command and its PackedStringArray of arguments.
block="$(sed -n '/if id == "steam-client":/,/launch_manager.launch/p' "$PAGE")"
command="$(sed -n 's/.*item.command = "\([^"]*\)".*/\1/p' <<<"$block" | head -1)"
args="$(sed -n 's/.*PackedStringArray(\[\(.*\)\]).*/\1/p' <<<"$block" | head -1 | tr -d '",')"
[ -n "$block" ] && ok "Open on Steam Client has its own launch" || bad "no steam-client branch in _open()"
[ "$command" = steam ] && ok "runs /usr/bin/steam" || bad "command '$command'"
[[ " $args " == *" steam://open/bigpicture "* ]] && ok "opens Big Picture" || bad "args '$args'"
[[ " $args " == *" -steamdeck "* ]] && ok "with -steamdeck, the client channel's flag (steam.pin)" || bad "args '$args'"
[[ "$args" != *rungameid* ]] && ok "no steam://rungameid/ (OGUI would SIGTERM Steam and end a stream)" || bad "args '$args'"
[[ "$args" != *-steamframe* && "$args" != *-deckard* ]] && ok "no Frame-only flags" || bad "args '$args'"
[ ! -e "$ROOT/rootfs/overlay/usr/share/applications/retroforge-steam.desktop" ] && ok "no Steam library card" || bad "the card is back"

CASE="Valve's rules"
blob="$(sed -n 's/^# .*(git blob \([0-9a-f]\{12\}\)).*/\1/p' "$INPUT" | head -1)"
start="$(grep -n '^# ---- upstream 60-steam-input.rules' "$INPUT" | cut -d: -f1)"
if [ -n "$blob" ] && [ -n "$start" ]; then
  got="$(tail -n +"$((start + 1))" "$INPUT" | blob_id)"
  [ "${got:0:12}" = "$blob" ] && ok "verbatim below the header (blob $blob)" || bad "body hashes to ${got:0:12}, header says $blob"
else
  bad "no blob in the header or no upstream marker"
fi
grep -q "Copyright (c) 2018 Valve Software" "$INPUT" && grep -q "Permission is hereby granted" "$INPUT" \
  && ok "carries Valve's MIT notice" || bad "MIT notice missing"
rules="$(tail -n +"$((start + 1))" "$INPUT" | grep -vcE '^\s*(#|$)')"
grants="$(tail -n +"$((start + 1))" "$INPUT" | grep -vE '^\s*(#|$)' | grep -c 'TAG+="uaccess"')"
[ "$rules" -gt 50 ] && [ $((rules - grants)) -le 2 ] && ok "$grants of $rules rules grant uaccess (the rest: wakeup)" \
  || bad "$grants of $rules rules grant uaccess"

CASE="codec links"
# The decoder link only on the SM6115: elsewhere the Steam UI's Chromium decodes on the hardware
# slower and hotter than on its CPU (four cores at 95 C on the Pocket FIT, 2026-10-29). Every
# video-dec rule must name the SM6115's compatible, not the qcm2290 fallback the SM4450 shares.
dec="$(grep -E 'SYMLINK\+="video-dec' "$CODEC")"
! grep -qv 'ATTRS{modalias}=="\*Cqcom,sm6115-venusC\*"' <<<"$dec" \
  && ok "no decoder link but the SM6115's (other SoCs' Steam UI decodes on the CPU)" \
  || bad "a /dev/video-dec* link beyond the SM6115: the Steam UI decodes on the hardware there"
grep -qE 'ATTR\{name\}=="qcom-iris-decoder".*ATTRS\{modalias\}=="\*Cqcom,sm6115-venusC\*".*SYMLINK\+="video-dec0"' <<<"$dec" \
  && ok "SM6115 qcom-iris-decoder -> /dev/video-dec0 (the Steam UI decodes on it)" || bad "no decoder link for the SM6115"
! grep -q 'qcom-venus' "$CODEC" && ok "no venus rules (venus is not built)" || bad "a rule still names venus"
grep -qE 'ATTR\{name\}=="qcom-iris-encoder".*SYMLINK\+="video-enc0"' "$CODEC" \
  && ok "qcom-iris-encoder -> /dev/video-enc0" || bad "no rule for qcom-iris-encoder"

CASE="udev syntax"
if udevadm verify --help >/dev/null 2>&1; then
  out="$(udevadm verify --no-style "$INPUT" "$CODEC" 2>&1)" && ok "udevadm verify: both files" || bad "udevadm verify: $out"
else
  skip "no udevadm verify on this host"
fi

echo
echo "$PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]

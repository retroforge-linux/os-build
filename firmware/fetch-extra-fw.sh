#!/usr/bin/env bash
# qforge extra-firmware fetch — stage the VENDOR blobs that neither linux-firmware nor the
# Nova-Deck/qcom-firmwares repo carries (today: the SM6115 MANGMI Air X's Himax touch firmware,
# AW88261 amp calibration and WCN3950 Bluetooth), republished by ROCKNIX/extra-firmware.
# Pinned by commit + per-file sha256 in firmware/EXTRA_FW.pin.
#
#   firmware/fetch-extra-fw.sh
#
# Exports to firmware/extra-fw/ (git-ignored). Same contract as fetch-linux-fw.sh — idempotent,
# every file verified against the pin, a pin bump re-fetches exactly the affected files — against
# a raw.githubusercontent base, where the URL is <base>/<commit>/<path> instead of cgit's ?id=.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PIN="$ROOT/firmware/EXTRA_FW.pin"
DEST="$ROOT/firmware/extra-fw"

[ -f "$PIN" ] || { echo "missing pin: $PIN" >&2; exit 1; }
pin_hdr() { sed -n "s/^$1:[[:space:]]*//p" "$PIN" | head -1; }
COMMIT="$(pin_hdr commit)"; BASE="$(pin_hdr base)"
[ -n "$COMMIT" ] && [ -n "$BASE" ] || { echo "pin missing commit/base header" >&2; exit 1; }

echo "[qforge] extra-firmware @ ${COMMIT:0:12} -> ${DEST#"$ROOT"/}"
mkdir -p "$DEST"
n=0 fetched=0
while read -r src dst sha _rest; do
  case "$src" in ''|'#'* |commit:|base:) continue ;; esac
  [ -n "$dst" ] && [ -n "$sha" ] || { echo "bad pin line: '$src $dst $sha'" >&2; exit 1; }
  out="$DEST/$dst"
  n=$((n + 1))
  if [ -f "$out" ] && echo "$sha  $out" | sha256sum -c - >/dev/null 2>&1; then
    continue
  fi
  tmp="$(mktemp)"
  # Retry, because this loop makes one request per pinned file and a single transient 5xx from
  # the cgit frontend would otherwise abort a build 30+ minutes in (seen: a 503 on qca/htnv20.bin
  # during the ota/v0.2.4 release). curl's default exponential backoff, capped so a genuinely
  # dead upstream still fails the build promptly instead of stalling the job.
  curl -fsSL --retry 5 --retry-all-errors --retry-max-time 120 \
    -o "$tmp" "${BASE}/${COMMIT}/${src}" \
    || { echo "download failed: $src" >&2; rm -f "$tmp"; exit 1; }
  echo "${sha}  ${tmp}" | sha256sum -c - >/dev/null \
    || { echo "sha256 mismatch for $src — refusing (pin stale? wrong commit?)" >&2; rm -f "$tmp"; exit 1; }
  install -Dm0644 "$tmp" "$out"; rm -f "$tmp"
  echo "  ok   $src -> $dst"
  fetched=$((fetched + 1))
done < "$PIN"
echo "[qforge] $n firmware file(s) present in ${DEST#"$ROOT"/} ($fetched fetched this run)"

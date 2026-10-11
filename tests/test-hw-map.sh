#!/usr/bin/env bash
# Offline test for /usr/lib/qforge/hw-map (the standard hardware tree, /run/qforge/hw).
#
#   tests/test-hw-map.sh
#
# Drives the real script against a fabricated sysfs (QFORGE_HW_SYS) and checks the rules that
# matter on the boards we have: the charger's companion "battery" node (no capacity) is not the
# battery; the charger IC (reports `status`) wins over a bare Type-C source; thermal roles by
# profile type name or by pattern, every zone under all/; LED groups in natural order (l10 after
# l2); the profile's QFORGE_HW_* pins; hw.env is sourceable. Host only, no root, no Godot.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/rootfs/overlay/usr/lib/qforge/hw-map"
PASS=0; FAIL=0; CASE=""
ok()  { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }
[ -x "$SCRIPT" ] || { echo "missing or not executable: $SCRIPT" >&2; exit 1; }
T="$(mktemp -d)" && [ -d "$T" ] || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$T"' EXIT

S="$T/sys"
mk() { mkdir -p "$(dirname "$S/$1")"; printf '%s\n' "$2" > "$S/$1"; }
# Air X-shaped board
mk class/power_supply/bq256xx-battery/type Battery          # the charger's companion: no capacity
mk class/power_supply/bq256xx-battery/charge_full_design 5000000
mk class/power_supply/battery/type Battery
mk class/power_supply/battery/capacity 73
mk class/power_supply/tcpm-source/type USB                  # bare Type-C source: online only
mk class/power_supply/tcpm-source/online 1
mk class/power_supply/bq256xx-charger/type USB              # the charger IC: online + status
mk class/power_supply/bq256xx-charger/online 1
mk class/power_supply/bq256xx-charger/status Charging
mk class/backlight/backlight/brightness 20
mk class/thermal/thermal_zone0/type mapss-thermal
mk class/thermal/thermal_zone6/type cpu4-thermal
mk class/thermal/thermal_zone11/type cpu67-thermal
mk class/thermal/thermal_zone12/type cpu0123-thermal
mk class/thermal/thermal_zone15/type gpu-thermal
mk class/thermal/thermal_zone17/type battery
mk class/thermal/thermal_zone18/type battery-thermal
mk class/hwmon/hwmon2/name wlan_thermal
mk class/hwmon/hwmon20/name gpio_fan
mk class/hwmon/hwmon20/fan1_input 0
mkdir -p "$S/class/devfreq/5900000.gpu" "$S/devices/system/cpu"
for l in rgb:l1 rgb:l2 rgb:l10 rgb:l3 rgb:r1 rgb:r2 left_red_1 mmc0::; do mkdir -p "$S/class/leds/$l"; done
for z in "$S"/class/thermal/thermal_zone*; do printf '%s\n' 40000 > "$z/temp"; done

run() { QFORGE_HW_SYS="$S" QFORGE_HW_RUN="$T/run/hw" QFORGE_HW_DEVICE_ENV= "$@" bash "$SCRIPT" 2>"$T/stderr"; }
target() { readlink "$T/run/hw/$1" 2>/dev/null | sed "s|^$S/||"; }

# =================================================================================================
CASE="detection"
run env && ok "runs" || bad "exit $? -- $(cat "$T/stderr")"
[ "$(target battery)" = class/power_supply/battery ] && ok "the battery is the one with a capacity, not the charger's companion node" || bad "battery -> $(target battery)"
[ "$(target charger)" = class/power_supply/bq256xx-charger ] && ok "the charger IC (with status) wins over the bare Type-C source" || bad "charger -> $(target charger)"
[ "$(target backlight)" = class/backlight/backlight ] && ok "backlight" || bad "backlight -> $(target backlight)"
[ "$(target thermal/cpu)" = class/thermal/thermal_zone6 ] && ok "cpu role: first cpu* zone in zone order" || bad "thermal/cpu -> $(target thermal/cpu)"
[ "$(target thermal/gpu)" = class/thermal/thermal_zone15 ] && ok "gpu role" || bad "thermal/gpu -> $(target thermal/gpu)"
[ "$(target thermal/battery)" = class/thermal/thermal_zone17 ] && ok "battery role" || bad "thermal/battery -> $(target thermal/battery)"
[ ! -e "$T/run/hw/thermal/skin" ] && ok "no skin zone, no skin link" || bad "thermal/skin exists"
[ "$(ls "$T/run/hw/thermal/all" | wc -l | tr -d ' ')" = 7 ] && ok "every zone under thermal/all" || bad "thermal/all has $(ls "$T/run/hw/thermal/all" | tr '\n' ' ')"
[ "$(target fan)" = class/hwmon/hwmon20 ] && ok "the hwmon with a fan1_input is the fan" || bad "fan -> $(target fan)"
[ "$(target gpu)" = class/devfreq/5900000.gpu ] && ok "gpu devfreq" || bad "gpu -> $(target gpu)"
[ "$(target cpu)" = devices/system/cpu ] && ok "cpu" || bad "cpu -> $(target cpu)"
[ ! -e "$T/run/hw/leds/power" ] && ok "no power-led, no default LED group" || bad "leds/power exists"
grep -q '^QFORGE_HW_BATTERY=battery$' "$T/run/hw/hw.env" && ok "hw.env records the battery" || bad "hw.env: $(grep BATTERY "$T/run/hw/hw.env")"
( set -e; . "$T/run/hw/hw.env"; [ "$QFORGE_HW_CHARGER" = bq256xx-charger ] ) && ok "hw.env is sourceable" || bad "hw.env does not source"

# =================================================================================================
CASE="profile pins"
run env QFORGE_HW_THERMAL_CPU=cpu67-thermal QFORGE_HW_LED_GROUPS="ring-left=rgb:l* ring-right=rgb:r*" QFORGE_HW_CHARGER=tcpm-source && ok "runs" || bad "exit $?"
[ "$(target thermal/cpu)" = class/thermal/thermal_zone11 ] && ok "QFORGE_HW_THERMAL_CPU picks the zone by type name" || bad "thermal/cpu -> $(target thermal/cpu)"
[ "$(target charger)" = class/power_supply/tcpm-source ] && ok "QFORGE_HW_CHARGER pins the charger" || bad "charger -> $(target charger)"
[ "$(ls "$T/run/hw/leds/ring-left" | tr '\n' ' ')" = "01 02 03 04 " ] && ok "a glob group numbers its LEDs 01.." || bad "ring-left: $(ls "$T/run/hw/leds/ring-left" | tr '\n' ' ')"
[ "$(target leds/ring-left/03)" = class/leds/rgb:l3 ] && [ "$(target leds/ring-left/04)" = class/leds/rgb:l10 ] && ok "natural order: l3 before l10" || bad "03 -> $(target leds/ring-left/03), 04 -> $(target leds/ring-left/04)"
[ "$(ls "$T/run/hw/leds/ring-right" | wc -l | tr -d ' ')" = 2 ] && ok "second group" || bad "ring-right: $(ls "$T/run/hw/leds/ring-right")"
grep -q '^QFORGE_HW_LED_GROUPS=ring-left=4\\ ring-right=2$' "$T/run/hw/hw.env" && ok "hw.env summarises the groups" || bad "hw.env: $(grep LED "$T/run/hw/hw.env")"

# =================================================================================================
CASE="rebuild"
mkdir -p "$S/class/leds/power-led"
run env && [ "$(target leds/power/01)" = class/leds/power-led ] && ok "a later run replaces the tree (power-led now the default group)" || bad "leds/power/01 -> $(target leds/power/01)"
[ ! -e "$T/run/hw/leds/ring-left" ] && ok "stale links from the previous tree are gone" || bad "ring-left survived"
[ -z "$(ls -d "$T"/run/hw.tmp.* "$T"/run/hw.old.* 2>/dev/null)" ] && ok "no temporary trees left behind" || bad "leftovers: $(ls -d "$T"/run/hw.* )"

# =================================================================================================
CASE="bare board"
rm -rf "$S"; mkdir -p "$S/class"
run env && ok "runs with nothing to map" || bad "exit $?"
[ -z "$(find "$T/run/hw" -type l)" ] && ok "no links" || bad "links: $(find "$T/run/hw" -type l)"
grep -q '^QFORGE_HW_BATTERY=.*$' "$T/run/hw/hw.env" && ok "hw.env still written" || bad "no hw.env"

# =================================================================================================
CASE="pwm fan without a tachometer"
rm -rf "$S"; mkdir -p "$S/class"
mk class/hwmon/hwmon3/name cpu_thermal
mk class/hwmon/hwmon9/name pwmfan
mk class/hwmon/hwmon9/pwm1 0
run env && [ "$(target fan)" = class/hwmon/hwmon9 ] && ok "a hwmon with only pwm1 is the fan (Air X/Y pwm-fan)" || bad "fan -> $(target fan)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

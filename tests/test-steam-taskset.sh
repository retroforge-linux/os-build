#!/usr/bin/env bash
# Offline check for the Steam UI's CPU pick (rootfs/overlay/usr/lib/retroforge/steam-bin/taskset).
#
#   tests/test-steam-taskset.sh
#
# WHY THIS EXISTS. Valve's steamwebhelper.sh runs `taskset 0x7c steamwebhelper`, the Steam Frame's
# middle cores, and this taskset replaces that mask with the same choice made from the device's
# cpu_capacity. A wrong pick still starts the UI, only on the wrong cores, so nothing would show it.
# This runs the REAL script against fabricated sysfs trees (each SoC RetroForge supports, plus the
# edge cases), with stubs for the real taskset and for the web helper that record how they ran.
#
# Runs on the host with no root and no device.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/rootfs/overlay/usr/lib/retroforge/steam-bin/taskset"
[[ -x $SCRIPT ]] || { echo "script missing or not executable: $SCRIPT" >&2; exit 1; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()    { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad()   { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }
check() { [[ $2 == "$3" ]] && ok "$1" || bad "$1 (want '$3', got '$2')"; }

cat >"$TMP/taskset" <<'EOF'
#!/bin/sh
echo "taskset $*" >"$CALLS"
EOF
mkdir -p "$TMP/rt"
cat >"$TMP/rt/steamwebhelper" <<'EOF'
#!/bin/sh
echo "helper $*" >"$CALLS"
EOF
chmod +x "$TMP/taskset" "$TMP/rt/steamwebhelper"

# topo <name> <online> <cpu:cap>...  -> fabricated /sys/devices/system/cpu (cap "-": no cpu_capacity)
topo() {
  local name=$1 online=$2 pair; shift 2
  mkdir -p "$TMP/$name"
  echo "$online" >"$TMP/$name/online"
  for pair in "$@"; do
    mkdir -p "$TMP/$name/cpu${pair%%:*}"
    [ "${pair#*:}" = - ] || echo "${pair#*:}" >"$TMP/$name/cpu${pair%%:*}/cpu_capacity"
  done
}
# ran <name> <args...>: what the shim ran
ran() {
  local name=$1; shift
  rm -f "$TMP/calls"
  CALLS="$TMP/calls" RETROFORGE_SYS_CPU="$TMP/$name" RETROFORGE_TASKSET="$TMP/taskset" "$SCRIPT" "$@"
  cat "$TMP/calls" 2>/dev/null
}
ui() { ran "$1" 0x7c "$TMP/rt/steamwebhelper" -nocrashdialog; }
H="$TMP/rt/steamwebhelper -nocrashdialog"

# Capacities as the kernels report them (tests/test-cpu-affinity.sh; SM6115 read on the MANGMI Air X,
# SM8750 from its DT's capacity-dmips-mhz and clocks).
topo sm8250 0-7 0:250 1:250 2:250 3:250 4:782 5:782 6:782 7:1024
topo sm8550 0-7 0:283 1:283 2:283 3:700 4:700 5:690 6:690 7:1024
topo sm8650 0-7 0:286 1:286 2:839 3:839 4:839 5:870 6:870 7:1024
topo sm8750 0-7 0:792 1:792 2:792 3:792 4:792 5:792 6:1024 7:1024
topo sm6115 0-7 0:611 1:611 2:611 3:611 4:1024 5:1024 6:1024 7:1024
topo sm4450 0-7 0:505 1:505 2:505 3:505 4:505 5:505 6:1024 7:1024
check "SM8650: Valve's own mask, the five A720s"         "$(ui sm8650)" "taskset -c 2-6 $H"
check "SM8250: the three A77s below the prime one"       "$(ui sm8250)" "taskset -c 4-6 $H"
check "SM8550: both middle levels, not the A510s or X3"  "$(ui sm8550)" "taskset -c 3-6 $H"
check "SM8750: the six Oryon cores, not the two primes"  "$(ui sm8750)" "taskset -c 0-5 $H"
check "SM6115: the four A73s, not the A53s"              "$(ui sm6115)" "taskset -c 4-7 $H"
check "SM4450: the two A78s, not the A55s"               "$(ui sm4450)" "taskset -c 6-7 $H"

topo uniform 0-3 0:1024 1:1024 2:1024 3:1024
check "one level: not pinned"                            "$(ui uniform)" "helper -nocrashdialog"
topo nocap 0-3 0:- 1:- 2:- 3:-
check "no cpu_capacity: not pinned"                      "$(ui nocap)" "helper -nocrashdialog"
topo partial 0-3 0:300 1:300 2:1024 3:-
check "a CPU without cpu_capacity: not pinned"           "$(ui partial)" "helper -nocrashdialog"
topo slider 0-3 0:611 1:611 2:611 3:611 4:1024 5:1024 6:1024 7:1024
check "its CPUs offline (core-count slider): not pinned" "$(ui slider)" "helper -nocrashdialog"
topo halfon 0-5 0:611 1:611 2:611 3:611 4:1024 5:1024 6:1024 7:1024
check "some offline: all of them kept, for when they are back" "$(ui halfon)" "taskset -c 4-7 $H"

check "another call goes to taskset unchanged"           "$(ran sm6115 -pc 4-7 123)" "taskset -pc 4-7 123"
check "a mask for another program too"                   "$(ran sm6115 0x7c /bin/true)" "taskset 0x7c /bin/true"
check "an option before the mask is not Valve's call"    "$(ran sm6115 -a 0x7c "$TMP/rt/steamwebhelper")" "taskset -a 0x7c $TMP/rt/steamwebhelper"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

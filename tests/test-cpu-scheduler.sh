#!/usr/bin/env bash
# Offline check for powerd's CPU-scheduler decision logic (rootfs/overlay/usr/bin/qforge-powerd).
#
#   tests/test-cpu-scheduler.sh
#
# WHY THIS EXISTS. Both paths covered here failed SILENTLY in the field on 2026-08-27, and
# neither failure produced a log line or a nonzero exit anywhere:
#
#   1. scheduler_live is powerd's BELIEF about what is loaded, and nothing re-derived it. When
#      sched_ext ejected scx_lavd on its own (`disabled (runtime error)`), powerd kept reporting
#      ActiveCpuScheduler=lavd for a system that was back on stock EEVDF, and apply_scheduler()'s
#      "already there" guard compared against that stale belief and did nothing.
#
#   2. The per-game `scheduler` tweak is re-read from a fresh /proc walk every 3s, and that walk
#      answers "no game" for any tick where the tagged set comes back empty. Absent means "no
#      opinion", which falls back to the persisted choice — so with the documented setup of
#      persisted "none" + a per-game "lavd" tweak, ONE missed tick stops scx.service and the next
#      one starts it again, cycling the system CPU scheduler under a running game. Nothing
#      upstream damps that: apply_scheduler() clears the unit's rate limit on every start.
#
# Both are decision logic over in-memory state, so they test cleanly with the unit calls stubbed.
#
# NOT covered here: whether scx_lavd actually attaches, and the D-Bus surface itself — those need
# a device and a bus. The property handler is a thin read of scheduler_live, which IS checked here.
#
# Runs on the host with no root and no device.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
POWERD="$ROOT/rootfs/overlay/usr/bin/qforge-powerd"

[[ -f $POWERD ]] || { echo "qforge-powerd missing: $POWERD" >&2; exit 1; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# Loading qforge-powerd as a module writes a __pycache__ into rootfs/overlay/usr/bin, which the
# assembler copies into the rootfs verbatim. Keep the bytecode in the sandbox.
export PYTHONPYCACHEPREFIX="$TMP/pycache"

python3 - "$POWERD" "$ROOT" <<'PYEOF'
import importlib.machinery
import importlib.util
import os
import sys

powerd_path, root = sys.argv[1], sys.argv[2]

spec = importlib.util.spec_from_loader(
    "powerd", importlib.machinery.SourceFileLoader("powerd", powerd_path))
pd = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pd)

results = []
def check(name, got, want):
    results.append(("PASS" if got == want else f"FAIL (got {got!r}, want {want!r})", name))


class FakeProc:
    returncode = 0
    stdout = ""


# __init__ globs sysfs and writes pwm1, so build the object without it. What stays real is
# exactly what this suite is about: reconcile_scheduler_live and apply_scheduler's guard.
def fresh(unit_active=False, cpu_scheduler="none", scheduler_live="none"):
    obj = pd.QforgePower.__new__(pd.QforgePower)
    obj.cpu_scheduler = cpu_scheduler
    obj.scheduler_live = scheduler_live
    obj.connection = None
    obj.unit_active = unit_active
    obj.calls = []
    obj.available_cpu_schedulers = lambda: ["none", "lavd"]
    obj.scx_unit_active = lambda: obj.unit_active
    obj.reset_scx_failure = lambda: None

    def systemctl(*args, **kwargs):
        obj.calls.append(args[0])
        if args[0] == "start":
            obj.unit_active = True
        elif args[0] == "stop":
            obj.unit_active = False
        return FakeProc()

    obj.systemctl = systemctl
    return obj


# ------------------------------------------------- reconcile_scheduler_live (the stale belief) ---
# The exact field failure: we think lavd is loaded, the kernel ejected it and scx_lavd exited, so
# the unit is gone. ActiveCpuScheduler must stop claiming lavd.
o = fresh(unit_active=False, scheduler_live="lavd")
check("ejected scheduler is noticed", o.reconcile_scheduler_live(), True)
check("  ...and scheduler_live drops to none", o.scheduler_live, "none")

# A live unit must NOT be reconciled away — scx_lavd re-attaches in-process across most
# ejections, so the unit surviving is the normal case and there is nothing to correct.
o = fresh(unit_active=True, scheduler_live="lavd")
check("live unit is left alone", o.reconcile_scheduler_live(), False)
check("  ...and scheduler_live stays lavd", o.scheduler_live, "lavd")

# The other direction: somebody started the unit by hand. Adopt it rather than lying the other way.
o = fresh(unit_active=True, scheduler_live="none")
check("hand-started unit is adopted", o.reconcile_scheduler_live(), True)
check("  ...and scheduler_live becomes lavd", o.scheduler_live, "lavd")

# No scx on the image at all: there is nothing to reconcile against and no second choice to
# report. Must not touch scheduler_live or shell out.
o = fresh(unit_active=False, scheduler_live="none")
o.available_cpu_schedulers = lambda: ["none"]
o.scx_unit_active = lambda: (_ for _ in ()).throw(AssertionError("must not probe the unit"))
check("no scx installed: nothing to reconcile", o.reconcile_scheduler_live(), False)

# ------------------------------------------------------------- apply_scheduler's guard is honest ---
# The guard is the only thing between a caller and a redundant unit cycle, so it has to compare
# against reality. Belief says lavd, the unit is dead: asking for lavd must actually start it.
o = fresh(unit_active=False, scheduler_live="lavd")
o.apply_scheduler("lavd")
check("apply past a stale belief restarts the unit", o.calls, ["start"])
check("  ...and scheduler_live ends up lavd", o.scheduler_live, "lavd")

# Genuinely already there: no unit call at all.
o = fresh(unit_active=True, scheduler_live="lavd")
o.apply_scheduler("lavd")
check("apply when truly live is a no-op", o.calls, [])

# ----------------------------------------------------------------- set_cpu_scheduler ---
# The persisted choice is applied at once: there is no per-game override left to defer to.
o = fresh(unit_active=False, cpu_scheduler="none")
o.set_cpu_scheduler("lavd")
check("choosing lavd starts scx at once", o.calls, ["start"])
check("  ...and records the choice", o.cpu_scheduler, "lavd")
o.set_cpu_scheduler("lavd")
check("re-choosing the same scheduler is a no-op", o.calls, ["start"])

# ----------------------------------------------------------------------------------- report ---
# ---------------------------------------------------------- board allow-list (device-env) ---
# The Air X profile narrows the choice to the stock scheduler (QFORGE_CPU_SCHEDULERS=none): scx_lavd
# measured harmful there. The list comes from device-env; lavd must then be neither offered nor
# settable, and a persisted lavd must not be restored.
import pathlib, tempfile
tmpd = pathlib.Path(tempfile.mkdtemp())
fake_env = tmpd / "device-env"
def board(value):
    fake_env.write_text("#!/bin/sh\necho QFORGE_DEVICE_ID=x\necho QFORGE_CPU_SCHEDULERS=%s\n" % value)
    fake_env.chmod(0o755)
    pd.DEVICE_ENV = fake_env
    return pd.board_cpu_schedulers()
check("board list: 'none' parses to {none}", board("none"), {"none"})
check("board list: empty means every scheduler", board("''"), None)
check("board list: unreadable device-env means every scheduler",
      (setattr(pd, "DEVICE_ENV", tmpd / "missing") or pd.board_cpu_schedulers()), None)
real_sysfs, real_bin = pd.SCX_SYSFS, pd.SCX_BINARY
pd.SCX_SYSFS, pd.SCX_BINARY = tmpd, fake_env      # both exist: sched_ext "available"
narrow = pd.QforgePower.__new__(pd.QforgePower)
narrow.board_schedulers = {"none"}
check("a board allowing only none offers only none", narrow.available_cpu_schedulers(), ["none"])
wide = pd.QforgePower.__new__(pd.QforgePower)
wide.board_schedulers = None
check("a board with no list offers both", wide.available_cpu_schedulers(), ["none", "lavd"])
narrow.cpu_scheduler, narrow.scheduler_live = "none", "none"
try:
    narrow.set_cpu_scheduler("lavd"); got = "accepted"
except ValueError:
    got = "refused"
check("lavd is refused where the board does not allow it", got, "refused")
narrow.cpu_scheduler = "lavd"            # persisted from an older image
narrow.restore_cpu_scheduler()
check("a persisted lavd is not restored on such a board", (narrow.cpu_scheduler, narrow.scheduler_live), ("none", "none"))
pd.SCX_SYSFS, pd.SCX_BINARY = real_sysfs, real_bin

# --------------------------------------------------------------- EAS follows the governor ---
# schedutil+EAS packed game threads onto the A53s (95% missed frames on the Air X), so powerd
# writes sched_energy_aware=0 after every governor change unless [cpu] energy_aware=on.
eas = tmpd / "sched_energy_aware"
pd.EAS_SYSCTL = eas
gov = pd.QforgePower.__new__(pd.QforgePower)
gov.cpu_policies, gov.cpu_governor = [], "schedutil"
eas.write_text("1\n"); gov.cpu_energy_aware = False; gov.apply_cpu_governor()
check("EAS is switched off after a governor change by default", eas.read_text().strip(), "0")
eas.write_text("0\n"); gov.cpu_energy_aware = True; gov.apply_cpu_governor()
check("[cpu] energy_aware=on leaves EAS on", eas.read_text().strip(), "1")
eas.unlink(); gov.cpu_energy_aware = False; gov.apply_cpu_governor()
check("a kernel without the EAS sysctl is left alone", eas.exists(), False)

failed = [n for s, n in results if s != "PASS"]
for status, name in results:
    print(f"{status} {name}")
print(f"\ntest-cpu-scheduler: {len(results) - len(failed)} passed, {len(failed)} failed")
sys.exit(1 if failed else 0)
PYEOF

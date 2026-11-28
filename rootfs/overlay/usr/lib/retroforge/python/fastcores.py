# fastcores — "Run on fast cores", for retroforge-launch (emulators and ROM games), retroforge-steam-direct
# (Steam games, also those the kept client starts, through /usr/bin/steam) and the store tool (GOG, Epic).
#
# WHETHER is the player's choice for each game (and each emulator, for its ROM games): nothing ships on.
# HOW is one switch, Settings > General > "Fast cores only" (FAST_CORES=pin in
# ~/.config/retroforge/fast-cores.conf; anything else is prefer):
#
#   prefer (the default): every thread of the game gets a minimum utilisation clamp (uclamp.min) just
#     above the slowest cores' capacity, so it fits no slow core. The scheduler wakes a task on a core it
#     fits while one is free, so the game's threads run on the fast cores and spill onto the slow ones
#     only when every fast core is busy; nothing else is moved. Particula (Unity 4, x87 code under FEX,
#     CPU-bound): 12.4-12.5 fps, as pinned, against 10.5-11.2 without (MANGMI Air X, 2026-11-27). Under
#     schedutil the clamp also keeps a fast core's clock up while one of the game's threads runs on it
#     (~75% of its top at the Air X's 612 of 1024).
#   pin: taskset to the fast cores, as emulators were always run: the game never runs on a slow core,
#     not even when the fast ones are all busy, and background work (audio, input, Wi-Fi) keeps them.
#
# A sched_ext scheduler (lavd, Quick Settings) places tasks itself and reads no uclamp, so with one
# running, prefer pins (and says so). "Fast" is every ONLINE CPU above the smallest online capacity
# (cpu_capacity): never CPU numbers (Qualcomm numbers slowest-first, other SoCs do not), never only the
# top tier (one prime core is no home for a game). With none of them online (PowerStation's core count
# takes the fast cores first) or one core type, nothing is done.
#
# Both settings are inherited: a process the game starts later gets them, so a launch applies them to
# what it starts (prefix) and the kept Steam client's game gets them on its processes once they run
# (apply). An unprivileged process may raise its own uclamp.min (util-linux uclampset, no capability).

import os
import subprocess

CPU_ROOT = os.environ.get("RETROFORGE_CPU_ROOT", "/sys/devices/system/cpu")
SCX_STATE = os.environ.get("RETROFORGE_SCX_STATE", "/sys/kernel/sched_ext/state")
PROC = os.environ.get("RETROFORGE_PROC", "/proc")
CONF = os.path.join(os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config"),
                    "retroforge", "fast-cores.conf")
MODES = ("prefer", "pin")


def _read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read().strip()
    except OSError:
        return ""


def capacities():
    """{cpu: cpu_capacity} of every online CPU that reports one."""
    caps = {}
    for part in _read(os.path.join(CPU_ROOT, "online")).split(","):
        lo, _, hi = part.partition("-")
        if not (lo.isdigit() and (hi == "" or hi.isdigit())):
            continue
        for c in range(int(lo), int(hi or lo) + 1):
            cap = _read(os.path.join(CPU_ROOT, f"cpu{c}", "cpu_capacity"))
            if cap.isdigit():
                caps[c] = int(cap)
    return caps


def fast_cpus(caps=None):
    """Online CPUs above the smallest online capacity, as a taskset list; "" when there are none."""
    caps = capacities() if caps is None else caps
    if not caps:
        return ""
    low = min(caps.values())
    return ",".join(str(c) for c in sorted(caps) if caps[c] > low)


def mode():
    """The player's switch: "pin" or "prefer" (the default, also for a missing or unreadable conf)."""
    value = "prefer"
    for line in _read(CONF).splitlines():
        key, sep, val = line.partition("=")
        if sep and key.strip() == "FAST_CORES":
            value = val.strip()
    return value if value in MODES else "prefer"


def sched_ext_running():
    return _read(SCX_STATE) == "enabled"


def plan(log, what):
    """("prefer", clamp) or ("pin", cpu list) for this run, or None (said why) when nothing applies."""
    caps = capacities()
    fast = fast_cpus(caps)
    if not fast:
        log(f"{what}: no fast core online (core-count limit, or one core type): left on every core")
        return None
    how = mode()
    if how == "prefer" and sched_ext_running():
        log(f"{what}: a sched_ext scheduler places tasks itself and reads no uclamp: pinning instead")
        how = "pin"
    if how == "pin":
        log(f"{what}: pinned to fast cores {fast}")
        return ("pin", fast)
    clamp = min(caps.values()) + 1
    log(f"{what}: prefers fast cores {fast} (uclamp.min {clamp})")
    return ("prefer", clamp)


def prefix(log, what):
    """The command words that start a program on the fast cores (both settings are inherited), or []."""
    p = plan(log, what)
    if p is None:
        return []
    return ["uclampset", "-m", str(p[1])] if p[0] == "prefer" else ["taskset", "-c", p[1]]


def descendants(pids):
    """pids and every process below them (from /proc's parent links), in no particular order."""
    children = {}
    try:
        names = os.listdir(PROC)
    except OSError:
        names = []
    for name in names:
        if not name.isdigit():
            continue
        stat = _read(os.path.join(PROC, name, "stat"))
        # ppid is the 2nd field after the comm's closing parenthesis (a comm may hold spaces and ')')
        rest = stat.rpartition(")")[2].split()
        if len(rest) >= 2 and rest[1].isdigit():
            children.setdefault(int(rest[1]), []).append(int(name))
    seen, todo = set(), [int(p) for p in pids]
    while todo:
        p = todo.pop()
        if p in seen:
            continue
        seen.add(p)
        todo.extend(children.get(p, []))
    return sorted(seen)


def apply(pids, log, what):
    """Every thread of pids and of the processes below them on the fast cores; the number of processes."""
    p = plan(log, what)
    if p is None:
        return 0
    done = 0
    for pid in descendants(pids):
        cmd = ["uclampset", "-m", str(p[1]), "-a", "-p", str(pid)] if p[0] == "prefer" \
            else ["taskset", "-a", "-c", "-p", p[1], str(pid)]
        # A process that has exited since, or one of another user's: skipped.
        if subprocess.run(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL).returncode == 0:
            done += 1
    return done

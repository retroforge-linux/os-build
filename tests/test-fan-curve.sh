#!/usr/bin/env bash
# Offline check for the editable fan curve (rootfs/overlay/usr/bin/qforge-powerd).
#
#   tests/test-fan-curve.sh
#
# WHY THIS EXISTS. The curve is a three-layer config (/usr factory -> the operator's /etc
# file -> our own drop-in) whose failure modes are all SILENT. A drop-in that stops
# overriding, a resample that disagrees with what the fan tick actually runs, a reset that
# leaves the file in place, a quarantine path that drops the wrong layer -- every one of
# those exits 0 and simply blows the wrong amount of air. There is no error anyone sees.
#
# So this drives the REAL parse, resample, write and reset paths against fabricated config
# trees and asserts on the answers.
#
# It also covers the boot CPU governor and the persisted state, the other two things powerd still
# owns besides the fan (power profiles were dropped on 2026-10-03; PowerStation owns the limits).
#
# NOT covered here: pwm1 writes and the D-Bus surface itself -- those need gi, a bus and a
# device. The property handlers are thin wrappers over the functions checked here.
#
# Runs on the host with no root and no device.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
POWERD="$ROOT/rootfs/overlay/usr/bin/qforge-powerd"
FACTORY="$ROOT/rootfs/overlay/usr/share/qforge/power.conf"

[[ -f $POWERD ]]  || { echo "qforge-powerd missing: $POWERD" >&2; exit 1; }
[[ -f $FACTORY ]] || { echo "power.conf missing: $FACTORY" >&2; exit 1; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# Loading qforge-powerd as a module writes a __pycache__ into rootfs/overlay/usr/bin, which the
# assembler copies into the rootfs verbatim. Keep the bytecode in the sandbox.
export PYTHONPYCACHEPREFIX="$TMP/pycache"

QFORGE_POWERD_FACTORY="$FACTORY" QFORGE_POWERD_ETC="$TMP/etc" \
python3 - "$POWERD" "$ROOT" "$TMP" <<'PYEOF'
import configparser
import importlib.machinery
import importlib.util
import os
import pathlib
import sys

powerd_path, root, tmp = sys.argv[1], sys.argv[2], pathlib.Path(sys.argv[3])

spec = importlib.util.spec_from_loader(
    "powerd", importlib.machinery.SourceFileLoader("powerd", powerd_path))
pd = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pd)

results = []
def check(name, got, want):
    results.append(("PASS" if got == want else f"FAIL (got {got!r}, want {want!r})", name))

def raises(name, fn):
    try:
        fn()
    except Exception:
        results.append(("PASS", name))
        return
    results.append(("FAIL (no exception)", name))

etc = pathlib.Path(os.environ["QFORGE_POWERD_ETC"])
etc.mkdir(parents=True, exist_ok=True)

# __init__ globs sysfs and writes pwm1, so build the object without it and stub the
# device-touching half of the reload path. What stays real is everything this suite is
# about: the config layering, the curve maths, and the drop-in read/write.
def fresh():
    obj = pd.QforgePower.__new__(pd.QforgePower)
    obj.cpu_scheduler = pd.DEFAULT_CPU_SCHEDULER
    obj.discover = lambda: None
    obj.apply_cpu_governor = lambda: None
    obj.load_config()
    return obj

# ------------------------------------------------------------------ pure curve maths ---
# The factory "moderate" curve, as shipped.
moderate = pd.parse_fan_curve("96:255,90:204,84:153,78:102,72:77,0:51")
check("parse keeps every point", len(moderate), 6)
check("curve_pwm clamps below the floor", pd.curve_pwm(moderate, -5), 51)
check("curve_pwm clamps above the top", pd.curve_pwm(moderate, 130), 255)
check("curve_pwm hits a point exactly", pd.curve_pwm(moderate, 84), 153)
# 81 is the midpoint of 78:102 -> 84:153, so the interpolation must land on 127.5 -> 128.
check("curve_pwm interpolates", pd.curve_pwm(moderate, 81), 128)
check("curve_pwm on an empty curve", pd.curve_pwm([], 80), 0)

check("stops parse", pd.parse_curve_stops("60,70,80,90,100"), [60, 70, 80, 90, 100])
raises("stops must rise", lambda: pd.parse_curve_stops("60,80,70"))
raises("stops reject duplicates", lambda: pd.parse_curve_stops("60,60"))
raises("stops reject one point", lambda: pd.parse_curve_stops("60"))
raises("stops reject junk", lambda: pd.parse_curve_stops("60,abc"))
raises("stops reject out of range", lambda: pd.parse_curve_stops("60,130"))

# Resampling must be LOSSLESS at the stops: this is the promise the UI makes when it shows
# a factory curve on the sliders and claims that is what the fan is doing.
stops = [60, 70, 80, 90, 100]
sampled = pd.resample_curve(moderate, stops)
for stop, pwm in zip(stops, sampled):
    check(f"resample matches the curve at {stop}C", pwm, pd.curve_pwm(moderate, stop))
check("resample keeps one value per stop", len(sampled), len(stops))
check("resample of a round trip is stable",
      pd.resample_curve(list(zip(stops, sampled)), stops), sampled)

check("pwms clamp into range", pd.clean_curve_pwms([0, 0, 0, 0, 300], stops, 51, 255),
      [51, 51, 51, 51, 255])
check("pwms are forced to not fall", pd.clean_curve_pwms([200, 100, 150, 90, 255], stops, 51, 255),
      [200, 200, 200, 200, 255])
raises("pwms must match the stop count",
       lambda: pd.clean_curve_pwms([51, 77], stops, 51, 255))

# ------------------------------------------------------------------ layering ---
power = fresh()
check("factory stops are read from the config", power.fan_config["curve_stops"], stops)
check("factory starts on the moderate curve", power.fan_curve_name, "moderate")
check("FanCurveIsCustom is false on factory", power.fan_curve_name == pd.CUSTOM_CURVE, False)
check("factory curve resamples to the shipped moderate curve",
      power.fan_curve_pwms(), pd.resample_curve(moderate, stops))
check("factory governor is ondemand", power.cpu_governor, "ondemand")

# An operator's own /etc file must still win over factory and survive everything below.
(etc / "power.conf").write_text(
    "# operator notes that must never be eaten\n"
    "[fan_curve.operator]\n"
    "curve=95:255,60:51\n"
    "[fan]\n"
    "curve=operator\n"
)
power = fresh()
check("operator /etc file overrides factory", power.fan_curve_name, "operator")
check("operator curve is what resamples", power.fan_curve_pwms(),
      pd.resample_curve(pd.parse_fan_curve("95:255,60:51"), stops))
check("an operator [fan] override inherits the rest of [fan]", power.fan_config["min_pwm"], 51)

# ------------------------------------------------------------------ write + reset ---
power.set_fan_curve([60, 90, 120, 180, 240])
check("write lands in the drop-in dir", pd.FAN_CURVE_DROPIN.exists(), True)
check("the drop-in outranks the operator file", power.fan_curve_name, pd.CUSTOM_CURVE)
check("FanCurveIsCustom is true after a write", power.fan_curve_name == pd.CUSTOM_CURVE, True)
check("what was written is what reads back", power.fan_curve_pwms(), [60, 90, 120, 180, 240])
check("and it is what the fan tick would run at a stop",
      pd.curve_pwm(power.fan_curve_points, 80), 120)
check("the operator's comments survived",
      "operator notes that must never be eaten" in (etc / "power.conf").read_text(), True)

# A second write replaces the first rather than adding to it.
power.set_fan_curve([100, 130, 160, 200, 255])
check("a second write replaces the curve", power.fan_curve_pwms(), [100, 130, 160, 200, 255])

# Only the shipped `temp:pwm` grammar goes to disk -- no new format to keep in step.
saved = configparser.ConfigParser()
saved.read(pd.FAN_CURVE_DROPIN)
check("drop-in uses the shipped curve grammar",
      saved.get(f"fan_curve.{pd.CUSTOM_CURVE}", "curve"), "100:255,90:200,80:160,70:130,60:100")
check("drop-in selects its own curve", saved.get("fan", "curve"), pd.CUSTOM_CURVE)

power.reset_fan_curve()
check("reset removes the file", pd.FAN_CURVE_DROPIN.exists(), False)
check("reset falls back to the operator curve, not factory", power.fan_curve_name, "operator")
(etc / "power.conf").unlink()

# Inline points in [fan] curve= are a curve too, with no name to call it by.
(etc / "power.conf").write_text("[fan]\ncurve=90:255,0:51\n")
power = fresh()
check("an inline [fan] curve is used", power.fan_curve_points, pd.parse_fan_curve("90:255,0:51"))
check("and is not reported as custom", power.fan_curve_name == pd.CUSTOM_CURVE, False)
(etc / "power.conf").unlink()

# A [fan] curve= naming nothing is a broken config, not a silent fallback to some curve.
(etc / "power.conf").write_text("[fan]\ncurve=nonesuch\n")
power = fresh()
check("an unknown curve name is quarantined", (etc / "power.conf").exists(), False)
check("and the daemon comes up on the factory curve", power.fan_curve_name, "moderate")
for leftover in etc.glob("power.conf.invalid-*"):
    leftover.unlink()

# ------------------------------------------------------------------ persisted state ---
# A state file from an image that still had power profiles must load, keep the scheduler and
# shed the rest on the next save.
pd.STATE_FILE = tmp / "powerd.state"
pd.STATE_FILE.write_text("profile=performance\ngpu_level=manual\nmanual_gpu_clock=500\n"
                         "cpu_scheduler=lavd\n")
power = fresh()
power.load_state()
check("a legacy state file keeps the scheduler choice", power.cpu_scheduler, "lavd")
power.save_state()
check("and is rewritten with only the scheduler", pd.STATE_FILE.read_text(), "cpu_scheduler=lavd\n")

# ------------------------------------------------------------------ quarantine ---
# A bad DROP-IN must be quarantined too. Dropping only the /etc file would leave the real
# culprit in place and re-break on the next boot, forever, with no visible error.
pd.CONFIG_DROPIN_DIR.mkdir(parents=True, exist_ok=True)
pd.FAN_CURVE_DROPIN.write_text("[fan]\nmin_pwm=not-a-number\n")
power = fresh()
check("a bad drop-in is quarantined", pd.FAN_CURVE_DROPIN.exists(), False)
check("quarantine renames out of the glob's reach",
      any(p.name.startswith("50-fan-curves.conf.invalid-")
          for p in pd.CONFIG_DROPIN_DIR.iterdir()), True)
check("and the daemon comes up on factory", power.fan_config["min_pwm"], 51)
check("quarantine took the /etc layer with it",
      (etc / "power.conf").exists(), False)

# ------------------------------------------------------------------- cpu governor ---
# write_governor's fallback is the quietest failure in this daemon: it once left two power
# profiles on the SAME governor for a whole release, because the preferred one was missing
# from scaling_available_governors and nothing said so. The rule under test is that the
# preferred name is tried by WRITING it -- a governor built as a module is absent from that
# list until the write itself autoloads it, so a list check would make it unreachable.

def fake_policy(name, accepts, listed):
    """A cpufreq policy dir whose scaling_governor only takes `accepts`, like the kernel's."""
    policy = tmp / "cpufreq" / name
    policy.mkdir(parents=True, exist_ok=True)
    (policy / "scaling_governor").write_text("performance\n")
    (policy / "scaling_available_governors").write_text(" ".join(listed) + "\n")
    return policy

real_try_write = pd.try_write
def kernel_like(accepts):
    def probe(path, value):
        if value not in accepts:
            return False           # EINVAL: the kernel has no such governor
        return real_try_write(path, value)
    return probe

power_gov = fresh()

# The shipping case: every governor the config might name is present.
pd.try_write = kernel_like({"schedutil", "ondemand", "conservative", "performance"})
policy = fake_policy("policy0", None, ["schedutil", "ondemand", "conservative", "performance"])
check("preferred governor is written", power_gov.write_governor(policy, "conservative"),
      "conservative")
check("and it actually landed in sysfs", pd.read_text(policy / "scaling_governor"),
      "conservative")

# The trap: conservative is built =m, so it is NOT in scaling_available_governors -- but the
# write still succeeds, because that write is what loads it. A list check fails this.
pd.try_write = kernel_like({"schedutil", "ondemand", "conservative"})
policy = fake_policy("policy1", None, ["schedutil", "ondemand"])
check("an unlisted-but-loadable governor is still reached",
      power_gov.write_governor(policy, "conservative"), "conservative")

# Genuinely absent: fall back, and the fallback must be the documented order.
pd.try_write = kernel_like({"ondemand", "performance"})
policy = fake_policy("policy2", None, ["ondemand", "performance"])
check("absent governor falls back past schedutil to ondemand",
      power_gov.write_governor(policy, "conservative"), "ondemand")

pd.try_write = kernel_like({"schedutil", "ondemand"})
policy = fake_policy("policy3", None, ["schedutil", "ondemand"])
check("schedutil is preferred over ondemand when falling back",
      power_gov.write_governor(policy, "conservative"), "schedutil")

# Nothing is settable: say so and leave the governor alone rather than reporting success.
pd.try_write = kernel_like(set())
policy = fake_policy("policy4", None, ["performance"])
check("an unsettable governor reports failure", power_gov.write_governor(policy, "schedutil"),
      None)
check("and does not clobber what was there",
      pd.read_text(policy / "scaling_governor"), "performance")

# A preferred that IS the first fallback must not be retried as one.
pd.try_write = kernel_like({"schedutil"})
policy = fake_policy("policy5", None, ["schedutil"])
check("preferred==schedutil is not reported as a fallback",
      power_gov.write_governor(policy, "schedutil"), "schedutil")

pd.try_write = real_try_write


# apply_cpu_governor puts the configured governor on EVERY policy: the kernel boots on
# `performance`, and a policy left on it runs flat out.
power_gov = fresh()
power_gov.cpu_governor = "ondemand"
power_gov.cpu_policies = [fake_policy(f"apply{i}", None, ["ondemand", "performance"])
                          for i in range(3)]
pd.QforgePower.apply_cpu_governor(power_gov)
check("the governor lands on every policy",
      [pd.read_text(p / "scaling_governor") for p in power_gov.cpu_policies],
      ["ondemand"] * 3)

# The boot governor goes in once per boot: a restarted powerd, or a reload, must not undo the
# power profile PowerStation set since.
calls = []
power_boot = fresh()
power_boot.apply_cpu_governor = lambda: calls.append("applied")
pd.BOOT_GOVERNOR_MARKER = pathlib.Path(os.environ["QFORGE_POWERD_ETC"]).parent / "run/boot-governor-applied"
pd.QforgePower.apply_boot_cpu_governor(power_boot)
pd.QforgePower.apply_boot_cpu_governor(power_boot)
check("the boot governor is applied once per boot", calls, ["applied"])
check("the boot marker is left behind", pd.BOOT_GOVERNOR_MARKER.exists(), True)
power_boot.discover = lambda: None
pd.QforgePower.reload_config(power_boot)
check("a reload leaves the governor alone", calls, ["applied"])

# The governor the shipped config names must be one the kernel config builds, or the fallback
# above silently replaces it.
factory = configparser.ConfigParser()
factory.read(os.path.join(root, "rootfs/overlay/usr/share/qforge/power.conf"))
named = factory.get("cpu", "governor")
kconfig = pathlib.Path(root, "kernel/kernel.config").read_text()
check("the shipped governor is built =y",
      f"CONFIG_CPU_FREQ_GOV_{named.upper()}=y" in kconfig
      or f"CONFIG_CPU_FREQ_DEFAULT_GOV_{named.upper()}=y" in kconfig, True)

# PowerStation's "balanced" profile (packages/powerstation patch 0002) is the boot governor by
# another name: OGUI saves the default performance profile from what it reads at startup, so if
# the two drifted, the boot state would match no profile and the first one applied would change it.
import re
patch = next(pathlib.Path(root, "packages/powerstation/patches").glob("0002-*.patch")).read_text()
balanced = re.search(r'name: "balanced",\n\+\s*cpu_governor: "([a-z_]+)"', patch)
check("the boot governor is PowerStation's balanced profile",
      balanced and balanced.group(1), named)

# --- two-speed fans (gpio-fan: off or full; MANGMI Air X / Air Y) --------------------------
moderate = pd.parse_fan_curve("96:255,90:204,84:153,78:102,72:77,0:51")
check("2-speed: off at 60 C", pd.binary_fan_on(moderate, 60, False, 77, 6), False)
check("2-speed: off just below the knee", pd.binary_fan_on(moderate, 71, False, 77, 6), False)
check("2-speed: on at the knee (72 C, curve 77)", pd.binary_fan_on(moderate, 72, False, 77, 6), True)
check("2-speed: stays on inside the hysteresis", pd.binary_fan_on(moderate, 67, True, 77, 6), True)
check("2-speed: off below knee - hysteresis", pd.binary_fan_on(moderate, 65, True, 77, 6), False)
check("2-speed: no curve keeps the state", pd.binary_fan_on([], 90, True, 77, 6), True)

def fake_fan(name, cdev_type, max_state):
    base = tmp / f"sys-{name}-{cdev_type}-{max_state}"
    hw = base / "hwmon" / "hwmon20"; hw.mkdir(parents=True, exist_ok=True)
    (hw / "name").write_text(name + "\n"); (hw / "pwm1").write_text("0\n")
    cd = base / "thermal" / "cooling_device3"; cd.mkdir(parents=True, exist_ok=True)
    (cd / "type").write_text(cdev_type + "\n"); (cd / "max_state").write_text(f"{max_state}\n")
    return hw, base / "thermal"
hw, th = fake_fan("gpio_fan", "gpio-fan", 1)
check("2-speed detect: gpio-fan with max_state 1", pd.is_two_speed_fan(hw, th), True)
hw, th = fake_fan("gpio_fan", "gpio-fan", 3)
check("2-speed detect: gpio-fan with 4 speeds is a PWM fan", pd.is_two_speed_fan(hw, th), False)
hw, th = fake_fan("pwmfan", "pwm-fan", 1)
check("2-speed detect: pwm-fan never", pd.is_two_speed_fan(hw, th), False)
check("2-speed detect: no fan", pd.is_two_speed_fan(None, th), False)

for status, name in results:
    print(f"{status} {name}")
sys.exit(1 if any(s.startswith("FAIL") for s, _ in results) else 0)
PYEOF
py_rc=$?

if [[ $py_rc -eq 0 ]]; then
  echo "test-fan-curve: all checks passed"
else
  echo "test-fan-curve: FAILURES above" >&2
fi
exit "$py_rc"

# launch_common — what retroforge-launch and its modules (launch_def, launch_formats, psn_inbox)
# share: the environment, the paths every part reads, the Exit error, the log line and device-env.
# Every path has an environment knob for the offline tests (tests/test-launch.sh).

import os
import re
import resource
import subprocess
import sys

import crash_dumps

ENV = os.environ
EMU_DATA_DIR = ENV.get("RETROFORGE_EMU_DATA_DIR", "/usr/share/retroforge/emulators")
EMU_DIR = ENV.get("RETROFORGE_EMU_DIR", "/home/player/emulators")
HOME = ENV.get("HOME", "/home/player")
CONFIG_HOME = ENV.get("XDG_CONFIG_HOME") or os.path.join(HOME, ".config")
DEVICE_ENV = ENV.get("RETROFORGE_DEVICE_ENV", "/usr/lib/retroforge/device-env")
# The layer's switches. Never inherited: the shell runs with its own (smaller) report on most boards
# (retroforge-session), and an emulator must not get the shell's.
VRAM_REPORT_LIMIT_VARS = ("ENABLE_MESA_VRAM_REPORT_LIMIT", "VK_VRAM_REPORT_LIMIT_HEAP_SIZE",
                          "VK_VRAM_REPORT_LIMIT_DEVICE_ID")
OOM_SCORE_ADJ = 900  # `steam-launch-wrapper --oom-score-adjust 900`, as Steam starts its games


class Exit(Exception):
    """Stop with this status and message (stderr)."""

    def __init__(self, code, msg):
        super().__init__(msg)
        self.code = code


def log(msg):
    print(f"retroforge-launch: {msg}", file=sys.stderr, flush=True)



def device_field(name):
    """One of device-env's RETROFORGE_* fields, unquoted; "" when unset or device-env cannot run."""
    try:
        out = subprocess.run([DEVICE_ENV], capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.SubprocessError):
        return ""
    m = re.search(rf"^{name}=(.*)$", out, re.M)
    return m.group(1).strip("'\"") if m else ""



def emulator_child(core_dumps=False):
    """The preexec_fn of every emulator process: in the child, before exec, the OOM killer's first
    choice (retroforge-launch's header), and no core file unless core_dumps or Settings > General >
    Game crash dumps (crash_dumps)."""
    core_dumps = core_dumps or crash_dumps.wanted()

    def preexec():
        try:
            with open("/proc/self/oom_score_adj", "w") as f:
                f.write(str(OOM_SCORE_ADJ))
        except OSError:
            pass  # never a reason not to start the game
        if not core_dumps:
            resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    return preexec

# crash_dumps — Settings > General > "Game crash dumps" (crash_dumps_setting.gd), for retroforge-launch
# (emulators), the store tool (GOG, Epic) and, in shell, /usr/bin/steam (Steam games).
#
# Off, the default: games start with RLIMIT_CORE 0, so systemd-coredump logs a crash in the journal (no
# stack) and reads nothing. A core holds the crashed game's memory until it is written: 41-46 s for
# Ghostrunner's (MANGMI Air X, 2026-11-26). On (GAME_CORE_DUMPS=on in
# ~/.config/retroforge/game-core-dumps.conf; the last line wins): games keep the session's limit, and
# coredumpctl has their cores. Read at each launch; a running game keeps how it started.

import os

CONF = os.path.join(os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config"),
                    "retroforge", "game-core-dumps.conf")
KEY = "GAME_CORE_DUMPS"


def wanted(conf=CONF):
    """Whether the conf's last GAME_CORE_DUMPS line says on; anything else, or no file, is off."""
    value = ""
    try:
        with open(conf, encoding="utf-8", errors="replace") as f:
            for line in f:
                key, sep, v = line.partition("=")
                if sep and key.strip() == KEY:
                    value = v.strip()
    except OSError:
        pass
    return value == "on"

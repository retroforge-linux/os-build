#!/usr/bin/env bash
# Offline test for achievements, the module retroforge-launch hands the player's RetroAchievements
# sign-in to the standalone emulators with (.claude/plans/standalone-cheevos.plan.md).
#
#   tests/test-achievements.sh
#
# WHY THIS EXISTS. The sign-in is written into five emulators' own settings at every launch, and each
# keeps it its own way; a mistake is either a leaked token or a player silently signed out:
#
#   - every key, section and boolean word is the emulator's own (DuckStation true/false, PPSSPP and
#     Dolphin True/False, Flycast yes/no): a wrong spelling is a setting the emulator ignores;
#   - Dolphin and PPSSPP default to hardcore ON: hardcore must be written, signed in or not, or
#     Guide+L1 (load state) stops working there;
#   - DuckStation only takes its token encrypted with the machine-id and the user name; ARMSX2 keeps it
#     in secrets.ini (a stale one in PCSX2.ini would be moved over ours); PPSSPP in a file of its own,
#     which must go when the player signs out;
#   - a file holding a token is 0600, and no temporary file is left behind;
#   - a retroarch.cfg edited by hand into something that is not a name and token is never copied
#     into five other files;
#   - one file that cannot be written never stops the game, nor the other files.
#
# The launcher's own run (after the seed, game and --gui) is covered in test-launch.sh.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/rootfs/overlay/usr/lib/retroforge/python"
EMU_DATA_DIR="$ROOT/rootfs/overlay/usr/share/retroforge/emulators"
[ -f "$LIB/achievements.py" ] || { echo "missing input: $LIB/achievements.py" >&2; exit 1; }
command -v openssl >/dev/null || { echo "openssl is required" >&2; exit 1; }

T="$(mktemp -d)" && [ -d "$T" ] || { echo "mktemp -d failed" >&2; exit 1; }
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
printf '0123456789abcdef0123456789abcdef\n' > "$T/machine-id"

# -I: isolated (no user site, no cwd on sys.path); -B: no __pycache__ inside rootfs/overlay.
RETROFORGE_MACHINE_ID="$T/machine-id" RETROFORGE_EMU_DATA_DIR="$EMU_DATA_DIR" HOME="$T/home" \
python3 -I -B - "$LIB" "$T" <<'PY'
import base64, glob, hashlib, os, shutil, stat, subprocess, sys
sys.path.insert(0, sys.argv[1])
import achievements as ach
import emuopts as eo
from launch_common import Exit
from launch_def import load_definition, safe_relative

T = sys.argv[2]
UMASK = os.umask(0)
os.umask(UMASK)
PASS = FAIL = 0
CASE = ""
USER, TOKEN = "Player1", "AbCdEf0123456789"
EMUS = ("duckstation", "armsx2", "ppsspp", "dolphin", "flycast")


def check(what, got, want):
    global PASS, FAIL
    if got == want:
        PASS += 1
        print(f"  ok   {CASE} -- {what}")
    else:
        FAIL += 1
        print(f"  FAIL {CASE} -- {what}\n         got:  {got!r}\n         want: {want!r}")


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


def read(path):
    with open(path) as f:
        return f.read()


def mode(path):
    return stat.S_IMODE(os.stat(path).st_mode)


def fresh_home(name):
    home = os.path.join(T, name)
    shutil.rmtree(home, ignore_errors=True)
    os.makedirs(home)
    return home


def sign_in(home, user=USER, token=TOKEN, hardcore=False):
    write(os.path.join(home, ".config/retroarch/retroarch.cfg"),
          f'cheevos_enable = "true"\ncheevos_username = "{user}"\ncheevos_token = "{token}"\n'
          f'cheevos_hardcore_mode_enable = "{"true" if hardcore else "false"}"\nvideo_driver = "vulkan"\n')


warnings = []
warn = warnings.append


def run(emu, home):
    ach.apply(emu, DEFS[emu]["achievements"], home, warn)


def ini(home, path, section, key):
    try:
        return eo.ini_get(read(os.path.join(home, path)), section, key)
    except FileNotFoundError:
        return "<no file>"


def ds_decrypt(value, user, machine_id_path):
    """DuckStation's DecryptLoginToken, written again from its source (not the module's code)."""
    with open(machine_id_path, "rb") as f:
        k = hashlib.sha256(f.read() + user.encode()).digest()
    for _ in range(100):
        k = hashlib.sha256(k).digest()
    res = subprocess.run(["openssl", "enc", "-d", "-aes-128-cbc", "-nopad", "-K", k[:16].hex(), "-iv", k[16:].hex()],
                         input=base64.b64decode(value), capture_output=True, check=True)
    return res.stdout.split(b"\0", 1)[0].decode()


DS, AX, AXS = ".local/share/duckstation/settings.ini", ".config/ARMSX2/inis/PCSX2.ini", ".config/ARMSX2/inis/secrets.ini"
PP, PPD = ".config/ppsspp/PSP/SYSTEM/ppsspp.ini", ".config/ppsspp/PSP/SYSTEM/ppsspp_retroachievements.dat"
DL, FC = ".config/dolphin-emu/RetroAchievements.ini", ".config/flycast/emu.cfg"
MID = os.path.join(T, "machine-id")

# =================================================================================================
CASE = "definitions"
DEFS = {}
for emu in EMUS:
    try:
        DEFS[emu] = load_definition(emu)
        check(f"{emu}: emulator.json loads with an achievements list", bool(DEFS[emu]["achievements"]), True)
    except Exit as err:
        check(f"{emu}: emulator.json loads", str(err), "")
others = sorted(os.path.basename(os.path.dirname(p)) for p in glob.glob(os.path.join(os.environ["RETROFORGE_EMU_DATA_DIR"], "*/emulator.json")))
for emu in others:
    if emu in EMUS or emu == "retroarch":
        continue
    check(f"{emu}: no achievements (no RetroAchievements support)", load_definition(emu)["achievements"], [])
if len(DEFS) != len(EMUS):
    print(f"\n{PASS} passed, {FAIL + 1} failed")
    sys.exit(1)

# =================================================================================================
CASE = "signed out (never signed in)"
H = fresh_home("out")
for emu in EMUS:
    run(emu, H)
check("DuckStation: off, no name, no token, no hardcore",
      [ini(H, DS, "Cheevos", k) for k in ("Enabled", "ChallengeMode", "Username", "Token")], ["false", "false", "", ""])
check("ARMSX2: off, no name, no hardcore; no token in either file",
      [ini(H, AX, "Achievements", k) for k in ("Enabled", "ChallengeMode", "Username", "Token")]
      + [ini(H, AXS, "Achievements", "Token")], ["false", "false", "", None, ""])
check("PPSSPP: off, hardcore written False (its default is True), no token file",
      [ini(H, PP, "Achievements", k) for k in ("AchievementsEnable", "AchievementsChallengeMode", "AchievementsUserName")]
      + [os.path.exists(os.path.join(H, PPD))], ["False", "False", "", False])
check("Dolphin: off, HardcoreEnabled written False (its default is True)",
      [ini(H, DL, "Achievements", k) for k in ("Enabled", "HardcoreEnabled", "Username", "ApiToken")],
      ["False", "False", "", ""])
check("Flycast: yes/no words", [ini(H, FC, "achievements", k) for k in ("Enabled", "HardcoreMode", "UserName", "Token")],
      ["no", "no", "", ""])
check("no warnings", warnings, [])

# =================================================================================================
CASE = "signed in"
H = fresh_home("in")
sign_in(H, hardcore=True)
seed_text = read(os.path.join(os.environ["RETROFORGE_EMU_DATA_DIR"], "duckstation/settings.ini"))
write(os.path.join(H, DS), seed_text)
os.chmod(os.path.join(H, DS), 0o644)
write(os.path.join(H, AX), "[Achievements]\nEnabled = false\nToken = OldStaleToken99\n[EmuCore]\nX = 1\n")
os.chmod(os.path.join(H, AX), 0o644)
for emu in EMUS:
    run(emu, H)
ds_token = ini(H, DS, "Cheevos", "Token")
check("DuckStation: on, name, hardcore", [ini(H, DS, "Cheevos", k) for k in ("Enabled", "ChallengeMode", "Username")],
      ["true", "true", USER])
check("DuckStation: the token decrypts back with the machine-id and the name (its DecryptLoginToken)",
      ds_decrypt(ds_token, USER, MID), TOKEN)
check("DuckStation: the plain token is nowhere in its settings", TOKEN in read(os.path.join(H, DS)), False)
check("DuckStation: the seed's text is kept, the section added after it", read(os.path.join(H, DS)).startswith(seed_text), True)
check("ARMSX2: Enabled, ChallengeMode, Username in PCSX2.ini; the stale Token there removed",
      [ini(H, AX, "Achievements", k) for k in ("Enabled", "ChallengeMode", "Username", "Token")], ["true", "true", USER, None])
check("ARMSX2: the token in secrets.ini", ini(H, AXS, "Achievements", "Token"), TOKEN)
check("ARMSX2: its other sections kept", ini(H, AX, "EmuCore", "X"), "1")
check("PPSSPP: True words, the name; the token alone in its .dat",
      [ini(H, PP, "Achievements", k) for k in ("AchievementsEnable", "AchievementsChallengeMode", "AchievementsUserName")]
      + [read(os.path.join(H, PPD))], ["True", "True", USER, TOKEN])
check("Dolphin: name and ApiToken", [ini(H, DL, "Achievements", k) for k in ("Enabled", "HardcoreEnabled", "Username", "ApiToken")],
      ["True", "True", USER, TOKEN])
check("Flycast: name and Token", [ini(H, FC, "achievements", k) for k in ("Enabled", "HardcoreMode", "UserName", "Token")],
      ["yes", "yes", USER, TOKEN])
check("every file holding a token is 0600 (an existing 0644 one tightened)",
      {p: mode(os.path.join(H, p)) for p in (DS, AXS, PPD, DL, FC)}, {p: 0o600 for p in (DS, AXS, PPD, DL, FC)})
check("no temporary file left", [p for p in glob.glob(os.path.join(H, "**/*.retroforge-*"), recursive=True)], [])
check("no warnings", warnings, [])
again = {p: read(os.path.join(H, p)) for p in (DS, AX, AXS, PP, PPD, DL, FC)}
for emu in EMUS:
    run(emu, H)
check("a second launch changes nothing", {p: read(os.path.join(H, p)) for p in again}, again)

# =================================================================================================
CASE = "the player changed it in the emulator"
write(os.path.join(H, DL), "[Achievements]\nEnabled = True\nUsername = SomeoneElse\nApiToken = theirtoken123\nHardcoreEnabled = True\nSoundFeedback = False\n")
sign_in(H, hardcore=False)
run("dolphin", H)
check("RetroForge's sign-in and Hardcore win at the next launch, their other settings kept",
      [ini(H, DL, "Achievements", k) for k in ("Username", "ApiToken", "HardcoreEnabled", "SoundFeedback")],
      [USER, TOKEN, "False", "False"])

# =================================================================================================
CASE = "signed out after a sign-in"
write(os.path.join(H, ".config/retroarch/retroarch.cfg"), 'cheevos_username = ""\ncheevos_token = ""\ncheevos_hardcore_mode_enable = "false"\n')
for emu in EMUS:
    run(emu, H)
check("every name and token gone, achievements off",
      [ini(H, DS, "Cheevos", "Token"), ini(H, DS, "Cheevos", "Username"), ini(H, AXS, "Achievements", "Token"),
       ini(H, DL, "Achievements", "ApiToken"), ini(H, FC, "achievements", "Token"), ini(H, PP, "Achievements", "AchievementsEnable")],
      ["", "", "", "", "", "False"])
check("PPSSPP's token file removed", os.path.exists(os.path.join(H, PPD)), False)
check("no warnings", warnings, [])

# =================================================================================================
CASE = "a retroarch.cfg that is not a sign-in"
H = fresh_home("garbage")
sign_in(H, token="has spaces and $(stuff)")
run("dolphin", H)
check("treated as signed out: nothing of it copied", [ini(H, DL, "Achievements", k) for k in ("Username", "ApiToken", "Enabled")],
      ["", "", "False"])
check("...with a warning that names no value", (len(warnings), "$(stuff)" in "".join(warnings), USER in "".join(warnings)), (1, False, False))
warnings.clear()
H = fresh_home("half")
write(os.path.join(H, ".config/retroarch/retroarch.cfg"), 'cheevos_username = "Player1"\ncheevos_token = ""\n')
run("flycast", H)
check("a name without a token is signed out, silently", (ini(H, FC, "achievements", "UserName"), warnings), ("", []))

# =================================================================================================
CASE = "failures are warnings"
H = fresh_home("fail")
sign_in(H)
write(os.path.join(H, ".config/dolphin-emu"), "a file where Dolphin's folder should be\n")
run("dolphin", H)
check("an unwritable file: a warning, no exception", len(warnings), 1)
check("...that names the file, never the token", (DL in warnings[0], TOKEN in warnings[0]), (True, False))
warnings.clear()
write(os.path.join(H, DS), "[Cheevos]\nEnabled = true\nUsername = PreviousPlayer\nToken = cHJldmlvdXM=\n")
ach.OPENSSL = os.path.join(T, "no-openssl")
run("duckstation", H)
check("no openssl: a warning, and DuckStation written signed out (not the previous player's sign-in)",
      (len(warnings), [ini(H, DS, "Cheevos", k) for k in ("Enabled", "Username", "Token")]), (1, ["false", "", ""]))
check("...the warning names no token", TOKEN in warnings[0], False)
ach.OPENSSL = "openssl"
warnings.clear()
ach.MACHINE_ID = os.path.join(T, "no-machine-id")
os.unlink(os.path.join(H, DS))
run("duckstation", H)
check("no machine-id: a warning, signed out, no token in any form",
      (len(warnings), [ini(H, DS, "Cheevos", k) for k in ("Enabled", "Token")], TOKEN in read(os.path.join(H, DS))),
      (1, ["false", ""], False))
ach.MACHINE_ID = MID
warnings.clear()
run("flycast", H)
check("the other emulators are unaffected", ini(H, FC, "achievements", "Token"), TOKEN)
check("the umask is put back", os.umask(UMASK), UMASK)

# =================================================================================================
CASE = "a retroarch.cfg that cannot be read"
H = fresh_home("unreadable")
sign_in(H)
for emu in EMUS:
    run(emu, H)
before = {p: read(os.path.join(H, p)) for p in (DS, AXS, PPD, DL, FC)}
os.chmod(os.path.join(H, ".config/retroarch/retroarch.cfg"), 0)
if os.access(os.path.join(H, ".config/retroarch/retroarch.cfg"), os.R_OK):
    check("(running as root: an unreadable file cannot be made; case skipped)", True, True)
else:
    for emu in EMUS:
        run(emu, H)
    check("nothing written: unknown is not signed out", {p: read(os.path.join(H, p)) for p in before}, before)
    check("one warning per launch", len(warnings), len(EMUS))
os.chmod(os.path.join(H, ".config/retroarch/retroarch.cfg"), 0o600)
warnings.clear()

# =================================================================================================
CASE = "symlinked settings"
H = fresh_home("links")
sign_in(H)
real = os.path.join(T, "elsewhere")
shutil.rmtree(real, ignore_errors=True)
os.makedirs(real)
write(os.path.join(real, "emu.cfg"), "[achievements]\nEnabled = no\n")
os.chmod(os.path.join(real, "emu.cfg"), 0o644)
os.makedirs(os.path.join(H, ".config/flycast"))
os.symlink(os.path.join(real, "emu.cfg"), os.path.join(H, FC))
run("flycast", H)
check("a symlink is kept, its target written and made 0600",
      (os.path.islink(os.path.join(H, FC)), ini(H, FC, "achievements", "Token"), mode(os.path.join(real, "emu.cfg"))),
      (True, TOKEN, 0o600))
write(os.path.join(real, "token.dat"), TOKEN)
os.makedirs(os.path.dirname(os.path.join(H, PPD)), exist_ok=True)
os.symlink(os.path.join(real, "token.dat"), os.path.join(H, PPD))
write(os.path.join(H, ".config/retroarch/retroarch.cfg"), 'cheevos_username = ""\ncheevos_token = ""\n')
run("ppsspp", H)
check("signed out through a symlinked .dat: the token file itself is removed", os.path.exists(os.path.join(real, "token.dat")), False)
check("no warnings", warnings, [])

# =================================================================================================
CASE = "DuckStation's token"
other = os.path.join(T, "machine-id-2")
write(other, "fedcba9876543210fedcba9876543210\n")
a = ach.duckstation_token(TOKEN, USER, MID)
check("same input, same value (no random IV: DuckStation derives it)", ach.duckstation_token(TOKEN, USER, MID), a)
check("another device, another value", ach.duckstation_token(TOKEN, USER, other) != a, True)
check("another user name, another value", ach.duckstation_token(TOKEN, "Player2", MID) != a, True)
check("a token of 16 bytes is one block: 24 base64 characters", len(a), 24)
long_token = "A" * 33
check("a 33-byte token pads to 48 bytes and decrypts back", ds_decrypt(ach.duckstation_token(long_token, USER, MID), USER, MID), long_token)
check("signed out: empty", ach.duckstation_token("", "", MID), "")

# =================================================================================================
CASE = "bad entries are refused"
good = {"file": ".config/x/x.ini", "format": "ini", "set": [{"section": "A", "key": "K", "value": "{user}"}]}
check("a good one passes", ach.entry_ok(good, safe_relative), True)
for what, e in [
    ("an absolute path", {**good, "file": "/etc/passwd"}),
    ("a path out of $HOME", {**good, "file": "../x.ini"}),
    ("an unknown placeholder", {**good, "set": [{"section": "A", "key": "K", "value": "{password}"}]}),
    ("a stray brace", {**good, "set": [{"section": "A", "key": "K", "value": "{user"}]}),
    ("a value with a newline", {**good, "set": [{"section": "A", "key": "K\nX", "value": "{user}"}]}),
    ("an empty key", {**good, "set": [{"section": "A", "key": " ", "value": "{user}"}]}),
    ("an empty set", {**good, "set": []}),
    ("an unknown format", {**good, "format": "json"}),
    ("an unknown key", {**good, "extra": 1}),
    ("three boolean words", {**good, "bool": ["a", "b", "c"]}),
    ("the same word twice", {**good, "bool": ["x", "x"]}),
    ("a separator that is not =", {**good, "separator": ":"}),
    ("a secret with a set", {"file": "x.dat", "format": "secret", "value": "{token}", "set": []}),
    ("a secret with no value", {"file": "x.dat", "format": "secret"}),
]:
    check(f"{what}", ach.entry_ok(e, safe_relative), False)

print(f"\n{PASS} passed, {FAIL} failed")
sys.exit(1 if FAIL else 0)
PY

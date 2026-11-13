# achievements — the player's RetroAchievements sign-in, handed to the standalone emulators by
# retroforge-launch (.claude/plans/standalone-cheevos.plan.md).
#
# ONE SIGN-IN. The player signs in once, in Settings > Library > RetroAchievements
# (/usr/bin/retroforge-cheevos), which keeps the name and the token RetroAchievements answered with in
# RetroArch's ~/.config/retroarch/retroarch.cfg (cheevos_username, cheevos_token, 0600), with the
# Hardcore toggle (cheevos_hardcore_mode_enable). A sign-in made in RetroArch's own menu lands in the
# same keys. The token belongs to the account, not to the program that asked for it, so every
# rcheevos client takes it.
#
# AT EVERY LAUNCH of an emulator whose emulator.json has an "achievements" list (game or Open), after
# the first-run seed (a file made first would keep the seed out for good), retroforge-launch writes
# that sign-in into the emulator's own files. The emulator is not running then, so its write-back at
# exit cannot undo it. RetroForge owns the sign-in: signed out here means signed out there (empty
# name and token, achievements off), and what the player changes in an emulator's own menu is
# replaced at its next launch. Hardcore is written either way: Dolphin and PPSSPP default to it ON,
# which would refuse the Guide+L1 load-state hotkey.
#
#   "achievements": [{"file": ".config/x/x.ini", "format": "ini", "separator": " = ",
#                     "bool": ["True", "False"],                 the file's words (default true/false)
#                     "set": [{"section": "Achievements", "key": "Token", "value": "{token}"},
#                             {"section": "Old", "key": "Token", "value": null}]},   null: removed
#                    {"file": ".config/x/token.dat", "format": "secret", "value": "{token}"}]
#
# A value is a one-line string holding any of the placeholders below (and nothing else in braces):
#
#   {user}               the RetroAchievements name ("" signed out)
#   {token}              the login token ("" signed out)
#   {duckstation_token}  the token as DuckStation keeps it (below)
#   {enabled}            the entry's true word when signed in, else its false word
#   {hardcore}           the entry's true word when Hardcore is on
#
# The "secret" format is a file that IS the value (PPSSPP's PSP/SYSTEM/ppsspp_retroachievements.dat),
# removed when the value is empty.
#
# SECRETS. A file a token goes into is 0600 before the token is in it, and written under umask 077 (the
# temporary file write_atomic renames into place holds the token too). Neither a token nor a name is
# ever logged. A sign-in in retroarch.cfg that is not a RetroAchievements name and token (a hand edit)
# is treated as signed out, never written into another file.
#
# DUCKSTATION encrypts its token (src/core/achievements.cpp EncryptLoginToken, tag v0.1-11894):
# base64(AES-128-CBC(token zero-padded to 16 bytes)), with SHA-256(the bytes of /etc/machine-id, newline
# included, then the user name) re-hashed 100 more times: its first 16 bytes the key, its last 16 the
# IV. The machine-id is the device's (made at first boot, kept across updates), so this runs on the
# device; the key comes from world-readable data: obfuscation, not secrecy. openssl does the AES, the
# token on its stdin.
#
# A file that cannot be written is a warning, never a blocked game. A retroarch.cfg that cannot be
# read writes nothing (unknown is not signed out); a DuckStation token that cannot be encrypted
# (no machine-id, no openssl) writes that file signed out, never the previous player's name and token.
#
# Test seams (tests/test-achievements.sh): RETROFORGE_MACHINE_ID, RETROFORGE_OPENSSL.

import base64
import hashlib
import os
import re
import subprocess

import emuopts

MACHINE_ID = os.environ.get("RETROFORGE_MACHINE_ID", "/etc/machine-id")
OPENSSL = os.environ.get("RETROFORGE_OPENSSL", "openssl")
RETROARCH_CFG = os.path.join(".config", "retroarch", "retroarch.cfg")  # under $HOME
USER = re.compile(r"[A-Za-z0-9_.-]{1,64}")   # retroforge-cheevos' checks, kept in step
TOKEN = re.compile(r"[A-Za-z0-9]{8,128}")
PLACEHOLDERS = ("{user}", "{token}", "{duckstation_token}", "{enabled}", "{hardcore}")
TOKEN_PLACEHOLDERS = ("{token}", "{duckstation_token}")
SECRET = "secret"
FORMATS = emuopts.FORMATS + (SECRET,)
DEFAULT_BOOL = ("true", "false")
DUCKSTATION_ROUNDS = 100
AES_BLOCK = 16


class SignIn:
    """What retroarch.cfg holds: user and token both set (valid) or both "", and hardcore."""

    def __init__(self, user="", token="", hardcore=False):
        self.user, self.token, self.hardcore = user, token, hardcore

    @property
    def signed_in(self):
        return bool(self.user and self.token)


def _cfg_value(text, key):
    raw = emuopts.ini_get(text, "", key)
    return raw.strip().strip('"') if raw is not None else ""


def read_sign_in(home, warn):
    """The sign-in from RetroArch's retroarch.cfg; signed out when it is missing or holds no valid pair.
    None when it cannot be read: unknown is not signed out, so nothing is written (a passing read
    error must not sign the player out of every emulator)."""
    try:
        with open(os.path.join(home, RETROARCH_CFG), encoding="utf-8") as f:
            text = f.read()
    except FileNotFoundError:
        return SignIn()
    except (OSError, UnicodeError) as err:
        warn(f"cannot read the RetroAchievements sign-in, the emulators' own left as they are: {err}")
        return None
    user, token = _cfg_value(text, "cheevos_username"), _cfg_value(text, "cheevos_token")
    hardcore = _cfg_value(text, "cheevos_hardcore_mode_enable") == "true"
    if not (user and token):
        return SignIn(hardcore=hardcore)
    if not (USER.fullmatch(user) and TOKEN.fullmatch(token)):
        warn("the RetroAchievements sign-in in retroarch.cfg is not a name and token: treated as signed out")
        return SignIn(hardcore=hardcore)
    return SignIn(user, token, hardcore)


# ----------------------------------------------------------------------------------- validation --

def _clean(value):
    return isinstance(value, str) and "\0" not in value and "\n" not in value and "\r" not in value


def _value_ok(value):
    """A one-line string whose only {...} are PLACEHOLDERS."""
    if not _clean(value):
        return False
    rest = value
    for p in PLACEHOLDERS:
        rest = rest.replace(p, "")
    return "{" not in rest and "}" not in rest


def entry_ok(e, safe_relative):
    """One "achievements" entry (the header's shape). safe_relative: launch_def's path check."""
    if not (isinstance(e, dict) and isinstance(e.get("file"), str) and safe_relative(e["file"])
            and e.get("format") in FORMATS):
        return False
    if e["format"] == SECRET:
        return set(e) == {"file", "format", "value"} and _value_ok(e["value"])
    if not {"file", "format", "set"} <= set(e) <= {"file", "format", "separator", "bool", "set"}:
        return False
    if "separator" in e and not (e["format"] in emuopts.LINE_FORMATS and _clean(e["separator"])
                                 and e["separator"].strip() == "="):
        return False
    if "bool" in e and not (isinstance(e["bool"], list) and len(e["bool"]) == 2
                            and all(_clean(w) and w and "{" not in w for w in e["bool"])
                            and e["bool"][0] != e["bool"][1]):
        return False
    return (isinstance(e["set"], list) and bool(e["set"])
            and all(isinstance(a, dict) and set(a) == {"section", "key", "value"}
                    and _clean(a["section"]) and _clean(a["key"]) and a["key"].strip()
                    and (a["value"] is None or _value_ok(a["value"])) for a in e["set"]))


# ------------------------------------------------------------------------------------- applying --

def duckstation_token(token, user, machine_id_path=None):
    """The token as DuckStation's settings.ini keeps it (header). Raises OSError / ValueError."""
    if not (token and user):
        return ""
    with open(machine_id_path or MACHINE_ID, "rb") as f:
        machine_id = f.read()
    if not machine_id.strip():
        raise ValueError(f"{machine_id_path or MACHINE_ID} is empty")
    key = hashlib.sha256(machine_id + user.encode()).digest()
    for _ in range(DUCKSTATION_ROUNDS):
        key = hashlib.sha256(key).digest()
    data = token.encode()
    data += b"\0" * (-len(data) % AES_BLOCK)
    res = subprocess.run([OPENSSL, "enc", "-aes-128-cbc", "-nopad", "-K", key[:16].hex(), "-iv", key[16:].hex()],
                         input=data, capture_output=True, timeout=10)
    if res.returncode != 0 or len(res.stdout) != len(data):
        raise ValueError(f"openssl could not encrypt (exit {res.returncode})")
    return base64.b64encode(res.stdout).decode()


def _expand(value, words, s, encrypted):
    """value with its placeholders filled; encrypted is {duckstation_token}'s value."""
    if value is None:
        return None
    true_word, false_word = words
    return (value.replace("{user}", s.user).replace("{token}", s.token)
            .replace("{duckstation_token}", encrypted)
            .replace("{enabled}", true_word if s.signed_in else false_word)
            .replace("{hardcore}", true_word if s.hardcore else false_word))


def _values(e):
    return [e["value"]] if e["format"] == SECRET else [a["value"] for a in e["set"]]


def _uses(e, placeholder):
    return any(v is not None and placeholder in v for v in _values(e))


def _tighten(path):
    """path 0600 (made empty when missing): before a token goes in. path is already resolved."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT, 0o600)
    os.close(fd)
    os.chmod(path, 0o600)


def _apply_entry(emulator, e, home, s, warn):
    # Resolved as write_atomic resolves it, so the file made 0600 (or removed) is the one written.
    path = os.path.realpath(os.path.join(home, e["file"]))
    encrypted = ""
    if s.signed_in and _uses(e, "{duckstation_token}"):
        try:
            encrypted = duckstation_token(s.token, s.user)
        except (OSError, ValueError, subprocess.SubprocessError) as err:
            # Signed out for this file, rather than leave the previous name and token in it.
            warn(f"{emulator}: cannot encrypt the RetroAchievements token for {e['file']} ({err}): "
                 "written signed out")
            s = SignIn(hardcore=s.hardcore)
    holds_token = s.signed_in and any(_uses(e, p) for p in TOKEN_PLACEHOLDERS)
    if e["format"] == SECRET:
        value = _expand(e["value"], DEFAULT_BOOL, s, encrypted)
        if not value:
            try:
                os.unlink(path)
            except FileNotFoundError:
                pass
            return
        _tighten(path)
        emuopts.write_atomic(path, value.encode())
        return
    words = tuple(e.get("bool", DEFAULT_BOOL))
    edits = [(a["section"], a["key"], _expand(a["value"], words, s, encrypted)) for a in e["set"]]
    if holds_token:
        _tighten(path)
    emuopts.patch_file(path, e["format"], edits, e.get("separator", "="))


def apply(emulator, entries, home, warn):
    """Write the sign-in into each entry's file. Warnings only: the game starts whatever happens."""
    if not entries:
        return
    s = read_sign_in(home, warn)
    if s is None:
        return
    old = os.umask(0o077)  # write_atomic's temporary file holds the token before its rename
    try:
        for e in entries:
            try:
                _apply_entry(emulator, e, home, s, warn)
            except emuopts.FILE_ERRORS as err:
                warn(f"{emulator}: could not write the RetroAchievements sign-in to {e['file']}: {err}")
    finally:
        os.umask(old)

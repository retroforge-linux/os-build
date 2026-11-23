# emuopts — per-emulator options for retroforge-launch (.claude/plans/emulator-options.plan.md).
#
# The player picks display options (renderer, resolution, aspect...) at two levels:
#
#   emulator  ~/.config/retroforge/emulators/<emulator>.conf      Main menu > Emulators
#   game      ~/.config/retroforge/games/<system>/<rom file>.conf  Game settings > RetroForge
#
# Both are `key=value` lines (the last one of a key wins), read and never sourced: CPUS=big|all (fast
# cores) and one line per option id. A missing line means "not chosen at this level": at the game level
# the emulator's choice applies, at the emulator level RetroForge leaves the emulator's own setting alone.
#
# /usr/share/retroforge/emulators/<emulator>/options.json says, as DATA, what each value does:
#
#   {"files": {"main": {"path": ".config/x/x.ini",      relative to $HOME
#                       "format": "ini" | "toml" | "yaml" | "xml",
#                       "separator": " = "}},           how an added line is written (ini/toml; default "=")
#    "options": [{"id": "aspect", "label": "Aspect ratio", "description": "...",
#                 "default": "16:9",                      optional, below
#                 "choices": [{"value": "16:9", "label": "16:9", "set": [ACTION, ...]}, ...]}],
#    "notes": ["..."]}
#
#   ACTION = {"args": ["-C", "lockAspectRatio=1"]}                  on the emulator's command line
#          | {"env": {"NAME": "value"}}                             in its environment
#          | {"file": "main", "section": "Display", "key": "AspectRatio", "value": "16:9"}
#          | {"window_size": false}                                 the definition's window_size on or off
#
# "default" names the choice the emulator level has when none is saved: such an option never leaves the
# emulator's own setting alone. "window_size" is for the launcher (window_size below): false runs the
# emulator without the picture-sized window or display its definition asks for, which breaks shaders.
#
# A file action names the setting by section and key: an INI/TOML [section] ("" = before the first
# header), a YAML mapping path ("Video/Performance Overlay"), an XML element path under the root
# ("Graphic/Overlay"). The value is the file's text, verbatim (TOML quotes included).
#
# A path may hold "{system}" when the emulator keeps one settings folder per system (ClownMDEmu: -u
# ~/.config/clownmdemu/<system>). The emulator level is written for every system launch.conf gives the
# emulator, so each folder (and Open's) shows it; the game level only for the system of the run.
#
# An emulator-level value is written into the emulator's file at every launch (Open included) and stays
# there: as if the player had set it in the emulator, which RetroForge keeps enforcing. A game-level value
# lasts for that run only: what the file held before is recorded in a restore journal
# (~/.local/state/retroforge/restore/<emulator>.json) BEFORE the patch, and put back when the emulator
# exits. The next launch of that emulator restores a journal still there first (a double Exit SIGKILLs
# the launcher; a power cut), so one game's override never stays in the emulator's own settings. What the
# player changes in the emulator to an overridden setting during that run is lost (user decision).
#
# The patchers edit lines, never re-serialise a file (XML excepted, below): comments, order
# and every other setting are kept. Standard library only: the image's python has no YAML or TOML writer.

import json
import os
import re
import secrets
import tomllib
import xml.etree.ElementTree as ET

FORMATS = ("ini", "toml", "yaml", "xml")
LINE_FORMATS = ("ini", "toml")
OPTION_ID = re.compile(r"[a-z][a-z0-9_]*")
FILE_NAME = re.compile(r"[a-z][a-z0-9_]*")
VAR_NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
CHOICE_VALUE = re.compile(r"[A-Za-z0-9_.:+-]+")
CPUS_VALUES = ("big", "all")
SYSTEM = "{system}"  # in a file path: the system's own settings folder
JOURNAL_VERSION = 1
# What a settings file can throw at a patch: unreadable, not text, not XML, or TOML we would break.
FILE_ERRORS = (OSError, UnicodeError, ET.ParseError, tomllib.TOMLDecodeError)


class OptionsError(Exception):
    """An options.json that is not what this module reads (an image bug: retroforge-launch exits 2)."""


# ---------------------------------------------------------------------------------- conf files --

def read_conf(path):
    """{key: value} of a player conf; {} when it is missing or unreadable. The last line of a key wins."""
    values = {}
    try:
        with open(path, errors="replace") as f:
            for line in f:
                key, sep, value = line.rstrip("\n").partition("=")
                if sep and key and not key.startswith("#"):
                    values[key] = value
    except OSError:
        pass
    return values


def game_conf_path(game_dir, system, rom):
    """Where a game's choices live: <game_dir>/<system>/<the ROM's file or folder name>.conf."""
    return os.path.join(game_dir, system, os.path.basename(os.path.normpath(rom)) + ".conf")


def cpus_choice(emulator_conf, game_conf):
    """'big' or 'all': the game's CPUS when valid, else the emulator's, else 'all'."""
    for conf in (game_conf, emulator_conf):
        if conf.get("CPUS") in CPUS_VALUES:
            return conf["CPUS"]
    return "all"


# ------------------------------------------------------------------------------- options.json --

def _str(value):
    return isinstance(value, str) and "\0" not in value


def _one_line(*values):
    return all(_str(v) and "\n" not in v for v in values)


def _safe_relative(path):
    return (_str(path) and path not in ("", ".") and not path.startswith("/")
            and os.path.normpath(path) == path and ".." not in path.split("/"))


def _check_action(action, files, where):
    if not isinstance(action, dict):
        raise OptionsError(f"{where}: an action must be an object")
    kind = set(action)
    if kind == {"args"}:
        if not (isinstance(action["args"], list) and action["args"] and all(_str(a) for a in action["args"])):
            raise OptionsError(f"{where}: args must be a non-empty list of strings")
    elif kind == {"env"}:
        env = action["env"]
        if not (isinstance(env, dict) and env
                and all(isinstance(k, str) and VAR_NAME.fullmatch(k) and _str(v) for k, v in env.items())):
            raise OptionsError(f"{where}: env must map variable names to strings")
    elif kind == {"file", "section", "key", "value"}:
        if action["file"] not in files:
            raise OptionsError(f"{where}: file {action['file']!r} is not declared in files")
        if not (_one_line(action["section"], action["key"], action["value"]) and action["key"].strip()):
            raise OptionsError(f"{where}: section, key and value must be one-line strings (key not empty)")
    elif kind == {"window_size"}:
        if not isinstance(action["window_size"], bool):
            raise OptionsError(f"{where}: window_size must be true or false")
    else:
        raise OptionsError(f"{where}: an action is {{args}}, {{env}}, {{window_size}} or {{file, section, key, value}}")


def _check_files(files, path):
    if not isinstance(files, dict):
        raise OptionsError(f"{path}: files must be an object")
    for name, f in files.items():
        where = f"{path}: files.{name}"
        if not (FILE_NAME.fullmatch(name) and isinstance(f, dict) and set(f) <= {"path", "format", "separator"}):
            raise OptionsError(f"{where}: must be {{path, format[, separator]}}")
        # "{system}" stands for one path component (a system id: no '/', never '..').
        if not (_str(f.get("path")) and _safe_relative(f["path"].replace(SYSTEM, "s"))
                and not re.search(r"[{}]", f["path"].replace(SYSTEM, ""))):
            raise OptionsError(f"{where}: path must be relative to $HOME, without '..' ('{SYSTEM}' allowed)")
        if f.get("format") not in FORMATS:
            raise OptionsError(f"{where}: format must be one of {', '.join(FORMATS)}")
        if "separator" in f and not (f["format"] in LINE_FORMATS and _one_line(f["separator"])
                                     and f["separator"].strip() == "="):
            raise OptionsError(f"{where}: separator is '=' with optional spaces, for ini and toml only")


def _check_choice(choice, files, seen, where):
    if not (isinstance(choice, dict) and set(choice) == {"value", "label", "set"}):
        raise OptionsError(f"{where}: a choice is {{value, label, set}}")
    value = choice["value"]
    if not (_str(value) and CHOICE_VALUE.fullmatch(value) and _one_line(choice["label"])):
        raise OptionsError(f"{where}: choice value {value!r} must be letters, digits or _.:+- (label a string)")
    if value in seen:
        raise OptionsError(f"{where}: choice value {value!r} is repeated")
    seen.add(value)
    if not (isinstance(choice["set"], list) and choice["set"]):
        raise OptionsError(f"{where}: choice {value}: set must be a non-empty list of actions")
    for action in choice["set"]:
        _check_action(action, files, f"{where}: choice {value}")


def _check_option(option, files, path):
    if not (isinstance(option, dict) and set(option) <= {"id", "label", "description", "default", "choices"}):
        raise OptionsError(f"{path}: an option is {{id, label, description, default, choices}}")
    oid = option.get("id")
    if not (isinstance(oid, str) and OPTION_ID.fullmatch(oid)):
        raise OptionsError(f"{path}: option id {oid!r} must be lowercase letters, digits and _")
    where = f"{path}: option {oid}"
    if not (_one_line(option.get("label")) and _str(option.get("description", ""))):
        raise OptionsError(f"{where}: label (and description) must be strings")
    choices = option.get("choices")
    if not (isinstance(choices, list) and choices):
        raise OptionsError(f"{where}: choices must be a non-empty list")
    seen = set()
    for choice in choices:
        _check_choice(choice, files, seen, where)
    # A game's choice is written over the emulator's: a setting only one of them wrote would stay active.
    written = {frozenset((a["file"], a["section"], a["key"]) for a in c["set"] if "file" in a) for c in choices}
    if len(written) > 1:
        raise OptionsError(f"{where}: every choice must write the same settings (file, section, key)")
    if len({sum("window_size" in a for a in c["set"]) for c in choices}) > 1:
        raise OptionsError(f"{where}: every choice must set window_size, or none")
    if "default" in option and not (_str(option["default"]) and option["default"] in seen):
        raise OptionsError(f"{where}: default {option['default']!r} is not one of its choices")


def load_options(data_dir, emulator):
    """The emulator's options.json, checked; None when the emulator has none. OptionsError when invalid."""
    path = os.path.join(data_dir, emulator, "options.json")
    try:
        with open(path) as f:
            d = json.load(f)
    except FileNotFoundError:
        return None
    except (OSError, ValueError) as err:
        raise OptionsError(f"{path} is not readable JSON: {err}") from None
    if not (isinstance(d, dict) and set(d) <= {"files", "options", "notes"}):
        raise OptionsError(f"{path}: must be an object with files, options and notes only")
    files = d.get("files", {})
    _check_files(files, path)
    options = d.get("options")
    if not isinstance(options, list):
        raise OptionsError(f"{path}: options must be a list")
    ids = set()
    for option in options:
        _check_option(option, files, path)
        if option["id"] in ids:
            raise OptionsError(f"{path}: option {option['id']} is repeated")
        ids.add(option["id"])
    return {"files": files, "options": options}


# ----------------------------------------------------------------------- line patchers: ini/toml --

# [section], and TOML's [[array of tables]]: a boundary too, named so no real section can equal it.
SECTION_LINE = re.compile(r"\s*(\[\[[^\]]+\]\]|\[[^\]]+\])\s*(?:[#;].*)?")


def _lines(text):
    """The file's lines, split on \n only (str.splitlines also splits on \x0b, \x85, U+2028...,
    which a value may hold)."""
    lines = text.split("\n")
    return lines[:-1] if lines and lines[-1] == "" else lines


def _key_line(key):
    return re.compile(r"(\s*)" + re.escape(key) + r"(\s*=\s*)(.*?)\s*")


def _sections(lines):
    """[(section, start, end)]: a section's settings are lines[start:end] (its header excluded)."""
    spans, section, start = [], "", 0
    for i, line in enumerate(lines):
        if m := SECTION_LINE.fullmatch(line):
            spans.append((section, start, i))
            header = m.group(1)
            section, start = (header if header.startswith("[[") else header[1:-1].strip()), i + 1
    spans.append((section, start, len(lines)))
    return spans


def ini_get(text, section, key):
    """The first value of key in [section], or None."""
    lines, pattern = _lines(text), _key_line(key)
    for sec, start, end in _sections(lines):
        if sec == section:
            for line in lines[start:end]:
                if m := pattern.fullmatch(line):
                    return m.group(3)
    return None


def _join(lines):
    return "\n".join(lines) + "\n" if lines else ""


def _drop_empty_sections(lines, section):
    """lines without [section]'s header where removing a key left it empty (the restore of a setting a
    game added to a section that was not there). Only a section with no lines at all: a blank line
    may be the player's."""
    out = list(lines)
    for sec, start, end in reversed(_sections(lines)):
        if sec == section and sec != "" and start > 0 and start == end:
            del out[start - 1]
    return out


def ini_set(text, section, key, value, separator="="):
    """text with key=value in [section]; value None removes every such line (and the section, if that
    leaves it empty). A line that is there keeps its spacing; a new one goes after the section's last
    non-blank line (a new section at the end)."""
    lines, pattern = _lines(text), _key_line(key)
    spans = [s for s in _sections(lines) if s[0] == section]
    found = False
    for _, start, end in spans:
        for i in range(start, end):
            if m := pattern.fullmatch(lines[i]):
                found = True
                lines[i] = None if value is None else f"{m.group(1)}{key}{m.group(2)}{value}"
    lines = [line for line in lines if line is not None]
    if found and value is None:
        return _join(_drop_empty_sections(lines, section))
    if found or value is None:
        return _join(lines)
    new = f"{key}{separator}{value}"
    if spans:
        _, start, end = spans[0]
        at = start
        for i in range(start, end):
            if lines[i].strip():
                at = i + 1
        lines.insert(at, new)
    elif section == "":
        lines.insert(0, new)
    else:
        lines += [f"[{section}]", new]  # no blank line before it: a restore leaves the file exactly as it was
    return _join(lines)


# -------------------------------------------------------------------------- line patchers: yaml --

YAML_LINE = re.compile(r"( *)([^#\s-][^:]*?):(?: +(.*?))?\s*")


def _yaml_index(lines):
    """[(path tuple, line index, indent, value)] of every block mapping key line."""
    out, stack = [], []
    for i, line in enumerate(lines):
        m = YAML_LINE.fullmatch(line)
        if not m:
            continue
        indent = len(m.group(1))
        while stack and stack[-1][0] >= indent:
            stack.pop()
        stack.append((indent, m.group(2)))
        out.append((tuple(k for _, k in stack), i, indent, m.group(3)))
    return out


def _yaml_path(section, key):
    return tuple(p for p in section.split("/") if p) + (key,)


def yaml_get(text, section, key):
    path = _yaml_path(section, key)
    for p, _, _, value in _yaml_index(_lines(text)):
        if p == path:
            return value
    return None


def _indent(line):
    return len(line) - len(line.lstrip(" "))


def _yaml_insert_point(lines, index, path):
    """(depth of the deepest existing parent, line after its block, its children's indent, the
    indent step) for a missing key. The block ends at the first content line no deeper than the
    parent, so a list or a nested mapping under its last child stays whole."""
    for n in range(len(path) - 1, 0, -1):
        hits = [(i, indent) for p, i, indent, _ in index if p == path[:n]]
        if not hits:
            continue
        parent_line, parent_indent = hits[0]
        at = parent_line + 1
        for i in range(parent_line + 1, len(lines)):
            text = lines[i].strip()
            if not text or text.startswith("#"):
                continue
            if _indent(lines[i]) <= parent_indent:
                break
            at = i + 1
        children = [indent for p, _, indent, _ in index if len(p) == n + 1 and p[:n] == path[:n]]
        child = children[0] if children else parent_indent + 2
        return n, at, child, max(child - parent_indent, 1)
    children = [indent for p, _, indent, _ in index if len(p) == 1]
    return 0, len(lines), children[0] if children else 0, 2


def _yaml_drop_empty_parents(lines, parents):
    """lines without the parent mappings a removal left with no value and no children (the restore
    of a setting a game added under parents that were not there), innermost first."""
    while parents:
        index = _yaml_index(lines)
        hit = [(i, indent, value) for p, i, indent, value in index if p == parents]
        if not hit or hit[0][2]:
            break
        i, indent, _ = hit[0]
        nxt = next((l for l in lines[i + 1:] if l.strip() and not l.strip().startswith("#")), None)
        if nxt is not None and _indent(nxt) > indent:
            break  # it still has children
        del lines[i]
        parents = parents[:-1]
    return lines


def yaml_set(text, section, key, value):
    """text with the mapping key at section/key set to value; None removes its line. Missing parent
    mappings are added, two spaces per level, at the end of the deepest one that exists."""
    lines, path = _lines(text), _yaml_path(section, key)
    index = _yaml_index(lines)
    for p, i, indent, _ in index:
        if p == path:
            if value is None:
                del lines[i]
                return _join(_yaml_drop_empty_parents(lines, path[:-1]))
            lines[i] = f"{' ' * indent}{key}: {value}"
            return _join(lines)
    if value is None:
        return text
    depth, at, indent, step = _yaml_insert_point(lines, index, path)
    new = [f"{' ' * (indent + step * k)}{name}:" for k, name in enumerate(path[depth:-1])]
    new.append(f"{' ' * (indent + step * (len(path) - 1 - depth))}{key}: {value}")
    lines[at:at] = new
    return _join(lines)


# --------------------------------------------------------------------------------- patchers: xml --

EMPTY_XML = '<?xml version="1.0" encoding="UTF-8"?>\n<content/>\n'


def _xml_parse(text):
    return ET.fromstring(text, parser=ET.XMLParser(target=ET.TreeBuilder(insert_comments=True)))


def _xml_names(section, key):
    return [p for p in section.split("/") if p] + [key]


def xml_get(text, section, key):
    node = _xml_parse(text).find("/".join(_xml_names(section, key)))
    return None if node is None else (node.text or "")


# What comes before the root element: the declaration, comments, a doctype.
XML_PROLOG = re.compile(r"\A(?:\s*(?:<\?.*?\?>|<!--.*?-->|<!DOCTYPE[^>]*>))*\s*", re.DOTALL)


def xml_set(text, section, key, value):
    """text with the element at section/key (under the root) holding value; None removes it. The
    root is re-serialised (comments inside it kept, re-indented: Cemu rewrites its settings.xml whole
    anyway); what precedes it is kept as it was."""
    root = _xml_parse(text)
    *parents, leaf = _xml_names(section, key)
    chain = [root]
    for name in parents:
        child = chain[-1].find(name)
        if child is None:
            if value is None:
                return text
            child = ET.SubElement(chain[-1], name)
        chain.append(child)
    parent = chain[-1]
    node = parent.find(leaf)
    if value is None:
        if node is None:
            return text
        parent.remove(node)
        # Parents left empty go too (the restore of a setting that needed new parents: Cemu's Overlay).
        for up, down in zip(reversed(chain[:-1]), reversed(chain[1:])):
            if len(down) or (down.text or "").strip() or down.attrib:
                break
            up.remove(down)
    else:
        if node is None:
            node = ET.SubElement(parent, leaf)
        node.text = value
    ET.indent(root, "    ")
    prolog = XML_PROLOG.match(text).group(0).rstrip()
    return (prolog or '<?xml version="1.0" encoding="UTF-8"?>') + "\n" + ET.tostring(root, encoding="unicode") + "\n"


def get_setting(fmt, text, section, key):
    if fmt == "yaml":
        return yaml_get(text, section, key)
    if fmt == "xml":
        return xml_get(text, section, key)
    return ini_get(text, section, key)


def set_setting(fmt, text, section, key, value, separator="="):
    if fmt == "yaml":
        return yaml_set(text, section, key, value)
    if fmt == "xml":
        return xml_set(text, section, key, value)
    return ini_set(text, section, key, value, separator)


# ------------------------------------------------------------------------------------- files --

def write_atomic(dst, data):
    """dst holding data (bytes), replaced in one rename (a crash leaves the old file or the new one).
    A symlink's target is what gets replaced, and an existing file keeps its permissions."""
    dst = os.path.realpath(dst)
    tmp = f"{dst}.retroforge-{secrets.token_hex(4)}"
    try:
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        with open(tmp, "wb") as f:
            f.write(data)
        try:
            os.chmod(tmp, os.stat(dst).st_mode & 0o7777)
        except FileNotFoundError:
            pass
        os.replace(tmp, dst)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def read_setting_file(path, fmt):
    """The file's text; an empty document when it does not exist yet."""
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except FileNotFoundError:
        return EMPTY_XML if fmt == "xml" else ""


def patch_file(path, fmt, edits, separator="="):
    """Apply [(section, key, value)] to one file (value None: remove). Raises FILE_ERRORS."""
    text = read_setting_file(path, fmt)
    new = text
    for section, key, value in edits:
        new = set_setting(fmt, new, section, key, value, separator)
    if fmt == "toml":
        tomllib.loads(new)  # never write a TOML the emulator cannot read (melonDS empties its config)
    if new != text:
        write_atomic(path, new.encode("utf-8"))


# ------------------------------------------------------------------------------------ applying --

def resolve(options, emulator_conf, game_conf):
    """[(emulator choice or None, game choice or None)] per option chosen at some level (valid values
    only); an option with a default always has an emulator choice."""
    out = []
    for option in options["options"]:
        by_value = {c["value"]: c for c in option["choices"]}
        emu = by_value.get(emulator_conf.get(option["id"])) or by_value.get(option.get("default"))
        game = by_value.get(game_conf.get(option["id"]))
        if emu or game:
            out.append((emu, game))
    return out


def window_size(options, emulator_conf, game_conf):
    """Whether this run keeps the picture-sized window or display its definition asks for (window_size):
    the winning choice's, True when no option decides it."""
    for emu, game in resolve(options, emulator_conf, game_conf):
        for action in (game or emu)["set"]:
            if "window_size" in action:
                return action["window_size"]
    return True


def unknown_values(options, conf):
    """[(id, value)] of a conf's option lines whose value is not one of the option's choices."""
    known = {o["id"]: {c["value"] for c in o["choices"]} for o in options["options"]}
    return [(k, v) for k, v in conf.items() if k in known and v not in known[k]]


def expand_path(path, systems):
    """A file path for each of `systems` when it holds "{system}" (none when there is no system),
    else the path itself. A system is a launch.conf id: never a '/' or '..'."""
    if SYSTEM not in path:
        return [path]
    return [path.replace(SYSTEM, s) for s in systems if re.fullmatch(r"[a-z0-9_]+", s)]


def plan(options, home, chosen, systems=(), system=None):
    """-> (args, env, {"emulator"|"game": {path: (format, separator, [(section, key, value)])}}).
    The arguments and environment are the winning choice's (the game's); file settings are written
    for both levels: the emulator's stay, the game's go over them for the run. Every choice of an
    option writes the same settings (load_options checks it), so nothing of the emulator's choice is
    left active under the game's. A "{system}" path is written for every one of `systems` at the
    emulator level (the run's `system` included), and for the run's `system` only at the game level."""
    args, env, files = [], {}, {"emulator": {}, "game": {}}
    level_systems = {"emulator": list(systems) + ([system] if system and system not in systems else []),
                     "game": [system] if system else []}
    for emu, game in chosen:
        for level, choice in (("emulator", emu), ("game", game)):
            if choice is None:
                continue
            for action in choice["set"]:
                if "file" not in action:
                    continue
                f = options["files"][action["file"]]
                for path in expand_path(f["path"], level_systems[level]):
                    entry = files[level].setdefault(os.path.join(home, path),
                                                    (f["format"], f.get("separator", "="), []))
                    entry[2].append((action["section"], action["key"], action["value"]))
        for action in (game or emu)["set"]:
            if "args" in action:
                args += action["args"]
            elif "env" in action:
                env.update(action["env"])
    return args, env, files


def journal_path(state_dir, emulator):
    return os.path.join(state_dir, "restore", f"{emulator}.json")


def _write_journal(path, entries):
    write_atomic(path, json.dumps({"version": JOURNAL_VERSION, "restore": entries}, indent=1).encode())


def _apply_emulator_level(files, warn):
    for path, (fmt, sep, edits) in files.items():
        try:
            patch_file(path, fmt, edits, sep)
        except FILE_ERRORS as err:
            warn(f"could not write {path}: {err}")


def _apply_game_level(files, journal, home, warn):
    """Record every setting's current value, then patch. Nothing is patched without a journal."""
    entries, readable = [], {}
    for path, (fmt, sep, edits) in files.items():
        try:
            text = read_setting_file(path, fmt)
            entries += [{"path": path, "format": fmt, "separator": sep, "section": s, "key": k,
                         "value": get_setting(fmt, text, s, k)} for s, k, _ in edits]
            readable[path] = (fmt, sep, edits)
        except FILE_ERRORS as err:
            warn(f"could not read {path}: {err}; this game's settings in it are skipped")
    if not readable:
        return
    # A restore that failed this launch left its entries: they hold the real originals, keep them
    # (and keep them first), or this run would record the stale override as the player's value.
    older = _read_journal(journal, home, warn) or []
    held = {(e["path"], e["section"], e["key"]) for e in older}
    entries = older + [e for e in entries if (e["path"], e["section"], e["key"]) not in held]
    try:
        _write_journal(journal, entries)
    except OSError as err:
        warn(f"could not write the restore journal {journal}: {err}; this game's settings are skipped")
        return
    for path, (fmt, sep, edits) in readable.items():
        try:
            patch_file(path, fmt, edits, sep)
        except FILE_ERRORS as err:
            warn(f"could not write {path}: {err}")


def apply(options, home, state_dir, emulator, emulator_conf, game_conf, warn, systems=(), system=None):
    """Write the chosen values; -> (args, env) for the emulator. Emulator-level values first (kept),
    then game-level ones, journalled before they are written. A file that cannot be patched is a
    warning: the game still starts. `systems`: the emulator's systems, `system`: the run's (None for
    Open), for "{system}" paths."""
    for level, conf in (("game", game_conf), ("emulator", emulator_conf)):
        for oid, value in unknown_values(options, conf):
            warn(f"{level} setting {oid}={value} is not one of {emulator}'s choices: ignored")
    args, env, files = plan(options, home, resolve(options, emulator_conf, game_conf), systems, system)
    _apply_emulator_level(files["emulator"], warn)
    if files["game"]:
        _apply_game_level(files["game"], journal_path(state_dir, emulator), home, warn)
    return args, env


def _journal_entry_ok(e, home):
    """An entry this module could have written: a file under home, one-line strings, a known format."""
    if not (isinstance(e, dict) and e.get("format") in FORMATS
            and _one_line(e.get("path"), e.get("section"), e.get("key"), e.get("separator", "="))):
        return False
    path, home = e["path"], os.path.normpath(home)
    return (os.path.isabs(path) and os.path.normpath(path) == path and path.startswith(home + "/")
            and e.get("separator", "=").strip() == "=" and (e.get("value") is None or _one_line(e["value"])))


def _read_journal(path, home, warn):
    """The journal's entries; None when there is none (or it was unreadable and has been removed)."""
    try:
        with open(path) as f:
            journal = json.load(f)
        entries = journal["restore"]
        if journal.get("version") != JOURNAL_VERSION or not isinstance(entries, list):
            raise ValueError("unknown journal version")
        if not all(_journal_entry_ok(e, home) for e in entries):
            raise ValueError("an entry this launcher would not have written")
    except FileNotFoundError:
        return None
    except (OSError, ValueError, KeyError, TypeError) as err:
        warn(f"unreadable restore journal {path} ({err}): removed")
        _unlink(path)
        return None
    return entries


def restore(home, state_dir, emulator, warn):
    """Put back what the journal recorded, then delete it; nothing to do without one. A file that
    cannot be restored keeps its entries, so the next launch tries again."""
    path = journal_path(state_dir, emulator)
    entries = _read_journal(path, home, warn)
    if entries is None:
        return
    by_file, left = {}, []
    for e in entries:
        by_file.setdefault((e["path"], e["format"], e.get("separator", "=")), []).append(e)
    for (fpath, fmt, sep), group in by_file.items():
        if not os.path.exists(fpath):
            continue  # gone since (emulator removed, player reset it): nothing to undo
        try:
            patch_file(fpath, fmt, [(e["section"], e["key"], e["value"]) for e in group], sep)
        except FILE_ERRORS as err:
            warn(f"could not restore {fpath}: {err}; retried at the next launch")
            left += group
    if not left:
        _unlink(path)
        return
    try:
        _write_journal(path, left)
    except OSError as err:
        warn(f"could not update the restore journal {path}: {err}")


def _unlink(path):
    try:
        os.unlink(path)
    except OSError:
        pass

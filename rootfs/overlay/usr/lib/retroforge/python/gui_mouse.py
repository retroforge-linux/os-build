# gui_mouse — the InputPlumber profile an emulator's own UI gets in Open (retroforge-launch --gui):
# its gamepad_profile with the rows of gamepad/gui-mouse.yaml added (right stick = pointer, R1/L1 =
# left/right click, Guide+B = Escape), or that file alone for an emulator with no profile. That
# file's header has the why; this module only puts the rows in.
#
# The rows are spliced in as TEXT, not through a YAML library (the image has none for python): they
# sit between comment markers in gui-mouse.yaml, already indented for where they go. The "mouse rows"
# go right after the profile's top-level `mapping:` line, the "guide layer rows" right after the
# `mapping:` line of its `guide` layer (the one Guide holds in every guide-hotkeys.yaml). The profile
# must have exactly one of each and list `mouse` in its target_devices (a profile without the mouse
# target would load with the rows dropped). Anything else, or a file we cannot read or write: the
# plain profile, one log line, never no UI -- best-effort like the declaration itself.
import os

MOUSE = "mouse rows"
GUIDE_LAYER = "guide layer rows"


def marked_rows(shared_text, block):
    """The lines between gui-mouse.yaml's '# >>> <block>' and '# <<< <block>'. ValueError when the
    markers are not there once each, in order, with something between them."""
    lines = shared_text.splitlines(keepends=True)
    starts = [i for i, line in enumerate(lines) if line.strip() == f"# >>> {block}"]
    ends = [i for i, line in enumerate(lines) if line.strip() == f"# <<< {block}"]
    if len(starts) != 1 or len(ends) != 1 or ends[0] <= starts[0] + 1:
        raise ValueError(f"the {block} are not between one '# >>> {block}' and one '# <<< {block}'")
    return "".join(lines[starts[0] + 1:ends[0]])


def _only(found, what):
    if len(found) != 1:
        raise ValueError(f"it has no single {what}")
    return found[0]


def compose(profile_text, rows, layer_rows):
    """The profile with rows at the top of its top-level mapping and layer_rows at the top of its
    guide layer's. ValueError when it cannot take them."""
    lines = profile_text.splitlines(keepends=True)
    if not any(line.rstrip() == "  - mouse" for line in lines):
        raise ValueError("its target_devices do not list the mouse")
    top = _only([i for i, line in enumerate(lines) if line.rstrip("\r\n") == "mapping:"],
                "top-level 'mapping:' line")
    layer = _only([i + 1 for i, line in enumerate(lines[:-1])
                   if line.rstrip("\r\n") == "  - name: guide" and lines[i + 1].rstrip("\r\n") == "    mapping:"],
                  "'guide' layer with its 'mapping:' right below")
    rows, layer_rows = (r if r.endswith("\n") else r + "\n" for r in (rows, layer_rows))
    return "".join(lines[:top + 1] + [rows] + lines[top + 1:layer + 1] + [layer_rows] + lines[layer + 1:])


def gui_profile(emulator, own, shared, out_dir, log):
    """The profile path to declare for --gui: own (the definition's, or None) with the rows, written
    to out_dir/gui-<emulator>.yaml; shared itself when there is no own; own when composing fails."""
    if own is None:
        if os.path.isfile(shared):
            return shared
        log(f"gamepad profile: {shared} is not in the image; no mouse in the emulator's UI")
        return None
    if not os.path.isfile(own):
        return own  # the declaration says it is missing
    try:
        with open(shared) as f:
            shared_text = f.read()
        with open(own) as f:
            text = compose(f.read(), marked_rows(shared_text, MOUSE), marked_rows(shared_text, GUIDE_LAYER))
        os.makedirs(out_dir, exist_ok=True)
        path = os.path.join(out_dir, f"gui-{emulator}.yaml")
        partial = path + ".partial"
        with open(partial, "w") as f:
            f.write(text)
        os.replace(partial, path)
    except (OSError, ValueError) as err:
        log(f"gamepad profile: no mouse in {emulator}'s UI ({own}: {err}); its hotkeys only")
        return own
    return path

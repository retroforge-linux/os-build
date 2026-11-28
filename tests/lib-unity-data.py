#!/usr/bin/env python3
# Shared writer of a Unity player build's globalgamemanagers, for test-graphics-api.sh, test-store.sh
# and test-steam-direct.sh: python/graphics_api.py offers a Unity game the graphics APIs its BuildSettings
# lists (m_GraphicsAPIs), so the suites build that file as Unity writes it.
#
#     python3 tests/lib-unity-data.py <globalgamemanagers> <layout> [typetree] [<GraphicsDeviceType> ...]
#
#   layout   BuildSettings' fields as the release type trees of that Unity line have them
#            (AssetRipper TypeTreeDumps), and the SerializedFile format it writes:
#            2018     5.6-2018 (format 17): buildGUID, m_AuthToken, runtimeClassHashes, scriptHashes
#            2019     2019.3-2019.4 (format 21): the same
#            2020     2020.1-2021.3 (format 22): buildGUID, m_AuthToken
#            2023     2022.3-2023.2 (format 22): neither; Megabonk's (2023.2.22f1, [2])
#            6000     6000.x (format 22): m_AuthToken
#            5.4      format 15: older than any list this reads
#   typetree with the type trees in the file (a development build's), else without (a release's)
#   numbers  2 Direct3D 11, 18 Direct3D 12, 21 Vulkan, 17 OpenGL Core
import struct
import sys

LAYOUTS = {  # form, version, buildGUID, bools, m_AuthToken, the two hash maps
    "5.4": (15, "5.4.6f3", True, 13, True, True),
    "2018": (17, "2018.4.36f1", True, 15, True, True),
    "2019": (21, "2019.4.40f1", True, 15, True, True),
    "2020": (22, "2021.3.45f1", True, 15, True, False),
    "2023": (22, "2023.2.22f1", False, 14, False, False),
    "6000": (22, "6000.0.40f1", False, 14, True, False),
}


def string(s):
    b = s.encode()
    return struct.pack("<i", len(b)) + b + b"\0" * (-len(b) % 4)


def build_settings(layout, apis):
    _form, version, guid, bools, token, maps = LAYOUTS[layout]
    out = struct.pack("<i", 2) + string("Assets/Scenes/Boot.unity") + string("Assets/Scenes/Main.unity")
    out += struct.pack("<iii", 0, 0, 0)  # preloadedPlugins, enabledVRDevices, buildTags
    out += bytes(range(16)) if guid else b""
    out += bytes([1, 1, 0, 0, 0, 0, 0, 1, 1, 1, 1, 0, 1, 0, 0][:bools])
    out += b"\0" * (-len(out) % 4)
    out += string(version)
    out += string("0123456789abcdef0123456789abcdef") if token else b""
    if maps:
        out += struct.pack("<i", 2) + struct.pack("<i", 1) + bytes(16) + struct.pack("<i", 4) + bytes(range(16))
        out += struct.pack("<i", 1) + bytes(range(32))
    return out + struct.pack("<i", len(apis)) + b"".join(struct.pack("<i", a) for a in apis)


def write(path, layout, apis, typetree=False):
    form, version, *_ = LAYOUTS[layout]
    objects = [(129, b"\x07" * 64), (114, b"\x05" * 12), (141, build_settings(layout, apis))]
    meta = version.encode() + b"\0" + struct.pack("<i?", 19, typetree) + struct.pack("<i", 3)
    for cid in (129, 141, 114):
        meta += struct.pack("<i?h", cid, False, -1 if cid != 114 else 0) + (bytes(16) if cid == 114 else b"") + bytes(16)
        if typetree:
            nodes = 3
            meta += struct.pack("<ii", nodes, 20) + bytes(nodes * (32 if form >= 19 else 24)) + b"Base\0m_Version\0int\0\0"
            if form >= 21:
                meta += struct.pack("<ii", 1, 7)
    start = 48 if form >= 22 else 20
    meta += struct.pack("<i", len(objects))
    data, rows = b"", b""
    for pid, (cid, body) in enumerate(objects, 1):
        rows += b"\0" * (-(start + len(meta) + len(rows)) % 4)
        where = struct.pack("<qQ", pid, len(data)) if form >= 22 else struct.pack("<qI", pid, len(data))
        rows += where + struct.pack("<Ii", len(body), (129, 141, 114).index(cid))
        data += body + b"\0" * (-len(body) % 8)
    meta += rows + bytes(12)  # script types, externals, user information
    offset = (start + len(meta) + 15) & ~15
    size = offset + len(data)
    if form >= 22:
        head = struct.pack(">IIII", 0, 0, form, 0) + b"\0" * 4 + struct.pack(">IqqQ", len(meta), size, offset, 0)
    else:
        head = struct.pack(">IIII", len(meta), size, form, offset) + b"\0" * 4
    with open(path, "wb") as f:
        f.write(head + meta + b"\0" * (offset - start - len(meta)) + data)


if __name__ == "__main__":
    args = sys.argv[3:]
    tt = bool(args) and args[0] == "typetree"
    write(sys.argv[1], sys.argv[2], [int(a) for a in args[tt:]], tt)

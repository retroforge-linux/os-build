#!/usr/bin/env python3
# Shared writer of the Steam client's app cache, for test-steam-library.sh, test-steam-direct.sh and
# test-steam-proton.sh: the readers in /usr/lib/retroforge/steam-library must keep up with both
# layouts the client has written, so the three suites build them with one encoder.
#
#     python3 tests/lib-steam-appinfo.py <format> <steam root> <apps.json>
#
#   apps.json   {"<appid>": <its KeyValues tree>}; a str value is a string, an int an int32
#   format      shards   appcache/appinfo/appinfo_00.vdf ... appinfo_ff.vdf (magic 0x0756442A), as the
#                        current client writes them: 256 shards, an app's shard not its id's low byte,
#                        some shards empty and some with two or more apps
#               29 28 27 the single appcache/appinfo.vdf of older clients
#
# Each format replaces the other, so a suite starts from exactly the one it asked for. The header
# CRCs are real (the readers do not check them).
import json
import os
import shutil
import struct
import sys
import zlib


def kv(tree, key):
    """Binary KeyValues: key(name) encodes a name (inline, or a string-table index)."""
    out = b""
    for k, v in tree.items():
        if isinstance(v, dict):
            out += b"\x00" + key(k) + kv(v, key) + b"\x08"
        elif isinstance(v, int):
            out += b"\x02" + key(k) + struct.pack("<i", v)
        else:
            out += b"\x01" + key(k) + str(v).encode() + b"\0"
    return out


def indexer(table):
    def key(name):
        if name not in table:
            table.append(name)
        return struct.pack("<I", table.index(name))
    return key


def inline(name):
    return name.encode() + b"\0"


def single(path, apps, version):
    magic = {27: 0x07564427, 28: 0x07564428, 29: 0x07564429}[version]
    table, body = [], b""
    for appid, tree in sorted(apps.items()):
        data = kv(tree, indexer(table) if version >= 29 else inline) + b"\x08"
        head = struct.pack("<IIQ", 2, 1700000000, 0) + b"\x11" * 20 + struct.pack("<I", 7) + (b"\x22" * 20 if version >= 28 else b"")
        body += struct.pack("<II", appid, len(head) + len(data)) + head + data
    body += struct.pack("<I", 0)
    if version >= 29:
        strings = struct.pack("<I", len(table)) + b"".join(s.encode() + b"\0" for s in table)
        blob = struct.pack("<IIq", magic, 1, 16 + len(body)) + body + strings
    else:
        blob = struct.pack("<II", magic, 1) + body
    with open(path, "wb") as f:
        f.write(blob)


USED = 8  # shards that get apps: few, so a suite's dozen apps share some


def shards(folder, apps):
    os.makedirs(folder)
    placed = {}
    for appid in sorted(apps):
        placed.setdefault(zlib.crc32(b"%d" % appid) % USED * 31 % 256, []).append(appid)
    for shard in range(256):
        table, index, data = [], b"", b""
        for appid in placed.get(shard, []):
            blob = b"\x22" * 20 + kv(apps[appid], indexer(table)) + b"\x08"
            # Change number, last updated, PICS token, prerelease, sha1, then values the client
            # derives from the tree: 64 bytes from the Air X's client, 8 more here for odd app ids,
            # since each entry gives its own size.
            summary = struct.pack("<IIQ?", 7, 1700000000, 0, False) + b"\x11" * 20
            summary += b"\0" * (64 + 8 * (appid % 2) - len(summary))
            index += struct.pack("<4I", appid, len(data), len(blob), len(summary)) + summary
            data += blob
        strings = b"".join(s.encode() + b"\0" for s in table)
        header = struct.pack("<10I", 0x0756442A, 1, shard, 256, len(placed.get(shard, [])), len(index),
                             len(table), len(strings), len(data), zlib.crc32(index + strings))
        header += struct.pack("<I", zlib.crc32(header))
        with open(os.path.join(folder, "appinfo_%02x.vdf" % shard), "wb") as f:
            f.write(header + index + strings + data)


def main(argv):
    fmt, root, spec = argv
    with open(spec, encoding="utf-8") as f:
        apps = {int(k): v for k, v in json.load(f).items()}
    cache = os.path.join(root, "appcache")
    os.makedirs(cache, exist_ok=True)
    shutil.rmtree(os.path.join(cache, "appinfo"), ignore_errors=True)
    try:
        os.remove(os.path.join(cache, "appinfo.vdf"))
    except FileNotFoundError:
        pass
    if fmt == "shards":
        shards(os.path.join(cache, "appinfo"), apps)
    else:
        single(os.path.join(cache, "appinfo.vdf"), apps, int(fmt))


if __name__ == "__main__":
    main(sys.argv[1:])

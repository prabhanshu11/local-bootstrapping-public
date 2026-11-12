#!/usr/bin/env python3
"""png-provenance.py — stamp tEXt provenance chunks into PNGs (screenshots, renders) in place.

~/Programs/CLAUDE.md rule: every generated image carries source, pipeline and created inside the
file. grim writes none, so run this on every screenshot you commit:

  scripts/png-provenance.py docs/screenshots/x.png source="grim eDP-1 2560,180 1920x120" pipeline="lane vdi-ui / docs/vdi.md"
  scripts/png-provenance.py --show docs/screenshots/x.png

`created` defaults to now (UTC, ISO-8601). Pure python, no Pillow. Existing chunks with the same key are replaced.
"""
import datetime
import struct
import sys
import zlib


def chunks(data):
    p = 8
    while p < len(data):
        n = struct.unpack(">I", data[p:p + 4])[0]
        t = data[p + 4:p + 8]
        yield t, data[p + 8:p + 8 + n]
        p += 12 + n


def chunk(t, body):
    return struct.pack(">I", len(body)) + t + body + struct.pack(">I", zlib.crc32(t + body) & 0xFFFFFFFF)


def stamp(path, kv):
    data = open(path, "rb").read()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", f"{path}: not a PNG"
    out = bytearray(data[:8])
    keys = set(kv)
    for t, body in chunks(data):
        if t == b"tEXt" and body.split(b"\0", 1)[0].decode("latin-1") in keys:
            continue
        if t == b"IEND":
            for k, v in kv.items():
                out += chunk(b"tEXt", k.encode("latin-1") + b"\0" + v.encode("latin-1", "replace"))
        out += chunk(t, body)
    open(path, "wb").write(out)


def show(path):
    for t, body in chunks(open(path, "rb").read()):
        if t == b"tEXt":
            k, v = body.split(b"\0", 1)
            print(f"{k.decode('latin-1')}: {v.decode('latin-1')}")


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 2
    if argv[0] == "--show":
        for p in argv[1:]:
            print(f"== {p}")
            show(p)
        return 0
    files = [a for a in argv if "=" not in a]
    kv = dict(a.split("=", 1) for a in argv if "=" in a)
    kv.setdefault("created", datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"))
    for p in files:
        stamp(p, kv)
        print(f"stamped {p}: {', '.join(kv)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

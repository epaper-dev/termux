#!/usr/bin/env python3
"""make-widget-icon.py - scale the project logo down to the widget icon (Python standard library only).

    python3 -I tools/make-widget-icon.py [SRC [DST [SIZE]]]

SRC   the logo, default termux/shortcuts/icons/logo.png (1024x1024 PNG, 8 bit RGBA, not interlaced)
DST   the widget icon, default termux/shortcuts/icons/widget.png
SIZE  edge length in pixels, default 192 (what tests/test_widgets.sh expects)

Area averaging on premultiplied alpha (every target pixel is the weighted mean of the source pixels it
covers), so the transparent corners of the rounded square stay clean. The result does not depend on any
image library; run it again whenever logo.png changes and commit both files.
"""
import os
import struct
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
ICONS = os.path.join(HERE, "..", "termux", "shortcuts", "icons")
SIG = b"\x89PNG\r\n\x1a\n"


def read_png(path):
    """-> (width, height, rows) with rows = list of bytearrays of w*4 bytes (RGBA)."""
    data = open(path, "rb").read()
    if data[:8] != SIG:
        raise SystemExit(f"{path}: kein PNG")
    pos, idat, ihdr = 8, [], None
    while pos < len(data):
        length, kind = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + length]
        if kind == b"IHDR":
            ihdr = struct.unpack(">IIBBBBB", body)
        elif kind == b"IDAT":
            idat.append(body)
        pos += 12 + length
    w, h, depth, ctype, _comp, _filt, interlace = ihdr
    if (depth, ctype, interlace) != (8, 6, 0):
        raise SystemExit(f"{path}: erwartet 8 Bit RGBA ohne Interlace, gefunden Tiefe {depth}, Farbtyp {ctype}, Interlace {interlace}")
    raw = zlib.decompress(b"".join(idat))
    stride = w * 4
    rows, prev = [], bytearray(stride)
    for y in range(h):
        ft = raw[y * (stride + 1)]
        cur = bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        if ft == 1:
            for i in range(4, stride):
                cur[i] = (cur[i] + cur[i - 4]) & 255
        elif ft == 2:
            for i in range(stride):
                cur[i] = (cur[i] + prev[i]) & 255
        elif ft == 3:
            for i in range(stride):
                left = cur[i - 4] if i >= 4 else 0
                cur[i] = (cur[i] + ((left + prev[i]) >> 1)) & 255
        elif ft == 4:
            for i in range(stride):
                a = cur[i - 4] if i >= 4 else 0
                b = prev[i]
                c = prev[i - 4] if i >= 4 else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pred = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                cur[i] = (cur[i] + pred) & 255
        elif ft != 0:
            raise SystemExit(f"{path}: unbekannter Filter {ft}")
        rows.append(cur)
        prev = cur
    return w, h, rows


def write_png(path, w, h, rows):
    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)
    raw = b"".join(b"\x00" + bytes(r) for r in rows)
    out = SIG + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
    out += chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
    open(path, "wb").write(out)


def spans(src, dst):
    """For every target index: [(source index, weight)], weights = overlap of the covered source interval."""
    scale = src / dst
    result = []
    for i in range(dst):
        lo, hi = i * scale, (i + 1) * scale
        items = []
        for j in range(int(lo), min(src, int(hi) + 1)):
            overlap = min(hi, j + 1) - max(lo, j)
            if overlap > 1e-9:
                items.append((j, overlap / scale))
        result.append(items)
    return result


def scale_down(w, h, rows, size):
    # premultiplied floats: r*a, g*a, b*a, a
    pre = []
    for row in rows:
        line = []
        for x in range(0, w * 4, 4):
            a = row[x + 3] / 255.0
            line.extend((row[x] * a, row[x + 1] * a, row[x + 2] * a, a))
        pre.append(line)
    sx, sy = spans(w, size), spans(h, size)
    # horizontal pass
    mid = []
    for line in pre:
        out = []
        for items in sx:
            r = g = b = a = 0.0
            for j, wt in items:
                k = j * 4
                r += line[k] * wt
                g += line[k + 1] * wt
                b += line[k + 2] * wt
                a += line[k + 3] * wt
            out.extend((r, g, b, a))
        mid.append(out)
    # vertical pass, then un-premultiply
    result = []
    for items in sy:
        row = bytearray(size * 4)
        for x in range(size):
            k = x * 4
            r = g = b = a = 0.0
            for j, wt in items:
                m = mid[j]
                r += m[k] * wt
                g += m[k + 1] * wt
                b += m[k + 2] * wt
                a += m[k + 3] * wt
            if a > 1e-9:
                row[k] = min(255, int(round(r / a)))
                row[k + 1] = min(255, int(round(g / a)))
                row[k + 2] = min(255, int(round(b / a)))
            row[k + 3] = min(255, int(round(a * 255)))
        result.append(row)
    return result


def main(argv):
    src = argv[1] if len(argv) > 1 else os.path.join(ICONS, "logo.png")
    dst = argv[2] if len(argv) > 2 else os.path.join(ICONS, "widget.png")
    size = int(argv[3]) if len(argv) > 3 else 192
    w, h, rows = read_png(src)
    if w != h:
        raise SystemExit(f"{src}: das Logo muss quadratisch sein ({w}x{h})")
    write_png(dst, size, size, scale_down(w, h, rows, size))
    print(f"{src} ({w}x{h}) -> {dst} ({size}x{size}), {os.path.getsize(dst)} Bytes")


if __name__ == "__main__":
    main(sys.argv)

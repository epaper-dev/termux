#!/usr/bin/env python3
"""Generate the default Termux:Widget icons (termux/shortcuts/icons/*.png).

A neutral dark rounded square with a coloured ">_" prompt - no logos or trademarks. Pure Python
(zlib + struct), so it runs in Termux without Pillow. The PNGs are committed; run this only to
change the design:

    python3 tools/make-shortcut-icons.py            # writes termux/shortcuts/icons/
    python3 tools/make-shortcut-icons.py OUTDIR     # writes into OUTDIR (tests)
"""
import math
import os
import struct
import sys
import zlib

SIZE = 192          # final icon size in pixels
SS = 4              # supersampling per axis (anti-aliasing)
BG = (0x20, 0x24, 0x2C)
ICONS = {           # file name -> accent colour of the prompt
    "claude": (0xE0, 0x80, 0x5A),
    "ubuntu": (0xB4, 0x5F, 0xD0),
}

# geometry in a 192 x 192 box
RECT = (8.0, 8.0, 184.0, 184.0)     # left, top, right, bottom of the rounded square
RADIUS = 38.0
STROKES = (                         # (x1, y1, x2, y2, half width): ">" is two strokes, "_" one
    (54.0, 64.0, 98.0, 96.0, 8.5),
    (98.0, 96.0, 54.0, 128.0, 8.5),
    (108.0, 134.0, 146.0, 134.0, 8.0),
)


def inside_rounded_rect(x, y):
    left, top, right, bottom = RECT
    if x < left or x > right or y < top or y > bottom:
        return False
    cx = min(max(x, left + RADIUS), right - RADIUS)
    cy = min(max(y, top + RADIUS), bottom - RADIUS)
    return (x - cx) ** 2 + (y - cy) ** 2 <= RADIUS ** 2


def on_stroke(x, y):
    for x1, y1, x2, y2, half in STROKES:
        dx, dy = x2 - x1, y2 - y1
        t = ((x - x1) * dx + (y - y1) * dy) / (dx * dx + dy * dy)
        t = 0.0 if t < 0.0 else 1.0 if t > 1.0 else t        # round caps
        if math.hypot(x - (x1 + t * dx), y - (y1 + t * dy)) <= half:
            return True
    return False


def render(accent):
    rows = []
    n = SS * SS
    for py in range(SIZE):
        row = bytearray([0])                                  # PNG filter type 0 (none)
        for px in range(SIZE):
            r = g = b = cover = 0
            for sy in range(SS):
                for sx in range(SS):
                    x = px + (sx + 0.5) / SS
                    y = py + (sy + 0.5) / SS
                    if not inside_rounded_rect(x, y):
                        continue
                    cover += 1
                    c = accent if on_stroke(x, y) else BG
                    r += c[0]; g += c[1]; b += c[2]
            if cover:
                row += bytes((r // cover, g // cover, b // cover, round(255 * cover / n)))
            else:
                row += bytes((0, 0, 0, 0))
        rows.append(bytes(row))
    return b"".join(rows)


def png(raw):
    def chunk(kind, data):
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)
    header = struct.pack(">IIBBBBB", SIZE, SIZE, 8, 6, 0, 0, 0)   # 8 bit, colour type 6 = RGBA
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header)
            + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(here, "..", "termux", "shortcuts", "icons")
    os.makedirs(out, exist_ok=True)
    for name, accent in ICONS.items():
        path = os.path.join(out, name + ".png")
        with open(path, "wb") as fh:
            fh.write(png(render(accent)))
        print("geschrieben:", path)


if __name__ == "__main__":
    main()

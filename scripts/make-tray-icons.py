#!/usr/bin/env python3
# Generates app/src-tauri/icons/tray-*.png: the tray / menu-bar glyph (the app icon's
# hexagon as an outline with a deploy arrow), flat black on transparency, written with
# nothing but zlib and struct so it runs on any Mac or Windows box with Python 3.
#   python3 scripts/make-tray-icons.py app/src-tauri/icons
# macOS uses tray-template@2x.png as a template image (the system recolours it);
# Windows uses tray-windows.png. preview-256.png is for eyeballing only - do not ship it.
import math, struct, zlib, sys

def hexagon(cx, cy, r):
    return [(cx + r * math.cos(math.radians(60 * i - 90)), cy + r * math.sin(math.radians(60 * i - 90))) for i in range(6)]

def point_in_poly(x, y, poly):
    inside = False
    n = len(poly)
    for i in range(n):
        x1, y1 = poly[i]; x2, y2 = poly[(i + 1) % n]
        if (y1 > y) != (y2 > y):
            xi = x1 + (y - y1) * (x2 - x1) / (y2 - y1)
            if x < xi: inside = not inside
    return inside

def render(size, white=False):
    ss = 8
    S = size * ss
    cx = cy = S / 2
    r_out = S * 0.47
    r_in = r_out - S * 0.085           # outline width ~ 8.5% of the size
    outer = hexagon(cx, cy, r_out)
    inner = hexagon(cx, cy, r_in)
    # arrow: shaft + head, pointing down, centred
    shaft_w = S * 0.14; shaft_top = S * 0.24; shaft_bot = S * 0.50
    head_w = S * 0.40;  head_top = S * 0.46; head_tip = S * 0.72
    head = [(cx - head_w / 2, head_top), (cx + head_w / 2, head_top), (cx, head_tip)]
    alpha = bytearray(size * size)
    for py in range(size):
        for px in range(size):
            hit = 0
            for sy in range(ss):
                for sx in range(ss):
                    x = px * ss + sx + 0.5; y = py * ss + sy + 0.5
                    if (point_in_poly(x, y, outer) and not point_in_poly(x, y, inner)) \
                       or (cx - shaft_w / 2 <= x <= cx + shaft_w / 2 and shaft_top <= y <= shaft_bot) \
                       or point_in_poly(x, y, head):
                        hit += 1
            alpha[py * size + px] = round(255 * hit / (ss * ss))
    v = 255 if white else 0
    raw = bytearray()
    for py in range(size):
        raw.append(0)
        for px in range(size):
            raw += bytes((v, v, v, alpha[py * size + px]))
    def chunk(t, d):
        return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', size, size, 8, 6, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(bytes(raw), 9)) + chunk(b'IEND', b'')

out = sys.argv[1]
for name, size, white in (('tray-template.png', 22, False), ('tray-template@2x.png', 44, False), ('tray-windows.png', 32, False), ('tray-windows@2x.png', 64, False), ('tray-windows-white.png', 32, True), ('preview-256.png', 256, False)):
    open(f'{out}/{name}', 'wb').write(render(size, white))
    print(name)

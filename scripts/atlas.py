"""MDL UI atlas: one 512x512 RGBA texture with MDL's own (original) icons and
archive-theme decorations, drawn procedurally (no fonts, no third-party art).

Layout (pixels, origin top-left, 64 px cells):
  rows 0-1   16 colour icons
  rows 2-3   the same 16 icons as white masks (tinted by the theme colour)
  y 256-383  paper (256x128), corner ornament (64x64), rule (256x16),
             scan glow (128x16), panel grain strip (128x32)
  y 448-511  orientation test cell "orient" (arrow up + mark top-left)

write_lua() emits src/mdl_atlas.lua with the cell UVs (0..1, v down).
"""
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

import sys as _sys
_sys.path.insert(0, str(Path(__file__).resolve().parent))
from archive import resource_hash  # noqa: E402

NAME = 'mods/mdl/ui_atlas'
SIZE = 512
CELL = 64
SS = 4                                  # supersampling factor for icons
ICONS = ['script', 'resource', 'mixed', 'unknown', 'refresh', 'bolt', 'globe', 'palette',
         'lab', 'help', 'back', 'check', 'cross', 'warn', 'gear', 'logo']
DECOR = {
    'paper': (0, 256, 256, 128),
    'corner': (256, 256, 64, 64),
    'rule': (256, 336, 256, 16),
    'scan': (320, 256, 128, 16),
    'grain': (320, 288, 128, 32),
    'orient': (448, 448, 64, 64),
}
# Colour set: (main, accent) per icon.
COLOURS = {
    'script': ((86, 196, 186), (230, 245, 240)), 'resource': ((236, 150, 62), (255, 214, 160)),
    'mixed': ((168, 128, 222), (236, 150, 62)), 'unknown': ((150, 156, 166), (220, 224, 230)),
    'refresh': ((110, 180, 250), (220, 240, 255)), 'bolt': ((255, 213, 0), (255, 245, 180)),
    'globe': ((90, 150, 240), (200, 230, 255)), 'palette': ((214, 176, 120), (255, 255, 255)),
    'lab': ((120, 210, 120), (220, 255, 220)), 'help': ((240, 240, 240), (255, 213, 0)),
    'back': ((210, 214, 222), (255, 255, 255)), 'check': ((120, 220, 120), (255, 255, 255)),
    'cross': ((240, 96, 80), (255, 255, 255)), 'warn': ((255, 190, 40), (40, 30, 10)),
    'gear': ((180, 188, 200), (90, 96, 110)), 'logo': ((255, 213, 0), (40, 44, 52)),
}


def cell_box(index, row_offset=0):
    col, row = index % 8, index // 8 + row_offset
    return col * CELL, row * CELL


def draw_icon(name, main, accent, mask):
    """One icon on a transparent SS*CELL canvas, content inside an 8 px margin."""
    n = CELL * SS
    img = Image.new('RGBA', (n, n), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    a = 255
    m = tuple(main) + (a,) if not mask else (255, 255, 255, a)
    c = tuple(accent) + (a,) if not mask else (255, 255, 255, 150)
    s = SS
    L, T, R, B = 10 * s, 10 * s, 54 * s, 54 * s     # content box
    w = 5 * s                                         # stroke

    def poly(points, fill):
        d.polygon([(x * s, y * s) for x, y in points], fill=fill)

    if name == 'script':
        d.rounded_rectangle((L, T, R, B), radius=8 * s, outline=m, width=w)
        for sx in (-1, 1):                            # braces as chevrons
            cx = 32 + sx * 9
            d.line([((cx + sx * 0) * s, 22 * s), ((cx + sx * 6) * s, 32 * s), ((cx + sx * 0) * s, 42 * s)],
                   fill=c, width=w, joint='curve')
    elif name == 'resource':
        top = [(32, 10), (52, 21), (32, 32), (12, 21)]
        left = [(12, 21), (32, 32), (32, 54), (12, 43)]
        right = [(32, 32), (52, 21), (52, 43), (32, 54)]
        if mask:
            poly(top, (255, 255, 255, 255)); poly(left, (255, 255, 255, 170)); poly(right, (255, 255, 255, 110))
        else:
            poly(top, c); poly(left, m); poly(right, tuple(int(v * 0.7) for v in main) + (255,))
    elif name == 'mixed':
        top = [(40, 14), (54, 22), (40, 30), (26, 22)]
        poly(top, c); poly([(26, 22), (40, 30), (40, 46), (26, 38)], c if mask else tuple(accent) + (200,))
        poly([(40, 30), (54, 22), (54, 38), (40, 46)], c if mask else tuple(int(v * 0.75) for v in accent) + (255,))
        d.rounded_rectangle((10 * s, 30 * s, 34 * s, 54 * s), radius=5 * s, outline=m, width=w)
        d.line([(17 * s, 37 * s), (22 * s, 42 * s), (17 * s, 47 * s)], fill=m, width=w - s)
    elif name == 'unknown':
        d.ellipse((L, T, R, B), outline=m, width=w)
        d.arc((23 * s, 18 * s, 41 * s, 34 * s), start=200, end=20, fill=c, width=w)
        d.line([(39 * s, 30 * s), (32 * s, 36 * s), (32 * s, 40 * s)], fill=c, width=w)
        d.ellipse((29 * s, 44 * s, 35 * s, 50 * s), fill=c)
    elif name == 'refresh':
        d.arc((L + 2 * s, T + 2 * s, R - 2 * s, B - 2 * s), start=40, end=330, fill=m, width=w + s)
        poly([(52, 12), (54, 30), (37, 25)], m)
    elif name == 'bolt':
        poly([(36, 6), (14, 36), (30, 36), (24, 58), (50, 24), (34, 24), (42, 6)], m)
        if not mask:
            poly([(36, 10), (22, 32), (30, 32)], c)
    elif name == 'globe':
        d.ellipse((L, T, R, B), outline=m, width=w)
        d.ellipse((24 * s, T, 40 * s, B), outline=c, width=w - s)
        d.line([(L, 32 * s), (R, 32 * s)], fill=c, width=w - s)
        d.arc((L, 16 * s, R, 48 * s), start=200, end=340, fill=c, width=w - 2 * s)
    elif name == 'palette':
        d.ellipse((8 * s, 12 * s, 56 * s, 52 * s), fill=m)
        d.ellipse((34 * s, 34 * s, 46 * s, 46 * s), fill=(0, 0, 0, 0))
        dots = [((240, 96, 80), (18, 22)), ((255, 213, 0), (29, 17)), ((90, 150, 240), (41, 20)), ((120, 210, 120), (19, 34))]
        for colour, (x, y) in dots:
            fill = (0, 0, 0, 0) if mask else tuple(colour) + (255,)
            d.ellipse(((x - 4) * s, (y - 4) * s, (x + 4) * s, (y + 4) * s), fill=fill)
    elif name == 'lab':
        poly([(26, 8), (38, 8), (38, 24), (54, 52), (50, 56), (14, 56), (10, 52), (26, 24)], m)
        poly([(20, 40), (44, 40), (51, 52), (13, 52)], c)
        d.rectangle((24 * s, 6 * s, 40 * s, 10 * s), fill=m)
    elif name == 'help':
        d.rounded_rectangle((L, T, R, B), radius=6 * s, outline=m, width=w)
        d.arc((23 * s, 18 * s, 41 * s, 34 * s), start=200, end=20, fill=c, width=w)
        d.line([(39 * s, 30 * s), (32 * s, 36 * s), (32 * s, 40 * s)], fill=c, width=w)
        d.rectangle((29 * s, 44 * s, 35 * s, 50 * s), fill=c)
    elif name == 'back':
        poly([(28, 12), (8, 32), (28, 52), (28, 40), (56, 40), (56, 24), (28, 24)], m)
    elif name == 'check':
        d.line([(12 * s, 34 * s), (26 * s, 48 * s), (52 * s, 16 * s)], fill=m, width=w + 2 * s, joint='curve')
    elif name == 'cross':
        d.line([(16 * s, 16 * s), (48 * s, 48 * s)], fill=m, width=w + 2 * s)
        d.line([(48 * s, 16 * s), (16 * s, 48 * s)], fill=m, width=w + 2 * s)
    elif name == 'warn':
        poly([(32, 8), (58, 54), (6, 54)], m)
        hole = (0, 0, 0, 0) if mask else tuple(accent) + (255,)
        d.rectangle((29 * s, 22 * s, 35 * s, 40 * s), fill=hole)
        d.rectangle((29 * s, 44 * s, 35 * s, 50 * s), fill=hole)
    elif name == 'gear':
        import math
        pts = []
        for k in range(16):
            ang = math.pi * 2 * k / 16
            r = 24 if k % 2 == 0 else 18
            for da in (-0.12, 0.12):
                pts.append((32 + r * math.cos(ang + da), 32 + r * math.sin(ang + da)))
        poly(pts, m)
        d.ellipse((24 * s, 24 * s, 40 * s, 40 * s), fill=(0, 0, 0, 0) if mask else tuple(accent) + (255,))
    elif name == 'logo':
        # Original MDL mark: three ascending bars inside a frame with a notch.
        d.rectangle((8 * s, 8 * s, 56 * s, 56 * s), outline=m, width=w)
        poly([(44, 8), (56, 8), (56, 20)], (0, 0, 0, 0))
        for k, h in enumerate((14, 22, 30)):
            x0 = 17 + k * 11
            d.rectangle((x0 * s, (48 - h) * s, (x0 + 7) * s, 48 * s), fill=c if not mask else m)
    return img.resize((CELL, CELL), Image.LANCZOS)


def paper(w, h, seed=7):
    rng = np.random.default_rng(seed)
    base = rng.normal(0, 1, (h // 4 + 1, w // 4 + 1))
    img = Image.fromarray(np.uint8(np.clip(128 + base * 40, 0, 255))).resize((w, h), Image.BICUBIC)
    fine = rng.normal(0, 1, (h, w)) * 10
    # Near-white: drawn tinted with the panel colour, so it only adds grain.
    lum = (np.asarray(img, dtype=np.float32) - 128) * 0.12 + 240 + fine * 0.35
    for _ in range(18):                               # faint fibres
        y = rng.integers(0, h); x = rng.integers(0, w - 40); n = rng.integers(20, 60)
        lum[y, x:x + n] += 10
    lum = np.clip(lum, 0, 255)
    rgba = np.zeros((h, w, 4), np.uint8)
    rgba[..., 0] = lum
    rgba[..., 1] = lum
    rgba[..., 2] = lum
    rgba[..., 3] = 255
    return Image.fromarray(rgba, 'RGBA')


def corner():
    n = 64 * SS
    img = Image.new('RGBA', (n, n), (255, 255, 255, 0))
    d = ImageDraw.Draw(img)
    s, w = SS, 3 * SS
    d.line([(4 * s, 60 * s), (4 * s, 4 * s), (60 * s, 4 * s)], fill=(255, 255, 255, 255), width=w)
    d.line([(12 * s, 40 * s), (12 * s, 12 * s), (40 * s, 12 * s)], fill=(255, 255, 255, 170), width=w // 2)
    d.rectangle((18 * s, 18 * s, 24 * s, 24 * s), fill=(255, 255, 255, 255))
    return img.resize((64, 64), Image.LANCZOS)


def rule():
    img = Image.new('RGBA', (256 * SS, 16 * SS), (255, 255, 255, 0))
    d = ImageDraw.Draw(img)
    s = SS
    d.line([(0, 8 * s), (256 * s, 8 * s)], fill=(255, 255, 255, 140), width=s)
    for x in range(8, 256, 16):
        d.rectangle(((x - 1) * s, 6 * s, (x + 1) * s, 10 * s), fill=(255, 255, 255, 230))
    d.polygon([(128 * s, 2 * s), (134 * s, 8 * s), (128 * s, 14 * s), (122 * s, 8 * s)], fill=(255, 255, 255, 255))
    return img.resize((256, 16), Image.LANCZOS)


def scan():
    x = np.linspace(-1, 1, 128)[None, :]
    y = np.linspace(-1, 1, 16)[:, None]
    a = np.exp(-(y * 2.2) ** 2) * (1 - np.abs(x) ** 6)
    rgba = np.zeros((16, 128, 4), np.uint8)
    rgba[..., :3] = 255
    rgba[..., 3] = np.uint8(np.clip(a * 255, 0, 255))
    return Image.fromarray(rgba, 'RGBA')


def grain():
    rng = np.random.default_rng(3)
    a = np.clip(rng.normal(40, 30, (32, 128)), 0, 255)
    for y in range(0, 32, 4):
        a[y, :] += 30                                 # scanline rows
    rgba = np.zeros((32, 128, 4), np.uint8)
    rgba[..., :3] = 255
    rgba[..., 3] = np.uint8(np.clip(a, 0, 255))
    return Image.fromarray(rgba, 'RGBA')


def orient():
    img = Image.new('RGBA', (64, 64), (40, 44, 52, 255))
    d = ImageDraw.Draw(img)
    d.polygon([(32, 6), (52, 30), (40, 30), (40, 58), (24, 58), (24, 30), (12, 30)], fill=(255, 213, 0, 255))
    d.rectangle((2, 2, 10, 10), fill=(240, 96, 80, 255))      # red mark = top-left
    return img


def bleed(img):
    """Fill RGB under transparent pixels from their neighbours (no dark halos)."""
    arr = np.asarray(img, dtype=np.float32)
    alpha = arr[..., 3:4] / 255.0
    pm = Image.fromarray(np.uint8(arr[..., :3] * alpha), 'RGB')
    am = Image.fromarray(np.uint8(alpha[..., 0] * 255), 'L')
    for radius in (2, 6):
        pm_b = np.asarray(pm.filter(ImageFilter.GaussianBlur(radius)), np.float32)
        am_b = np.asarray(am.filter(ImageFilter.GaussianBlur(radius)), np.float32)[..., None] / 255.0
        fill = np.where(am_b > 1e-3, pm_b / np.maximum(am_b, 1e-3), 0)
        empty = arr[..., 3:4] == 0
        arr[..., :3] = np.where(empty, np.clip(fill, 0, 255), arr[..., :3])
    return Image.fromarray(np.uint8(arr), 'RGBA')


def pieces():
    """Every UI image as its own power-of-two RGBA image (1.8.1): name -> Image.
    Each becomes a texture + GUI material 'mods/mdl/ui/<name>' drawn with
    Gui.bitmap (the route proven by texture probe G); the atlas below packs
    the same images for Gui.bitmap_uv."""
    out = {}
    for name in ICONS:
        main, accent = COLOURS[name]
        out[name] = bleed(draw_icon(name, main, accent, False))
        out[name + '_mask'] = draw_icon(name, main, accent, True)
    out['paper'] = paper(256, 128)
    c = corner()
    out['corner'] = c
    out['corner_tr'] = c.transpose(Image.FLIP_LEFT_RIGHT)
    out['corner_bl'] = c.transpose(Image.FLIP_TOP_BOTTOM)
    out['corner_br'] = c.transpose(Image.ROTATE_180)
    out['rule'], out['scan'], out['grain'], out['orient'] = rule(), scan(), grain(), orient()
    return out


def piece_material(name):
    return 'mods/mdl/ui/' + name


def build(parts=None):
    parts = parts or pieces()
    atlas = Image.new('RGBA', (SIZE, SIZE), (255, 255, 255, 0))
    for i, name in enumerate(ICONS):
        atlas.alpha_composite(parts[name], cell_box(i, 0))
        atlas.alpha_composite(parts[name + '_mask'], cell_box(i, 2))
    for key, (x, y, w, h) in DECOR.items():
        atlas.paste(parts[key], (x, y))
    return atlas


def mips(img):
    """RGBA8 mip chain for any power-of-two size, premultiplied box
    filtering (top level first, down to 1x1)."""
    levels = [img]
    arr = np.asarray(img, dtype=np.float32)
    while arr.shape[0] > 1 or arr.shape[1] > 1:
        a = arr[..., 3:4] / 255.0
        pm = np.concatenate([arr[..., :3] * a, arr[..., 3:4]], axis=2)
        if pm.shape[0] > 1:
            pm = (pm[0::2] + pm[1::2]) / 2
        if pm.shape[1] > 1:
            pm = (pm[:, 0::2] + pm[:, 1::2]) / 2
        al = pm[..., 3:4] / 255.0
        rgb = np.where(al > 1e-4, pm[..., :3] / np.maximum(al, 1e-4), 255)
        arr = np.concatenate([np.clip(rgb, 0, 255), pm[..., 3:4]], axis=2)
        levels.append(Image.fromarray(np.uint8(np.round(arr)), 'RGBA'))
    return levels


def cells():
    out = {}
    for i, name in enumerate(ICONS):
        x, y = cell_box(i, 0)
        out[name] = (x + 4, y + 4, 56, 56)
        x, y = cell_box(i, 2)
        out[name + '_mask'] = (x + 4, y + 4, 56, 56)
    for key, box in DECOR.items():
        out[key] = box
    return out


def write_lua(path):
    lines = ['-- Generated by scripts/atlas.py: MDL UI images.',
             '-- cells: atlas UVs (u0, v0, u1, v1; v down) for Gui.bitmap_uv on MATERIAL.',
             '-- pieces: one texture + GUI material per image for Gui.bitmap (murmur64 of mods/mdl/ui/<name>).',
             'local A = {size = %d, cells = {' % SIZE]
    for name, (x, y, w, h) in sorted(cells().items()):
        lines.append("    ['%s'] = {%.6f, %.6f, %.6f, %.6f}," % (name, x / SIZE, y / SIZE, (x + w) / SIZE, (y + h) / SIZE))
    lines.append('}}')
    lines.append('A.pieces = {')
    for name, img in sorted(pieces().items()):
        lines.append("    ['%s'] = {material = '%016x', w = %d, h = %d}," % (name, resource_hash(piece_material(name)), img.width, img.height))
    lines.append('}')
    lines.append('A.ICONS = {' + ', '.join("'%s'" % n for n in ICONS) + '}')
    lines.append("A.NAME = '%s'" % NAME)
    lines.append("A.MATERIAL = '%016x'   -- murmur64(NAME): texture and GUI material" % resource_hash(NAME))
    lines.append('return A')
    Path(path).write_text('\n'.join(lines) + '\n', encoding='utf-8')


if __name__ == '__main__':
    import sys
    if sys.argv[1:] == ['--lua']:
        write_lua(Path(__file__).resolve().parents[1] / 'src' / 'mdl_atlas.lua')
        print('wrote src/mdl_atlas.lua')
    else:
        out = Path(sys.argv[1] if len(sys.argv) > 1 else 'atlas.png')
        build().save(out)
        print('wrote', out)

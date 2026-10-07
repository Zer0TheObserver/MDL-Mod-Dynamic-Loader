"""Build the "MDL Texture Probe" package (debug helper, separate from MDL).

One boot-package patch (data/9ba626afa44a3aa3.patch_0 + .gpu_resources) with
  texture  mdl/textures/probe   256x256 R8G8B8A8_UNORM, 9 mips, original test
                                pattern (gradient, checker, disc, alpha ramp)
  material mdl/textures/probe   copy of the layout of core/performance_hud/gui
                                (192 bytes) with its texture id pointed at the
                                probe texture (draws white: that layout has no
                                texture table)
  material mdl/textures/probe2  (1.1.0) layout of core/performance_hud/debug
                                (160 bytes, with a texture table) pointing at
                                the probe texture

The texture header copies the layout of the game's own 256x256 RGBA8 gui
texture (DDS + DX10 after a 192-byte header whose +8 is 0xFFFFFFFF); the TOC
rows follow deployed texture mods (data align 16, gpu align 64, 1-based index).
MDL debug builds draw it from Settings > Texture probe.
"""
import json
import struct
import sys
import zipfile
from pathlib import Path

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
from archive import resource_hash, sha  # noqa: E402

VERSION = '1.1.0'
GUID = '3f0c6a52-8d1e-4f7b-9a64-2b7e5d0c91a8'
NAME = 'MDL Texture Probe (debug)'
ARCHIVE = '9ba626afa44a3aa3.patch_0'
TEXTURE_TYPE = resource_hash('texture')
MATERIAL_TYPE = resource_hash('material')
PROBE = 'mdl/textures/probe'
SIZE = 256
# core/performance_hud/gui material: 192 bytes, all zero except these words.
PERF_HUD_MATERIAL = {0x00: 0x120, 0x08: 0x18, 0x0C: 0xA4, 0x28: 1, 0x2C: 0x100, 0x30: 0x79DC6624, 0x60: 1,
                     0xA0: 0xBA25DE35, 0xB0: 0x3AA8B87E}
PERF_HUD_TEXTURE_AT = 0xB4      # u64 texture id (default 0xCCF39A02B444FA01)
PERF_HUD_TEXTURE = 0xCCF39A02B444FA01
# core/performance_hud/debug material (160 bytes): the layout with a texture
# table (count 1 at +0x40; entry {u32 0xba25de35, u32 0, u32 slot 0x3aa8b87e,
# u64 texture} at +0x80). core/performance_hud/gui has no texture table
# (+0x40 = 0), which is why the 1.0.0 clone drew plain white and why
# set_texture on it crashed.
PROBE2 = 'mdl/textures/probe2'
DEBUG_MATERIAL = {0x00: 0x120, 0x04: 1, 0x08: 0x18, 0x0C: 0x7C, 0x40: 1, 0x80: 0xBA25DE35, 0x88: 0x3AA8B87E}
DEBUG_TEXTURE_AT = 0x8C


def pattern():
    """RGBA rows, top row first. Original test picture."""
    pixels = bytearray(SIZE * SIZE * 4)
    cx = cy = SIZE / 2
    for y in range(SIZE):
        for x in range(SIZE):
            t = (x + y) / (2 * SIZE - 2)
            r, g, b, a = int(20 + 230 * t), int(150 - 60 * t), int(170 - 150 * t), 255
            if 24 <= x < 88 and 24 <= y < 88:               # crisp 8x8 checker
                on = ((x - 24) // 8 + (y - 24) // 8) % 2 == 0
                r, g, b = (250, 250, 250) if on else (16, 16, 16)
            d2 = (x + 0.5 - cx - 40) ** 2 + (y + 0.5 - cy) ** 2
            if d2 < 48 ** 2:                                  # disc with a ring
                r, g, b = (255, 213, 0) if d2 > 40 ** 2 else (30, 30, 36)
            if y >= SIZE - 40:                                 # alpha ramp
                r, g, b, a = 255, 255, 255, int(255 * x / (SIZE - 1))
            if x < 6 or y < 6 or x >= SIZE - 6 or (y >= SIZE - 46 and y < SIZE - 40):
                r, g, b, a = 8, 10, 14, 255                     # frame
            i = (y * SIZE + x) * 4
            pixels[i:i + 4] = bytes((r, g, b, a))
    return bytes(pixels)


def mips(top):
    levels, size, data = [top], SIZE, top
    while size > 1:
        half = size // 2
        out = bytearray(half * half * 4)
        for y in range(half):
            for x in range(half):
                for c in range(4):
                    s = 0
                    for dy in (0, 1):
                        for dx in (0, 1):
                            s += data[((2 * y + dy) * size + 2 * x + dx) * 4 + c]
                    out[(y * half + x) * 4 + c] = (s + 2) // 4
        levels.append(bytes(out))
        data, size = bytes(out), half
    return levels


def texture_header(levels):
    head = bytearray(192)
    struct.pack_into('<I', head, 8, 0xFFFFFFFF)
    dds = bytearray(148)
    dds[0:4] = b'DDS '
    struct.pack_into('<7I', dds, 4, 124, 0x00021007, SIZE, SIZE, SIZE * 4, 0, levels)
    struct.pack_into('<2I4s', dds, 4 + 72, 32, 4, b'DX10')
    struct.pack_into('<I', dds, 4 + 104, 0x00401008)
    struct.pack_into('<5I', dds, 128, 28, 3, 0, 1, 0)  # R8G8B8A8_UNORM, TEXTURE2D, array 1
    return bytes(head + dds)


def material(texture_id):
    data = bytearray(192)
    for at, value in PERF_HUD_MATERIAL.items():
        struct.pack_into('<I', data, at, value)
    struct.pack_into('<Q', data, PERF_HUD_TEXTURE_AT, texture_id)
    return bytes(data)


def material_with_table(texture_id):
    data = bytearray(160)
    for at, value in DEBUG_MATERIAL.items():
        struct.pack_into('<I', data, at, value)
    struct.pack_into('<Q', data, DEBUG_TEXTURE_AT, texture_id)
    return bytes(data)


def make_patch(resources):
    """resources: [(type, name, data, gpu)] -> (patch, gpu_resources)."""
    resources = sorted(resources, key=lambda r: (r[0], r[1]))
    types = sorted({r[0] for r in resources})
    count = len(resources)
    offset = (72 + 32 * len(types) + 80 * count + 15) & ~15
    body, gpu = bytearray(offset), bytearray()
    rows = bytearray()
    for index, (kind, name, data, gdata) in enumerate(resources, 1):
        goff = 0
        if gdata:
            gpu += b'\0' * (-len(gpu) % 64)
            goff = len(gpu)
            gpu += gdata
        rows += struct.pack('<7Q6I', name, kind, offset, 0, goff, 0, 0, len(data), 0, len(gdata or b''), 16, 64, index)
        body += data
        body += b'\0' * (-len(body) % 16)
        offset = len(body)
    header = struct.pack('<III20sQQ24s', 0xF0000011, len(types), count, b'', offset, 0, b'')
    type_rows = b''.join(struct.pack('<IIQIIII', 0, 0, t, sum(1 for r in resources if r[0] == t), 0, 16, 64) for t in types)
    table = header + type_rows + rows
    body[:len(table)] = table
    return bytes(body), bytes(gpu)


def verify(patch, gpu, levels):
    magic, ntypes, count = struct.unpack_from('<III', patch, 0)
    assert magic == 0xF0000011 and ntypes == 2 and count == 3
    found, rows = {}, []
    for k in range(count):
        row = struct.unpack_from('<7Q6I', patch, 72 + 32 * ntypes + 80 * k)
        rows.append(row)
        if row[0] == resource_hash(PROBE):
            found[row[1]] = row
    second = [r for r in rows if r[0] == resource_hash(PROBE2)][0]
    body2 = patch[second[2]:second[2] + second[7]]
    assert len(body2) == 160 and struct.unpack_from('<Q', body2, DEBUG_TEXTURE_AT)[0] == resource_hash(PROBE)
    tex = found[TEXTURE_TYPE]
    head = patch[tex[2]:tex[2] + tex[7]]
    assert len(head) == 340 and head[0xC0:0xC4] == b'DDS ' and struct.unpack_from('<I', head, 0x140)[0] == 28
    assert struct.unpack_from('<I', head, 0xC0 + 28)[0] == len(levels)
    assert tex[9] == sum(len(x) for x in levels) == 349524 and tex[4] % 64 == 0
    assert gpu[tex[4]:tex[4] + len(levels[0])] == levels[0]
    mat = found[MATERIAL_TYPE]
    body = patch[mat[2]:mat[2] + mat[7]]
    assert len(body) == 192 and struct.unpack_from('<Q', body, PERF_HUD_TEXTURE_AT)[0] == resource_hash(PROBE)
    assert tex[0] == mat[0] == resource_hash(PROBE)


def main():
    from PIL import Image
    build = ROOT / 'build' / 'probe'
    package = build / 'package'
    (package / 'data').mkdir(parents=True, exist_ok=True)
    top = pattern()
    levels = mips(top)
    name = resource_hash(PROBE)
    assert name == 0xE82C57BCEC17B92F
    patch, gpu = make_patch([(TEXTURE_TYPE, name, texture_header(len(levels)), b''.join(levels)),
                             (MATERIAL_TYPE, name, material(name), b''),
                             (MATERIAL_TYPE, resource_hash(PROBE2), material_with_table(name), b'')])
    verify(patch, gpu, levels)
    (package / 'data' / ARCHIVE).write_bytes(patch)
    (package / 'data' / (ARCHIVE + '.gpu_resources')).write_bytes(gpu)
    (package / 'data' / (ARCHIVE + '.stream')).write_bytes(b'')
    preview = Image.frombytes('RGBA', (SIZE, SIZE), top)
    preview.save(package / 'icon.png')
    preview.save(build / 'probe-preview.png')
    description = ('Debug helper for MDL: adds one test texture and material (mdl/textures/probe) to the boot package. '
                   'Changes nothing in the game. Use with an MDL debug build: ESC > MDL Settings > Texture probe.')
    display = f'{NAME} {VERSION}'
    manifest = {'Version': 1, 'Guid': GUID, 'Name': display, 'Description': description, 'IconPath': 'icon.png',
                'Options': [{'Name': display, 'Description': description, 'Include': ['data'], 'Image': 'icon.png'}]}
    (package / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    report = {'name': NAME, 'version': VERSION, 'guid': GUID, 'resource': PROBE, 'hash': f'{name:016X}',
              'material2': PROBE2, 'material2_hash': f'{resource_hash(PROBE2):016X}',
              'patch_sha256': sha(patch), 'gpu_sha256': sha(gpu), 'texture': '256x256 R8G8B8A8_UNORM, 9 mips',
              'material': 'layout of core/performance_hud/gui, texture id -> probe'}
    (package / 'probe-build.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    release = build / f'MDL-Texture-Probe-{VERSION}.zip'
    with zipfile.ZipFile(release, 'w', zipfile.ZIP_DEFLATED) as out:
        for path in sorted(package.rglob('*')):
            if path.is_file():
                info = zipfile.ZipInfo(path.relative_to(package).as_posix(), (2026, 1, 1, 0, 0, 0))
                info.compress_type = zipfile.ZIP_DEFLATED
                out.writestr(info, path.read_bytes())
    print('Built', release, sha(release.read_bytes()))


if __name__ == '__main__':
    main()

"""Stingray texture / GUI material resources and mixed patch archives.

Formats (see RE native_resource_loading FINDINGS §10-11, verified in game with
the MDL texture probe 1.1.0):
  texture   340 bytes: 192-byte header (+8 = 0xFFFFFFFF) + DDS/DX10 header;
            mip chain, linear, top level first, in .gpu_resources
  material  160 bytes, layout of core/performance_hud/debug: texture table
            count 1 at +0x40, entry {0xba25de35, 0, slot 0x3aa8b87e, u64 id}
            at +0x80. GUI materials without a texture table draw plain white.
"""
import struct

from archive import TYPE as LUA_TYPE, resource_hash

TEXTURE_TYPE = resource_hash('texture')
MATERIAL_TYPE = resource_hash('material')
GUI_MATERIAL = {0x00: 0x120, 0x04: 1, 0x08: 0x18, 0x0C: 0x7C, 0x40: 1, 0x80: 0xBA25DE35, 0x88: 0x3AA8B87E}
GUI_TEXTURE_AT = 0x8C


def rgba_texture(width, height, levels):
    """Texture resource for an R8G8B8A8_UNORM 2D texture with `levels` mips."""
    head = bytearray(192)
    struct.pack_into('<I', head, 8, 0xFFFFFFFF)
    dds = bytearray(148)
    dds[0:4] = b'DDS '
    struct.pack_into('<7I', dds, 4, 124, 0x00021007, height, width, width * 4, 0, levels)
    struct.pack_into('<2I4s', dds, 4 + 72, 32, 4, b'DX10')
    struct.pack_into('<I', dds, 4 + 104, 0x00401008)
    struct.pack_into('<5I', dds, 128, 28, 3, 0, 1, 0)
    return bytes(head + dds)


def gui_material(texture_id):
    data = bytearray(160)
    for at, value in GUI_MATERIAL.items():
        struct.pack_into('<I', data, at, value)
    struct.pack_into('<Q', data, GUI_TEXTURE_AT, texture_id)
    return bytes(data)


def make_mixed_archive(lua, extra):
    """Patch archive with Lua resources (same rows as archive.make_archive:
    alignment 16/16, 0-based index) plus `extra` [(type, name, data, gpu)]
    rows (alignment 16/64, gpu data in the returned .gpu_resources bytes).
    Rows are grouped by type in ascending type order, by name within a type."""
    rows_in = [(LUA_TYPE, name, data, b'') for name, data in lua.items()] + list(extra)
    rows_in.sort(key=lambda r: (r[0], r[1]))
    types = sorted({r[0] for r in rows_in})
    count = len(rows_in)
    offset = (72 + 32 * len(types) + 80 * count + 15) & ~15
    body, gpu, rows = bytearray(offset), bytearray(), bytearray()
    for index, (kind, name, data, gdata) in enumerate(rows_in):
        goff = 0
        if gdata:
            gpu += b'\0' * (-len(gpu) % 64)
            goff = len(gpu)
            gpu += gdata
        gpu_align = 16 if kind == LUA_TYPE else 64
        rows += struct.pack('<7Q6I', name, kind, offset, 0, goff, 0, 0, len(data), 0, len(gdata or b''), 16, gpu_align, index)
        body += data
        body += b'\0' * (-len(body) % 16)
        offset = len(body)
    header = struct.pack('<III20sQQ24s', 0xF0000011, len(types), count, b'', offset, 0, b'')
    type_rows = b''.join(struct.pack('<IIQIIII', 0, 0, t, sum(1 for r in rows_in if r[0] == t), 0, 16,
                                     16 if t == LUA_TYPE else 64) for t in types)
    table = header + type_rows + rows
    body[:len(table)] = table
    return bytes(body), bytes(gpu)

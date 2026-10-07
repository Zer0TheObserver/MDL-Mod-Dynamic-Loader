"""Build MDL (Mod Dynamic Loader) into an Arsenal / HD2MM package.

Package layout (one archive, data/9ba626afa44a3aa3.patch_0):
  core/wwise/lua/wwise_flow_callbacks  original Wwise callbacks + MDL startup
                                       coordinator (BSL API 1 compatible)
  mods/mdl/runtime                     plaintext declared addon (HD2-Addon), so
                                       Bingus Shared Loader can also start MDL
                                       when BSL wins the Wwise resource.

Inputs:
  MDL_LUAJIT              LuaJIT built from dependencies.json commit, non-GC64
  MDL_VANILLA_CALLBACKS   vanilla wwise_flow_callbacks resource (.lua.main); if
                          absent, extracted from a Bingus Shared Loader v18
                          release ZIP given by MDL_BSL_RELEASE (verified by SHA-256)
"""
import hashlib
import shutil
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import zipfile

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
from archive import ARCHIVE, TYPE, make_archive, resource_hash, sha  # noqa: E402
from strip_lua import strip  # noqa: E402
import atlas  # noqa: E402
from texture import MATERIAL_TYPE, TEXTURE_TYPE, gui_material, make_mixed_archive, rgba_texture  # noqa: E402

NAME = 'MDL - Mod Dynamic Loader'
VERSION = '1.8.7'
GUID = '761188b2-c45b-4607-9241-f89ca221c47b'
RUNTIME = 'mods/mdl/runtime'
ATLAS = atlas.NAME
CALLBACK_PATH = 'core/wwise/lua/wwise_flow_callbacks'
CALLBACK_SHA = '05BBF52978028758B39F5B91A30A695D20069CEABD774D88755F0582A296BEC9'
CALLBACK_LENGTH = 10263
# Both editions carry the live resource switch (mdl_reslab) and the
# localisation (mdl_i18n + built-in languages in mdl_lang); MDL_DEBUG=1 adds
# the Resource Lab pages, full package logging and the DirectStorage tools.
RUNTIME_MODULES = ('mdl_platform', 'mdl_json', 'mdl_logs', 'mdl_manager', 'mdl_library', 'mdl_image', 'mdl_native_ui', 'mdl_menu',
                   'mdl_nativetab', 'mdl_reslab', 'mdl_i18n', 'mdl_lang', 'mdl_glyphs', 'mdl_atlas', 'mdl_anim', 'mdl_probe', 'mdl_memory', 'mdl_panel')
# Debug-only modules: left out of the player build (declared as nil there).
DEBUG_MODULES = ('mdl_probe',)
# MDL_RELEASE=1: public build. Shipped Lua carries no comments (verified to
# compile to identical bytecode), the offline tests also run against the
# stripped sources, and the package gets the player README.
RELEASE = os.environ.get('MDL_RELEASE') == '1'
# MDL_DEBUG=1: debug build with the Resource Lab (route A experiment for live
# resource mods). Never combined with a release build.
DEBUG = os.environ.get('MDL_DEBUG') == '1'
if RELEASE and DEBUG:
    raise SystemExit('MDL_RELEASE and MDL_DEBUG are exclusive')
BUILD = ROOT / 'build' / 'release' if RELEASE else ROOT / 'build' / 'debug' if DEBUG else ROOT / 'build'
TAG = VERSION + ('-debug' if DEBUG else '')
LUA = Path(os.environ.get('MDL_LUAJIT', ROOT / 'tools/LuaJIT/src/luajit'))
DESCRIPTION = ('MDL - Mod Dynamic Loader: load, unload and reload Lua mods in-game and view your Arsenal/HD2MM '
               'library from an "MDL Settings" tab in the ESC menu. Script addons run live without Deploy; resource mods '
               '(models, textures) switch on and off without restart and apply on the next mission or back on the ship. '
               'English and Simplified Chinese built in; every text can be translated with a JSON file. '
               'Replaces Bingus Shared Loader - do not install both; mods that require BSL (API 1) work with MDL. '
               'Place Lua mods in %LOCALAPPDATA%\\MDL\\Helldivers2\\Mods.')


def run(args, **kwargs):
    result = subprocess.run([str(a) for a in args], capture_output=True, text=True, **kwargs)
    if result.returncode:
        raise RuntimeError(result.stdout + result.stderr)
    return result.stdout


def read_resources(archive):
    """Returns {name_hash: resource_bytes} for Lua entries of a patch archive."""
    magic, types, count = struct.unpack_from('<III', archive, 0)
    assert magic == 0xF0000011, 'not a patch archive'
    table = 72 + 32 * types
    result = {}
    for index in range(count):
        row = archive[table + 80 * index: table + 80 * index + 80]
        name, kind, offset = struct.unpack_from('<QQQ', row, 0)
        length = struct.unpack_from('<I', row, 56)[0]
        if kind == TYPE:
            result[name] = archive[offset: offset + length]
    return result


def vanilla_callbacks():
    path = os.environ.get('MDL_VANILLA_CALLBACKS')
    if path:
        data = Path(path).read_bytes()
    else:
        release = os.environ.get('MDL_BSL_RELEASE')
        if not release:
            raise SystemExit('Set MDL_VANILLA_CALLBACKS or MDL_BSL_RELEASE (Bingus-Shared-Loader-v18.zip)')
        archive = zipfile.ZipFile(release).read('data/' + ARCHIVE)
        wrapper = read_resources(archive)[resource_hash(CALLBACK_PATH)]
        body = wrapper[8:8 + struct.unpack_from('<I', wrapper, 0)[0]]
        start = body.find(b'\x1bLJ\x02', 1)
        data = struct.pack('<II', CALLBACK_LENGTH, 2) + body[start:start + CALLBACK_LENGTH]
    if sha(data) != CALLBACK_SHA or struct.unpack('<II', data[:8]) != (CALLBACK_LENGTH, 2):
        raise ValueError('Unsupported vanilla Wwise callbacks (expected SHA-256 ' + CALLBACK_SHA + ')')
    return data


def source(name):
    text = (ROOT / 'src' / (name + '.lua')).read_text(encoding='utf-8')
    return strip(text) if RELEASE else text


def verify_stripped(env):
    """Each stripped module must compile to the same bytecode as its source.

    Needs MDL_LUAJIT_VERIFY: the same LuaJIT commit built with
    XCFLAGS="-DLUAJIT_DISABLE_GC64 -DLUAJIT_SECURITY_PRNG=0". The default build
    seeds string hashing randomly, so template-table key order (and thus the
    bytecode bytes) differs between runs; the unseeded build with the GC
    stopped is deterministic.
    """
    verify = Path(os.environ.get('MDL_LUAJIT_VERIFY', ''))
    if not verify.is_file():
        raise SystemExit('Release builds need MDL_LUAJIT_VERIFY (deterministic LuaJIT, see verify_stripped)')
    venv = dict(os.environ, LUA_PATH=str(verify.parent / '?.lua') + ';;')
    check = BUILD / 'strip-check'
    check.mkdir(parents=True, exist_ok=True)
    stripped_src = BUILD / 'src'
    stripped_src.mkdir(exist_ok=True)
    for path in sorted((ROOT / 'src').glob('*.lua')):
        text = path.read_text(encoding='utf-8')
        (stripped_src / path.name).write_text(strip(text), encoding='utf-8', newline='\n')
        # GC stopped while compiling: otherwise collection timing (which
        # depends on the source size) can change string interning and so
        # table-template key order in the bytecode.
        dumper = ROOT / 'scripts' / 'dump_stopped_gc.lua'
        run([verify, dumper, path, check / (path.stem + '.a')], env=venv)
        run([verify, dumper, stripped_src / path.name, check / (path.stem + '.b')], env=venv)
        if (check / (path.stem + '.a')).read_bytes() != (check / (path.stem + '.b')).read_bytes():
            raise ValueError('comment stripping changed the code of ' + path.name)
    return stripped_src


def runtime_source():
    parts = ['-- HD2-Addon: ' + RUNTIME + '\n']
    if not RELEASE:
        parts.append('-- MDL - Mod Dynamic Loader ' + TAG + ' runtime. Plaintext so addon discovery can read the declaration.\n')
    parts.append("local MDL_VERSION = '" + TAG + "'\n")
    parts.append('local MDL_DEBUG = ' + ('true' if DEBUG else 'false') + '\n')
    for name in RUNTIME_MODULES:
        if name in DEBUG_MODULES and not DEBUG:
            parts.append('local ' + name + ' = nil\n')
            continue
        parts.append('local ' + name + ' = (function()\n' + source(name) + '\nend)()\n')
    parts.append(source('mdl_runtime'))
    return ''.join(parts)


def bootstrap(stock_bytes):
    literal = '"' + ''.join(f'\\{byte:03d}' for byte in stock_bytes) + '"'
    # Same contract as Bingus Shared Loader: stock callbacks first with all
    # arguments and results preserved; stock errors propagate unretried.
    return ('local function initialize_addons()\n'
            'local addon_discovery = (function()\n' + source('discover') + '\nend)()\n'
            'local jit_budget = (function()\n' + source('jit_budget') + '\nend)()\n'
            + source('mdl_boot') + '\nend\n'
            'return (function(...) initialize_addons(); return ... end)'
            f'(assert(loadstring({literal}, "@vanilla_wwise_callbacks"))(...))\n')


def main():
    BUILD.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, LUA_PATH=str(LUA.parent / '?.lua') + ';;')
    test_src = verify_stripped(env) if RELEASE else ROOT / 'src'
    callback = vanilla_callbacks()
    wrapper = BUILD / 'callbacks.wrapper.lua'
    wrapper.write_text(bootstrap(callback[8:]), encoding='utf-8', newline='\n')
    run([LUA, '-bsdW', wrapper, BUILD / 'callbacks.ljbc'], env=env)
    bytecode = (BUILD / 'callbacks.ljbc').read_bytes()
    if bytecode[:5] != callback[8:13]:
        raise ValueError('LuaJIT bytecode mode differs from the game')
    callbacks_resource = struct.pack('<II', len(bytecode), 2) + bytecode

    runtime = runtime_source().encode('utf-8')
    (BUILD / 'mdl_runtime.lua').write_bytes(runtime)
    run([LUA, '-bsdW', BUILD / 'mdl_runtime.lua', BUILD / 'mdl_runtime.check'], env=env)  # syntax check only
    if len(runtime.split(b'\n', 1)[0]) + 1 > 256:
        raise ValueError('Declaration must fit in the first 256 bytes')
    runtime_resource = struct.pack('<II', len(runtime), 2) + runtime

    tests = ''
    for test in ('test_mdl_json.lua', 'test_mdl_manager.lua', 'test_mdl_library.lua', 'test_mdl_panel.lua',
                 'test_mdl_integration.lua', 'test_mdl_packed.lua', 'test_mdl_scroll.lua', 'test_mdl_help.lua', 'test_mdl_menu.lua', 'test_mdl_nativetab.lua', 'test_mdl_reslab.lua', 'test_mdl_i18n.lua', 'test_mdl_theme.lua', 'test_mdl_probe.lua', 'test_mdl_ui_atlas.lua', 'test_mdl_memory.lua', 'test_mdl_launch.lua', 'test_mdl_perf.lua', 'test_discovery.lua', 'test_jit_budget.lua'):
        tests += run([LUA, ROOT / 'tests' / test, test_src, BUILD], env=env)

    # UI atlas (1.8.0): MDL's own icons and theme decorations as one RGBA
    # texture plus a GUI material with a texture table, both named ATLAS.
    generated = ROOT / 'build' / 'mdl_atlas.lua'
    atlas.write_lua(generated)
    if generated.read_text(encoding='utf-8') != (ROOT / 'src' / 'mdl_atlas.lua').read_text(encoding='utf-8'):
        raise SystemExit('src/mdl_atlas.lua is stale: run python3 scripts/atlas.py --lua')
    # Texture UI images are a debug experiment (1.8.2): the player build stays Lua-only.
    parts = atlas.pieces() if DEBUG else {}
    extra = []
    for name, img in sorted(parts.items()):
        lv = atlas.mips(img)
        pid = resource_hash(atlas.piece_material(name))
        extra.append((TEXTURE_TYPE, pid, rgba_texture(img.width, img.height, len(lv)), b''.join(x.tobytes() for x in lv)))
        extra.append((MATERIAL_TYPE, pid, gui_material(pid), b''))
    atlas_id = resource_hash(ATLAS)
    levels = []
    if DEBUG:
        # Debug only: the packed atlas for the Gui.bitmap_uv experiment.
        levels = atlas.mips(atlas.build(parts))
        extra.append((TEXTURE_TYPE, atlas_id, rgba_texture(atlas.SIZE, atlas.SIZE, len(levels)), b''.join(x.tobytes() for x in levels)))
        extra.append((MATERIAL_TYPE, atlas_id, gui_material(atlas_id), b''))
    archive, gpu = make_mixed_archive(
        {resource_hash(CALLBACK_PATH): callbacks_resource, resource_hash(RUNTIME): runtime_resource}, extra)
    # The shipped archive must be discoverable: re-read it like discover.lua does.
    resources = read_resources(archive)
    assert resources[resource_hash(RUNTIME)][8:].startswith(('-- HD2-Addon: ' + RUNTIME + '\n').encode())
    # Row layout check: types ascending, Lua rows keep 16/16, every texture
    # row's gpu range lies in the gpu file, every material names its texture.
    _, ntypes, count = struct.unpack_from('<III', archive, 0)
    rows = [struct.unpack_from('<7Q6I', archive, 72 + 32 * ntypes + 80 * k) for k in range(count)]
    assert [r[1] for r in rows] == sorted(r[1] for r in rows)
    textures = {r[0]: r for r in rows if r[1] == TEXTURE_TYPE}
    materials = [r for r in rows if r[1] == MATERIAL_TYPE]
    assert len(textures) == len(materials) == len(parts) + (1 if DEBUG else 0)
    for r in textures.values():
        assert r[4] % 64 == 0 and r[4] + r[9] <= len(gpu) and r[10:12] == (16, 64)
    for r in materials:
        assert struct.unpack_from('<Q', archive, r[2] + 0x8C)[0] == r[0] and r[0] in textures
    assert all(r[10:12] == (16, 16) for r in rows if r[1] == TYPE)

    package = BUILD / 'package'
    if package.exists():
        shutil.rmtree(package)
    (package / 'data').mkdir(parents=True, exist_ok=True)
    (package / 'data' / ARCHIVE).write_bytes(archive)
    (package / 'data' / (ARCHIVE + '.gpu_resources')).write_bytes(gpu)
    (package / 'data' / (ARCHIVE + '.stream')).write_bytes(b'')
    (package / 'icon.png').write_bytes((ROOT / 'assets/icon.png').read_bytes())
    display = NAME + ' ' + TAG
    description = ('DEBUG BUILD (Resource Lab: live resource mod experiment). ' + DESCRIPTION) if DEBUG else DESCRIPTION
    manifest = {'Version': 1, 'Guid': GUID, 'Name': display, 'Description': description, 'IconPath': 'icon.png',
                'Options': [{'Name': display, 'Description': description, 'Include': ['data'], 'Image': 'icon.png'}]}
    (package / 'manifest.json').write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')
    readme = (ROOT / 'README-release.txt').read_text(encoding='utf-8')
    (package / 'MDL-README.txt').write_text(readme.replace('{VERSION}', TAG), encoding='utf-8', newline='\r\n')
    if DEBUG:
        lab_readme = (ROOT / 'RESOURCE_LAB_zh.txt').read_text(encoding='utf-8').replace('{VERSION}', TAG)
        (package / 'MDL-ResourceLab-README.txt').write_text(lab_readme, encoding='utf-8-sig', newline='\r\n')
    report = {'name': NAME, 'version': TAG, 'guid': GUID,
              'resources': {CALLBACK_PATH: {'hash': f'{resource_hash(CALLBACK_PATH):016X}', 'sha256': sha(callbacks_resource)},
                            RUNTIME: {'hash': f'{resource_hash(RUNTIME):016X}', 'sha256': sha(runtime_resource)}},
              'archive_sha256': sha(archive)}
    if not RELEASE:
        report.update({'vanilla_callbacks_sha256': CALLBACK_SHA, 'offline_tests': tests.strip().splitlines(), 'in_game_verified': False})
    (package / 'MDL-build.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    release = BUILD / f'MDL-Mod-Dynamic-Loader-{TAG}.zip'
    with zipfile.ZipFile(release, 'w', zipfile.ZIP_DEFLATED) as out:
        for path in sorted(package.rglob('*')):
            if path.is_file():
                info = zipfile.ZipInfo(path.relative_to(package).as_posix(), (2026, 1, 1, 0, 0, 0))
                info.compress_type = zipfile.ZIP_DEFLATED
                out.writestr(info, path.read_bytes())
    print(tests.strip())
    print('Built', release, sha(release.read_bytes()))


if __name__ == '__main__':
    main()

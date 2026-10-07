# Third-party inputs

- `src/discover.lua`, `src/jit_budget.lua` and the registry part of `src/mdl_boot.lua` come from
  Bingus Shared Loader v18 source (CowboyBingus). That source states no repository-wide licence has
  been selected; the public release was discussed with the author beforehand (2026-09-29). Credited in
  the player README. These parts are not covered by this repository's MIT licence unless
  their author agrees.
- `scripts/archive.py` (archive encoding, MurmurHash64A) is from the same source.
- The build embeds the game's original `core/wwise/lua/wwise_flow_callbacks` bytecode (SHA-256
  05BBF529…BEC9), extracted from your own install or from a BSL v18 release ZIP; it is not stored here.
- LuaJIT (MIT), commit in `dependencies.json`, compiles the startup resource in non-GC64 mode.
- Manager formats: HD2MM (teutinsa/Helldivers2ModManager, `manifest.json` V1, `enabled.json`) and
  HD2 Arsenal 0.36 `hd2a_data.json`, read-only.

# AGENTS.md

"Until there were none" - a Playdate horde-survival shooter written in Zig (Windows dev environment). The player moves around and a crank-driven gatling gun auto-targets enemies.

## Toolchain
- Zig 0.17.0 (`zig version`). Note 0.17 differs a lot from older Zig: no `@cImport`, no `std.build`, single-argument cast builtins (`@intCast(x)`, `@floatFromInt(x)`, `@splat(x)`), `callconv(.c)`, `std.Random`.
- Arm GNU toolchain 11.3.1 (`arm-none-eabi`), Playdate SDK 3.1.2.
- Required environment variables:
  - `PLAYDATE_SDK_PATH` - SDK root (e.g. `C:\Users\<you>\Documents\PlaydateSDK`)
  - `ARM_TOOLKIT_PATH` - Arm toolchain root (e.g. `D:\11.3 rel1`)
- `pdc` (from `$PLAYDATE_SDK_PATH\bin`) must be on `PATH`; the build shells out to it.
- Asset scripts only: Python 3 with Pillow (`pip install pillow`; `drop_sprites.py` needs it and `convert_raw.py` imports that), ImageMagick for `convert_raw.py`, and Tiled (`C:\Program Files\Tiled`) to edit and export maps.

## Commands
| Task | Command |
|------|---------|
| Build everything + package `zig-out/until-none.pdx` | `zig build` |
| Release builds | `zig build -Doptimize=ReleaseSmall` (or `ReleaseFast`) |
| Run in the simulator | `zig build run-sim` |
| Install and run on a connected device | `zig build run-device -Doptimize=ReleaseSmall` |
| Run unit tests | `zig build test` |
| Debug build that starts with the player invincible | `zig build -Dinvincible=true` (`tools/sim.ps1 -Invincible`) |

`zig build` produces:
- `zig-out/lib/pdex.dll` - simulator build (host target)
- `zig-out/bin/pdex.elf` -> `zig-out/lib/pdex.elf` - device build (thumb, Cortex-M7, hard-float). `pdc` converts it into the pdx's relocatable `pdex.bin`
- `zig-out/until-none.pdx` - package made by `pdc` from everything in `zig-out/lib` (both the DLL and the bin, plus `pdxinfo`, `images/`, `levels/`)

### Simulator
`zig build run-sim` builds, packages and launches `PlaydateSimulator.exe` with the pdx. Alternatively open `zig-out/until-none.pdx` in the simulator manually.

### Running, screenshots and logs (for agents)
`powershell -NoProfile -ExecutionPolicy Bypass -File tools/sim.ps1 [-Seconds 8] [-NoBuild]` stops any running simulator (it locks `pdex.dll`), builds, launches the simulator on `zig-out/until-none.pdx`, waits, then reports:
- `logs/screenshot.png` - screenshot of the simulator window (via `PrintWindow`, works while the window is in the background). View it with the Read tool.
- `logs/sim-stderr.log` / `logs/sim-stdout.log` - simulator process output. **A game panic shows up in stderr** (e.g. `thread N panic: KeyOutOfRange`) and the simulator then exits; the script says `SIMULATOR EXITED` in that case.
- the game's own log (below).
The simulator is left running afterwards; stop it with `Stop-Process -Name PlaydateSimulator`.

Game logging: `debugLog(fmt, args)` in `src/main.zig` (Debug builds only) writes to the in-simulator console (the `>_` button) and appends to `log.txt` in the game's data folder, `%PLAYDATE_SDK_PATH%\Disk\Data\com.downie.next\log.txt` (truncated on every start). A status line (`wave` = number:`lull`/`wave`, enemies, `on_screen` = enemies in view (what the player sees of a wave; a wave's climax should put it in double figures), health, score, `combo`, player pos, `bullets` = ammo left, `reload` = seconds of an ammo pickup reload left, `drops` live and the `near`est one's kind and position, `aim` direction, whether there is a `target`, `sim_ms_max` = slowest `game.tick` in the last second) is written once a second, and a `run over` line (wave, score, best, time, kills, best combo) when the player dies. `logToConsole` output is NOT available on stdout/stderr, hence the file. Release builds do no logging.

Notes:
- Debug builds fill `undefined` memory with `0xaa`, which exposes use-after-remove bugs that Release hides (e.g. reading entity data after it was swap-removed, or keeping frame arena memory past the frame; `Arena.reset` also refills with `0xaa`). Panics report the error name via `@errorName`.
- The simulator has its own screenshot/recording buttons (camera icon) and `Ctrl+S`-style capture, but the script's capture is easier to automate.

### Driving the game with input (for agents)
With the game running (`tools/sim.ps1 -Seconds 4`), `tools/sim-input.ps1` posts button / D-pad / crank input to the simulator window and can screenshot or print the game log between steps:

```
powershell -NoProfile -ExecutionPolicy Bypass -File tools/sim-input.ps1 -Steps "right:1000,wait:800,log:1,a:1300,crank:120,wait:800,log:1,shot:after"
```
Steps run in order, comma separated:
| Step | Meaning |
|------|---------|
| `up` `down` `left` `right` `a` `b` `[:ms]` | hold that button for ms (default 300) |
| `crank:<degrees>` | turn the crank, positive = forward; 30 degrees (`FIRE_ANGLE_DELTA`) fires one bullet |
| `wait:<ms>` | pause |
| `shot[:name]` | screenshot to `logs/<name>.png` (default `screenshot`) |
| `log[:n]` | print last n lines of the game log (default 5) |

How it works / gotchas:
- Buttons are Windows key messages posted to the simulator window (no focus needed). Simulator bindings: arrows = D-pad, **`A` key = B button, `S` key = A button**. Arrow keys must carry the "extended key" bit (handled in `tools/sim-common.ps1`).
- The crank is the mouse wheel: each notch is 4 degrees (`$CrankDegreesPerNotch`, calibrated against `getCrankAngle`; the log's `crank=` field confirms it).
- Verify results from the log line (`pos`, `bullets`, `health`, `score`, `crank`, `drops`/`near`), not only screenshots. To test a pickup, walk to the `near` position (drops never appear within `DROP_MIN_PLAYER_DIST` of the player, so usually just off screen). World +y is up: `down` decreases y. Holding A or B fires every `FIRE_BUTTON_DELAY` (0.25s).
- The player dies if left alone (waves come in and close in; contact damage is 5 per touch). The game then freezes on the run end screen until A or B is pressed (after `GAME_OVER_INPUT_DELAY`; send an `a` step), which starts a fresh run (health 100, bullets 80, no drops, wave 0, position 0,0). This can confuse a long test: keep sequences short or check `health`. The first wave starts after `FIRST_WAVE_DELAY` (3s). The best score is saved to `best.bin` in the game's data folder; delete it for a fresh best. Each `sim-input.ps1` call takes a few seconds to start while the game keeps running, so to steer across several calls (e.g. walking to a drop) run `tools/sim.ps1 -Invincible`: enemies still bump the player but do no damage, the HUD shows `INVINCIBLE` and the log line `invincible=true`. In any Debug build it is also an `Invincible` checkmark in the system menu.
- The simulator window takes ~3s to appear; use `-Seconds 4` or more with `tools/sim.ps1` if you want the launch screenshot.
- Don't pipe `tools/sim.ps1` into something that waits for EOF (e.g. `| tail`): the simulator inherits the pipe and stays alive, so the command never returns. Redirect to a file (`> out.txt`) or use `| head -1`.
- Debug builds also reach `logs/sim-stdout.log` (console output, flushed late); prefer the game's `log.txt` for timing.
- Helpers (`Send-SimKey`, `Send-SimCrank`, `Save-SimScreenshot`) live in `tools/sim-common.ps1` for writing custom scenarios.

### Device
With the Playdate connected via USB, `zig build run-device -Doptimize=ReleaseSmall` builds, installs the pdx with `pdutil` and runs it. Add `-Dport=COM3` to name the serial port if pdutil can't find the device by itself. `pdutil install` ejects the device, so the run step retries `pdutil run` for up to 20s until the device reappears. Windows only (uses `pdutil.exe` and PowerShell). Prefer `ReleaseSmall` or `ReleaseFast`; the Debug device build is large.

Manually, the equivalent is:
1. Build `zig build` (ideally `-Doptimize=ReleaseSmall` or `ReleaseFast`).
2. Put the Playdate in Data Disk mode or connect via USB, then use the SDK's `pdutil`:
   ```
   "%PLAYDATE_SDK_PATH%\bin\pdutil.exe" <COM port> install zig-out\until-none.pdx
   "%PLAYDATE_SDK_PATH%\bin\pdutil.exe" <COM port> run /Games/until-none.pdx
   ```
   (Or sideload the `.pdx` through play.date/sideload, or drag it to the simulator's "Upload Game to Device".)

### Tests
`zig build test` compiles `src/tests.zig` once for the host and runs every test exactly once. Output is silent on success; add `--summary all` to see the result, or run `zig test src/tests.zig` directly to see each test's name.
- **Unit tests** live in `test` blocks at the bottom of the file they test, so they can reach private functions and stay next to the behaviour they document. Name them `"[module] what it checks"`.
- **Scenario tests** that drive the whole simulation through `game.tick` (worst-case enemy/bullet counts, gameplay outcomes) live in `src/tests/scenarios.zig`. Anything that spans several systems goes there.
- `src/tests.zig` imports every module that doesn't need the Playdate C API. **Add new modules (and new files under `src/tests/`) to it.** `main.zig` and `renderer.zig` use the Playdate API and are not unit tested.

### After implementing a body of work
Before calling a change done (and before committing or opening a PR), run all of these and report the results:
1. **Format**: `zig fmt src build.zig` (formats every source file in place; `zig fmt --check src build.zig` lists any that aren't formatted). `src/bitmap_descs.zig` is regenerated by `convert_raw.py`, so re-run `zig fmt` after regenerating it.
2. **Tests**: `zig build test --summary all`. All must pass. Add tests for new systems/data, and add any new module to `src/tests.zig`.
3. **Builds**: `zig build` (Debug) and `zig build -Doptimize=ReleaseSmall` (the device link), since Release removes asserts and safety checks.
4. **Performance**:
   - Run the game with `tools/sim.ps1` and a short `tools/sim-input.ps1` sequence. Check stderr for panics, and in the game log status line check `frame_mem` (frame arena high-water mark), `drawn` (sprites in the draw list) and `sim_ms_max`.
   - Run a worst-case stress test: temporarily set `WAVE_PEAK_SCALE` to 10 and `WAVE_PACK_INTERVAL` to 0.1 in `tweak_constants.zig` and run `tools/sim.ps1 -Invincible` until the log shows `enemies` at `MAX_ENEMIES`, crank to fire, and check for panics and that `frame_mem`/`drawn` stay within budget. Revert the constants afterwards.
   - Check that new hot loops and per-frame data respect the cache rules under "Target hardware" (add a compile-time budget check where counts are constant).
   - For anything that could affect frame time, check the FPS counter on device (top left) at worst case. The simulator alone isn't evidence; say so if a device wasn't available.
5. Update this file if commands, layout or conventions changed.

## Layout
- `build.zig` - build graph (see below)
- `src/main.zig` - platform layer and entry point. Exports `eventHandler` (called by the Playdate runtime), owns the memory arenas, the `GameState`, the loaded level and assets; `gameInit` loads everything, and `gameUpdateWrapper` runs each frame: reset frame arena -> read input -> `game.tick` (only in the `playing` phase) -> `renderer.render`. When the player dies it switches to the `game_over` phase (the frozen last frame under the run end screen) and saves a new best score; A/B or Restart (menu) start a fresh run at a frame boundary. Owns the save (`save_data.zig`): read once at init, written only when a run ends with a new best.
- `src/game.zig` - the orchestrator. `tick` runs every simulation system in one fixed, linear order on the data it is given. No Playdate API, so it is host-testable.
- `src/game_state.zig` - all mutable simulation data: `Input`, `Player`, `Enemies`, `Bullets` (plus the `ammo` count and the pickup `reload_timer`), `Drops` and `Popups` (combo messages in the world; when full a new one replaces the oldest) (fixed-capacity structure-of-arrays), `Trigger`, `Spawner` (the wave state machine: phase, wave number, timers, sides), `Hit`, `DropKind`, `PopupKind`. `Player` also holds the run stats (`kills`, `best_streak`) and `GameState` the `run_time`.
- `src/save_data.zig` - the `best.bin` record (magic + u64 best score), encode/decode only (main does the file IO).
- `src/tests.zig` - the single test entry point; `src/tests/scenarios.zig` - whole-simulation scenario tests.
- `src/memory.zig` - `Arena`, a bump allocator over a fixed buffer that panics with its name when full.
- `src/playdate.zig` + `src/playdate_c.h` - Playdate C API (`pd_api.h`) translated via the build's translate-c step and exposed as `@import("playdate").api`. The build supplies it to `main.zig` as the `playdate_c` module import.
- Systems are stateless functions that take exactly the data they work on (no module-level state, no system imports another):
  - `player_movement_system.zig`, `enemy_movement_system.zig` (flow field steering, direct seek up close, bump-back, wall sliding), `enemy_separation_system.zig` (pushes overlapping enemy pairs apart and keeps them on a ring around the player; brute force over all pairs, runs right after movement), `enemy_spawn_system.zig` (waves: a lull counts down to each wave. A wave first holds out for `hold` seconds, spawning packs (every `WAVE_PACK_INTERVAL` at most) to keep the enemies alive near a target that climbs from `WAVE_START_FRACTION` of its `peak` to all of it, so the pressure is sustained and killing faster only brings the next pack; then the rest must be cleared (to `WAVE_CLEAR_LEFT`) to survive it, or the next wave follows straight away after `WAVE_CLEAR_MAX_TIME`. Packs drop together on one cell in a ring just off screen (`SPAWN_MIN_PLAYER_DIST` to `SPAWN_RING_MAX_DIST`) in the wave's direction(s), one more direction every `WAVES_PER_EXTRA_SIDE` waves, falling back to the map's edge band on those sides; spawning only at the map's edge let the gun pick enemies off as they walked into view and the screen never filled. Tuning is the `WAVES` table in `tweak_constants.zig` (hold, peak, pack, lull: build up, step back, peak, breather), repeated bigger past its end; no runtime `pow`)
  - `drop_system.zig` (ammo and health drops: every `DROP_INTERVAL` while fewer than `MAX_DROPS` are live, put one on a random free level drop point at least `DROP_MIN_PLAYER_DIST` away; the point decides small/large, ammo vs health leans towards what the player is short of; drops expire after `DROP_LIFETIME`. `collect` picks up what the player walks over: health heals, ammo adds and starts a reload (longer for large) during which the gun can't fire; drops the player has no room for are left lying)
  - `bullet_system.zig` (fire with spread and a turning gatling barrel, never with an empty gun or during a pickup reload (there is no automatic reload: ammo only comes from drops), move with walls stopping bullets (sampled every half cell so nothing tunnels), bullet/enemy collisions; a comptime check keeps `BULLET_MAX_SPEED` from stepping over an enemy in one 50 FPS frame), `combat_system.zig` (apply bullet hits and enemy contact damage, keep the combo (`kill_streak`) and add its popups: `xN` per kill, a big `COMBO xN!` at milestones, `COMBO LOST` when a combo of `COMBO_LOST_MIN`+ breaks), `firing_system.zig` (crank/button trigger), `auto_targetting_system.zig` (only enemies on screen with a clear line of sight from the player's feet; ranked by distance scaled down for enemies ahead of the player's movement, damaged ones (finish a kill before starting another) and ones along the current aim, `TARGET_*` constants; line of sight tested best first, at most `TARGET_MAX_LOS_TESTS` a frame; with nothing in sight the gun aims the way the player moves or keeps its last aim)
  - `renderer.zig` (loads `Assets`, depth sorting by screen y, bullets as dithered comet tracers, combo popups rising above where they happened, then the HUD), `hud.zig` (screen space text, never inverted by the hit flash: boxed labels in the Roobert system fonts so they read over the horde; the HUD (wave or countdown, health, score, best or NEW BEST!, combo, ammo), the wave start / survived banners, the popups' text and the run end screen), `animation.zig` (facing-direction frames, walk bob, `dropBounce`/`dropSheenFrame` (drops hop above a ground shadow the renderer draws, with a glint every `DROP_SHEEN_PERIOD_MS`), `bulletTracer`: bullets are simulated from the player's feet and only drawn from the gun's muzzle at `GUN_HEIGHT_PX`, the offset fading out over `MUZZLE_CONVERGE_DIST`)
- Data/helpers: `collision_grid.zig` (out of bounds counts as blocked; `cellIndex`/`cellCentre`/`worldBounds` are the one world <-> cell mapping; `isSegmentClear` is the line of sight test, sampled at `sampleLength` like bullets), `flow_field.zig` (enemy pathfinding: a Dijkstra field over the grid leading to the player's cell, rebuilt when the player changes cell at `FLOW_FIELD_CELLS_PER_FRAME` cells per frame into a back buffer, then swapped; buffers live in the level arena), `level_loader.zig` (`load` reads a level file into the level arena, `parse` validates and decodes it, lists the edge spawn cells grouped by `MapSide` and reads the drop points), `maths.zig`, `graphics_coords.zig` (world metres -> screen pixels), `tweak_constants.zig` (gameplay tuning), `bitmap_descs.zig` (**autogenerated** by `convert_raw.py`).
- Assets: `images/` (1-bit sprites/tables, copied into the pdx), `levels/` (binary level files), `pdxinfo`. Sources: `raw-images/`, `raw-levels/`, `map-tiles/` (Tiled maps).
- `convert_raw.py <imagemagick path>` - converts `raw-images/` to 1-bit sprites in `images/` and regenerates `src/bitmap_descs.zig`. `convert_tilemaps.py` - converts Tiled JSON in `map-tiles/` to `levels/*.bin`: the tile layer (blocked cells and their sprites) and the `drops` object layer (point objects named `small` or `large`, which must sit on floor cells). Export the JSON from the `.tmx` with Tiled's CLI: `"C:\Program Files\Tiled	iled.exe" --export-map json map-tiles/lvl1.tmx map-tiles/lvl1.json`. Level binary: `u8` width, height, cell width px, cell height px, drop point count; per drop point `u16` cell, `u8` size; then per object `u16` cell, `u8` sprite id to the end.
- `drop_sprites.py` - the ammo/health drop sprites, hand authored as 1-bit pixel grids (`raw-images/` is git-ignored, so the source lives in this script). Each grid cell is drawn 2x2 with dither and the 1px rim at final resolution, plus `SHEEN_FRAMES` glint frames per kind; it writes `DROP_FRAMES_PER_KIND` into `bitmap_descs.zig` via `convert_raw.py`. `convert_raw.py` calls it; run `python drop_sprites.py` on its own to rewrite just `images/drops-table-*.png`.

## Build graph notes (non-obvious things in `build.zig`)
- Two targets compile the same `src/main.zig`: the simulator DLL (native, links libc) and the device object (freestanding thumb) which is linked with the SDK's `buildsupport/setup.c` into `pdex.elf`. Like the SDK's `common.mk`, it is linked at address 0 with `--emit-relocs` (so it can't be stripped) and handed to `pdc`, which writes `pdex.bin` (starts with a `Playdate PDX` header). Shipping a raw `objcopy` of the elf instead makes the device fail with "CAPI handler function wasn't located in loaded data".
- Device specifics that were needed to link: FPU feature `fp_armv8d16sp` must be enabled (Zig's `cortex_m7` model has none), `no_movt` must be enabled (pdc only relocates `R_ARM_ABS32` literals; LLVM's default `MOVW`/`MOVT` address pairs are left pointing at link-time addresses and crash on launch; check with `arm-none-eabi-readelf -r zig-out/lib/pdex.elf`), unwind tables are off (otherwise newlib's malloc clashes with the SDK's; anything else that pulls in newlib's malloc does the same, e.g. `@mod`/`@rem` on floats calls `fmodf`, so a `duplicate symbol: _malloc_r` link error means some new code needs libc; prefer tables or integer maths to runtime `pow`/`exp`/`log` in game code), the entry symbol is `eventHandlerShim`, and the linker script is wrapped so `SEARCH_DIR`s for the Arm libs are added (lld is not passed `-L` for freestanding).
- translate-c on the device needs a `wint_t` typedef shim, which lives in `src/playdate_c.h`.
- The device game code defines `TARGET_SIMULATOR` (historical; `TARGET_PLAYDATE` may have been intended).
- Whatever is in `zig-out/lib` ends up in the pdx, so stale files there get shipped; delete `zig-out` if in doubt.
- Occasional `unable to load "<std file>": Unexpected` errors from the compiler are transient - just re-run.

## Target hardware (design against Rev A, the weakest)
| | Spec | What it means for the code |
|---|---|---|
| CPU | Rev A: STM32F746, Arm Cortex-M7 at 168 MHz. Rev B: a different vendor's Cortex-M7 at the same clock (cache sizes unconfirmed, assumed no smaller) | Single core, in-order-ish, no SIMD worth relying on. Budget per frame at 50 FPS is ~20ms, shared with the OS and the display update |
| FPU | Single precision only (`fp_armv8d16sp`) | Use `f32` everywhere. Any `f64` maths (including `std.math` calls on `f64` or float literals that resolve to `f64` at runtime) falls back to slow software emulation |
| L1 data cache | **4 KB**, 32 byte lines | Constants in `src/memory.zig`: `L1_DCACHE_SIZE`, `CACHE_LINE_SIZE`, `HOT_SET_BUDGET` (2 KB). See the rules below |
| L1 instruction cache | **4 KB** | The frame loop's code competes for it. Keep hot loops small and simple, avoid heavy generic instantiation or forced inlining in them, and prefer `ReleaseSmall` unless `ReleaseFast` measures faster on device |
| RAM | 16 MB external memory | Plenty of space, but a cache miss to it is expensive. Size matters less than access pattern |
| Display | 400x240, 1-bit, refresh up to 50 Hz | Shipping target is a locked 50 FPS. Drawing is done by the SDK into a 1-bit framebuffer; overdraw and the number of draw calls cost more than the maths around them |
| Storage / load | Flash, assets read through the SDK file API | Pre-convert assets offline (`convert_*.py`), read each file once at load into an arena |

### Cache rules for data layouts
- **Revisited data must fit `HOT_SET_BUDGET` (half the D-cache)**: anything a loop re-reads per outer iteration or accesses in random order, e.g. the enemy positions re-read for every bullet, or the draw list read back in sorted order. The other half is left for the stack, the SDK and framebuffer writes.
- **Streamed data only needs to be dense**: structure-of-arrays with no padding and no cold fields mixed in, so every 32 byte line fetched is fully used (4 `Vec2f`, 8 `f32`, 32 `u8`).
- **Split hot from cold**: fields only read in rare cases live in their own arrays (e.g. `Enemies.bump_offset` is only touched while bumping; `Bullets.dir` is read on a hit, not per collision test).
- **Enforce budgets at compile time** where the counts are constant: `state.COLLISION_HOT_SET_BYTES`, `enemy_separation_system.SEPARATION_HOT_SET_BYTES`, `auto_targetting_system.TARGET_HOT_SET_BYTES` and the renderer's character draw list all `@compileError` if they outgrow the budget. When adding a hot loop, add the same kind of check.
- **Arrays in entity stores start on a cache line** (`align(memory.CACHE_LINE_SIZE)`).
- **Smallest types that fit, no pointers in per-entity or per-frame records**: indices or enums into small tables instead (the renderer's `DrawItem` is 8 bytes: `i16` screen position, `u8` frame, `Sheet` enum; `animation.BitmapFrame` is 2 bytes).
- **Cull before you sort or draw**: only on-screen sprites enter the draw list, so its size follows what is visible rather than the level size.
- **Sort plain integer keys, not indices compared through another array**: the draw list sorts packed `u32` keys (depth << 16 | index).
- The collision grid (1 byte per cell, 900 B on `lvl1`) is read at random by the bullets' wall test, which runs in its own loop in `bullet_system.update` so it never shares the cache with the bullet/enemy collision set; `gameInit` warns if it outgrows `HOT_SET_BUDGET`.
- The flow field's `dir` (1 byte per cell, 900 B on `lvl1`) is read at random by enemy movement and also serves as the enemies' wall test, so it must fit the hot set; it isn't a compile-time count, so `gameInit` logs its size and warns if a level outgrows `HOT_SET_BUDGET`.
- The debug status line reports `frame_mem` (frame arena high-water mark) and `drawn` (sprites in the draw list) to keep an eye on these. At 100 enemies `drawn` is ~110, which is ~1.3 KB of draw list.
- Verify on device: the simulator runs on a desktop CPU with megabytes of cache and hides all of this.

## Design principles (these take priority over everything below)
- **Data-oriented design.** Model the game as data transformed by systems, not as objects with behaviour. Prefer plain structs and flat arrays (structure-of-arrays where it helps) over per-entity objects, pointers or hierarchies. Systems iterate contiguous data; per-entity state lives in parallel arrays indexed by entity (see `Enemies` in `game_state.zig`).
- **Simple, efficient data structures with layouts chosen for the hardware.** The target is a Cortex-M7 with a 4 KB data cache and a single-precision FPU (see Target hardware): keep hot data compact and contiguous, use the smallest integer types that fit (`u8` ids, `u16` indices), avoid pointer chasing and per-frame allocation, keep iteration linear and cache friendly, and reach for the simplest structure that works before anything clever. Measure before adding complexity.
- **Solid, stable 50 FPS on device with no runtime frame drops.** Every frame must fit its budget (~33ms) in the worst case, not just on average: no allocation, file IO, sorting of unbounded data or other spiky work in the frame loop, and all pools are fixed size with worst-case counts tested (max enemies, max bullets). Do not trade a stable frame time for a higher average. Check performance on device, not only in the simulator (the simulator runs on a desktop CPU and hides problems). Note `gameInit` currently calls `setRefreshRate(0)` (uncapped) to measure performance; the shipping target is a locked 50 FPS.
- **Near-instant load times.** Do all expensive setup once, up front, with fixed buffers, and keep assets small and in the formats the device loads fastest (pre-converted 1-bit images and compact binary levels, produced offline by the `convert_*.py` scripts rather than parsed or processed at runtime). Avoid runtime asset processing or any startup work that scales with content size.

## Conventions
- Memory: no heap. Pools with a constant capacity (`MAX_ENEMIES`, `BULLET_POOL_SIZE`, `MAX_DROPS` in `tweak_constants.zig`) are plain arrays inside `GameState`. Anything sized at runtime comes from an `Arena` (`memory.zig`) matching its lifetime: the **app** arena (a static buffer in `main.zig`) is split into the **level** arena (reset when a level loads: level objects, collision grid) and the **frame** arena (reset at the start of every frame: hit lists, render buffers). Never keep frame arena memory across frames. Running out `@panic`s with the arena name; the status log line reports the frame arena's high-water mark (`frame_mem`).
- Vectors are `@Vector(2, f32)` (`Vec2f`) in world metres; `METRES_TO_PIXELS` converts to screen.
- Entities have no ids: an entity is its index into its store, packed into `0..len`. To delete one, flag it (enemy `health = 0`, bullet `lifetime <= 0`) and let `removeDead` swap-remove the flagged ones once per frame; indices (e.g. in `Hit`) are only valid until then.
- Call the Playdate API through function pointers on the `PlaydateAPI` struct (`sys.getCurrentTimeMilliseconds.?()`).
- Comments use `///` doc comments on functions, matching existing style.

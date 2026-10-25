# AGENTS.md

"Until there were none" - a Playdate horde-survival shooter written in Zig (Windows dev environment). The player moves around and a crank-driven gatling gun auto-targets enemies.

## Toolchain
- Zig 0.17.0 (`zig version`). Note 0.17 differs a lot from older Zig: no `@cImport`, no `std.build`, single-argument cast builtins (`@intCast(x)`, `@floatFromInt(x)`, `@splat(x)`), `callconv(.c)`, `std.Random`.
- Arm GNU toolchain 11.3.1 (`arm-none-eabi`), Playdate SDK 1.13.2.
- Required environment variables:
  - `PLAYDATE_SDK_PATH` - SDK root (e.g. `C:\Users\<you>\Documents\PlaydateSDK`)
  - `ARM_TOOLKIT_PATH` - Arm toolchain root (e.g. `D:\11.3 rel1`)
- `pdc` (from `$PLAYDATE_SDK_PATH\bin`) must be on `PATH`; the build shells out to it.

## Commands
| Task | Command |
|------|---------|
| Build everything + package `zig-out/until-none.pdx` | `zig build` |
| Release builds | `zig build -Doptimize=ReleaseSmall` (or `ReleaseFast`) |
| Run in the simulator | `zig build run-sim` |
| Run unit tests | `zig build test` |

`zig build` produces:
- `zig-out/lib/pdex.dll` - simulator build (host target)
- `zig-out/bin/pdex.elf` -> `zig-out/lib/pdex.bin` - device build (thumb, Cortex-M7, hard-float)
- `zig-out/until-none.pdx` - package made by `pdc` from everything in `zig-out/lib` (both the DLL and the bin, plus `pdxinfo`, `images/`, `levels/`)

### Simulator
`zig build run-sim` builds, packages and launches `PlaydateSimulator.exe` with the pdx. Alternatively open `zig-out/until-none.pdx` in the simulator manually.

### Running, screenshots and logs (for agents)
`powershell -NoProfile -ExecutionPolicy Bypass -File tools/sim.ps1 [-Seconds 8] [-NoBuild]` stops any running simulator (it locks `pdex.dll`), builds, launches the simulator on `zig-out/until-none.pdx`, waits, then reports:
- `logs/screenshot.png` - screenshot of the simulator window (via `PrintWindow`, works while the window is in the background). View it with the Read tool.
- `logs/sim-stderr.log` / `logs/sim-stdout.log` - simulator process output. **A game panic shows up in stderr** (e.g. `thread N panic: KeyOutOfRange`) and the simulator then exits; the script says `SIMULATOR EXITED` in that case.
- the game's own log (below).
The simulator is left running afterwards; stop it with `Stop-Process -Name PlaydateSimulator`.

Game logging: `debugLog(fmt, args)` in `src/main.zig` (Debug builds only) writes to the in-simulator console (the `>_` button) and appends to `log.txt` in the game's data folder, `%PLAYDATE_SDK_PATH%\Disk\Data\com.downie.next\log.txt` (truncated on every start). A status line (enemies, health, score, player pos) is written once a second. `logToConsole` output is NOT available on stdout/stderr, hence the file. Release builds do no logging.

Notes:
- Debug builds fill `undefined` memory with `0xaa`, which exposes use-after-remove bugs that Release hides (e.g. iterating a `SparseArray` while removing from it). Panics report the error name via `@errorName`.
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
| `crank:<degrees>` | turn the crank, positive = forward; 60 degrees fires one bullet |
| `wait:<ms>` | pause |
| `shot[:name]` | screenshot to `logs/<name>.png` (default `screenshot`) |
| `log[:n]` | print last n lines of the game log (default 5) |

How it works / gotchas:
- Buttons are Windows key messages posted to the simulator window (no focus needed). Simulator bindings: arrows = D-pad, **`A` key = B button, `S` key = A button**. Arrow keys must carry the "extended key" bit (handled in `tools/sim-common.ps1`).
- The crank is the mouse wheel: each notch is 4 degrees (`$CrankDegreesPerNotch`, calibrated against `getCrankAngle`; the log's `crank=` field confirms it).
- Verify results from the log line (`pos`, `bullets`, `health`, `score`, `crank`), not only screenshots. World +y is up: `down` decreases y. Holding A or B fires every `FIRE_BUTTON_DELAY_MS` (500ms).
- The player dies in ~10s if left alone (enemies spawn on top of them) and the game resets (health back to 100, bullets 60, position 0,0), which can confuse a long test. Keep sequences short or check `health`.
- The simulator window takes ~3s to appear; use `-Seconds 4` or more with `tools/sim.ps1` if you want the launch screenshot.
- Don't pipe `tools/sim.ps1` into something that waits for EOF (e.g. `| tail`): the simulator inherits the pipe and stays alive, so the command never returns. Redirect to a file (`> out.txt`) or use `| head -1`.
- Debug builds also reach `logs/sim-stdout.log` (console output, flushed late); prefer the game's `log.txt` for timing.
- Helpers (`Send-SimKey`, `Send-SimCrank`, `Save-SimScreenshot`) live in `tools/sim-common.ps1` for writing custom scenarios.

### Device
There is no build step for this yet (it is on the README TODO list). Manually:
1. Build `zig build` (ideally `-Doptimize=ReleaseSmall` or `ReleaseFast`; the Debug device build is large).
2. Put the Playdate in Data Disk mode or connect via USB, then use the SDK's `pdutil`:
   ```
   "%PLAYDATE_SDK_PATH%\bin\pdutil.exe" <COM port> install zig-out\until-none.pdx
   "%PLAYDATE_SDK_PATH%\bin\pdutil.exe" <COM port> run /Games/until-none.pdx
   ```
   (Or sideload the `.pdx` through play.date/sideload, or drag it to the simulator's "Upload Game to Device".)

### Tests
`zig build test` runs the unit tests in `src/maths.zig`, `src/graphics_coords.zig` and `src/sparse_array.zig` on the host. Output is silent on success; add `--summary all` to see what ran. Other files are not unit tested (they depend on the Playdate C API). Add new test files to the list in `build.zig`.

## Layout
- `build.zig` - build graph (see below)
- `src/main.zig` - entry point. Exports `eventHandler` (called by the Playdate runtime), owns global game state, `gameInit`, `update` and the frame loop (`gameUpdateWrapper`).
- `src/playdate.zig` + `src/playdate_c.h` - Playdate C API (`pd_api.h`) translated via the build's translate-c step and exposed as `@import("playdate").api`. The build supplies it to `main.zig` as the `playdate_c` module import.
- Systems (plain modules with module-level state and `init`/`reset`/`update`):
  - `player_movement_system.zig`, `enemy_movement_system.zig` (seek + bump-back), `enemy_spawn_system.zig`
  - `bullet_system.zig` (pooled bullets, bullet/enemy collisions), `auto_targetting_system.zig`
  - `renderer.zig` (bitmap tables, depth sorting by screen y, HUD), `animation.zig` (facing-direction frames, walk bob)
- Data/helpers: `sparse_array.zig` (dense data + key lookup, used for enemy components), `collision_grid.zig`, `level_loader.zig` (reads `lvl1.bin`), `maths.zig`, `graphics_coords.zig` (world metres -> screen pixels), `tweak_constants.zig` (gameplay tuning), `bitmap_descs.zig` (**autogenerated** by `convert_raw.py`).
- Assets: `images/` (1-bit sprites/tables, copied into the pdx), `levels/` (binary level files), `pdxinfo`. Sources: `raw-images/`, `raw-levels/`, `map-tiles/` (Tiled maps).
- `convert_raw.py <imagemagick path>` - converts `raw-images/` to 1-bit sprites in `images/` and regenerates `src/bitmap_descs.zig`. `convert_tilemaps.py` - converts Tiled JSON in `map-tiles/` to `levels/*.bin`.

## Build graph notes (non-obvious things in `build.zig`)
- Two targets compile the same `src/main.zig`: the simulator DLL (native, links libc) and the device object (freestanding thumb) which is linked with the SDK's `buildsupport/setup.c` into `pdex.elf`, then `objcopy`'d to `pdex.bin`.
- Device specifics that were needed to link: FPU feature `fp_armv8d16sp` must be enabled (Zig's `cortex_m7` model has none), unwind tables are off (otherwise newlib's malloc clashes with the SDK's), the entry symbol is `eventHandlerShim`, and the linker script is wrapped so `SEARCH_DIR`s for the Arm libs are added (lld is not passed `-L` for freestanding).
- translate-c on the device needs a `wint_t` typedef shim, which lives in `src/playdate_c.h`.
- The device game code defines `TARGET_SIMULATOR` (historical; `TARGET_PLAYDATE` may have been intended).
- Whatever is in `zig-out/lib` ends up in the pdx, so stale files there get shipped; delete `zig-out` if in doubt.
- Occasional `unable to load "<std file>": Unexpected` errors from the compiler are transient - just re-run.

## Design principles (these take priority over everything below)
- **Data-oriented design.** Model the game as data transformed by systems, not as objects with behaviour. Prefer plain structs and flat arrays (structure-of-arrays where it helps) over per-entity objects, pointers or hierarchies. Systems iterate contiguous data; per-entity state lives in parallel arrays keyed by id (see `SparseArray`).
- **Simple, efficient data structures with layouts chosen for the hardware.** The target is a Cortex-M7 with small caches and a single-precision FPU: keep hot data compact and contiguous, use the smallest integer types that fit (`u8` ids, `u16` indices), avoid pointer chasing and per-frame allocation, keep iteration linear and cache friendly, and reach for the simplest structure that works before anything clever. Measure before adding complexity.
- **Solid, stable 30 FPS on device with no runtime frame drops.** Every frame must fit its budget (~33ms) in the worst case, not just on average: no allocation, file IO, sorting of unbounded data or other spiky work in the frame loop, and all pools are fixed size with worst-case counts tested (max enemies, max bullets). Do not trade a stable frame time for a higher average. Check performance on device, not only in the simulator (the simulator runs on a desktop CPU and hides problems). Note `gameInit` currently calls `setRefreshRate(0)` (uncapped) to measure performance; the shipping target is a locked 30 FPS.
- **Near-instant load times.** Do all expensive setup once, up front, with fixed buffers, and keep assets small and in the formats the device loads fastest (pre-converted 1-bit images and compact binary levels, produced offline by the `convert_*.py` scripts rather than parsed or processed at runtime). Avoid runtime asset processing or any startup work that scales with content size.

## Conventions
- Memory: no heap on device. `main.zig` carves everything from a fixed 1 MiB buffer via `FixedBufferAllocator` during `gameInit`; pools are fixed size (`MAX_ENEMIES` etc. in `tweak_constants.zig`). Failures `@panic` with a short context message.
- Vectors are `@Vector(2, f32)` (`Vec2f`) in world metres; `METRES_TO_PIXELS` converts to screen.
- Entity ids are `u8`, recycled through a free-id stack in `main.zig`.
- Call the Playdate API through function pointers on the `PlaydateAPI` struct (`sys.getCurrentTimeMilliseconds.?()`).
- Comments use `///` doc comments on functions, matching existing style.

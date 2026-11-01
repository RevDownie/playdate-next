# Story mode ("Fever"): handover

The design for a story mode, and a plan to build it in layers. Each layer builds, is tested and is played before the
next one goes on top. Read `AGENTS.md` first: its design principles (data-oriented, fixed pools, a stable 50 FPS,
near-instant loads) and its "After implementing a body of work" checklist apply to every layer here.

- **Survival** is the existing game, kept as the replayable high score mode. It must play exactly as it does today
  at the end of every layer.
- **Story** is a new mode: six chapters on a fixed route, with dialogue, collectibles and an ending.

---

## Part 1: the story

### The premise
**Surface story:** one night something happens to the town. Tom Hale comes to on his kitchen floor and the street
outside is overrun. His daughter Ellie gets through on a walkie-talkie: she is at St Bride's Hospital across town.
He sets out to reach her. We never say why she is there.

**What is really happening:** Tom collapsed at home with a severe infection. Ellie found him, and he is in a bed at
St Bride's while his body fights it. She is beside him, talking to him. The levels are real places on his route,
**not** organs or anything shaped like a body. The twist is carried by what Tom hears, how the HUD and rules behave,
and small things the world gets wrong.

**The thread through the whole game:** Tom keeps asking Ellie whether she is hurt, and she never answers directly.
The player assumes, like Tom, that she is hurt or trapped. In the last chapter she turns out to be there for him.

No other backstory: no lost wife, no grudge against the hospital. Keep it a father trying to get to his daughter.

### The voices
Each voice has its own look, so the player learns to tell them apart before understanding what they mean.

| Voice | Drawn as | Where it seems to come from | What it really is |
|---|---|---|---|
| Tom | Plain text, bottom of the screen, no box | His own thoughts | Tom |
| Ellie | Box at the top with a static-dither border | A walkie-talkie he carries | Ellie at the bedside |
| PA | Hard black box, capitals, often cut off mid-sentence | Police loudspeakers, army megaphones | Ward staff |

### Chapters (the route home to the hospital)
| # | Level | Kit | To St Bride's | Story temperature | Objective |
|---|---|---|---|---|---|
| 1 | Ashby Road | **new: suburb** (houses, fences, gardens, parked cars) | 6 mi | 38.4° | Survive the waves, then reach the exit |
| 2 | Town Centre | city (existing) | 4 mi | 39.1° | Survive, reach the exit |
| 3 | Fallow Park | woods (existing) | 2.5 mi | 40.2° | Survive, reach the exit |
| 4 | The Cordon | quarantine (existing) | 1 mi | **41.0°** | Survive, reach the exit |
| 5 | St Bride's | **new: hospital grounds** (car park, ambulance bay, main doors) | 0.2 mi | 39.6° | Biggest wave, reach the doors |
| 6 | The Ward | **new: interior**, small (about 8x10 cells) | - | 37.8° | No horde: walk to the bed |

Keeping the journey readable:
- St Bride's tower is in every level's `outside` fill (the view beyond the map), closer each chapter.
- A travel map between chapters: one 1-bit image of the route; cranking walks Tom's marker to the next stop and
  the distance counts down.
- Every level ends at an exit that opens when its waves are survived, with an off-screen marker like a drop's.

Open question: is the suburb a new kit, or the city kit with houses added? A new kit gives the opening identity but
is the most art of the three.

### Dialogue and key beats
Lines fire once each, on: chapter intro/outro cards, the first lull, a wave cleared, low health, a keepsake picked up,
a static line tuned in, reaching the exit. Death in story mode flashes white with **"CLEAR -"** and restarts the
chapter.

**Chapter 1: Ashby Road**
- Intro card: *"You wake on the kitchen floor. The street outside is screaming."*
- First lull. Ellie: "Dad? Dad, can you hear me?"
- Tom: "Ellie! Where are you? Are you hurt?"
- Ellie: "I'm at St Bride's. I'm okay. I'm just waiting for you."
- At the exit. Tom: "Stay where you are. I'm coming."
- Beat: Tom's front door is still open, the hall light on behind him. (Real world: where Ellie found him.)

**Chapter 2: Town Centre**
- Intro card: *"Every clock in town says 2:10."*
- Police loudspeaker (PA): "REMAIN IN YOUR HOMES. HELP IS ON THE -". Later, same voice: "PRESSURE'S EIGHTY OVER -"
- Ellie: "Everyone here keeps asking me questions. I don't know the answers, Dad."
- Tom: "What questions? Ellie, what's going on there?"
- Ellie: "...Just keep coming."

**Chapter 3: Fallow Park**
- Intro card: *"The roads are blocked. Through the park, then."*
- Ellie: "Do you remember the pond? You threw bread for the ducks until they got sick of it."
- Tom (low health): "Not now, love. Not now."
- Mid-chapter PA: "HE'S NOT RESPONDING. TRY THE OTHER ONE." The bullet tracers change subtly from here on (the
  doctors switching his treatment; nothing is labelled).

**Chapter 4: The Cordon**
- Intro card: *"They've fenced off the hospital."*
- Army megaphone (PA): "STAY BACK FROM THE LINE." Later: "FAMILY CAN STAY. FOR NOW."
- Tom: "My daughter's in there!"
- Ellie: "They told me I should say goodbye. I'm not going to."
- Tom: "Goodbye? Ellie - Ellie, are you hurt?" (no reply)
- Beat: the lowest point and the fever's peak. The player now fears for Ellie.

**Chapter 5: St Bride's**
- Intro card: *"Dawn. The first light in days."* (Tom has walked a single night.)
- Ellie: "Something's changed. They're smiling at me. Don't stop now, Dad."
- Beat: the biggest wave of the story, the crisis of the fever.
- At the doors. Tom: "I'm here. I'm here."

**Chapter 6: The Ward**
- No horde. The last few infected stop and stand still as Tom walks past.
- The corridor ends at a bed: a man who looks like Tom, Ellie asleep in the chair, unhurt.
- Turn the crank slowly to take her hand. The screen dithers to white.
- Ellie, in plain text (not the radio, for the first time): "...Dad?"

**Ending:** Tom always wakes. Collecting every keepsake adds a short epilogue: Tom and Ellie at the park pond, weeks
later.

The full line list still needs a writing pass (Layer 11); the lines above are the key beats.

### Collectibles
**Keepsakes (3 per chapter).** Things from Tom and Ellie's life: her bike bell, a school drawing, a cinema ticket
stub, the other walkie-talkie from when she was little, her old phone with a cracked screen, his watch...
- **Ellie's lines make them appear.** A keepsake is not on the map until Ellie mentions it: *"I brought your watch
  in. The one with the scratched face."* Then it appears, with an off-screen marker. After the reveal it turns out
  she was putting real things by his bed.
- **Placed to make you take risks:** at the edges of the map, away from the exit, some only after a wave is cleared.
- **Resolve:** each one raises maximum health by 5 for the rest of the story.
- **Scrapbook:** on the story menu, a short memory per keepsake; together they tell the story of Tom raising Ellie.
- **They count through death:** one collected before a "CLEAR" restart stays collected.

**Static (1 per chapter, secret).** Sometimes during a lull a static icon shows on the HUD. Stop firing and turn the
crank to tune in. The reward is an unfiltered line from the real room, the most direct clues in the game:
*"His hand's warm. Is that good?"*, *"Okay, Dad. I'm going to keep talking."*, *"They said hearing is the last thing
to go."* The crank is also the gun, so tuning in is a real risk.

### Clues (no labels on drops, no organ-shaped levels)
Story mode only; survival shows none of them.
- **Sound:** a faint, steady beep under everything, faster as health falls and during waves; picking up a drop
  briefly steadies it; on the ward it comes from a monitor in the room. (The game has no audio yet: see Layer 8.)
- **HUD:** waves are shown as a temperature (`39.2°`) instead of a wave number; clearing a wave lowers it.
- **Death:** "CLEAR -" and a white flash; the run end screen draws an ECG trace.
- **Bullet tracers** change after "try the other one".
- **System menu image:** pressing Menu shows a hospital wristband, `HALE, T. - WARD 7` (`setMenuImage`).
- **Clocks** in the levels jump by hours each chapter: 02:10, 06:40, 14:00 (ward round times).
- **The infected only go for Tom:** no other victims, no bodies.
- **The Cordon's soldiers** wear gowns and visors; their tents have drip stands.
- **A huge, soft shadow** sometimes sweeps over the map: a nurse leaning over the bed (a dither sweep).
- **Ellie runs on a different clock:** she talks about mornings and visiting hours while Tom walks one night.
- **Second playthrough:** the title screen shows an ECG line, and the PA lines play complete: *"PRESSURE'S EIGHTY
  OVER FIFTY. PUSH ANOTHER BAG."*

---

## Part 2: how it fits the code

These are recommendations from reading the code at the time of writing; check them against the code as it is.

**What exists today**
- `main.zig` starts straight into a survival run: `startRun` picks a level with `level_select.next`, and the only
  screen besides play is the run end (`run_end: ?state.RunEnd`). There is no title screen (`TODO.md` lists one).
- `game.tick` runs every system in a fixed order and returns `.playing` or `.player_died`.
- The wave state machine is `state.Spawner` driven by `enemy_spawn_system` from `consts.WAVES`. A spawner `timer` of
  infinity stops spawning.
- Drops live on the level's drop points (`level.drop_cells`), and `hud.drawDropMarker` points at off-screen ones.
- `drop_system` treats `consts.PLAYER_MAX_HEALTH` as the cap; `Player.health` is a `u8`.
- The level file is header, drop points, blocked-cell bitmask, then objects **until the end of the file**, so any new
  section must go before the objects (or the header must carry a count). Every `.bin` is generated by
  `convert_tilemaps.py`, so the parser and the script change together and every level is regenerated; no format
  versioning is needed.
- `save_data.zig` is the `best.bin` record (magic `UTN1` + `u64`).
- No audio at all yet.

**The shape to aim for**
- **Screens in `main.zig`:** replace `run_end: ?RunEnd` with one tagged union of what is up:
  `title`, `playing`, `run_end`, `story_card` (chapter intro/outro, CLEAR), `travel_map`, `scrapbook`. The simulation
  only ticks in `playing`. Changes between them happen at a frame boundary, as restarts do now.
- **`Mode` (`survival` / `story`)** chosen on the title screen. Survival keeps today's path through `startRun`.
- **`story.zig` (data, host-testable):** comptime tables, no behaviour in objects:
  - `CHAPTERS`: `{ level: u8, objective: Objective, waves: u8, temps: [..]u16 (tenths of a degree), intro: TextId,
    outro: TextId }` where `Objective = enum(u8) { survive_then_exit, walk }`.
  - `BEATS`: `{ chapter: u8, trigger: Trigger, arg: u8, voice: Voice, text: TextId, reveals_keepsake: u8 (0xff none) }`,
    sorted by chapter so a chapter's beats are one contiguous range (comptime-check the sort).
  - One string table for all text (`TextId = u16`). Text lives in flash; nothing is formatted at runtime.
- **`StoryEvent` records:** like `Hit`/`Impact`, a small fixed array in `GameState` cleared at the start of each
  tick: `{ kind: enum(u8) { wave_cleared, low_health, keepsake_taken, exit_reached, lull_started, static_tuned },
  arg: u8 }`, capacity ~8. Systems that already know these moments append to it. Survival can write them too
  (harmless) or skip them; either way no survival behaviour may change.
- **`story_system.zig`:** runs at the end of `game.tick` only in story mode. Matches this frame's events against the
  current chapter's `BEATS` range, keeps fired beats as a `u64` bitmask, pushes lines into a small fixed text queue
  (`{ text: TextId, voice: Voice, time_left: f32 }`, capacity ~4) and reveals keepsakes. Sets the chapter's exit open
  when its waves are done. Stateless function over `GameState.story` data, like the other systems.
- **`GameState.story`:** chapter, fired beats, text queue, exit open, keepsakes collected this chapter. Small and
  cold; nothing in it is touched by the hot loops.
- **Spawner in story mode:** a chapter plays `waves` waves from `consts.WAVES` (or a per-chapter table) and then stops
  spawning (infinite timer). Ward chapter: no waves.
- **Level data:** two new point names in the Tiled `drops` layer, `exit` and `keepsake` (keepsake with an `id`
  property, the index into the chapter's keepsakes). `Level` gains `exit_cell: ?u16` and
  `keepsake_cells: []const u16` / `keepsake_ids: []const u8`. Survival ignores them.
- **Keepsakes as drops:** a new `DropKind.keepsake` (never rolled by `drop_system.update`; added by the story system
  on a beat), so picking up and off-screen markers come for free. Its pickup writes a `keepsake_taken` event. Check
  `Drops` code paths that assume ammo or health (`isAmmo`, `isLarge`, the bitmap table order in `drop_sprites.py`).
- **Max health:** `Player` gains `max_health: u8` (default `PLAYER_MAX_HEALTH`), and `drop_system` uses it instead of
  the constant. Story sets it from keepsakes collected.
- **Save:** a separate `story.bin` (its own magic): chapter `u8`, keepsakes `u32` bitmask (15 used), static lines `u8`
  bitmask, finished flag, levels unlocked for survival. Written at chapter boundaries only, never mid-frame-loop work
  beyond that one write.
- **Survival rotation:** `LEVEL_NAMES` gains the new levels; a per-level flag (generated by `convert_tilemaps.py`)
  marks story-only levels (the ward). `level_select.next` picks only from levels allowed in survival (and, if you want
  unlocks, ones the story save has unlocked).

---

## Part 3: build it in layers

Every layer ends with: `zig fmt src build.zig`, `zig build test --summary all`, `zig build` and
`zig build -Doptimize=ReleaseSmall`, a play in the simulator (`tools/sim.ps1` + `tools/sim-input.ps1`), and a check
that **survival plays as before**. Layers that touch the frame loop also get the AGENTS.md stress test. Placeholder
text and art are fine until Layer 9/11.

### Layer 0: title screen and mode split
- Title screen: Story / Survival, d-pad + A. Survival goes straight into today's game.
- Screens as one tagged union in `main.zig` (replacing `run_end: ?RunEnd`).
- Story can start a plain survival run for now, with "STORY" on the HUD.
- System menu "Restart Level" works in both; add "Title" to get back.
- **Test:** sim: title -> survival -> die -> run end -> A restarts survival. Title -> story starts. Unit tests
  unchanged and passing.

### Layer 1: chapters on existing levels
- `story.zig` with `CHAPTERS`, temporarily mapped to existing levels (e.g. city, woods, quarantine) with a wave count.
- Story run: chapter's level, its waves, then spawning stops; when the level is clear the chapter is complete
  (no exit yet). Next chapter loads. Death restarts the chapter.
- `story_card` screen: plain text "Chapter N" intro/outro, A to continue.
- `story.bin` save: current chapter. Title "Story" resumes it.
- **Test:** unit tests for the chapter table (comptime checks: every level index valid) and story save
  encode/decode. Scenario test: a story chapter stops spawning after its waves and reports complete when cleared.
  Sim: play chapter 1 with `-Dinvincible=true`, see chapter 2 load.

### Layer 2: exits and keepsake points in the level format
- `convert_tilemaps.py`: `exit` and `keepsake` points (on free cells, validated like drop points); write them before
  the objects. `level_loader.parse`: read them into `Level`. Regenerate every level. Add an exit point to the
  existing maps for testing.
- Story: once waves are done the exit opens (off-screen marker, drawn like a drop marker); walking onto it completes
  the chapter.
- **Test:** `level_loader` unit tests for the new fields and errors (on a blocked cell, out of range, more than one
  exit). Scenario test: walking to the open exit completes the chapter; a closed exit does nothing. Sim: walk to it.

### Layer 3: story events, beats and the dialogue box
- `StoryEvent` array in `GameState`, written by spawn (wave cleared, lull started), combat (low health), drop collect
  (keepsake), story (exit reached).
- `BEATS` table and text table; `story_system` matches events and queues lines.
- HUD: Tom / Ellie / PA styles, one line at a time from the queue, each shown for a fixed time; wrap long lines
  (`drawTextInRect` or pre-wrapped text in the table, whichever measures cheaper).
- **Test:** unit tests: a beat fires once, only in its chapter, in table order; the queue drops the oldest when full;
  comptime check that `BEATS` is sorted by chapter. Scenario test: clearing wave 1 of chapter 1 queues Ellie's first
  line. Sim: screenshot each voice. Check the HUD draw cost with many lines queued (FPS counter on device).

### Layer 4: keepsakes, resolve and the scrapbook
- `DropKind.keepsake`, revealed by a beat onto its keepsake point; collected keepsakes saved in `story.bin` and not
  revealed again on a retry.
- `Player.max_health`; each keepsake +5 in story; `drop_system` uses `max_health`.
- Placeholder keepsake sprite in `drop_sprites.py` (one more row in the drops table).
- Scrapbook screen from the title/story menu: a list of found keepsakes and their memory text.
- **Test:** unit tests: keepsakes never spawn from `drop_system.update`; max health rises and survives a chapter
  restart; health drops fill to `max_health`. Scenario test: beat reveals keepsake -> walk over -> event -> bitmask.
  Sim: collect one, die, restart: still collected.

### Layer 5: static tuning
- During a lull, at a beat or a timer, the static icon shows. While it shows, the crank feeds a tune meter instead of
  the trigger (`firing_system` must not fire from the crank then; buttons still fire). Full meter -> the static line
  plays (`static_tuned` event) and its bit is saved. The icon goes when the wave starts.
- **Test:** unit tests: crank fills the meter and does not fire while tuning; nothing changes in survival. Sim: crank
  through a lull with `sim-input.ps1` and check the log.

### Layer 6: chapter cards and the travel map
- Intro/outro cards with the chapter text over a dithered background.
- Travel map: one image (generated offline into `images/`), the route as a list of points in `story.zig`; crank
  moves the marker; distance and temperature shown; A to skip.
- **Test:** sim screenshots of each card and the map; load time of the map image logged.

### Layer 7: clues (each independent; do in any order)
- Temperature HUD in story (from `CHAPTERS.temps` per wave) instead of the wave number.
- "CLEAR -" white flash on death; ECG trace on the story run end screen.
- Wristband image via `setMenuImage` in story mode only (cleared in survival).
- Tracer variant after the "try the other one" beat (a flag in story state the renderer reads).
- Nurse shadow sweep: an occasional dither band crossing the screen (renderer, cheap: one pattern fill).
- Clock decals per chapter (art, Layer 9).
- **Test:** each is visual; screenshot in story, and screenshot survival to confirm it is absent.

### Layer 8: audio, the beep
- The first audio in the game: a synth voice (Playdate sound API, no samples needed) ticking at a rate from health
  and wave phase; steadies briefly on pickup. Story only. Fits the "Audio" items in `TODO.md`.
- **Test:** sim by ear; device check that it costs nothing measurable.

### Layer 9: art and levels
- Kits (`env_kits.py`): suburb (or the city kit extended), hospital grounds, ward interior. Hospital tower in the
  `outside` fill of every story level.
- Tiled maps for every chapter with `start`, `exit`, `keepsake` and drop points; `CHAPTERS` pointed at the real
  levels. Clock decals.
- Story-only flag for the ward; new levels join the survival rotation (unlocked by finishing their chapter, if
  wanted).
- **Test:** `convert_tilemaps.py --preview logs` overviews; play each level in survival with `-Dlevel=<name>`; check
  the collision grid and flow field fit the hot set (`gameInit` warns).

### Layer 10: the ward and the ending
- `walk` objective: no spawner; the remaining infected stop and stand still.
- The bed interaction (stand by it, crank slowly), dither to white, Ellie's last line.
- Epilogue if every keepsake was found. Finished flag in `story.bin`; second-playthrough changes (ECG title, full
  PA lines).
- **Test:** scenario test of the walk objective; sim play-through of chapter 6 from a save.

### Layer 11: writing and tuning
- Full line list for every chapter (several Ellie lines per chapter so she feels present, the keepsake memories,
  the static lines), wave counts and difficulty per chapter, keepsake placement.
- **Test:** full play-through on device at a locked 50 FPS.

### Order and shortcuts
Layers 0 to 3 are the core; after Layer 3 the story can be played start to end with placeholder text on existing
levels, which is the point to judge whether it works. Layers 4 to 8 can be reordered freely. Layer 9 (art) can run in
parallel with anything from Layer 2 on.

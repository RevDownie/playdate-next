---
name: character-pixel-artist
description: 2D character pixel artist for 1-bit (Playdate) sprites and frame animation. Use when designing, reviewing or converting the player, enemies and bosses, their facing-direction sheets, walk/attack/hit/death animation cycles, dithering and contrast, or when planning sprite sheets, flipping and memory budgets for characters.
---

# Character pixel artist (1-bit sprites and frame animation)

You create heroes and enemies that stay readable in a swarm of 100 on a 400x240 1-bit screen, animate with the fewest possible frames, and cost almost no memory. Read `AGENTS.md`, `convert_raw.py` (`CHAR_W`/`CHAR_H`, dither settings), `src/animation.zig` (direction to frame lookup, flip, walk bob) and `src/renderer.zig` (sheets, 8-byte `DrawItem`, depth sort) before changing anything.

## What this game needs from a character
- Top-down 3/4 view, horde shooter: many enemies on screen, the player must always be findable, and enemies must read as threats at a glance.
- Existing sheets: 48x48 cells, 19 frames per character covering facing directions every 10 degrees from 0 (towards screen) to 180 (away); the other half is the mirror (`animation.BitmapFrame{ index, flipped }`). Match this convention unless the task explicitly changes it, and if it changes, update `animation.zig` and its tests.

## Reading at tiny size
- **Silhouette first.** Fill the sprite solid black; the pose and the character class must still be recognisable. Give the player and each enemy type a distinct outline: a hat, a big head, a hunch, a weapon, a tail. Never rely on interior detail for identity.
- **Player vs enemy contrast.** The player is the highest contrast thing on screen: strong 1px black outline, clear white and black masses, little dither. Enemies use more mid-value dither so a crowd forms a textured mass, while still carrying a clear outline so individuals separate. A crowd of identical dark sprites turns to a blob, so enemies need white gaps (a pale face, belly, or limb highlight) to break the silhouette up where they overlap.
- **Mass and head.** Large head and chunky body (about 2-3 heads tall) read better at 48px than realistic proportions. The eyes and weapon are the focal pixels: 1-2 pixels each, high contrast.
- **Orient the face/weapon clearly** in every facing so direction is obvious; the gun and its barrel should break the outline.
- **Ground contact.** A small dither or black oval shadow under the feet anchors the sprite and doubles as the sort anchor. Keep it identical in every frame so it does not jitter.
- **Hit/state feedback in 1-bit.** No colour to use: use inversion (the renderer already draws the player inverted on hit via `kDrawModeInverted`), a white silhouette flash, a one-frame size pop, or shake. Prefer a draw-mode trick over extra frames (zero memory).

## Dithering characters
- **Use fine ordered dither (Bayer/halftone) and few tones.** Skin/cloth mid-tones at 25-50%, shadows at 75% or solid black, highlights white. Characters at 48px cannot afford large pattern cells; use fine patterns, and stay with the same matrix for every character so they share a visual language (`convert_raw.py` uses `h6x6a` for characters).
- **Pattern must not shimmer in animation.** Dither is fixed to the sprite's pixels. Between frames, keep dither regions at the same pixel positions on parts that did not move (torso, head) so the pattern does not crawl; only parts that actually move should change. When a sprite is drawn at an odd screen offset over the dithered ground the combined pattern can moire; keep the ground calmer under moving characters (see `environment-pixel-artist`).
- **Dither shows form.** Wrap the pattern around the volume: shaded underside, shaded side away from the light (top-left light, like the environment). Do not spread dither evenly across the whole sprite, since that reads as flat grey noise.
- **Outline carries the drawing.** Dither supports it. Fix auto-dither output by hand: remove orphan pixels, repair broken outline pixels, keep 1px thin lines solid, and make sure thin limbs (1-2 px) stay connected black rather than dithered away.
- **Shrink first, dither last.** Resize the source to the final cell size, then dither, otherwise the pattern turns to mud. Better still, paint or touch up at final resolution in pure 1-bit.

## Frame animation
Animate with the minimum frames that sell the motion; every frame is paid for in memory, and in work multiplied by the number of facings.
- **Principles that work at 1-bit.** Strong key poses (contact, passing, extreme); squash and stretch via 1-2 pixel changes; anticipation before an attack; overshoot and a held frame on impact; clear arcs on limbs and weapon; a silhouette that changes on every frame of the cycle.
- **Typical frame counts.** Idle: 1 frame, or 2 on a slow 1px breathing loop. Walk: 4 frames (contact, down, contact-mirrored, down), or 2 frames plus a body bob. Attack: 3 (wind-up, strike, recovery). Hit: 1 (or a draw-mode flash). Death: 3-4 then a persistent corpse frame, or just a dissolve/flash and removal, which is usually enough in a horde game.
- **Use procedural animation to save frames.** The project already does a walk bob in code (`animation.walkBobAnim`) instead of a walk cycle sheet. Cheap, memory-free options: vertical bob, squash scale by sprite choice, a 1-2px horizontal sway, a flash, a rotation through the 10-degree facing frames, mirrored limb swap by flipping. Prefer these before drawing a new frame.
- **Timing.** Animate on a fixed frame clock (for example advance every N ticks, or from distance travelled like the bob does, so feet match speed). Do not tie animation to wall-clock time in a way that breaks at 50 FPS or when paused. Enemy cycles should be phase-offset per enemy (using the index or position) so a crowd does not step in unison.
- **Loop cleanly.** First and last frames must join with no pop; walk cycles are symmetrical so you can author half and mirror.
- **One reference body.** Every facing of every frame shares the same cell, the same foot anchor, and the same shadow position. A frame that shifts by a pixel makes the sprite jitter.

## Constrained environments: memory, atlas, flip
A 48x48 1-bit sprite with a mask is about 0.5 KB. 19 facings x 4 walk frames = 76 frames = about 38 KB per character; a handful of enemy types multiplies that. Do the arithmetic before drawing, and report it.
- **Facing: mirror, don't draw.** Draw 0..180 degrees and get 180..360 with `kBitmapFlippedX` (what `animation.zig` does), halving memory. Design so mirroring is safe: do not put asymmetric details (a logo, a handedness that matters for the gun) in places that would visibly swap. If the weapon hand must stay on one side, restrict the mirrored range to poses where that is hidden, or draw the weapon as a separate sprite.
- **Fewer facings.** 36 facings (10 degrees) are a luxury. 8 facings (45 degrees, 5 drawn + 3 mirrored) is enough for most enemies; keep high resolution only for the player and aimed weapons. Consider rotating a small separate weapon sprite and keeping only a few body facings.
- **Split parts.** For the player, a body sheet plus a separate gun sheet (barrel rotated through 10-degree frames) is much smaller than body x gun combinations, and you can aim independently of the walk direction.
- **Atlas / bitmap table.** Put all frames of a character in a single bitmap table (`name-table-N.png` files or `name-table-WxH` grid, packed by pdc into one table; index API 0-based, files 1-based). Frame index is computed by `facing * frames_per_facing + anim_frame`, or the inverse; choose a layout so a walk cycle for one facing is contiguous (cache and arithmetic friendly) and document the layout next to the table lookup.
- **Cell size = largest frame.** Every cell in a table is the same size. Trim cell size to the character (small enemies in a 24x24 table, bosses in their own bigger table), since padding costs mask and pixel bits.
- **Share between enemy types.** Make palette-swap equivalents in 1-bit: different dither on the same base shape, an added hat or horn overlay, or the same body drawn in inverted draw mode. Variants through code (inversion, overlays, scale of the shadow, speed) are free.
- **Render cost.** Characters go in the depth-sorted draw list as an 8-byte `DrawItem` (screen position `i16`, `u8` frame, `Sheet` enum, flip). A new animation must still fit `u8` frame indices (max 256 frames per sheet) and must not add pointers or fields per entity. Per-enemy animation state should be a small `u8` phase derived from existing data (position, a spawn-time index), not a new per-entity struct.
- **No runtime image work.** Everything converted offline by `convert_raw.py`, loaded once into the app/level arena; never resample, recolour or build bitmaps at runtime. Cull off-screen characters before drawing. Overdraw of 100 overlapping 48x48 masked sprites is a real cost on device, which is another reason to keep enemies small.

## Workflow in this repo
1. Author at the final cell size (`CHAR_W` x `CHAR_H`) in `raw-images/<Name>/<name>-table-N.png`; the transparent key colour is red (`-transparent red`), so do not use red in the art.
2. Run `python convert_raw.py <imagemagick path>` (wipes `images/` and rewrites `src/bitmap_descs.zig`), then `zig fmt src`.
3. If you add a character, a sheet or frame layout: add the `Sheet` enum value and the `loadBitmapTable` line in `src/renderer.zig`, extend `animation.zig` with the lookup (plus a `test` block named `"[animation] ..."`), and check the frame count against the `u8` frame index.
4. Verify in the simulator with `tools/sim.ps1` and `tools/sim-input.ps1`: screenshot while the character turns through every facing and stands in a crowd; check for jitter, a flipped weapon on the wrong side, a missing facing, and frame pops at the loop point. Look at it at 1:1, and on device if possible.
5. Report frame counts, cell size, estimated bytes per table, and what was saved by mirroring or procedural animation.

## Review checklist
- Silhouette distinct per character class; player is the strongest contrast; enemies separate from each other in a crowd?
- Fine ordered dither, same matrix everywhere, hand-cleaned, thin lines solid?
- Foot anchor and shadow identical in every frame; no jitter?
- Minimum frames; procedural bob/flash used where possible; loop is clean; crowd phases offset?
- Mirroring is safe (no handedness or text); facings reduced where possible?
- One bitmap table per character, tight cell size, contiguous layout, `u8` frame index fits, `DrawItem` unchanged?

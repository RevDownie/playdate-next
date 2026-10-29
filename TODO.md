# TODO List

## Improve auto-targetting
- Needs design input
- Constrain player visibility of targets based on distance and line of sight
- Ensure that auto-targetting feels good - prefer firing in direction of movement if there are enemies ahead to clear
- Expanded requirements (level design input, lvl1 cells are 0.45 x 0.21m, the screen shows ~3.1 x 1.9m of a 13.4 x 6.3m map):
  - Only target what the player can see: enemies inside the camera's view (plus a small margin) with a clear line
    of sight from the player's feet. The line test samples the collision grid every half cell, like bullets, so
    the gun never empties the magazine into a wall
  - Score candidates by distance, scaled down for enemies ahead of the player's movement (`TARGET_AHEAD_WEIGHT`)
    and, a little, for enemies near the current aim (`TARGET_STICKY_WEIGHT`) so the aim doesn't flick between two
    similar targets. No entity ids: stickiness uses the previous aim direction
  - No separate "danger" tier: a full horde sits on a ring at the same distance, so nearest-first there would pick
    enemies behind a player cutting their way out. The weighted distance already favours whatever is close and ahead
  - Bounded cost: line of sight is only tested on the best candidates in score order, at most `TARGET_MAX_LOS_TESTS`
    per frame; per enemy scores live in the frame arena and fit the L1 hot set (compile-time check)
  - No visible target: aim the way the player is moving, or keep the last aim when standing still (no snapping right)
  - Show the current target with a small reticle at its feet so the player can read what the gun is doing
  - Unit tests per rule, plus a scenario: the gun doesn't fire at an enemy behind a wall when one in the open is further away

## Combine enemy_separation_system into enemy_movement_system
- Feels like these should be in the same file as they relate to enemy positioning

## Improve enemy spawning
- Feels like there is too much chance of enemies failing to spawn
- Perhaps spawn locations should be specified on the map - like player spawn is

## Run loop follow-up (waves, run end, combo)
- Playtest the wave curve on device: `WAVES` table (hold, peak, pack, lull), `WAVES_PER_EXTRA_SIDE`, `WAVE_PACK_INTERVAL`
- A player who keeps moving can still kite most of a wave: runners (faster than the player, from wave 2) help, but the
  drop-seeking scenario bot still survives its whole 600s. Playtest whether runners need to come sooner or in packs
- Whether a timed-out wave should give any signal (today the next wave just starts)
- Combo popups and HUD text: draw cost on device with a full horde and 8 popups

## Drops follow-up
- Playtest the tuning on device (`DROP_*`, `AMMO_DROP_*`, `HEALTH_DROP_*`, `RELOAD_TIME_*` in tweak_constants.zig)
- Decide whether off-screen drops need an edge-of-screen indicator, or if searching for them is the point
- Reload feedback on the player (the HUD says "Reloading")

## Camera improvements
- With input from design
- Have camera track in direction of movement to improve line of sight
- Subtle interpolation
- Camera shake in response to firing and impact

## Visuals - Characters follow-up
- Check the character sheets on device: FPS with a full horde (up to 100 masked sprites up to 64x64, plus gore: up to `MAX_GIBS` gibs, 200 pools and spatters and `MAX_DROPLETS` droplets drawn outside the draw list)
- Gore: tune the spray (`GIB_*`, `DROPLET_*`) in play; maybe a bigger burst for melee kills, blood on the hero, a short hit stop on brute kills
- Playtest the enemy kinds (`ENEMY_KINDS`, `ENEMY_BRUTE_*`): brutes walk through fire, so is wave 3 too early?
- Brutes use the walker's separation distance and contact radius, so they overlap other enemies a little
- Firing animation (barrels turning, muzzle flash)
- Enemy spawn animation

## Visuals - Environment
- Obstacles, walls, buildings and terrain
- Perhaps woodland, abandoned village or abandoned warehouse themed

## VFX
- Explosions
- Gunfire
- Blood impact / spatter
- Spawn
- Disappear / despawn
- Drops appearing and being picked up (they spawn instantly for now)

## Implement Audio system for VFX and Music
- Using the Playdate audio sdk
- Allow for volume changes
- Fading between 2 tracks
- Pool of SFX to use (with ducking as appropriate)

## Playdate Launcher and card
- Create assets and integrate to launcher and card

## Main menu
- Start button
- Instructions screen showing controls and goals
- Violence warning
- Credits screen
- High score per level 


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
- Enemies should spawn in waves so players get a peak and trough experience where they feel they can gear up for the next battle

## Improve enemy spawning
- Feels like there is too much chance of enemies failing to spawn
- Perhaps spawn locations should be specified on the map - like player spawn is

## Health Drops
- Based on predefined spawn locations in the map
- Drop periodically with visuals and animation
- Different sized drops restore different amounts of health

## Ammo drops
- Based on predefined spawn locations in the map
- Drop periodically with visuals and animation
- Different sized drops restore different amounts of ammo
- Reloading on collection takes time based on size of ammo drop

## Camera improvements
- With input from design
- Have camera track in direction of movement to improve line of sight
- Subtle interpolation
- Camera shake in response to firing and impact

## Visuals - Main character
- Improve character sprites to look more like a battle worn soldier
- More rotation frames
- Holding a gun
- Movement and firing animations
- Health decrease animations
- Death animations

## Visuals - Enemies
- Improve visuals - zombie or horrible creatures
- Variety of enemies
- Walk, hit, die and spawn animations

## Visuals - Environment
- Obstacles, walls, buildings and terrain
- Perhaps woodland, abandoned village or abandoned warehouse themed

## VFX
- Explosions
- Gunfire
- Blood impact / spatter
- Spawn
- Disappear / despawn

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


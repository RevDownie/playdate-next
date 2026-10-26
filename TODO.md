# TODO List

## Bullet behaviour
- Bullets should be blocked by walls
  - A bullet dies on the first blocked collision cell along its path, including when it's spawned inside one or leaves the map
  - Never tunnels through a wall, even on a long (`MAX_FRAME_DT`) frame: the path is sampled every half cell
  - Enemies behind a wall can't be shot through it
  - The wall test runs on its own in `bullet_system.update` (the grid isn't added to the bullet/enemy collision hot set)
- Improve bullet travel feel so bullets move like machine gun bullets
  - Faster (`BULLET_MAX_SPEED` 14 m/s), but capped at compile time so a 50 FPS step can't skip over an enemy's hit circle
  - Range based lifetime (`BULLET_RANGE`) rather than flying for 3s across the whole map
  - Small random spread per shot (`BULLET_SPREAD`) that still hits at typical range
  - Drawn as tracer streaks along the direction of travel (never poking back behind the gun) instead of 6px squares
- Improve bullet spawn location so it spawns at the appropriate spot and offset for a gatling gun
  - Bullets leave from the gun at hip height, ahead of and to the right hand side of the player, not from the feet
  - The 6 barrels turn with the crank (one shot per 60 degrees), so each shot leaves from the next barrel
  - The offset is visual only: the simulated bullet starts at the player's feet so enemies hugging the player can still be hit, and the drawn offset fades out over `MUZZLE_CONVERGE_DIST` so tracers meet the aim line
- Out of scope (own TODOs): muzzle flash and impact sparks (VFX), firing shake (camera), target choice (auto-targetting)

## Improve auto-targetting
- Needs design input
- Constrain player visibility of targets based on distance and line of sight
- Ensure that auto-targetting feels good - prefer firing in direction of movement if there are enemies ahead to clear

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
- Different sized drops restore different amounts of health
- Reloading on collection takes time

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


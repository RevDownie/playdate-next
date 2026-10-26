# TODO List

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


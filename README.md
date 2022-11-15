# playdate-next
A Playdate game written in Zig using Windows

## Game Overview
Inspired by shooters like Minigore. This is a simple horde survival game where the player moves around and uses a crank controlled gatling gun to take down enemies.

## Toolchain
- Built with Zig 0.10.0
- Build with Arm toolchain 11.3.1

## TODO List
* Simulator hot reload of DLL
* Scrolling camera to follow player
** Offset in the direction of movement
* Convert world space to metres
* Physics with respect to time
* Bullet projectiles
* Culling
* Enemies
* Health
* Scoreboard
* Auto targetting? Or button to switch target?
* Split up main.zig as it gets too large
* Level background (isometric tiles?)
* Movement bounds
* Actual character sprite and animation
* Launcher tile
* Running on device
* Add running on sim and device to zig build (pdutil)
* Transparency
* Sprites vs Bitmaps
* Enemy spawn effects - pattern

# Until there were none...
A Playdate game written in Zig using Windows

## Game Overview
Inspired by shooters like Minigore. This is a simple horde survival game where the player moves around and uses a crank controlled gatling gun to take down enemies.

## Toolchain
- Built with Zig 0.10.0
- Build with Arm toolchain 11.3.1

## TODO List
### P1 - Functional
* Add running on device to zig build (pdutil)
* Music
* SFX
* Crash bug

### P2 - Improvements
* Combine sparse arrays for enemies
* Culling - Test if we need to cull and handle the culling logic
* Movement bounds
* New characters
* Better auto targetting
* Enemies spawning in waves and at better locations
* Leaderboard
* Launcher and card images
* Violence warning
* Bullet system refactor so it doesn't have outlier rendering pattern
* Reloading bar
* Replace text with custom bitmap font
* Stop the enemies bunching up


### P3 - Polish
* Offset camera in the direction of movement
* Instructions
* Spawn effects
* Hit effects
* Fire effects
* Player/enemy die anim
* Player/enemy move anim
* Player fire anim
* Better BG
* Rotation interpolation for new target
* Obstacles

### P4 - Future
* Levels
* Enemy types
* Gun types

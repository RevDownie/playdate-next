# Until there were none...
A Playdate game written in Zig using Windows

## Game Overview
Inspired by shooters like Minigore. This is a simple horde survival game where the player moves around and uses a crank controlled gatling gun to take down enemies.

## Toolchain
- Built with Zig 0.10.1
- Built with Arm toolchain 11.3.1
- Built with Playdate SDK 1.13.2

## TODO List
### P1 - Functional
* Music
* SFX
* Player obstacle collision
* Enemy obstacle avoidance???
* Bullet sorting and rendering refactor
* Health crates
* Ammo crates

### P2 - Improvements
* Combine sparse arrays for enemies
* Culling - Test if we need to cull and handle the culling logic
* Movement bounds
* New character models
* Better auto targetting
* Enemies spawning in waves and at better locations
* Trophy Room (artefacts and high score)
* Launcher and card images
* Violence warning
* Replace text with custom bitmap font
* Stop the enemies bunching up
* Randomised level selection
* Add running on device to zig build (pdutil)
* Tweak constants editing in realtime on simulator via file read


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

### P4 - Future
* Enemy types
* Gun types

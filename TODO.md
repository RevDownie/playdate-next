# TODO

## Gameplay
- Story mode
- Explosive barrels

## Enemy spawning
- Packs sometimes fail to find a spawn cell and wait for the next interval: make that rarer
- Consider spawn points placed in the Tiled maps, like the player start and drop points

## Visuals
- Gatling barrels turning on the gun sprite (bullets already leave from the turning barrel)
- Enemy spawn animation
- Depth sort the bullet tracers with the sprites (they are drawn over everything)

## VFX
- Explosions
- Enemies spawning and despawning
- Drops appearing and being picked up (they pop in and out)

## Audio (Playdate sound API)
- Music, with a fade between two tracks
- A pool of SFX, ducking as appropriate
- Volume control

## Launcher
- Card and launcher assets

## Main menu
- Start button
- Instructions screen showing controls and goals
- Violence warning
- Credits screen
- High score per level

## Launch checklist (from help.play.date "Designing for Playdate")
### Launcher and metadata
- Accurate game name and version in `pdxinfo` (shown under Settings > Games)
- Card art includes the game name (the launcher shows no label)
- Animated launcher card: selected, launching and loading states (chain them into the game start)
- Custom wrapping paper pattern hinting at the game

### System menu and pause
- Menu image: custom pause image left of the System Menu (e.g. score, wave, best)
- System menu options for things that don't fit the game UI (music toggle, restart; Invincible is debug only)
- Tell players on the instructions screen to check the Menu for custom options

### Controls and accessibility
- Crank indicator (`ui.crankIndicator`) when the crank is docked / needed
- Show buttons as circles in on screen instructions
- Respect Settings accessibility preferences (e.g. reduce flashing: the hit flash and screen shake; the muzzle flash already follows it)

### Audio testing
- Normalise sample loudness against other Playdate games and system sounds
- Test on the device speaker and with headphones (inaudible bass, noisy peaks)

### Text and graphics legibility
- Check HUD and banner text sizes against the guide (HUD at least 10 px cap height, other text at least 8 px; dialogue 12-14 px) and strokes at least 2 px
- Prefer Roobert 20 Medium for UI text and 24 Medium for headings; make sure the Asheville 14 fallback never shows


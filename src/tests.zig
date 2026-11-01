//! Single entry point for `zig build test`. Unit tests live next to the code they test (so they can reach
//! private functions); scenario tests that span systems live in `tests/`. Importing a file here runs its
//! tests - add every new module that doesn't need the Playdate API (main.zig, renderer.zig and hud.zig do).

test {
    _ = @import("maths.zig");
    _ = @import("graphics_coords.zig");
    _ = @import("memory.zig");
    _ = @import("save_data.zig");
    _ = @import("animation.zig");
    _ = @import("game_state.zig");
    _ = @import("collision_grid.zig");
    _ = @import("level_loader.zig");
    _ = @import("level_select.zig");
    _ = @import("story.zig");
    _ = @import("screens.zig");
    _ = @import("flow_field.zig");
    _ = @import("bullet_system.zig");
    _ = @import("enemy_movement_system.zig");
    _ = @import("enemy_spawn_system.zig");
    _ = @import("combat_system.zig");
    _ = @import("firing_system.zig");
    _ = @import("drop_system.zig");
    _ = @import("melee_system.zig");
    _ = @import("gore_system.zig");
    _ = @import("auto_targetting_system.zig");
    _ = @import("camera_system.zig");
    _ = @import("player_movement_system.zig");
    _ = @import("game.zig");
    _ = @import("tests/scenarios.zig");
}

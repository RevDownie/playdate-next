const std = @import("std");
const maths = @import("maths.zig");
const consts = @import("tweak_constants.zig");
const state = @import("game_state.zig");
const Arena = @import("memory.zig").Arena;
const Level = @import("level_loader.zig").Level;
const flow_field = @import("flow_field.zig");
const player_move_sys = @import("player_movement_system.zig");
const enemy_spawn_sys = @import("enemy_spawn_system.zig");
const enemy_move_sys = @import("enemy_movement_system.zig");
const bullet_sys = @import("bullet_system.zig");
const combat_sys = @import("combat_system.zig");
const auto_target_sys = @import("auto_targetting_system.zig");
const firing_sys = @import("firing_system.zig");

const Vec2f = @Vector(2, f32);

pub const TickResult = enum { playing, player_died };

/// The orchestrator: advances the simulation one frame by running every system in a fixed order.
/// Systems only see the data they are handed; per frame scratch comes from `frame_arena`.
/// Platform independent (no Playdate API) so it can be driven from tests.
/// `field` is the enemies' path to the player; it is level-sized so it lives in the level arena, not `game`.
///
pub fn tick(game: *state.GameState, level: *const Level, field: *flow_field.FlowField, input: state.Input, dt: f32, frame_arena: *Arena) TickResult {
    const grid = &level.collision_grid;

    //1. Spawn new enemies around the player
    enemy_spawn_sys.update(&game.spawner, &game.enemies, game.rng.random(), game.player.pos, level.spawn_cells, field, grid, dt);

    //2. Movement. The flow field follows the player, a bounded slice of a rebuild per frame
    player_move_sys.update(&game.player, input, grid, dt);
    flow_field.update(field, grid, grid.cellIndex(game.player.pos), consts.FLOW_FIELD_CELLS_PER_FRAME);
    enemy_move_sys.update(&game.enemies, field, grid, game.player.pos, dt);

    //3. Move projectiles and resolve bullet -> enemy hits (kills are flagged then compacted out)
    bullet_sys.update(&game.bullets, dt);
    const hits = bullet_sys.collide(&game.bullets, game.enemies.positions(), frame_arena.alloc(state.Hit, game.bullets.len));
    combat_sys.applyBulletHits(hits, &game.enemies, &game.player);
    game.bullets.removeDead();
    game.enemies.removeDead();

    //4. Enemies touching the player hurt them
    combat_sys.applyEnemyContact(&game.enemies, &game.player);
    if (game.player.health == 0) return .player_died;

    //5. Now that the enemy positions are final, aim at the hottest target and fire
    const target_dir = auto_target_sys.calculateHottestTargetDir(game.player.pos, game.enemies.positions()) orelse maths.normaliseSafe(game.player.vel, Vec2f{ 1, 0 });
    if (firing_sys.update(&game.trigger, input, dt)) {
        bullet_sys.fire(&game.bullets, game.player.pos, target_dir);
    }
    game.player.facing_dir = target_dir; //Player faces the way they are firing

    //6. Camera and effects
    game.camera_pos = game.player.pos; //Follow the player directly for now
    game.player.hit_flash_timer = @max(game.player.hit_flash_timer - dt, 0);

    return .playing;
}

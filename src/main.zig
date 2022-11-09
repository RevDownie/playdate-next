const std = @import("std");

const pd = @cImport({
    @cInclude("pd_api.h");
});

var playdate_api: *pd.PlaydateAPI = undefined;
var player_sprite: *pd.LCDBitmap = undefined;

pub export fn eventHandler(playdate: [*c]pd.PlaydateAPI, event: pd.PDSystemEvent, _: c_ulong) callconv(.C) c_int {
    switch (event) {
        pd.kEventInit => {
            playdate_api = playdate;
            gameInit();
            playdate.*.system.*.setUpdateCallback.?(gameUpdate, null);
        },
        else => {},
    }
    return 0;
}

fn gameInit() void {
    //Spawn the player sprite
    const graphics = playdate_api.graphics.*;
    player_sprite = graphics.loadBitmap.?("Test0.pdi", null).?;
    //std.debug.assert(player_sprite != null);
    //Load the enemies sprite pool
    //Init the systems
}

fn gameUpdate(_: ?*anyopaque) callconv(.C) c_int {
    const playdate = playdate_api;
    const graphics = playdate.graphics.*;
    const sys = playdate.system.*;
    // const disp = playdate.display.*;

    graphics.clear.?(pd.kColorWhite);
    sys.drawFPS.?(0, 0);
    _ = graphics.drawText.?("hello world!", 12, pd.kASCIIEncoding, 100, 100);

    graphics.drawBitmap.?(player_sprite, 200, 100, pd.kBitmapUnflipped);

    const shouldFire = firingSystemUpdate(sys);
    if (shouldFire) {
        sys.logToConsole.?("Fire");
    }

    return 0;
}

var crank_angle_since_fire: f32 = 0.0;
/// Fire everytime the crank moves through 360 degrees
///
fn firingSystemUpdate(sys: pd.playdate_sys) bool {
    const crank_delta = sys.getCrankChange.?();
    if (crank_delta >= 0) {
        crank_angle_since_fire += crank_delta;
        if (crank_angle_since_fire >= 360) {
            //Fire
            crank_angle_since_fire -= 360;
            return true;
        }
    }

    return false;
}

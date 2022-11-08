const std = @import("std");

const pd = @cImport({
    @cInclude("pd_api.h");
});

var playdate_api: *pd.PlaydateAPI = undefined;

pub export fn eventHandler(playdate: [*c]pd.PlaydateAPI, event: pd.PDSystemEvent, _: c_ulong) callconv(.C) c_int {
    switch (event) {
        pd.kEventInit => {
            playdate_api = playdate;
            playdate.*.system.*.setUpdateCallback.?(update, null);
        },
        else => {},
    }
    return 0;
}

fn update(_: ?*anyopaque) callconv(.C) c_int {
    const playdate = playdate_api;
    const graphics = playdate.graphics.*;
    const sys = playdate.system.*;
    // const disp = playdate.display.*;

    graphics.clear.?(pd.kColorWhite);
    sys.drawFPS.?(0, 0);
    _ = graphics.drawText.?("hello world!", 12, pd.kASCIIEncoding, 100, 100);

    const shouldFire = firingSystemUpdate(sys);
    if (shouldFire) {
        sys.logToConsole.?("Fire");
    }

    return 0;
}

var crank_angle_since_fire: f32 = 0.0;
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

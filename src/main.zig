const std = @import("std");

const pd = @cImport({
    @cInclude("pd_api.h");
});

pub export fn eventHandler(playdate: [*c]pd.PlaydateAPI, event: pd.PDSystemEvent, _: c_ulong) callconv(.C) c_int {
    switch (event) {
        pd.kEventInit => playdate.*.system.*.setUpdateCallback.?(update, null),
        else => {},
    }
    return 0;
}

fn update(_: ?*anyopaque) callconv(.C) c_int {
    return 0;
}

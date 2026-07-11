//! Promise listener callbacks shared by actor and driver tests.

const pancake = @import("pancake");

const actors = pancake.actors;

pub fn captureInt(ctx: ?*anyopaque, resolution: actors.Resolution) void {
    const slot: *i64 = @ptrCast(@alignCast(ctx.?));
    slot.* = switch (resolution) {
        .fulfilled => |value| value.integer,
        .broken, .give => -1,
    };
}

pub fn captureBroken(ctx: ?*anyopaque, resolution: actors.Resolution) void {
    const slot: *bool = @ptrCast(@alignCast(ctx.?));
    slot.* = resolution == .broken;
}

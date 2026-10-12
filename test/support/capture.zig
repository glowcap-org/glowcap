//! Promise listener callbacks and settled-value captures shared by actor and
//! driver tests. These cover the plain "listen, drive, assert" shape. A
//! listener whose firing is itself the scenario (re-entrant drives, nested
//! serves) stays local to its test.

const std = @import("std");
const glowcap = @import("glowcap");

const actors = glowcap.actors;
const model = glowcap.ocapn.model;

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

/// Copy a fulfilled `.bytes` reply into an inline buffer. A break or give
/// only sets the flag, so the assertion that follows fails on empty text.
pub const CapturedBytes = CapturedText(.bytes);

/// The `.string`-arm sibling of `CapturedBytes`.
pub const CapturedString = CapturedText(.string);

fn CapturedText(comptime arm: enum { bytes, string }) type {
    return struct {
        buf: [128]u8 = undefined,
        len: usize = 0,
        broken: bool = false,

        pub fn record(ctx: ?*anyopaque, resolution: actors.Resolution) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            const payload = switch (resolution) {
                .fulfilled => |value| switch (arm) {
                    .bytes => if (value == .bytes) value.bytes else return,
                    .string => if (value == .string) value.string else return,
                },
                .broken, .give => {
                    self.broken = true;
                    return;
                },
            };
            self.len = @min(payload.len, self.buf.len);
            @memcpy(self.buf[0..self.len], payload[0..self.len]);
        }

        pub fn text(self: *const @This()) []const u8 {
            return self.buf[0..self.len];
        }
    };
}

/// Capture a fulfilled reference reply, keeping a broken vow's reason so
/// `require` can print why the settle went wrong instead of a bare error.
pub const CapturedRef = struct {
    ref: ?model.Reference = null,
    broken: bool = false,
    reason_buf: [128]u8 = undefined,
    reason_len: usize = 0,

    pub fn record(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        const self: *CapturedRef = @ptrCast(@alignCast(ctx.?));
        switch (resolution) {
            .fulfilled => |value| switch (value) {
                .reference => |reference| self.ref = reference,
                else => {},
            },
            .broken => |reason| {
                self.broken = true;
                self.reason_len = @min(reason.len, self.reason_buf.len);
                @memcpy(self.reason_buf[0..self.reason_len], reason[0..self.reason_len]);
            },
            .give => self.broken = true,
        }
    }

    pub fn require(self: *const CapturedRef) !model.Reference {
        if (self.broken) {
            std.debug.print("vow broke: {s}\n", .{self.reason_buf[0..self.reason_len]});
            return error.VowBroke;
        }
        return self.ref orelse error.VowDidNotSettle;
    }
};

/// Capture a fulfilled integer reply. Anything else leaves `value` null.
pub const CapturedInt = struct {
    value: ?i64 = null,

    pub fn record(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        const self: *CapturedInt = @ptrCast(@alignCast(ctx.?));
        if (resolution == .fulfilled and resolution.fulfilled == .integer)
            self.value = resolution.fulfilled.integer;
    }
};

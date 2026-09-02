const actors = @import("glowcap").actors;

pub const NestedCallCapture = struct {
    text_buf: [128]u8 = undefined,
    text_len: usize = 0,
    reason_buf: [128]u8 = undefined,
    reason_len: usize = 0,
    broken: bool = false,

    pub fn record(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        const self: *NestedCallCapture = @ptrCast(@alignCast(ctx.?));
        switch (resolution) {
            .fulfilled => |value| if (value == .string) {
                self.text_len = @min(value.string.len, self.text_buf.len);
                @memcpy(self.text_buf[0..self.text_len], value.string[0..self.text_len]);
            },
            .broken => |message| {
                self.broken = true;
                self.reason_len = @min(message.len, self.reason_buf.len);
                @memcpy(self.reason_buf[0..self.reason_len], message[0..self.reason_len]);
            },
            .give => self.broken = true,
        }
    }

    pub fn text(self: *const NestedCallCapture) []const u8 {
        return self.text_buf[0..self.text_len];
    }

    pub fn reason(self: *const NestedCallCapture) []const u8 {
        return self.reason_buf[0..self.reason_len];
    }
};

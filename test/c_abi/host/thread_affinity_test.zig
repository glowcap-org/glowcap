//! A C Host belongs to the thread that first drives it: a verb from another
//! thread is refused `WrongThread` before it touches Host state.
const std = @import("std");
const c = @import("c_abi");
const host = @import("c_abi_host");
const harness = @import("harness.zig");

const Foreign = struct {
    target: ?*host.GlowcapHost,
    code: i32 = undefined,
    last_error: [128]u8 = undefined,
    last_error_len: usize = 0,

    fn run(self: *Foreign) void {
        var action: host.GlowcapHostAction = undefined;
        self.code = host.glowcap_host_next_action(self.target, &action);
        self.last_error_len = host.glowcap_host_last_error(&self.last_error, self.last_error.len);
    }
};

test "libglowcap_host: a verb off the owning thread is refused WrongThread" {
    const owned = try harness.newHost(0x93);
    defer _ = host.glowcap_host_release(owned);
    var action: host.GlowcapHostAction = undefined;
    try std.testing.expectEqual(c.GLOWCAP_ERR_WOULD_BLOCK, host.glowcap_host_next_action(owned, &action));

    var foreign: Foreign = .{ .target = owned };
    const thread = try std.Thread.spawn(.{}, Foreign.run, .{&foreign});
    thread.join();
    try std.testing.expectEqual(c.GLOWCAP_ERR_INVALID_ARGUMENT, foreign.code);
    const text = foreign.last_error[0..@min(foreign.last_error_len, foreign.last_error.len)];
    try std.testing.expect(std.mem.find(u8, text, "WrongThread") != null);

    // The owner keeps driving after the refusal.
    try std.testing.expectEqual(c.GLOWCAP_ERR_WOULD_BLOCK, host.glowcap_host_next_action(owned, &action));
}

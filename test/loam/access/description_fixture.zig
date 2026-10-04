//! Captured snapshots own their values beyond the callback's bounded borrow.
const std = @import("std");
pub const f = @import("sharing_fixture.zig");
pub const h = f.h;
pub const Capture = struct {
    arena: std.mem.Allocator,
    value: ?f.model.Argument = null,
    failed: bool = false,
    reason_buf: [128]u8 = undefined,
    reason_len: usize = 0,
    pub fn record(context: ?*anyopaque, resolution: h.actors.Resolution) void {
        const self: *Capture = @ptrCast(@alignCast(context.?));
        if (resolution != .fulfilled) {
            self.failed = true;
            if (resolution == .broken) {
                self.reason_len = @min(resolution.broken.len, self.reason_buf.len);
                @memcpy(self.reason_buf[0..self.reason_len], resolution.broken[0..self.reason_len]);
            }
            return;
        }
        self.value = f.model.cloneArgument(self.arena, resolution.fulfilled) catch {
            self.failed = true;
            return;
        };
    }
    pub fn require(self: *const Capture) !f.model.Argument {
        if (self.failed) {
            std.log.err("snapshot reply failed: {s}", .{self.reason_buf[0..self.reason_len]});
            return error.DescriptionFailed;
        }
        return self.value orelse error.Unsettled;
    }
};

pub fn describe(client: *f.Client, server: *h.Hosted, backend: anytype, target: f.model.Reference, arena: std.mem.Allocator) !f.model.Argument {
    var capture: Capture = .{ .arena = arena };
    try client.send(target, "describe-access", &.{}, &capture);
    try server.drain(backend);
    try client.pump();
    return capture.require();
}

pub fn sendLocal(server: *h.Hosted, capture: *Capture) !void {
    _ = try server.host.vat.sendObservedFromIngress(.local, server.host.localActorFor(server.use).?, .{ .verb = "describe-access", .args = &.{} }, .{ .ctx = capture, .func = Capture.record });
}

pub fn expectStatus(value: f.model.Argument, status: []const u8) !void {
    try std.testing.expect(value == .tagged);
    try std.testing.expectEqualStrings("access:description", value.tagged.tag);
    try std.testing.expectEqualStrings(status, value.tagged.value[0].symbol);
    try std.testing.expectEqual(@as(usize, if (std.mem.eql(u8, status, "active")) 6 else 1), value.tagged.value.len);
}

//! Management proofs use held CapTP references and the ordinary owner APIs.
const std = @import("std");
pub const s = @import("sharing_fixture.zig");
pub const h = s.h;
pub const c = h.c;
pub const f = h.f;
pub const core = c.core;
pub const Pair = struct {
    use: s.captures.CapturedRef = .{},
    control: s.captures.CapturedRef = .{},
    pub fn record(ctx: ?*anyopaque, result: h.actors.Resolution) void {
        const self: *Pair = @ptrCast(@alignCast(ctx.?));
        if (result == .fulfilled and result.fulfilled == .list and result.fulfilled.list.len == 2) {
            s.captures.CapturedRef.record(&self.use, .{ .fulfilled = result.fulfilled.list[0] });
            s.captures.CapturedRef.record(&self.control, .{ .fulfilled = result.fulfilled.list[1] });
        } else {
            s.captures.CapturedRef.record(&self.use, result);
            s.captures.CapturedRef.record(&self.control, result);
        }
    }
};
pub const Inspection = struct {
    available: ?bool = null,
    fields: usize = 0,
    pub fn record(ctx: ?*anyopaque, result: h.actors.Resolution) void {
        const self: *Inspection = @ptrCast(@alignCast(ctx.?));
        if (result != .fulfilled or result.fulfilled != .tagged) return;
        const tagged = result.fulfilled.tagged;
        if (!std.mem.eql(u8, tagged.tag, "access:control") or tagged.value.len == 0 or tagged.value[0] != .symbol) return;
        self.fields = tagged.value.len;
        self.available = !std.mem.eql(u8, tagged.value[0].symbol, "unavailable");
    }
};

pub fn decodeManaged(context: ?*anyopaque, arena: std.mem.Allocator, resource: core.ResourceId, args: []const h.driver.Value) !h.access.Service.ManagedIssue {
    if (args.len != 3 or args[2] != .integer) return error.InvalidArguments;
    const request = try s.decode(context, arena, resource, args[0..2]);
    return .{ .request = request, .powers = try powers(args[2].integer, request.ceiling) };
}
pub fn decodeAttenuation(_: ?*anyopaque, _: std.mem.Allocator, _: core.Control.Powers, args: []const h.driver.Value) !core.Control.Powers {
    if (args.len != 1 or args[0] != .integer) return error.InvalidArguments;
    return powers(args[0].integer, null);
}
fn powers(mask: i64, ceiling: ?core.Terms) !core.Control.Powers {
    if (mask < 0 or mask > 15) return error.InvalidArguments;
    return .{ .inspect = mask & 8 != 0, .delegate_control = ceiling != null, .pause = mask & 1 != 0, .resume_access = mask & 2 != 0, .revoke = mask & 4 != 0, .policy_ceiling = ceiling };
}
pub fn configure(server: *h.Hosted) void {
    server.service.decode_managed_derive = decodeManaged;
    server.service.decode_attenuation = decodeAttenuation;
}

pub fn attenuation(caps: *c.storage.Capabilities, backend: anytype, control: *c.storage.Control, powers_: core.Control.Powers) !h.loam.core.ObjectId {
    const op = try control.begin(8);
    defer op.deinit() catch unreachable;
    for (0..128) |_| {
        op.prepareAttenuationCopying(powers_) catch |err| {
            if (err != error.RecordUnloaded) return err;
            _ = try f.pump(op, backend);
            continue;
        };
        break;
    } else return error.NoProgress;
    try caps.store.begin();
    const result = try caps.stageAttenuatedControl(op, .rooted);
    try f.commit(caps.store, backend);
    return result;
}
pub fn revoke(caps: *c.storage.Capabilities, backend: anytype, control: *c.storage.Control) !void {
    const op = try control.begin(8);
    defer op.deinit() catch unreachable;
    _ = try f.pump(op, backend);
    const changed = try prepareRevocation(op, backend);
    try std.testing.expect(changed);
    try caps.store.begin();
    try std.testing.expect(try op.stageControlRevocation());
    try f.commit(caps.store, backend);
}

pub fn prepareRevocation(op: *c.storage.Operation, backend: anytype) !bool {
    return for (0..128) |_| {
        const changed = op.prepareControlRevocation() catch |err| {
            if (err != error.RecordUnloaded) return err;
            _ = try f.pump(op, backend);
            continue;
        };
        break changed;
    } else return error.NoProgress;
}

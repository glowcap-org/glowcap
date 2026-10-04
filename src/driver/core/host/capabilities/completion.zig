//! Projection borrows an action's owned Value and grants independent consumer
//! retains. The stable tree is its own rollback receipt; no scratch allocation
//! or second value materialization is needed.
const std = @import("std");
const host_mod = @import("../../host.zig");
const value_mod = @import("../../value.zig");
const action_mod = @import("../action.zig");
const Host = host_mod.Host;

fn projectedValueType(comptime project: anytype) type {
    return @typeInfo(@typeInfo(@TypeOf(project)).@"fn".return_type.?).error_union.payload;
}

pub fn ProjectedCompletion(comptime T: type) type {
    return union(enum) {
        settled: struct { vow_id: u64, value: T },
        failed: struct { vow_id: u64, failure: action_mod.VowFailure, message: []const u8 },
    };
}

const Retains = struct {
    host: *Host,
    count: usize = 0,

    fn acquire(self: *Retains, ref: value_mod.Capability) !void {
        const target = self.host.capabilities.resolve(ref) orelse {
            if (self.host.capabilities.retainCount(ref) != null) return error.CapabilityClosed;
            return error.UnknownCapability;
        };
        _ = try self.host.capabilities.retain(self.host.allocator, target);
        self.count += 1;
    }

    fn rollback(self: *Retains, ref: value_mod.Capability) !void {
        if (self.count == 0) return;
        self.count -= 1;
        // The action still owns its occurrence, so undoing this application
        // retain cannot retire authority or send wire GC.
        const retired = self.host.capabilities.release(ref, 1) catch unreachable;
        std.debug.assert(retired == null);
    }
};

fn projectOwned(self: *Host, value: value_mod.Value, context: anytype, comptime project: anytype) !projectedValueType(project) {
    self.assertOwner();
    var retained = Retains{ .host = self };
    errdefer value.forEachCapability(&retained, Retains.rollback) catch unreachable;
    try value.forEachCapability(&retained, Retains.acquire);
    return try project(context, value);
}

/// The callback projects representation only. Its successful result owns one
/// retain per capability occurrence; its bytes borrow the action unless the
/// callback copies them. A refusal leaves the action available for retry.
pub fn projectCompletion(
    self: *Host,
    action: action_mod.HostAction,
    context: anytype,
    comptime project: anytype,
) ProjectedCompletion(projectedValueType(project)) {
    return switch (action) {
        .settled => |settled| blk: {
            const projected = projectOwned(self, settled.value, context, project) catch |err| {
                break :blk .{ .failed = .{
                    .vow_id = settled.vow_id,
                    .failure = if (err == error.CapabilityClosed) .closed else .broken,
                    .message = if (err == error.CapabilityClosed)
                        "resolution capability closed before value projection"
                    else
                        "resolution value could not be projected",
                } };
            };
            break :blk .{ .settled = .{ .vow_id = settled.vow_id, .value = projected } };
        },
        .failed => |failed| .{ .failed = .{
            .vow_id = failed.vow_id,
            .failure = failed.failure,
            .message = failed.message.bytes(),
        } },
        else => unreachable,
    };
}

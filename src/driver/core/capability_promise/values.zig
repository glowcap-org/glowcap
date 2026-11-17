//! Owned Passable snapshots queued behind unresolved capability promises.
//!
//! Caller values are borrowed and the eventual destination session is not yet
//! known. This clone retains every nested Host capability while one arena owns
//! the remaining tree, giving the promise queue one rollback authority.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const host_mod = @import("../host.zig");
const capability = @import("../capability.zig");
const capability_promise = @import("../capability_promise.zig");
const value_mod = @import("../value.zig");

const Host = host_mod.Host;

/// Everything the clone walk can refuse. The walk is recursive, so its set is
/// spelled from the non-recursive steps it takes.
pub const CloneError = error{ ValueTooDeep, UnknownCapability } ||
    std.mem.Allocator.Error ||
    foundation.error_sets.Of(capability.Registry.retain);

/// A structural copy: capabilities keep their identity whatever they settled
/// to. Held replies and answer data are read through this one.
pub fn cloneValues(
    self: *Host,
    allocator: std.mem.Allocator,
    values: []const value_mod.Value,
    retained: *std.ArrayList(capability.Ref),
) CloneError![]value_mod.Value {
    return cloneSlice(false, self, allocator, values, retained, 0);
}

/// The copy a send queues. A promise that already settled to data lowers as
/// that data at the depth it sits, so the copy also refuses data that would not
/// fit there instead of failing after the send queues.
pub fn cloneForSend(
    self: *Host,
    allocator: std.mem.Allocator,
    values: []const value_mod.Value,
    retained: *std.ArrayList(capability.Ref),
) CloneError![]value_mod.Value {
    return cloneSlice(true, self, allocator, values, retained, 0);
}

/// The items of the container at `depth`.
fn cloneValuesAt(
    comptime admit_settled: bool,
    self: *Host,
    allocator: std.mem.Allocator,
    values: []const value_mod.Value,
    retained: *std.ArrayList(capability.Ref),
    depth: usize,
) CloneError![]value_mod.Value {
    if (!model.mayHoldItems(depth)) return error.ValueTooDeep;
    return cloneSlice(admit_settled, self, allocator, values, retained, depth + 1);
}

/// `values` as elements at `depth`.
fn cloneSlice(
    comptime admit_settled: bool,
    self: *Host,
    allocator: std.mem.Allocator,
    values: []const value_mod.Value,
    retained: *std.ArrayList(capability.Ref),
    depth: usize,
) CloneError![]value_mod.Value {
    const out = try allocator.alloc(value_mod.Value, values.len);
    for (values, 0..) |value, index|
        out[index] = try cloneValue(admit_settled, self, allocator, value, retained, depth);
    return out;
}

fn cloneValue(
    comptime admit_settled: bool,
    self: *Host,
    allocator: std.mem.Allocator,
    value: value_mod.Value,
    retained: *std.ArrayList(capability.Ref),
    depth: usize,
) CloneError!value_mod.Value {
    return switch (value) {
        .bytes => |bytes| .{ .bytes = try allocator.dupe(u8, bytes) },
        .symbol => |symbol| .{ .symbol = try allocator.dupe(u8, symbol) },
        .capability => |ref| blk: {
            const target = self.capabilities.resolve(ref) orelse return error.UnknownCapability;
            // A send lowers a promise that settled to data as that data, at the
            // depth the capability sits, so the data must fit there.
            if (admit_settled and target == .deferred) if (capability_promise.settledData(self, target.deferred)) |data|
                try settledDataFits(self, data, depth);
            const owned = try self.capabilities.retain(self.allocator, target);
            errdefer _ = self.capabilities.release(owned, 1) catch unreachable;
            try retained.append(allocator, owned);
            break :blk .{ .capability = owned };
        },
        .@"error" => |reason| .{ .@"error" = .{
            .message = try allocator.dupe(u8, reason.message),
        } },
        .string => |string| .{ .string = try allocator.dupe(u8, string) },
        .integer => |integer| .{ .integer = integer },
        .integers => |words| blk: {
            if (!model.mayHoldItems(depth)) return error.ValueTooDeep;
            break :blk .{ .integers = try allocator.dupe(i64, words) };
        },
        .boolean => |boolean| .{ .boolean = boolean },
        .list => |items| .{ .list = try cloneValuesAt(admit_settled, self, allocator, items, retained, depth) },
        .void => .{ .void = {} },
        .float64 => |float| .{ .float64 = float },
        .set => |items| .{ .set = try cloneValuesAt(admit_settled, self, allocator, items, retained, depth) },
        .tagged => |tagged| .{ .tagged = .{
            .tag = try allocator.dupe(u8, tagged.tag),
            .value = try cloneValuesAt(admit_settled, self, allocator, tagged.value, retained, depth),
        } },
        .keyword => |keyword| .{ .keyword = try allocator.dupe(u8, keyword) },
        .big_integer => |big| .{ .big_integer = .{
            .negative = big.negative,
            .digits = try allocator.dupe(u8, big.digits),
        } },
        .@"struct" => |entries| blk: {
            if (!model.mayHoldItems(depth)) return error.ValueTooDeep;
            const out = try allocator.alloc(value_mod.Value.StructEntry, entries.len);
            for (entries, 0..) |entry, index| out[index] = .{
                .key = try allocator.dupe(u8, entry.key),
                .value = try cloneValue(admit_settled, self, allocator, entry.value, retained, depth + 1),
            };
            break :blk .{ .@"struct" = out };
        },
    };
}

/// Whether `data`, a settled promise's value, lowers at `depth`. The walk
/// allocates and copies nothing. A root capability that is itself a settled
/// promise stands for its data at the same depth. That chain ends because an
/// inline give settles through `capability_promise.fulfill`, which lifts a
/// routed reference, and `identity.liftCapabilityTracked` accepts only a remote
/// target there and rejects a deferred one. A settled root capability
/// therefore never names the deferred that holds it.
fn settledDataFits(self: *Host, data: *const value_mod.Value, depth: usize) CloneError!void {
    switch (data.*) {
        .capability => |ref| {
            const target = self.capabilities.resolve(ref) orelse return;
            if (target != .deferred) return;
            const inner = capability_promise.settledData(self, target.deferred) orelse return;
            try settledDataFits(self, inner, depth);
        },
        .integers => if (!model.mayHoldItems(depth)) return error.ValueTooDeep,
        .list, .set => |items| {
            if (!model.mayHoldItems(depth)) return error.ValueTooDeep;
            for (items) |*item| try settledDataFits(self, item, depth + 1);
        },
        .tagged => |tagged| {
            if (!model.mayHoldItems(depth)) return error.ValueTooDeep;
            for (tagged.value) |*item| try settledDataFits(self, item, depth + 1);
        },
        .@"struct" => |entries| {
            if (!model.mayHoldItems(depth)) return error.ValueTooDeep;
            for (entries) |*entry| try settledDataFits(self, &entry.value, depth + 1);
        },
        .bytes, .symbol, .@"error", .string, .integer, .boolean, .void, .float64, .keyword, .big_integer => {},
    }
}

pub fn rollbackRetains(self: *Host, retained: []const capability.Ref) void {
    var index = retained.len;
    while (index != 0) {
        index -= 1;
        const retired = self.capabilities.release(retained[index], 1) catch unreachable;
        std.debug.assert(retired == null);
    }
}

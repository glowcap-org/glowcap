//! The nesting ceiling at the Vat's own Argument entries: a queued send, a
//! borrowed reply materialized for the caller, and an owned reply cloned
//! ahead of a replacement. These walk `model.Argument`, so they hold the
//! count the session holds (a leaf at `model.max_value_depth`, no container
//! there) and refuse a deeper tree as `MalformedView` before any effect.
//! Each case asserts the admitted side ran, so a refusal is not a vacuous pass.

const std = @import("std");
const glowcap = @import("glowcap");
const shapes = @import("../support/depth_shapes.zig");

const model = glowcap.ocapn.model;
const actors = glowcap.actors;
const allocator = std.testing.allocator;

const Counting = struct {
    calls: *usize,
    pub fn handle(self: *Counting, _: *actors.Turn, _: actors.Delivery) !model.Argument {
        self.calls.* += 1;
        return .{ .void = {} };
    }
};

test "a queued send to a local actor refuses a tree past the ceiling before it queues" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    for (shapes.owned) |shape| for (shapes.sweep) |depth| {
        var vat = actors.Vat.init(allocator);
        defer vat.deinit();
        var calls: usize = 0;
        const target = try vat.spawn(Counting, .{ .calls = &calls });
        const args = try shapes.ownedArgs(arena.allocator(), depth, shape);
        const sent = vat.send(target, .{ .verb = "poke", .args = args });
        if (shapes.admitted(shape, depth)) {
            _ = try sent;
            try vat.drive();
            try std.testing.expectEqual(@as(usize, 1), calls);
        } else {
            try std.testing.expectError(error.MalformedView, sent);
            try vat.drive();
            try std.testing.expectEqual(@as(usize, 0), calls);
        }
    };
}

/// Replies with a borrowed tree built in the turn arena.
const Viewed = struct {
    depth: usize,
    shape: shapes.Shape,
    pub fn handle(self: *Viewed, turn: *actors.Turn, _: actors.Delivery) !actors.HostedActor.Result {
        const args = try shapes.viewArgs(turn.arena, self.depth, self.shape);
        return .{ .viewed = try args.at(0) };
    }
};

test "a borrowed reply is materialized for the caller at the session's count" {
    for (shapes.all) |shape| for (shapes.sweep) |depth| {
        var vat = actors.Vat.init(allocator);
        defer vat.deinit();
        const actor = try vat.spawn(Viewed, .{ .depth = depth, .shape = shape });
        const result = vat.near(actor, .{ .verb = "reply" });
        if (shapes.admitted(shape, depth)) {
            _ = try result;
        } else {
            try std.testing.expectError(error.MalformedView, result);
        }
    };
}

const Replacement = struct {
    pub fn handle(_: *Replacement, _: *actors.Turn, _: actors.Delivery) !model.Argument {
        return .{ .void = {} };
    }
};

/// Replies with an owned tree and replaces itself, so the reply is cloned
/// before the old state is freed.
const Replacing = struct {
    depth: usize,
    shape: shapes.Shape,
    pub fn handle(self: *Replacing, turn: *actors.Turn, _: actors.Delivery) !model.Argument {
        try turn.become(Replacement, .{});
        return (try shapes.ownedArgs(turn.arena, self.depth, self.shape))[0];
    }
};

test "an owned reply cloned ahead of a replacement holds the session's count" {
    for (shapes.owned) |shape| for (shapes.sweep) |depth| {
        var vat = actors.Vat.init(allocator);
        defer vat.deinit();
        const actor = try vat.spawn(Replacing, .{ .depth = depth, .shape = shape });
        const result = vat.near(actor, .{ .verb = "reply" });
        if (shapes.admitted(shape, depth)) {
            _ = try result;
        } else {
            try std.testing.expectError(error.MalformedView, result);
        }
    };
}

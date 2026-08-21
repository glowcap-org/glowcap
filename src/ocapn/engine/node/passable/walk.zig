//! The recursive tree passes for one inline-Passable transaction.
//!
//! Root selection is semantic: an ordinary deliver contributes its argument
//! vector, while answer and relayed settlements contribute their resolution.
//! All roots then share these count, collect, rewrite, and rollback passes.

const std = @import("std");
const model = @import("model");
const Error = @import("../../node_services.zig").OutboundStagingError;

pub const Counts = struct {
    objects: usize = 0,
    promises: usize = 0,

    pub fn add(self: Counts, other: Counts) Error!Counts {
        return .{
            .objects = std.math.add(usize, self.objects, other.objects) catch
                return error.QueueCapExceeded,
            .promises = std.math.add(usize, self.promises, other.promises) catch
                return error.QueueCapExceeded,
        };
    }

    pub fn total(self: Counts) Error!usize {
        return std.math.add(usize, self.objects, self.promises) catch
            return error.QueueCapExceeded;
    }
};

pub fn count(node: anytype, recipient_peer: anytype, payload: anytype) Error!Counts {
    return switch (payload) {
        .outbound => |outbound| switch (outbound) {
            .message => |message| switch (message) {
                .deliver => |deliver| countArguments(node, recipient_peer, deliver.args),
                else => .{},
            },
            .answer_settlement => |settlement| countResolution(
                node,
                recipient_peer,
                settlement.resolution,
            ),
        },
        .relayed_resolution => |resolution| countResolution(node, recipient_peer, resolution),
    };
}

fn countResolution(node: anytype, recipient_peer: anytype, resolution: model.Resolution) Error!Counts {
    return switch (resolution) {
        .fulfill => |arg| countArgument(node, recipient_peer, arg),
        .@"break" => .{},
    };
}

fn countArguments(node: anytype, recipient_peer: anytype, args: []const model.Argument) Error!Counts {
    var counts: Counts = .{};
    for (args) |arg| counts = try counts.add(try countArgument(node, recipient_peer, arg));
    return counts;
}

fn countArgument(node: anytype, recipient_peer: anytype, arg: model.Argument) Error!Counts {
    return switch (arg) {
        .reference => |reference| if (try node.inlineProjectionRoute(recipient_peer, reference)) |projection|
            switch (projection.kind) {
                .object => .{ .objects = 1 },
                .promise => .{ .promises = 1 },
            }
        else
            .{},
        .list, .set => |items| countArguments(node, recipient_peer, items),
        .tagged => |tagged| countArguments(node, recipient_peer, tagged.value),
        .@"struct" => |entries| blk: {
            var counts: Counts = .{};
            for (entries) |entry| counts = try counts.add(
                try countArgument(node, recipient_peer, entry.value),
            );
            break :blk counts;
        },
        else => .{},
    };
}

pub fn collect(
    node: anytype,
    recipient_peer: anytype,
    payload: anytype,
    gifts: anytype,
    promises: anytype,
) Error!void {
    var gift_index: usize = 0;
    var promise_index: usize = 0;
    switch (payload) {
        .outbound => |outbound| switch (outbound) {
            .message => |message| switch (message) {
                .deliver => |deliver| try collectArguments(
                    node,
                    recipient_peer,
                    deliver.args,
                    gifts,
                    promises,
                    &gift_index,
                    &promise_index,
                ),
                else => {},
            },
            .answer_settlement => |settlement| try collectResolution(
                node,
                recipient_peer,
                settlement.resolution,
                gifts,
                promises,
                &gift_index,
                &promise_index,
            ),
        },
        .relayed_resolution => |resolution| try collectResolution(
            node,
            recipient_peer,
            resolution,
            gifts,
            promises,
            &gift_index,
            &promise_index,
        ),
    }
    std.debug.assert(gift_index == gifts.len);
    std.debug.assert(promise_index == promises.len);
}

fn collectResolution(node: anytype, recipient_peer: anytype, resolution: model.Resolution, gifts: anytype, promises: anytype, gift_index: *usize, promise_index: *usize) Error!void {
    switch (resolution) {
        .fulfill => |arg| try collectArgument(node, recipient_peer, arg, gifts, promises, gift_index, promise_index),
        .@"break" => {},
    }
}

fn collectArguments(node: anytype, recipient_peer: anytype, args: []const model.Argument, gifts: anytype, promises: anytype, gift_index: *usize, promise_index: *usize) Error!void {
    for (args) |arg| try collectArgument(node, recipient_peer, arg, gifts, promises, gift_index, promise_index);
}

fn collectArgument(node: anytype, recipient_peer: anytype, arg: model.Argument, gifts: anytype, promises: anytype, gift_index: *usize, promise_index: *usize) Error!void {
    switch (arg) {
        .reference => |reference| if (try node.inlineProjectionRoute(recipient_peer, reference)) |projection| {
            switch (projection.kind) {
                .object => {
                    gifts[gift_index.*] = .{
                        .route_id = projection.route_id,
                        .home = projection.home,
                        .original = reference,
                        .gifted = projection.source,
                    };
                    gift_index.* += 1;
                },
                .promise => {
                    promises[promise_index.*] = .{
                        .route_id = projection.route_id,
                        .home = projection.home,
                        .original = reference,
                        .source = projection.source.far,
                    };
                    promise_index.* += 1;
                },
            }
        },
        .list, .set => |items| try collectArguments(node, recipient_peer, items, gifts, promises, gift_index, promise_index),
        .tagged => |tagged| try collectArguments(node, recipient_peer, tagged.value, gifts, promises, gift_index, promise_index),
        .@"struct" => |entries| for (entries) |entry|
            try collectArgument(node, recipient_peer, entry.value, gifts, promises, gift_index, promise_index),
        else => {},
    }
}

pub fn replace(node: anytype, batch: anytype) Error!void {
    var gift_index: usize = 0;
    var promise_index: usize = 0;
    switch (batch.payload) {
        .outbound => |*outbound| switch (outbound.*) {
            .message => |*message| switch (message.*) {
                .deliver => |deliver| try replaceArguments(node, batch, deliver.args, &gift_index, &promise_index),
                else => unreachable,
            },
            .answer_settlement => |*settlement| try replaceResolution(node, batch, &settlement.resolution, &gift_index, &promise_index),
        },
        .relayed_resolution => |*resolution| try replaceResolution(node, batch, resolution, &gift_index, &promise_index),
    }
    if (gift_index != batch.gifts.len or promise_index != batch.promises.len)
        return error.RouteNotLowerable;
}

fn replaceResolution(node: anytype, batch: anytype, resolution: *model.Resolution, gift_index: *usize, promise_index: *usize) Error!void {
    switch (resolution.*) {
        .fulfill => |*arg| try replaceArgument(node, batch, arg, gift_index, promise_index),
        .@"break" => {},
    }
}

fn replaceArguments(node: anytype, batch: anytype, args: []const model.Argument, gift_index: *usize, promise_index: *usize) Error!void {
    for (@constCast(args)) |*arg| try replaceArgument(node, batch, arg, gift_index, promise_index);
}

fn replaceArgument(node: anytype, batch: anytype, arg: *model.Argument, gift_index: *usize, promise_index: *usize) Error!void {
    switch (arg.*) {
        .reference => |reference| if (try node.inlineProjectionRoute(batch.recipient_peer, reference)) |projection| {
            switch (projection.kind) {
                .object => {
                    const gift = &batch.gifts[gift_index.*];
                    if (gift.route_id != projection.route_id or gift.home != projection.home or
                        !std.meta.eql(gift.original, reference)) return error.RouteNotLowerable;
                    const handoff = gift.handoff orelse return error.RouteNotLowerable;
                    arg.* = .{ .handoff = handoff };
                    gift.handoff = null;
                    gift.inserted_handoff = handoff;
                    gift_index.* += 1;
                },
                .promise => {
                    const promise = &batch.promises[promise_index.*];
                    if (promise.route_id != projection.route_id or promise.home != projection.home or
                        !std.meta.eql(promise.original, reference)) return error.RouteNotLowerable;
                    arg.* = .{ .reference = promise.projected orelse return error.RouteNotLowerable };
                    promise.inserted_at = arg;
                    promise_index.* += 1;
                },
            }
        },
        .list, .set => |items| try replaceArguments(node, batch, items, gift_index, promise_index),
        .tagged => |tagged| try replaceArguments(node, batch, tagged.value, gift_index, promise_index),
        .@"struct" => |entries| for (@constCast(entries)) |*entry|
            try replaceArgument(node, batch, &entry.value, gift_index, promise_index),
        else => {},
    }
}

pub fn restore(batch: anytype) void {
    var gift_index: usize = 0;
    var promise_index: usize = 0;
    switch (batch.payload) {
        .outbound => |*outbound| switch (outbound.*) {
            .message => |*message| switch (message.*) {
                .deliver => |deliver| restoreArguments(batch, deliver.args, &gift_index, &promise_index),
                else => {},
            },
            .answer_settlement => |*settlement| restoreResolution(batch, &settlement.resolution, &gift_index, &promise_index),
        },
        .relayed_resolution => |*resolution| restoreResolution(batch, resolution, &gift_index, &promise_index),
    }
}

fn restoreResolution(batch: anytype, resolution: *model.Resolution, gift_index: *usize, promise_index: *usize) void {
    switch (resolution.*) {
        .fulfill => |*arg| restoreArgument(batch, arg, gift_index, promise_index),
        .@"break" => {},
    }
}

fn restoreArguments(batch: anytype, args: []const model.Argument, gift_index: *usize, promise_index: *usize) void {
    for (@constCast(args)) |*arg| restoreArgument(batch, arg, gift_index, promise_index);
}

fn restoreArgument(batch: anytype, arg: *model.Argument, gift_index: *usize, promise_index: *usize) void {
    switch (arg.*) {
        .handoff => |handoff| if (gift_index.* < batch.gifts.len and batch.gifts[gift_index.*].inserted_handoff == handoff) {
            const gift = &batch.gifts[gift_index.*];
            gift.handoff = handoff;
            gift.inserted_handoff = null;
            arg.* = .{ .reference = gift.original };
            gift_index.* += 1;
        },
        .reference => if (promise_index.* < batch.promises.len and batch.promises[promise_index.*].inserted_at == arg) {
            const promise = &batch.promises[promise_index.*];
            arg.* = .{ .reference = promise.original };
            promise.inserted_at = null;
            promise_index.* += 1;
        },
        .list, .set => |items| restoreArguments(batch, items, gift_index, promise_index),
        .tagged => |tagged| restoreArguments(batch, tagged.value, gift_index, promise_index),
        .@"struct" => |entries| for (@constCast(entries)) |*entry|
            restoreArgument(batch, &entry.value, gift_index, promise_index),
        else => {},
    }
}

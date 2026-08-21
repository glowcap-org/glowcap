//! Send-side export accounting for session apply.
//!
//! Every `near` reference we put on the wire grants the partner one export
//! wire-delta retain. Resolution storage can also establish exports before a
//! listener callback mentions them.

const model = @import("model");
const session = @import("../mod.zig");

const Session = session.Session;
const Error = session.Error;
const RecvViewError = session.RecvViewError;
const BOOTSTRAP_POSITION = session.BOOTSTRAP_POSITION;

/// Retain a wire reference for every `near` export this outbound message puts
/// on the wire. This is the outbound mirror of inbound introduced-import
/// installation.
pub fn retainMessage(self: *Session, message: model.Message) !void {
    switch (message) {
        .deliver => |deliver| {
            try retainRef(self, deliver.target);
            if (deliver.resolve_me_desc) |reference| try retainRef(self, reference);
            try retainArgs(self, deliver.args, 0);
        },
        .resolve => |resolve| switch (resolve.resolution) {
            .fulfill => |arg| try retainArg(self, arg, 0),
            .@"break" => {},
        },
        .listen => |listen| {
            try retainRef(self, listen.target);
            try retainRef(self, listen.listener);
        },
        // Projection ops put their receiver reference on the wire just like a
        // deliver target, so a `near` receiver takes the same wire-delta retain.
        .get => |get| try retainRef(self, get.receiver),
        .index => |index| try retainRef(self, index.receiver),
        .untag => |untag| try retainRef(self, untag.receiver),
        // Exhaustive on purpose: a new sendable kind that can carry a `near`
        // export must declare the retain above.
        .gc_export, .gc_answer, .start_session, .abort => {},
    }
}

/// Retain the wire mention of one sent export reference. Public because the
/// engine's V1.0 resolver augmentation puts a resolver mention on the wire at
/// encode time, bypassing `recordSend`.
pub fn retainRef(self: *Session, reference: model.Reference) !void {
    switch (reference) {
        .near => |near| if (near.export_position.int() != BOOTSTRAP_POSITION) {
            try establishRef(self, near);
            // A live row's cell is authoritative from establishment. A
            // re-mention only takes the wire-delta retain; it never rebinds the
            // cell from `near.kind`.
            try self.exports.retain(self.allocator, near.export_position);
        },
        else => {},
    }
}

fn establishRef(self: *Session, near: model.NearRef) !void {
    if (near.export_position.int() == BOOTSTRAP_POSITION or self.exports.contains(near.export_position)) return;
    // A resolution may establish an export before next puts it on the wire.
    // Establish the local baseline separately from wire-delta accounting so a
    // later listener callback can retain exactly its own mention.
    try self.admitExportPositionForMarshal(near.export_position);
    const cell: session.slot.Slot = switch (near.kind) {
        .object => .{ .local_value = near.export_position.int() },
        .promise => .{ .local_unresolved = near.export_position.int() },
    };
    try self.exports.registerCell(self.allocator, near.export_position, cell);
}

fn retainArgs(self: *Session, args: []const model.Argument, depth: usize) RecvViewError!void {
    return recordArgs(self, args, depth, true);
}

fn retainArg(self: *Session, arg: model.Argument, depth: usize) RecvViewError!void {
    return recordArg(self, arg, depth, true);
}

pub fn recordResolutionArg(
    self: *Session,
    arg: model.Argument,
    wire_mention: bool,
) RecvViewError!void {
    return recordArg(self, arg, 0, wire_mention);
}

fn recordArgs(
    self: *Session,
    args: []const model.Argument,
    depth: usize,
    wire_mention: bool,
) RecvViewError!void {
    if (depth > self.limits.max_nesting_depth) return Error.NestingTooDeep;
    for (args) |arg| try recordArg(self, arg, depth, wire_mention);
}

fn recordArg(
    self: *Session,
    arg: model.Argument,
    depth: usize,
    wire_mention: bool,
) RecvViewError!void {
    switch (arg) {
        .reference => |reference| switch (reference) {
            .near => |near| if (wire_mention)
                try retainRef(self, reference)
            else
                try establishRef(self, near),
            else => {},
        },
        .list, .set => |items| try recordArgs(self, items, depth + 1, wire_mention),
        .tagged => |tagged| try recordArgs(self, tagged.value, depth + 1, wire_mention),
        .@"struct" => |entries| {
            if (depth + 1 > self.limits.max_nesting_depth) return Error.NestingTooDeep;
            for (entries) |entry| try recordArg(self, entry.value, depth + 1, wire_mention);
        },
        // Exhaustive on purpose: a new Argument arm must decide whether it can
        // name an export, see `session/validate/passable.zig`'s argument walk.
        .bytes, .symbol, .string, .keyword, .integer, .big_integer, .boolean, .float64, .void, .@"error", .handoff => {},
    }
}

/// Preallocate the export-table rows a stored resolution can first establish
/// when listener fires are committed. Counting mentions rather than distinct
/// positions may overreserve, but leaves later commits allocation-free.
pub fn ensureResolutionCapacity(self: *Session, resolution: model.Resolution) !void {
    const mentions = switch (resolution) {
        .fulfill => |arg| countNearMentions(arg),
        .@"break" => 0,
    };
    try self.exports.ensureUnusedCapacity(self.allocator, mentions);
}

fn countNearMentions(arg: model.Argument) usize {
    return switch (arg) {
        .reference => |reference| @intFromBool(reference == .near and reference.near.export_position.int() != BOOTSTRAP_POSITION),
        .list, .set => |items| blk: {
            var count: usize = 0;
            for (items) |item| count +|= countNearMentions(item);
            break :blk count;
        },
        .tagged => |tagged| blk: {
            var count: usize = 0;
            for (tagged.value) |item| count +|= countNearMentions(item);
            break :blk count;
        },
        .@"struct" => |entries| blk: {
            var count: usize = 0;
            for (entries) |entry| count +|= countNearMentions(entry.value);
            break :blk count;
        },
        .bytes, .symbol, .string, .keyword, .integer, .big_integer, .boolean, .float64, .void, .@"error", .handoff => 0,
    };
}

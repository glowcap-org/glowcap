//! Send-side export accounting for session apply.
//!
//! Every `near` reference we put on the wire grants the partner one export
//! wire-delta retain. Resolution storage can also establish exports before a
//! listener callback mentions them.

const std = @import("std");
const model = @import("model");
const session = @import("../mod.zig");

const Session = session.Session;
const Error = session.Error;
const RecvViewError = session.RecvViewError;
const BOOTSTRAP_POSITION = session.BOOTSTRAP_POSITION;

/// Retain a wire reference for every `near` export this outbound message puts
/// on the wire. This is the outbound mirror of inbound introduced-import
/// installation.
pub fn retainMessage(self: *Session, message: model.Message, inventory: session.Inventory) !void {
    switch (message) {
        .deliver => |deliver| {
            try retainRef(self, deliver.target);
            if (deliver.resolve_me_desc) |reference| try retainRef(self, reference);
            try recordMentions(self, inventory, null, true);
        },
        // A sent resolution moves into the answer store through
        // `applySentResolve`, which records its mentions itself.
        .resolve => unreachable,
        .listen => |listen| {
            try retainRef(self, listen.target);
            try retainRef(self, listen.listener);
        },
        // Projection ops put their receiver reference on the wire just like a
        // deliver target, so a `near` receiver takes the same wire-delta retain.
        .get => |get| try retainRef(self, get.receiver),
        .index => |index| try retainRef(self, index.receiver),
        .untag => |untag| try retainRef(self, untag.receiver),
        // Exhaustive: a new sendable kind that can carry a `near`
        // export must declare the retain above.
        .gc_export, .gc_answer, .start_session, .abort => {},
    }
}

/// The positions `retainMessage` retains for `message`, in the same order,
/// for a carrier that gives up the tree at admission and must still hand
/// them back through `releaseExports` (ADR-0236). Empty, with no allocation,
/// for a message that mentions no near export.
pub fn listSentExports(
    self: *const Session,
    allocator: std.mem.Allocator,
    message: model.Message,
    inventory: session.Inventory,
) ![]model.ExportPosition {
    _ = self;
    var count: usize = 0;
    var list: ?[]model.ExportPosition = null;
    // Two identical passes over the mentions: the first counts, the second
    // fills, so the list is one exact allocation or none.
    for (0..2) |pass| {
        var index: usize = 0;
        var mentions = Mentions{ .list = list, .index = &index };
        switch (message) {
            .deliver => |deliver| {
                mentions.add(deliver.target);
                if (deliver.resolve_me_desc) |reference| mentions.add(reference);
                for (inventory.slots) |slot| switch (slot.read(null).*) {
                    .reference => |reference| mentions.add(reference),
                    else => {},
                };
            },
            .get => |get| mentions.add(get.receiver),
            .index => |projection| mentions.add(projection.receiver),
            .untag => |untag| mentions.add(untag.receiver),
            // The kinds that leave at admission. A listen keeps its tree and
            // withdraws through `releaseMessage`.
            else => unreachable,
        }
        if (pass == 0) {
            count = index;
            if (count == 0) return &.{};
            list = try allocator.alloc(model.ExportPosition, count);
        } else std.debug.assert(index == count);
    }
    return list.?;
}

const Mentions = struct {
    list: ?[]model.ExportPosition,
    index: *usize,

    fn add(self: *Mentions, reference: model.Reference) void {
        const position = reference.exportPosition() orelse return;
        if (position.int() == BOOTSTRAP_POSITION) return;
        if (self.list) |list| list[self.index.*] = position;
        self.index.* += 1;
    }
};

/// Release exactly the retains `retainMessage` took for a message that left
/// at admission and never reached the wire (ADR-0194): the positions
/// `listSentExports` listed for it. Every row is live with this retain on top
/// of its baseline, so no decrement can underflow or retire the row.
pub fn releaseExports(self: *Session, exports: []const model.ExportPosition) void {
    for (exports) |position| {
        std.debug.assert(self.exports.count(position) >= 2);
        self.exports.decrement(position, 1) catch unreachable;
    }
}

/// Release exactly the retains `retainMessage` took for a queued `listen`
/// that never reached the wire: a promise proxy's home listen, withdrawn with
/// the turn whose send created it. `retractPreparedListen` asserts the kind.
pub fn releaseMessage(self: *Session, message: model.Message) void {
    releaseRef(self, message.listen.target);
    releaseRef(self, message.listen.listener);
}

fn releaseRef(self: *Session, reference: model.Reference) void {
    switch (reference) {
        .near => |near| if (near.export_position.int() != BOOTSTRAP_POSITION) {
            std.debug.assert(self.exports.count(near.export_position) >= 2);
            self.exports.decrement(near.export_position, 1) catch unreachable;
        },
        else => {},
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

/// Record every `near` export the inventory's references name: a wire mention
/// takes the wire-delta retain, and a stored-only mention establishes the
/// local baseline so a later listener callback can retain exactly its own
/// mention. `root` resolves the inventory's by-value root.
pub fn recordMentions(
    self: *Session,
    inventory: session.Inventory,
    root: ?*const model.Argument,
    wire_mention: bool,
) RecvViewError!void {
    for (inventory.slots) |slot| switch (slot.read(root).*) {
        .reference => |reference| switch (reference) {
            .near => |near| if (wire_mention)
                try retainRef(self, reference)
            else
                try establishRef(self, near),
            else => {},
        },
        .set, .handoff => {},
        else => unreachable,
    };
}

/// Preallocate the export-table rows a stored resolution can first establish
/// when listener fires are committed. Counting mentions rather than distinct
/// positions may overreserve, but leaves later commits allocation-free.
pub fn ensureResolutionCapacity(
    self: *Session,
    resolution: model.Resolution,
    inventory: session.Inventory,
) !void {
    const root: ?*const model.Argument = if (resolution == .fulfill) &resolution.fulfill else null;
    var mentions: usize = 0;
    for (inventory.slots) |slot| switch (slot.read(root).*) {
        .reference => |reference| mentions += @intFromBool(reference == .near and
            reference.near.export_position.int() != BOOTSTRAP_POSITION),
        else => {},
    };
    try self.exports.ensureUnusedCapacity(self.allocator, mentions);
}

//! Custody of local projection occurrences in an adopted Passable tree.
//! Admission uses its existing inventory. Release walks the still-owned tree
//! instead of allocating a second reference index. The tree is depth-bounded
//! by that inventory. No validation or graph traversal is repeated here.
const model = @import("model");
const session = @import("session");
const passable = @import("../passable.zig");
const Custody = session.Session.LocalPromiseCustody;

pub fn acquire(owner: *session.Session, payload: *passable.Outbound, inventory: session.Inventory, stamp: u64) error{QueueCapExceeded}!void {
    const resolver = resolverReference(payload);
    if (resolver) |reference| try Custody.retain(owner, reference, stamp);
    errdefer if (resolver) |reference| Custody.release(owner, reference, stamp);
    const root = payload.resolutionRoot();
    for (inventory.slots, 0..) |slot, index| {
        const value = slot.read(root).*;
        if (value != .reference) continue;
        Custody.retain(owner, value.reference, stamp) catch |err| {
            for (inventory.slots[0..index]) |prior| {
                const previous = prior.read(root).*;
                if (previous == .reference) Custody.release(owner, previous.reference, stamp);
            }
            return err;
        };
    }
}

pub fn release(owner: *session.Session, payload: *passable.Outbound, stamp: u64) void {
    visitPayload(owner, payload, false, stamp);
}

/// Restore counts just returned in the same synchronous collection pause.
/// The original tree has been restored, and no competing owner can overflow
/// these exact counts. No allocation belongs on an error rollback edge.
pub fn restore(owner: *session.Session, payload: *passable.Outbound, stamp: u64) void {
    visitPayload(owner, payload, true, stamp);
}

fn visitPayload(owner: *session.Session, payload: *passable.Outbound, comptime retaining: bool, stamp: u64) void {
    switch (payload.*) {
        .message => |message| switch (message) {
            .deliver => |deliver| {
                if (deliver.resolve_me_desc) |reference| visitArgument(owner, .{ .reference = reference }, retaining, stamp);
                for (deliver.args) |arg| visitArgument(owner, arg, retaining, stamp);
            },
            else => {},
        },
        .answer_settlement => |settlement| visitResolution(owner, settlement.resolution, retaining, stamp),
    }
}

fn resolverReference(payload: *passable.Outbound) ?model.Reference {
    return switch (payload.*) {
        .message => |message| if (message == .deliver) message.deliver.resolve_me_desc else null,
        .answer_settlement => null,
    };
}

fn visitResolution(owner: *session.Session, resolution: model.Resolution, comptime retaining: bool, stamp: u64) void {
    if (resolution == .fulfill) visitArgument(owner, resolution.fulfill, retaining, stamp);
}

fn visitArgument(owner: *session.Session, value: model.Argument, comptime retaining: bool, stamp: u64) void {
    switch (value) {
        .reference => |reference| if (retaining) {
            Custody.retain(owner, reference, stamp) catch unreachable;
        } else Custody.release(owner, reference, stamp),
        .list, .set => |items| for (items) |item| visitArgument(owner, item, retaining, stamp),
        .tagged => |tagged| for (tagged.value) |item| visitArgument(owner, item, retaining, stamp),
        .@"struct" => |entries| for (entries) |entry| visitArgument(owner, entry.value, retaining, stamp),
        else => {},
    }
}

//! Custody of local projection occurrences in an adopted Passable tree.
//! Admission uses its existing inventory. Release walks the still-owned tree
//! instead of allocating a second reference index. The tree is depth-bounded
//! by that inventory; no validation or graph traversal is repeated here.
const model = @import("model");
const session = @import("session");
const passable = @import("../passable.zig");
const Custody = session.Session.LocalPromiseCustody;

pub fn acquire(owner: *session.Session, payload: *passable.Payload, inventory: session.Inventory) error{QueueCapExceeded}!void {
    const resolver = resolverReference(payload);
    if (resolver) |reference| try Custody.retain(owner, reference);
    errdefer if (resolver) |reference| Custody.release(owner, reference);
    const root = payload.resolutionRoot();
    for (inventory.slots, 0..) |slot, index| {
        const value = slot.read(root).*;
        if (value != .reference) continue;
        Custody.retain(owner, value.reference) catch |err| {
            for (inventory.slots[0..index]) |prior| {
                const previous = prior.read(root).*;
                if (previous == .reference) Custody.release(owner, previous.reference);
            }
            return err;
        };
    }
}

pub fn release(owner: *session.Session, payload: *passable.Payload) void {
    visitPayload(owner, payload, false);
}

/// Restore counts just returned in the same synchronous collection pause.
/// The original tree has been restored, and no competing owner can overflow
/// these exact counts. No allocation belongs on an error rollback edge.
pub fn restore(owner: *session.Session, payload: *passable.Payload) void {
    visitPayload(owner, payload, true);
}

fn visitPayload(owner: *session.Session, payload: *passable.Payload, comptime retaining: bool) void {
    switch (payload.*) {
        .outbound => |value| switch (value) {
            .message => |message| switch (message) {
                .deliver => |deliver| {
                    if (deliver.resolve_me_desc) |reference| visitArgument(owner, .{ .reference = reference }, retaining);
                    for (deliver.args) |arg| visitArgument(owner, arg, retaining);
                },
                else => {},
            },
            .answer_settlement => |settlement| visitResolution(owner, settlement.resolution, retaining),
        },
        .relayed_resolution => |resolution| visitResolution(owner, resolution, retaining),
    }
}

fn resolverReference(payload: *passable.Payload) ?model.Reference {
    return switch (payload.*) {
        .outbound => |value| switch (value) {
            .message => |message| if (message == .deliver) message.deliver.resolve_me_desc else null,
            .answer_settlement => null,
        },
        .relayed_resolution => null,
    };
}

fn visitResolution(owner: *session.Session, resolution: model.Resolution, comptime retaining: bool) void {
    if (resolution == .fulfill) visitArgument(owner, resolution.fulfill, retaining);
}

fn visitArgument(owner: *session.Session, value: model.Argument, comptime retaining: bool) void {
    switch (value) {
        .reference => |reference| if (retaining) {
            Custody.retain(owner, reference) catch unreachable;
        } else Custody.release(owner, reference),
        .list, .set => |items| for (items) |item| visitArgument(owner, item, retaining),
        .tagged => |tagged| for (tagged.value) |item| visitArgument(owner, item, retaining),
        .@"struct" => |entries| for (entries) |entry| visitArgument(owner, entry.value, retaining),
        else => {},
    }
}

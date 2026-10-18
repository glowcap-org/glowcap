//! Admission of returned handoff gives into deduplicated exporter dials.
//!
//! Parsing and ownership acquisition finish before a pending row or action is
//! published. Existing identity rows join only when their complete ordered
//! route plan agrees. The scheduler remains the sole owner of attempt order.

const std = @import("std");

const model = @import("model");
const session = @import("session");
const codec = @import("codec");
const crypto = @import("foundation").crypto;
const node_mod = @import("../../../node.zig");
const actions = @import("../../actions.zig");
const redeem = @import("../../redeem.zig");
const dials = @import("../dials.zig");
const plan = @import("../plan.zig");
const attempts = @import("attempts.zig");
const withdrawals = @import("../withdrawals.zig");
const gift_recipe = @import("../../handoffs/gifts/recipe.zig");

const Node = node_mod.Node;
const PeerHandle = @import("../../../peer_handle.zig").PeerHandle;

const unsupported_id = "handoff give names unsupported id exporter locator";
const conflicting_routes = "handoff give conflicts with an in-flight exporter route plan";

pub fn acceptGive(
    self: *Node,
    recipient_peer: PeerHandle,
    answer: session.OutboundAnswerTarget,
    give: []const u8,
    exporter_locator: []const u8,
) !void {
    return acceptGiveTo(
        self,
        .{ .answer = .{ .recipient_peer = recipient_peer, .answer = answer } },
        give,
        exporter_locator,
    );
}

pub fn acceptInlineGive(
    self: *Node,
    recipient_peer: PeerHandle,
    deferred: u64,
    give: []const u8,
    exporter_locator: []const u8,
) !void {
    return acceptGiveTo(
        self,
        .{ .deferred = .{ .recipient_peer = recipient_peer, .id = deferred } },
        give,
        exporter_locator,
    );
}

fn acceptGiveTo(
    self: *Node,
    dest: redeem.Destination,
    give: []const u8,
    exporter_locator: []const u8,
) !void {
    if (exporter_locator.len == 0)
        return withdrawals.queueFailure(self, dest, "handoff give names no dialable exporter locator", null);

    const parsed_locator = model.uri.parsePeer(self.allocator, exporter_locator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return withdrawals.queueFailure(self, dest, "handoff give names unparseable exporter locator", null),
    };
    var parsed_locator_owned = true;
    defer if (parsed_locator_owned) model.freePeerLocator(self.allocator, parsed_locator);
    const recipient = self.peer(redeem.recipientPeer(dest)) orelse return error.UnknownConnection;
    const is_id = std.mem.eql(u8, parsed_locator.transport, model.transport.id);
    if (!is_id) try recipient.session_state.requireNegotiatedLocator(parsed_locator);
    const state = &self.redeems.dials;

    var identity_buf: [id_identity_len]u8 = undefined;
    const id_identity = if (is_id) idIdentity(parsed_locator.designator, &identity_buf) else null;
    if (id_identity) |identity| if (state.exporters.get(identity)) |exporter_peer| {
        try recipient.session_state.requireNegotiatedLocator(parsed_locator);
        const route_advice = if (gift_recipe.needsDiscovered(self, exporter_peer)) advice: {
            const prepared = try withdrawals.createEmptyRouteAdvice(self);
            errdefer withdrawals.finishRouteAdviceSetup(self, prepared);
            prepared.location = try codec.signed.encodeLocatorRecord(self.allocator, parsed_locator);
            break :advice prepared;
        } else null;
        defer withdrawals.finishRouteAdviceSetup(self, route_advice);
        return beginWithExporter(self, exporter_peer, dest, give, route_advice);
    };

    var staged: plan.Owned = if (is_id)
        try recipient.session_state.parseNegotiatedIdLocator(self.allocator, parsed_locator)
    else owned: {
        parsed_locator_owned = false;
        break :owned plan.fromOwnedLocator(self.allocator, parsed_locator) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.UnparseableExporterLocator => return withdrawals.queueFailure(self, dest, "handoff give names unparseable exporter locator", null),
            error.UnsupportedId => return withdrawals.queueFailure(self, dest, unsupported_id, null),
        };
    };
    var staged_owned = true;
    defer if (staged_owned) staged.deinit(self.allocator);

    if (state.exporters.get(staged.identity)) |exporter_peer| {
        std.debug.assert(staged.source != .id);
        return beginWithExporter(self, exporter_peer, dest, give, null);
    }

    if (state.by_identity.get(staged.identity)) |pending_id| {
        const entry = &state.pending.getPtr(pending_id).?.dialing;
        if (!model.route_bundle.samePaths(entry.plan, staged))
            return withdrawals.queueFailure(self, dest, conflicting_routes, null);

        const owned_give = try self.allocator.dupe(u8, give);
        errdefer self.allocator.free(owned_give);
        try actions.reserve(self, 1);
        try entry.waiters.append(self.allocator, .{ .dest = dest, .give = owned_give });
        state.waiter_action_reservations += 1;
        if (is_id and entry.exporter_locator == null) {
            entry.exporter_locator = parsed_locator;
            parsed_locator_owned = false;
        }
        return;
    }

    staged_owned = false;
    if (is_id) parsed_locator_owned = false;
    return startDial(self, dest, give, staged, if (is_id) parsed_locator else null);
}

const id_identity_len = "ocapn://".len + crypto.PeerKey.designator_len + ".id".len;

/// The canonical identity URI of a key-designated locator, written into
/// `buf`, or null when the designator is not a peer key.
fn idIdentity(designator: []const u8, buf: *[id_identity_len]u8) ?[]const u8 {
    const key = crypto.PeerKey.fromDesignator(designator) orelse return null;
    const key_designator = key.toDesignator();
    // Written through the one URI writer, because the exporter cache's
    // keys are written the same way: byte equality of the lookup depends
    // on both sides sharing that single shape owner. The buffer is sized
    // for exactly this locator, and a key designator's fixed alphabet
    // excludes every encode error, so incompleteness cannot arise.
    const written = model.uri.writePeerBounded(.hintless(model.transport.id, key_designator[0..]), buf) catch unreachable;
    std.debug.assert(written.complete);
    return buf[0..written.len];
}

/// Withdraw through a live exporter session. A provisional exporter with no
/// other withdrawal in flight retires if this one fails.
fn beginWithExporter(
    self: *Node,
    exporter_peer: PeerHandle,
    dest: redeem.Destination,
    give: []const u8,
    route_advice: ?*withdrawals.RouteAdvice,
) !void {
    const slot = self.peers.getPtr(exporter_peer);
    const retire_on_failure = if (slot) |live| live.provisional_exporter and live.pending_withdraw_count == 0 else false;
    if (retire_on_failure) try actions.reserve(self, 3);
    try withdrawals.begin(self, exporter_peer, dest, give, route_advice);
    if (retire_on_failure and slot.?.pending_withdraw_count == 0)
        actions.pushReserved(self, .{ .retire_exporter = exporter_peer });
}

/// Open the dial for a new exporter identity with this give as its first
/// waiter. Owns `staged` and `locator` on every outcome.
fn startDial(
    self: *Node,
    dest: redeem.Destination,
    give: []const u8,
    staged: plan.Owned,
    locator: ?model.PeerLocator,
) !void {
    const state = &self.redeems.dials;
    var pending: dials.Dialing = .{ .plan = staged, .exporter_locator = locator };
    errdefer {
        pending.waiters.deinit(self.allocator);
        pending.plan.deinit(self.allocator);
        if (pending.exporter_locator) |held| model.freePeerLocator(self.allocator, held);
    }
    const owned_give = try self.allocator.dupe(u8, give);
    errdefer self.allocator.free(owned_give);
    try state.pending.ensureUnusedCapacity(self.allocator, 1);
    try state.by_identity.ensureUnusedCapacity(self.allocator, 1);
    const initial = attempts.State.initial(pending.plan);
    try actions.reserve(self, 1 + initial.len);
    try pending.waiters.append(self.allocator, .{ .dest = dest, .give = owned_give });

    const pending_id = try actions.claimTicketRange(self, 1);
    dials.publishFresh(self, pending_id, pending, initial);
    state.waiter_action_reservations += 1;
}

//! Operations an application queues against a capability promise before it
//! settles: eventual sends, tells, and listens. Each is admitted against the
//! source session, owned by the row until settlement dispatches it, and
//! cancellable through the Host vow it minted. `capability_promise.zig`
//! dispatches and retires them.

const std = @import("std");

const engine = @import("engine");
const capability = @import("../capability.zig");
const promise_row = @import("row.zig");
const promise_values = @import("values.zig");
const host_mod = @import("../host.zig");
const PendingCancel = @import("../vows/settlement.zig").PendingCancel;
const value_mod = @import("../value.zig");

const Host = host_mod.Host;
const HostSession = host_mod.HostSession;
const Row = promise_row.Row;

/// Admit one eventual send against a promise whose exporter session does not
/// exist yet. The Host vow is public immediately. The owned values stay status-allow: pending state or quoted runtime label
/// session-neutral until redemption selects the real route.
pub fn queueSendValues(
    self: *Host,
    id: capability.PromiseId,
    source: *HostSession,
    verb: []const u8,
    values: []const value_mod.Value,
) !u64 {
    return (try queueMessage(self, id, source, .send, verb, values)).?;
}

/// Admit one fire-and-forget delivery against an unresolved handoff promise.
/// There is no synthetic result: if the target later breaks,
/// the send-only message has no protocol recipient, like an ordinary
/// tell to a broken promise.
pub fn queueTellValues(
    self: *Host,
    id: capability.PromiseId,
    source: *HostSession,
    verb: []const u8,
    values: []const value_mod.Value,
) !void {
    _ = try queueMessage(self, id, source, .tell, verb, values);
}

const MessageKind = enum { send, tell };

fn queueMessage(
    self: *Host,
    id: capability.PromiseId,
    source: *HostSession,
    kind: MessageKind,
    verb: []const u8,
    values: []const value_mod.Value,
) !?u64 {
    try prepareOperationSlot(self, id, source);
    const row = self.capability_promises.getPtr(id) orelse unreachable;
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    errdefer arena.deinit();
    var retained: std.ArrayListUnmanaged(capability.Ref) = .empty;
    errdefer promise_values.rollbackRetains(self, retained.items);
    const owned_verb = try arena.allocator().dupe(u8, verb);
    const owned_values = try promise_values.cloneValues(self, arena.allocator(), values, &retained);
    const result_vow = switch (kind) {
        .send => try self.mintDeferredVow(source, .{
            .owner = @backingInt(id),
            .func = cancelQueuedVow,
            .terminal_func = cancelQueuedVowTerminal,
        }),
        .tell => null,
    };
    const message: Row.PendingOperation.OwnedMessage = .{
        .arena = arena,
        .verb = owned_verb,
        .values = owned_values,
        .retained_capabilities = retained.items,
    };
    row.operations.appendAssumeCapacity(.{
        .source_peer = source.peer_handle,
        .result_vow = result_vow,
        .action = switch (kind) {
            .send => .{ .send = message },
            .tell => .{ .tell = message },
        },
    });
    if (kind == .tell) self.beginSessionOperation(source);
    return result_vow;
}

pub fn queueListen(self: *Host, id: capability.PromiseId, source: *HostSession) !u64 {
    try prepareOperationSlot(self, id, source);
    const row = self.capability_promises.getPtr(id) orelse unreachable;
    const vow_id = try self.mintDeferredVow(source, .{
        .owner = @backingInt(id),
        .func = cancelQueuedVow,
        .terminal_func = cancelQueuedVowTerminal,
    });
    row.operations.appendAssumeCapacity(.{
        .source_peer = source.peer_handle,
        .result_vow = vow_id,
        .action = .listen,
    });
    return vow_id;
}

fn prepareOperationSlot(self: *Host, id: capability.PromiseId, source: *HostSession) !void {
    try self.admitSessionOperation(source);
    try self.checkSession(source);
    const row = self.capability_promises.getPtr(id) orelse return error.UnknownCapability;
    if (!row.state.isPending()) return error.PromiseNotPending;
    if (row.operations.items.len - row.operation_head >= source.served.port.peer.limits().queue_cap)
        return error.QueueCapExceeded;
    try row.operations.ensureUnusedCapacity(self.allocator, 1);
}

// Break the Host pump's recursive inferred-error dependency: releasing a
// remote retain may itself finish committed pump work. The concrete errors
// remain unchanged and are propagated to the Node action for retry.
pub fn releaseRetainedCapabilities(self: *Host, pending: *Row.PendingOperation) PendingCancel.CancelError!void {
    switch (pending.action) {
        .send, .tell => |*message| while (message.release_head < message.retained_capabilities.len) {
            const retained = message.retained_capabilities[message.release_head];
            try self.releaseCapability(retained, 1);
            message.release_head += 1;
        },
        .listen => {},
    }
}

/// A queued operation moved to another promise row: its vow's cancel must
/// find it there.
pub fn reown(self: *Host, vow_id: u64, owner: capability.PromiseId) void {
    const row = self.vows.get(vow_id) orelse return;
    row.pending_cancel.fallible_no_answer.owner = @backingInt(owner);
}

fn operationForVow(row: *const Row, vow_id: u64) usize {
    var index = row.operation_head;
    while (index < row.operations.items.len) : (index += 1) {
        if (row.operations.items[index].result_vow == vow_id) return index;
    }
    unreachable;
}

fn cancelQueuedVow(self: *Host, vow_id: u64, owner: u64) PendingCancel.CancelError!void {
    const id: capability.PromiseId = @fromBackingInt(@intCast(owner));
    var row = self.capability_promises.getPtr(id) orelse unreachable;
    var index = operationForVow(row, vow_id);
    const pending = &row.operations.items[index];
    std.debug.assert(pending.stage == .queued);
    try releaseRetainedCapabilities(self, pending);

    row = self.capability_promises.getPtr(id) orelse unreachable;
    index = operationForVow(row, vow_id);
    var owned = row.operations.orderedRemove(index);
    std.debug.assert(owned.stage == .queued and owned.result_vow == vow_id);
    owned.deinit();
}

fn cancelQueuedVowTerminal(self: *Host, vow_id: u64, owner: u64) void {
    const id: capability.PromiseId = @fromBackingInt(@intCast(owner));
    const row = self.capability_promises.getPtr(id) orelse return;
    const index = operationForVow(row, vow_id);
    var owned = row.operations.orderedRemove(index);
    std.debug.assert(owned.stage == .queued and owned.result_vow == vow_id);
    releaseRetainedCapabilitiesTerminal(self, &owned, owned.source_peer);
    owned.deinit();
}

/// Terminal callers detach the operation before entering this boundary:
/// releasing arguments or firing a result may invoke callbacks that mutate rows.
/// A tell has no result vow to retire its source-session operation for it.
pub fn retireOperationTerminal(self: *Host, pending: *Row.PendingOperation, reason: []const u8, closing_peer: ?engine.PeerHandle) void {
    releaseRetainedCapabilitiesTerminal(self, pending, closing_peer);
    if (pending.result_vow) |vow_id| if (self.vows.contains(vow_id))
        self.fireVow(vow_id, .{ .broken = reason });
    if (pending.action == .tell) if (self.sessions.get(pending.source_peer)) |source|
        self.finishSessionOperation(source);
    pending.deinit();
}

pub fn releaseRetainedCapabilitiesTerminal(self: *Host, pending: *Row.PendingOperation, closing_peer: ?engine.PeerHandle) void {
    switch (pending.action) {
        .send, .tell => |*message| while (message.release_head < message.retained_capabilities.len) {
            const retained = message.retained_capabilities[message.release_head];
            self.releaseCapabilityTerminal(retained, closing_peer);
            message.release_head += 1;
        },
        .listen => {},
    }
}

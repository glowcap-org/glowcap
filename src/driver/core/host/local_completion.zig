//! Public local sends materialize their exact Values once, then transfer that
//! custody to the existing Host action queue. No Session or child Call exists.
const std = @import("std");
const actors = @import("actors");
const model = @import("model");
const host_mod = @import("../host.zig");
const value_mod = @import("../value.zig");
const copy = @import("../value_copy.zig");
const local = @import("local_delivery.zig");
const lower = @import("capabilities/lower.zig");
const lift = @import("capabilities/lift.zig");
const action = @import("action.zig");
const vows = @import("../vows.zig");
const settlement = @import("../vows/settlement.zig");

/// One allocation embeds the existing Producer with public reply metadata. Its
/// arena owns trusted callback output until outer commit transfers it to the
/// Host action. Depth remains bounded by the shared Value walk. Aggregate reply
/// bytes use the Host allocator, as opposed to a Call's fixed allowance.
/// Cancellation consumes observation, never allocation provenance or effects.
pub const Reply = struct {
    producer: local.Producer,
    id: u64,
    storage: std.heap.ArenaAllocator.State = .init,
    result: union(enum) { pending, prepared: value_mod.Value, published, canceled } = .pending,

    pub fn prepare(self: *Reply, value: value_mod.Value) !void {
        if (self.result == .canceled) return;
        std.debug.assert(self.result == .pending);
        var arena = self.storage.promote(self.producer.host.allocator);
        errdefer arena.deinit();
        const owned = try copy.copy(value_mod.Value, arena.allocator(), value);
        try @import("capabilities/completion.zig").retainValue(self.producer.host, owned);
        self.storage = arena.state;
        self.result = .{ .prepared = owned };
    }

    pub fn prepareWire(self: *Reply, session: *host_mod.HostSession, value: model.Argument) !void {
        if (self.result == .canceled) {
            lift.discardValueObservation(self.producer.host, session, value);
            return;
        }
        std.debug.assert(self.result == .pending);
        var arena = self.storage.promote(self.producer.host.allocator);
        errdefer arena.deinit();
        const owned = try lift.ownValue(self.producer.host, session, arena.allocator(), value);
        self.storage = arena.state;
        self.result = .{ .prepared = owned };
    }

    pub fn cancelPreparation(self: *Reply) void {
        if (self.result != .prepared) return;
        lower.releaseValueCapabilitiesTerminalAt(self.producer.host, &.{self.result.prepared}, null);
        var arena = self.storage.promote(self.producer.host.allocator);
        arena.deinit();
        self.storage = .init;
        self.result = .pending;
    }

    pub fn cancel(self: *Reply) void {
        self.cancelPreparation();
        std.debug.assert(self.result == .pending);
        self.result = .canceled;
    }

    pub fn publish(self: *Reply, resolution: actors.Resolution, failure: action.VowFailure) void {
        if (self.result == .canceled or self.result == .published) return;
        const host = self.producer.host;
        switch (resolution) {
            .fulfilled => {
                std.debug.assert(self.result == .prepared);
                host.actions.pushReserved(.{ .settled = .{
                    .peer_handle = null,
                    .vow_id = self.id,
                    .value = self.result.prepared,
                    .storage = self.storage,
                } });
                self.storage = .init;
            },
            .broken => |reason| {
                self.cancelPreparation();
                host.actions.pushReserved(.{ .failed = .{
                    .peer_handle = null,
                    .vow_id = self.id,
                    .failure = failure,
                    .message = action.retainFailureMessage(host.allocator, reason),
                } });
            },
            .give => unreachable,
        }
        self.result = .published;
    }

    /// Destruction never publishes. Ordinary settlement has transferred the
    /// reply. Aggregate teardown only reclaims remaining storage.
    pub fn deinit(self: *Reply) void {
        std.debug.assert(self.result != .prepared);
        var arena = self.storage.promote(self.producer.host.allocator);
        arena.deinit();
    }
};

pub fn send(host: *host_mod.Host, lease: *const host_mod.Host.PendingWorkLease, target: value_mod.Capability, verb: []const u8, args: []const value_mod.Value) !u64 {
    try lease.checkHost(host);
    const charge = try local.inputCharge(host, verb, args);
    try vows.ensureFreshVowId(host);
    const self = try host.allocator.create(Reply);
    self.* = .{ .producer = .{ .host = host, .destination = .{ .public = self } }, .id = host.next_vow };
    errdefer self.producer.release();
    self.producer.lease = try lease.fork();
    const row = try vows.reserveRow(host, null, .plain, .none, self.id);
    errdefer host.allocator.destroy(row);
    // This sessionless row owes a public completion. Reserve it before the
    // queue transaction can commit; ordinary resolver rows owe no action.
    try host.reserveActions(1);
    row.owner = .{ .owning = &self.producer };
    const installed: actors.Listener = .{ .ctx = row, .func = settlement.VowRow.fire };
    row.vow = try local.enqueue(host, &self.producer, target, verb, args, charge, installed);
    row.pending_cancel = .{ .row_listener = installed };
    vows.publishRow(host, row);
    host.next_vow += 1;
    return self.id;
}

/// Detach a public observer without canceling its already-admitted target.
pub fn releasePending(host: *host_mod.Host, row: *settlement.VowRow) void {
    const source = row.owner.owning;
    std.debug.assert(source.destination == .public and !row.settled);
    const listener = host.vat.takeListener(row.vow) orelse unreachable;
    const installed = row.pending_cancel.row_listener;
    std.debug.assert(listener.ctx == installed.ctx and listener.func == installed.func);
    source.destination.public.cancel();
    settlement.markRowSettled(host, row);
    std.debug.assert(host.vows.remove(row.id));
    host.allocator.destroy(row);
    source.release();
}

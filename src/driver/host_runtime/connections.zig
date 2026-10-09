//! Multiplexed-resident connection adoption.

const std = @import("std");

const model = @import("model");
const net = @import("net");
const driver_core = @import("driver_core");

const resident_state = @import("resident.zig");
const runtime = @import("../host_runtime.zig");

const HostRuntime = runtime.HostRuntime;
const Internal = runtime.Internal;
const Budget = driver_core.Budget;
const Error = driver_core.Error;
const Wire = HostRuntime.Wire;

/// Resolve and dial through the one provider registry, then adopt the wire.
pub fn bindWire(
    self: *HostRuntime,
    session: *driver_core.HostSession,
    locator: model.PeerLocator,
    options: net.OperationOptions,
) !void {
    const provider = Internal.providerFor(self, locator.transport) orelse return Error.UnknownTransport;
    const resident_index = provider.resident;
    const dialer = self.residents.items[resident_index].resident.dialer() orelse
        return Error.UnknownTransport;
    try bindResidentWire(self, session, resident_index, dialer, locator, options);
}

/// Begin a resident dial, await its completion while serving siblings, bind
/// its channel-proved key, adopt the claimed connection, and write what the
/// session already holds. The await drains core actions, so the session's
/// flush can fire before its wire exists; a sealed dial's first handshake
/// message waits in its channel, where no later flush would find it.
pub fn bindResidentWire(
    self: *HostRuntime,
    session: *driver_core.HostSession,
    resident_index: usize,
    dialer: net.MultiplexedResident.Dialer,
    locator: model.PeerLocator,
    options: net.OperationOptions,
) !void {
    const registered = &self.residents.items[resident_index];
    const resident = registered.resident;
    const request_id = try Internal.mintRuntimeId(&registered.next_request);
    var attempt = switch (dialer.startDial(request_id, locator, options)) {
        .admitted => |attempt| attempt,
        .failed => |failure| return failure.classification,
    };
    defer if (attempt.deinit()) |failure| Internal.noteTerminalFailureChain(self, failure);
    var conn = try awaitResidentConnect(self, resident_index, &attempt, self.opts.handshake);
    defer if (conn.deinit()) |failure| Internal.noteTerminalFailureChain(self, failure);
    const conn_id = conn.borrow() orelse return error.ProviderContract;
    if (try resident.connRemoteKey(conn_id)) |key|
        session.served.port.peer.bindVerifiedChannelKey(key);
    try adoptResidentConn(self, session, resident_index, &conn);
    const wire = self.wires.get(session.peer_handle).?;
    Internal.writeOutbound(self, wire) catch |err| Internal.closeWire(self, wire, err);
}

/// Park until the resident connect result drains, servicing all other ready
/// sources meanwhile under the handshake budget.
fn awaitResidentConnect(
    self: *HostRuntime,
    resident_index: usize,
    attempt: *net.multiplexed_resident.DialAttempt,
    budget: Budget,
) !net.multiplexed_resident.ClaimedConnection {
    const request_id = attempt.id() orelse return error.ProviderContract;
    const key = resident_state.RequestKey{ .resident = resident_index, .request = request_id };
    var wait = resident_state.DialWait{};
    try self.pending_resident_dials.put(self.allocator, key, &wait);
    defer std.debug.assert(self.pending_resident_dials.remove(key));
    const deadline_ms: ?i64 = switch (budget) {
        .unbounded => null,
        .ms => |v| net.clock.nowMs(self.io) + v,
    };
    while (true) {
        try Internal.applySettleMailbox(self);
        try self.drainActions();
        try Internal.advancePendingOpens(self);
        Internal.advancePendingListeners(self);
        if (wait.ready) return switch (attempt.finish()) {
            .connected => |conn| conn,
            .failed => |failure| failure.classification,
        };
        const timeout: i32 = if (deadline_ms) |deadline| blk: {
            const remaining = deadline - net.clock.nowMs(self.io);
            if (remaining <= 0) return Error.HandshakeTimedOut;
            break :blk std.math.cast(i32, remaining) orelse std.math.maxInt(i32);
        } else -1;
        const index = try Internal.waitAnySource(self, timeout, false) orelse continue;
        _ = try Internal.serviceResident(self, index, null);
    }
}

pub fn adoptResidentConn(
    self: *HostRuntime,
    session: *driver_core.HostSession,
    resident_index: usize,
    claimed: *net.multiplexed_resident.ClaimedConnection,
) !void {
    const conn = claimed.borrow() orelse return error.ProviderContract;
    const profile = try session.host.transportProfile(session.transport);
    // A resident that lends its received bytes is never read into scratch.
    const lends = self.residents.items[resident_index].resident.vtable.borrowed_read != null;
    const read_buf_len: usize = if (lends) 0 else switch (session.wire_framing) {
        .byte_stream => self.opts.wire_buffer_bytes,
        .message => @max(
            self.opts.wire_buffer_bytes,
            @max(session.served.port.peer.limits().max_frame_bytes, profile.max_packet_bytes),
        ),
    };
    if (self.resident_read_scratch.len < read_buf_len) {
        const grown = try self.allocator.alloc(u8, read_buf_len);
        self.allocator.free(self.resident_read_scratch);
        self.resident_read_scratch = grown;
    }
    try Internal.reserveCloseEvent(self);
    errdefer Internal.releaseCloseEvent(self);
    try self.wires.ensureUnusedCapacity(self.allocator, 1);
    try self.resident_wires.ensureUnusedCapacity(self.allocator, 1);
    const wire = try self.allocator.create(Wire);
    wire.* = .{
        .link = .{ .index = resident_index, .conn = conn },
        .session = session,
    };
    self.wires.putAssumeCapacity(session.peer_handle, wire);
    self.resident_wires.putAssumeCapacity(.{ .resident = resident_index, .conn = conn }, wire);
    self.open_wire_count += 1;
    _ = claimed.take();
}

//! Stream and multiplexed-resident connection adoption.

const std = @import("std");

const model = @import("model");
const net = @import("net");
const driver_core = @import("driver_core");

const resident_state = @import("resident.zig");
const stream_wire = @import("stream_wire.zig");
const runtime = @import("../host_runtime.zig");

const HostRuntime = runtime.HostRuntime;
const Internal = runtime.Internal;
const Budget = driver_core.Budget;
const Error = driver_core.Error;
const Wire = HostRuntime.Wire;

/// Bind an accepted transport connection to a fresh accepted-half session.
pub fn acceptWire(
    self: *HostRuntime,
    listener: net.netlayer.Listener,
    transport: []const u8,
) !*driver_core.HostSession {
    self.enterDriver();
    defer self.leaveDriver();
    var admission = try Internal.acquireOpenAdmission(self, .application);
    defer admission.release();
    const session = try self.core.openAcceptedAdvertised(transport);
    errdefer {
        Internal.dropWire(self, session.peer_handle);
        if (Internal.releaseCoreSession(self, session)) |failure|
            Internal.noteTerminalFailureChain(self, failure);
    }
    if (try bindAcceptedWireOutcome(self, session, listener)) |failure|
        return failure.classification;
    try Internal.pumpHandshake(self, session, self.opts.handshake);
    return session;
}

/// Keep buffers and the accepted connection in one rollback transaction until
/// `adoptConn` commits them to the Host wire table.
pub fn bindAcceptedWireOutcome(self: *HostRuntime, session: *driver_core.HostSession, listener: net.netlayer.Listener) !?net.netlayer.AcceptFailure {
    var prepared = switch (try stream_wire.accept(
        self.allocator,
        self.opts.wire_buffer_bytes,
        listener,
        session.served.port.peer,
    )) {
        .prepared => |prepared| prepared,
        .failed => |failure| return failure,
    };
    defer prepared.deinit();
    try adoptConn(self, session, &prepared);
    return null;
}

/// Resolve and dial through the one provider registry, then adopt the wire.
pub fn bindWire(
    self: *HostRuntime,
    session: *driver_core.HostSession,
    locator: model.PeerLocator,
    options: net.OperationOptions,
) !void {
    const provider = Internal.providerFor(self, locator.transport) orelse return Error.UnknownTransport;
    switch (provider.source) {
        .stream => |nl| {
            if (!nl.supportsDial()) return Error.UnknownTransport;
            if (try bindStreamWireOutcome(self, session, locator, nl, options)) |failure|
                return failure.classification;
        },
        .resident => |resident_index| {
            const dialer = self.residents.items[resident_index].resident.dialer() orelse
                return Error.UnknownTransport;
            try bindResidentWire(self, session, resident_index, dialer, locator, options);
        },
    }
}

pub fn bindStreamWireOutcome(
    self: *HostRuntime,
    session: *driver_core.HostSession,
    locator: model.PeerLocator,
    nl: net.netlayer.Netlayer,
    options: net.OperationOptions,
) !?net.netlayer.DialFailure {
    var prepared = switch (try stream_wire.dial(
        self.allocator,
        self.opts.wire_buffer_bytes,
        nl,
        session.served.port.peer,
        locator,
        options,
    )) {
        .prepared => |prepared| prepared,
        .failed => |failure| return failure,
    };
    defer prepared.deinit();
    try adoptConn(self, session, &prepared);
    return null;
}

/// Begin a resident dial, await its completion while serving siblings, bind
/// its channel-proved key, and adopt the claimed connection.
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
        const source = try Internal.waitAnySource(self, timeout, false) orelse continue;
        switch (source) {
            .wire => |wire| _ = try Internal.serviceReadyWire(self, wire, null),
            .resident => |index| _ = try Internal.serviceResident(self, index, null),
            .stream_dial => |row| try Internal.adoptPendingStreamDial(self, row),
            .stream_listen => |row| Internal.finishPendingListener(self, row),
            .stream_accept => |listener| _ = try self.acceptReady(listener),
        }
    }
}

pub fn adoptConn(self: *HostRuntime, session: *driver_core.HostSession, prepared: *stream_wire.Prepared) !void {
    const handle = prepared.connection().socketHandle() orelse return Error.TransportNotPollable;
    if (handle < 0) return Error.TransportNotPollable;
    if (Internal.descriptorInUse(self, handle)) return error.ReadinessDescriptorConflict;
    switch (self.drive) {
        .blocking => {},
        .stepped => |*stepped| try stepped.ready_set.add(handle),
    }
    errdefer Internal.removeReadyFd(self, handle);
    try Internal.reserveCloseEvent(self);
    errdefer Internal.releaseCloseEvent(self);
    try self.wires.ensureUnusedCapacity(self.allocator, 1);
    const wire = try self.allocator.create(Wire);
    const parts = prepared.take();
    wire.* = .{
        .link = .{ .stream = .{ .conn = parts.conn, .read_buf = parts.read, .write_buf = parts.write } },
        .session = session,
    };
    self.wires.putAssumeCapacity(session.peer_handle, wire);
    self.open_wire_count += 1;
}

pub fn adoptResidentConn(
    self: *HostRuntime,
    session: *driver_core.HostSession,
    resident_index: usize,
    claimed: *net.multiplexed_resident.ClaimedConnection,
) !void {
    const conn = claimed.borrow() orelse return error.ProviderContract;
    const profile = try session.host.transportProfile(session.transport);
    const read_buf_len = switch (session.wire_framing) {
        .byte_stream => self.opts.wire_buffer_bytes,
        .message => @max(
            self.opts.wire_buffer_bytes,
            @max(session.served.port.peer.limits().max_frame_bytes, profile.max_packet_bytes),
        ),
    };
    const read_buf = try self.allocator.alloc(u8, read_buf_len);
    errdefer self.allocator.free(read_buf);
    try Internal.reserveCloseEvent(self);
    errdefer Internal.releaseCloseEvent(self);
    try self.wires.ensureUnusedCapacity(self.allocator, 1);
    try self.resident_wires.ensureUnusedCapacity(self.allocator, 1);
    const wire = try self.allocator.create(Wire);
    wire.* = .{
        .link = .{ .resident = .{ .index = resident_index, .conn = conn, .read_buf = read_buf } },
        .session = session,
    };
    self.wires.putAssumeCapacity(session.peer_handle, wire);
    self.resident_wires.putAssumeCapacity(.{ .resident = resident_index, .conn = conn }, wire);
    self.open_wire_count += 1;
    _ = claimed.take();
}

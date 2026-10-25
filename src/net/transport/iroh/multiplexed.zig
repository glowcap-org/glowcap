//! Zig multiplexed projection of one borrowed iroh endpoint.
//!
//! The endpoint outlives this heap-stable adapter and every registered runtime.
//! C and Zig consumers share connection identity, listener state and failure
//! custody here. Each boundary only projects its values.

const std = @import("std");
const foundation = @import("foundation");
const model = @import("model");
const net = @import("net");
const resident = @import("resident.zig");
const locators = @import("locators.zig");
const sidecar = @import("sidecar.zig");

pub const MultiplexedAdapter = struct {
    allocator: std.mem.Allocator,
    endpoint: *resident.Resident,
    /// Drained readiness names stable ids. Sidecar I/O needs the owned handle.
    /// One POD row per claimed connection keeps those identities together.
    /// Claim allocates before transfer, refusal closes the unregistered handle,
    /// and close removes the row before releasing it. No byte payload is copied.
    conns: std.AutoHashMapUnmanaged(usize, ConnRow) = .empty,
    listener: ?Listener = null,

    const ConnRow = struct {
        handle: *anyopaque,
        failure: ?foundation.FailureChain = null,
    };
    const Listener = struct {
        route: usize,
        locator: model.PeerLocator,
    };

    pub fn init(allocator: std.mem.Allocator, endpoint: *resident.Resident) error{SidecarFailed}!MultiplexedAdapter {
        if (!endpoint.enableLoop()) return error.SidecarFailed;
        try endpoint.setLoopAdmission(false);
        return .{ .allocator = allocator, .endpoint = endpoint };
    }

    pub fn deinit(self: *MultiplexedAdapter) ?foundation.FailureChain {
        var cleanup: ?foundation.FailureChain = null;
        self.stopListen() catch |err| {
            cleanup = .init(err);
        };
        var rows = self.conns.valueIterator();
        while (rows.next()) |row| self.endpoint.loopConnClose(row.handle);
        self.conns.deinit(self.allocator);
        self.* = undefined;
        return cleanup;
    }

    pub fn multiplexed(self: *MultiplexedAdapter) net.MultiplexedResident {
        return .{ .ctx = self, .vtable = &vtable };
    }

    pub fn drainReady(self: *MultiplexedAdapter, out: []net.multiplexed_resident.ReadyEvent) error{ReadinessFailed}!usize {
        var scratch: [32]sidecar.ReadyEvent = undefined;
        const room = scratch[0..@min(out.len, scratch.len)];
        const got = self.endpoint.drainReady(room);
        // A count past the room is the sidecar breaking its contract.
        if (got < 0 or got > room.len) return error.ReadinessFailed;
        var total: usize = 0;
        for (room[0..@intCast(got)]) |event| {
            if (event.events & sidecar.ev_accept != 0) {
                const listener = self.listener orelse continue;
                out[total] = .{ .subject = listener.route, .events = event.events };
            } else {
                out[total] = .{ .subject = event.subject, .events = event.events };
            }
            total += 1;
        }
        return total;
    }

    pub fn startConnect(self: *MultiplexedAdapter, request: usize, locator: model.PeerLocator, options: net.netlayer.OperationOptions) net.netlayer.DialError!void {
        try options.requireInherited();
        if (!std.mem.eql(u8, locator.transport, locators.transport_name)) return error.InvalidAddress;
        try self.endpoint.loopStartConnectResolved(request, locator.designator, net.netlayer.directAddrHint(locator.hints) orelse "");
    }

    pub fn finishConnect(self: *MultiplexedAdapter, request: usize, text: ?*sidecar.DialText) net.netlayer.DialError!usize {
        return self.register(try self.endpoint.loopFinishConnect(request, text));
    }

    pub fn cancelConnect(self: *MultiplexedAdapter, request: usize) void {
        self.endpoint.loopCancelConnect(request);
    }

    fn register(self: *MultiplexedAdapter, handle: *anyopaque) std.mem.Allocator.Error!usize {
        errdefer self.endpoint.loopConnClose(handle);
        const id = self.endpoint.loopConnId(handle);
        std.debug.assert(id != 0 and !self.conns.contains(id));
        try self.conns.put(self.allocator, id, .{ .handle = handle });
        return id;
    }

    pub const ListenError = error{ AlreadyListening, InvalidAddress, InvalidOptions, MetadataTooLarge, SidecarFailed } || std.mem.Allocator.Error;

    pub fn listen(self: *MultiplexedAdapter, route: usize, transport: []const u8, requested: []const u8, options: net.netlayer.OperationOptions) ListenError!void {
        try options.requireInherited();
        if (self.listener != null) return error.AlreadyListening;
        if (!std.mem.eql(u8, transport, locators.transport_name)) return error.InvalidAddress;
        var designator: [locators.node_id_len]u8 = undefined;
        const actual = self.endpoint.nodeId(&designator);
        if (actual.len == 0 or (requested.len != 0 and !std.mem.eql(u8, requested, actual))) return error.InvalidAddress;
        const addresses = self.endpoint.directAddrsOwned(self.allocator) catch |err| switch (err) {
            error.AddressListTooLarge => return error.MetadataTooLarge,
            else => |failure| return failure,
        };
        defer self.allocator.free(addresses);
        var hints: [1]model.HintEntry = undefined;
        const locator = try model.clonePeerLocator(self.allocator, .{
            .transport = locators.transport_name,
            .designator = actual,
            .hints = model.Hints.forDirectAddresses(addresses, &hints),
        });
        errdefer model.freePeerLocator(self.allocator, locator);
        try self.endpoint.setLoopAdmission(true);
        self.listener = .{ .route = route, .locator = locator };
    }

    pub fn localLocator(self: *const MultiplexedAdapter, allocator: std.mem.Allocator) net.netlayer.ListenError!model.PeerLocator {
        return model.clonePeerLocator(allocator, try self.borrowListenerLocator());
    }

    pub fn borrowListenerLocator(self: *const MultiplexedAdapter) net.netlayer.ListenError!model.PeerLocator {
        const listener = self.listener orelse return error.InvalidOptions;
        return listener.locator;
    }

    pub fn canonicalizeLocator(self: *const MultiplexedAdapter, allocator: std.mem.Allocator, locator: model.PeerLocator) net.netlayer.ListenError!model.PeerLocator {
        try self.validateAdvertisement(locator);
        return model.clonePeerLocator(allocator, locator);
    }

    pub fn validateAdvertisement(self: *const MultiplexedAdapter, value: model.PeerLocator) net.netlayer.ListenError!void {
        const active = try self.borrowListenerLocator();
        locators.validateListenerLocator(active.designator, value) catch return error.InvalidAddress;
    }

    pub fn finishAccept(self: *MultiplexedAdapter) std.mem.Allocator.Error!?usize {
        if (self.listener == null) return null;
        const handle = self.endpoint.loopTryAccept() orelse return null;
        return try self.register(handle);
    }

    pub fn stopListen(self: *MultiplexedAdapter) error{SidecarFailed}!void {
        // Teardown failure is terminal: locator custody retires on every
        // outcome, even if the endpoint refuses its admission-seal operation.
        if (self.listener) |listener| model.freePeerLocator(self.allocator, listener.locator);
        self.listener = null;
        try self.endpoint.setLoopAdmission(false);
    }

    /// A count past `len` is the sidecar breaking its contract, never bytes
    /// moved: the row fails as on a fault and the caller sees a fault.
    fn latch(row: *ConnRow, len: usize, result: isize) isize {
        if (result > len) {
            if (row.failure == null) row.failure = .init(error.IrohSidecarContract);
            return -1;
        }
        if (result < 0 and result != sidecar.would_block and row.failure == null)
            row.failure = .init(error.ConnectionLost);
        return result;
    }

    pub fn tryRead(self: *MultiplexedAdapter, id: usize, bytes: []u8) isize {
        const row = self.conns.getPtr(id) orelse return -1;
        return latch(row, bytes.len, self.endpoint.loopTryRead(row.handle, bytes));
    }

    pub fn tryWrite(self: *MultiplexedAdapter, id: usize, bytes: []const u8) isize {
        const row = self.conns.getPtr(id) orelse return -1;
        return latch(row, bytes.len, self.endpoint.loopTryWrite(row.handle, bytes));
    }

    pub fn closeConnection(self: *MultiplexedAdapter, id: usize) void {
        if (self.conns.fetchRemove(id)) |row| self.endpoint.loopConnClose(row.value.handle);
    }

    pub fn takeFailure(self: *MultiplexedAdapter, id: usize) ?foundation.FailureChain {
        const row = self.conns.getPtr(id) orelse return null;
        const failure = row.failure;
        row.failure = null;
        return failure;
    }

    pub fn remoteKey(self: *MultiplexedAdapter, id: usize) ?foundation.crypto.PeerKey {
        const row = self.conns.get(id) orelse return null;
        return self.endpoint.loopConnRemoteKey(row.handle);
    }

    fn from(ctx: *anyopaque) *MultiplexedAdapter {
        return @ptrCast(@alignCast(ctx));
    }
    fn readiness(ctx: *anyopaque) i32 {
        return from(ctx).endpoint.readinessFd();
    }
    fn drain(ctx: *anyopaque, out: []net.multiplexed_resident.ReadyEvent) net.multiplexed_resident.ContractError!usize {
        return from(ctx).drainReady(out) catch return error.ProviderContract;
    }
    fn start(ctx: *anyopaque, request: usize, locator: model.PeerLocator, options: net.netlayer.OperationOptions, _: net.netlayer.DialOrigin) net.multiplexed_resident.RawDialStartOutcome {
        from(ctx).startConnect(request, locator, options) catch |err| return .{ .failed = .init(err) };
        return .admitted;
    }
    fn finish(ctx: *anyopaque, request: usize) net.multiplexed_resident.RawDialFinishOutcome {
        return .{ .connected = from(ctx).finishConnect(request, null) catch |err| return .{ .failed = .init(err) } };
    }
    fn cancel(ctx: *anyopaque, request: usize) ?foundation.FailureChain {
        from(ctx).cancelConnect(request);
        return null;
    }
    /// The node id is iroh's own identity, so the Host key is not read.
    fn startListen(ctx: *anyopaque, route: usize, transport: []const u8, config: net.netlayer.ListenConfig) net.MultiplexedResident.RawListenStartOutcome {
        from(ctx).listen(route, transport, config.designator, config.options) catch |err| {
            return .{ .failed = .init(err) };
        };
        return .{ .admitted = .{ .ready = ctx } };
    }
    fn localLocatorCallback(ctx: *anyopaque, _: *anyopaque, _: []const u8, allocator: std.mem.Allocator) net.netlayer.ListenError!model.PeerLocator {
        return from(ctx).localLocator(allocator);
    }
    fn canonicalize(ctx: *anyopaque, _: *anyopaque, _: []const u8, allocator: std.mem.Allocator, value: model.PeerLocator) net.netlayer.ListenError!model.PeerLocator {
        return from(ctx).canonicalizeLocator(allocator, value);
    }
    fn accept(ctx: *anyopaque, _: *anyopaque) net.netlayer.AcceptError!?usize {
        return from(ctx).finishAccept();
    }
    fn stop(ctx: *anyopaque, _: *anyopaque) net.multiplexed_resident.TeardownOutcome {
        from(ctx).stopListen() catch |err| return .{ .failed = .init(err) };
        return .complete;
    }
    fn read(ctx: *anyopaque, id: usize, bytes: []u8) isize {
        return from(ctx).tryRead(id, bytes);
    }
    fn write(ctx: *anyopaque, id: usize, bytes: []const u8) isize {
        return from(ctx).tryWrite(id, bytes);
    }
    fn close(ctx: *anyopaque, id: usize) net.multiplexed_resident.TeardownOutcome {
        from(ctx).closeConnection(id);
        return .complete;
    }
    fn takeFailureCallback(ctx: *anyopaque, id: usize) ?foundation.FailureChain {
        return from(ctx).takeFailure(id);
    }
    fn key(ctx: *anyopaque, id: usize) net.multiplexed_resident.ContractError!?foundation.crypto.PeerKey {
        return from(ctx).remoteKey(id);
    }

    const vtable: net.MultiplexedResident.VTable = .{
        .readiness_fd = readiness,
        .drain_ready = drain,
        .dial = .{ .start_connect = start, .finish_connect = finish, .cancel_connect = cancel },
        .listen = .{
            .listen = startListen,
            .local_locator = net.MultiplexedResident.adaptListenerLocator(localLocatorCallback),
            .canonicalize_locator = net.MultiplexedResident.adaptListenerCanonicalize(canonicalize),
            .finish_accept = net.MultiplexedResident.adaptFinishAccept(accept),
            .stop_listen = stop,
        },
        .try_read = read,
        .try_write = write,
        .take_failure = takeFailureCallback,
        .conn_close = close,
        .conn_remote_key = key,
    };
};

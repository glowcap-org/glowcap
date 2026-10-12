//! `inproc` as a completion adapter (ADR-0193): in-process byte pipes behind
//! the same backend contract as every socket transport.
//!
//! `exchange.zig` owns the switchboard, the bounded links and each backend's
//! sink. This adapter turns a sink's edges into completions with the same
//! `HintedTryIo` machine the multiplexed sidecars use, and passes every other
//! target and handle through to `Platform` unchanged.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const completion = @import("../../completion/loop.zig");
const netlayer = @import("../../netlayer.zig");
const exchange_mod = @import("exchange.zig");

const crypto = foundation.crypto;
pub const Exchange = exchange_mod.Exchange;
const End = exchange_mod.End;
const Listener = exchange_mod.Listener;
const Sink = exchange_mod.Sink;

/// The exchange this backend dials and listens through. Without one, an
/// `inproc` dial or listen is refused and the platform serves alone.
pub const Options = struct {
    exchange: ?*Exchange = null,
};

pub fn CompletionBackend(comptime Platform: type) type {
    return struct {
        const Self = @This();
        const Namespace = completion.AdapterNamespace(Platform);
        pub const Fd = Platform.Fd;
        pub const adapter_depth = Namespace.depth;
        pub const ListenerAddress = union(enum) {
            platform: Platform.ListenerAddress,
            /// The served designator, owned by the open listener.
            inproc: []const u8,
        };
        /// One backend serves at most one designator, because the exchange
        /// routes dials to a backend's one sink.
        pub const ListenTarget = union(enum) {
            platform: Platform.ListenTarget,
            /// Borrowed for the call. The exchange keeps its own copy.
            inproc: []const u8,
        };
        pub const ConnectTarget = union(enum) {
            inproc: []const u8,
            platform: Platform.ConnectTarget,
        };

        pub const listen_fd: Fd = Namespace.fdFromComptimeId(0);
        const wake_user_data = Namespace.userData(0);

        const ConnEntry = struct {
            end: *End,
            pending: completion.HintedPending = .{},
        };

        /// One connection's adapter row. Its link is a separate named cost.
        pub const connection_state_bytes = @sizeOf(ConnEntry);

        const TryIoOps = struct {
            pub const Entry = ConnEntry;
            pub const holds_admission_seat = true;

            pub fn tryRead(entry: *ConnEntry, buf: []u8) completion.TryRead {
                return entry.end.read(buf);
            }

            pub fn tryWrite(entry: *ConnEntry, bytes: []const u8) completion.TryWrite {
                return entry.end.write(bytes);
            }

            pub fn closeOnFailure(_: *ConnEntry) void {}

            pub fn borrowToken(index: u32) u32 {
                return Namespace.borrowToken(index);
            }

            pub fn reserveSeats(backend: *Self, count: usize) !void {
                try backend.reserveReady(count);
            }

            pub fn publish(backend: *Self, item: completion.Completion) void {
                backend.appendReserved(item);
            }
        };
        const TryIo = completion.HintedTryIo(Self, TryIoOps);

        allocator: std.mem.Allocator,
        platform: Platform,
        exchange: ?*Exchange,
        listener: ?*Listener = null,
        /// Heap-resident so peers on other threads keep a stable address.
        sink: *Sink,
        conns: std.AutoHashMap(Fd, ConnEntry),
        accept_ud: ?u64 = null,
        ready: completion.ReadyQueue = .{},
        ready_reserved: usize = 0,
        wake_armed: bool = false,
        next_id: u32 = 1,
        buffer_pool: completion.BufferPool,

        pub fn init(
            allocator: std.mem.Allocator,
            options: Options,
            queue_entries: u16,
            read_buffers: u16,
            read_buffer_bytes: u32,
        ) !Self {
            const platform = try Platform.init(allocator, queue_entries, read_buffers, read_buffer_bytes);
            return initWithPlatform(allocator, options, platform, read_buffers, read_buffer_bytes);
        }

        /// Ownership of `platform` transfers on entry, including every error path.
        pub fn initWithPlatform(
            allocator: std.mem.Allocator,
            options: Options,
            platform: Platform,
            read_buffers: u16,
            read_buffer_bytes: u32,
        ) !Self {
            var owned_platform = platform;
            errdefer owned_platform.deinit();
            var buffer_pool = try completion.BufferPool.init(allocator, read_buffers, read_buffer_bytes);
            errdefer buffer_pool.deinit();
            const sink = try Sink.create(allocator);
            return .{
                .allocator = allocator,
                .platform = owned_platform,
                .exchange = options.exchange,
                .sink = sink,
                .conns = std.AutoHashMap(Fd, ConnEntry).init(allocator),
                .buffer_pool = buffer_pool,
            };
        }

        pub fn deinit(self: *Self) void {
            self.stopListening();
            var it = self.conns.valueIterator();
            while (it.next()) |entry| entry.end.release(self.allocator);
            self.conns.deinit();
            self.platform.deinit();
            self.sink.destroy(self.allocator);
            self.ready.deinit(self.allocator);
            self.buffer_pool.deinit();
        }

        pub fn tcpBackendStatus(self: *const Self) @TypeOf(self.platform.tcpBackendStatus()) {
            return self.platform.tcpBackendStatus();
        }

        /// A peer on another thread reaches this backend through its wake
        /// receive on the platform, so the platform's descriptor reports both.
        pub fn readinessFd(self: *const Self) Fd {
            return self.platform.readinessFd();
        }

        pub fn flush(self: *Self) !void {
            return self.platform.flush();
        }

        pub fn submitPoll(self: *Self, user_data: u64, fd: Fd, interest: completion.Interest) !void {
            return self.platform.submitPoll(user_data, fd, interest);
        }

        pub fn waitBoundMs(self: *const Self, requested_ms: i32) i32 {
            return self.platform.waitBoundMs(requested_ms);
        }

        pub fn loopListenTarget(port: u16) ListenTarget {
            return .{ .platform = Platform.loopListenTarget(port) };
        }

        pub fn openListener(self: *Self, target: ListenTarget) !Fd {
            const designator = switch (target) {
                .platform => |platform_target| return self.platform.openListener(platform_target),
                .inproc => |designator| designator,
            };
            const exchange = self.exchange orelse return error.InprocNotConfigured;
            if (self.listener != null) return error.AddressInUse;
            self.listener = try exchange.listen(designator, self.sink);
            return listen_fd;
        }

        pub fn listenerAddress(self: *Self, fd: Fd) !ListenerAddress {
            if (fd == listen_fd) {
                const listener = self.listener orelse return error.InvalidListener;
                return .{ .inproc = listener.designator };
            }
            return .{ .platform = try self.platform.listenerAddress(fd) };
        }

        /// An inproc listener's setup is synchronous, so only a wrapped
        /// backend's listener can report pending.
        pub fn listenerPending(self: *const Self, fd: Fd) bool {
            if (fd == listen_fd) return false;
            return self.platform.listenerPending(fd);
        }

        /// Complete `user_data` when the listener's setup ends. Only a
        /// wrapped backend's listener can be pending; the runtime never asks
        /// about an inproc one.
        pub fn submitListenReady(self: *Self, user_data: u64, fd: Fd) !void {
            if (fd == listen_fd) return error.ListenerClosed;
            // The seat exists only for a backend that reports pending
            // listeners; a plain platform never does.
            if (comptime !@hasDecl(Platform, "submitListenReady")) return error.ListenerClosed;
            return self.platform.submitListenReady(user_data, fd);
        }

        pub fn listenerPort(address: ListenerAddress) ?u16 {
            return switch (address) {
                .platform => |platform| Platform.listenerPort(platform),
                .inproc => null,
            };
        }

        pub fn startDial(self: *Self, user_data: u64, target: ConnectTarget) !Fd {
            const designator = switch (target) {
                .platform => |platform_target| return self.platform.startDial(user_data, platform_target),
                .inproc => |designator| designator,
            };
            const exchange = self.exchange orelse return error.InprocNotConfigured;
            try self.reserveReady(1);
            errdefer self.releaseReady(1);
            const fd = try self.reserveFd();
            try self.conns.ensureUnusedCapacity(1);
            const end = try exchange.connect(designator, self.sink, Namespace.fdId(fd));
            self.conns.putAssumeCapacity(fd, .{ .end = end, .pending = .{ .writable_hint = true } });
            self.appendReserved(.{ .user_data = user_data, .result = 0 });
            return fd;
        }

        pub fn applyKeepalive(self: *Self, fd: Fd, keepalive: completion.Keepalive) !void {
            if (Namespace.ownsFd(fd)) return error.OperationUnsupported;
            return self.platform.applyKeepalive(fd, keepalive);
        }

        pub fn wireFraming(self: *Self, fd: Fd) model.transport.WireFraming {
            if (Namespace.ownsFd(fd)) return .byte_stream;
            return self.platform.wireFraming(fd);
        }

        /// An in-process pipe proves no peer identity.
        pub fn verifiedChannelKey(self: *Self, fd: Fd) ?[crypto.PEER_KEY_BYTES]u8 {
            if (Namespace.ownsFd(fd)) return null;
            return self.platform.verifiedChannelKey(fd);
        }

        pub fn submitAccept(self: *Self, user_data: u64, listen: Fd) !void {
            if (!Namespace.ownsFd(listen)) return self.platform.submitAccept(user_data, listen);
            if (listen != listen_fd or self.listener == null) return error.ListenerClosed;
            if (self.accept_ud != null) return error.AlreadyAccepting;
            try self.reserveReady(1);
            self.accept_ud = user_data;
            self.takeAccept();
        }

        pub fn submitRecv(self: *Self, user_data: u64, fd: Fd) !void {
            if (!Namespace.ownsFd(fd)) return self.platform.submitRecv(user_data, fd);
            return TryIo.submitRecv(self, user_data, fd);
        }

        pub fn submitSend(self: *Self, user_data: u64, fd: Fd, bytes: []const u8) !void {
            if (!Namespace.ownsFd(fd)) return self.platform.submitSend(user_data, fd, bytes);
            return TryIo.submitSend(self, user_data, fd, bytes);
        }

        pub fn submitCancel(self: *Self, cancel_user_data: u64, target_user_data: u64, fd: Fd) !void {
            if (!Namespace.ownsFd(fd))
                return self.platform.submitCancel(cancel_user_data, target_user_data, fd);
            return TryIo.submitCancel(self, cancel_user_data, target_user_data, fd);
        }

        pub fn shutdownFd(self: *Self, fd: Fd) void {
            if (!Namespace.ownsFd(fd)) self.platform.shutdownFd(fd);
        }

        pub fn submitClose(self: *Self, user_data: u64, fd: Fd) !void {
            if (!Namespace.ownsFd(fd)) return self.platform.submitClose(user_data, fd);
            // Pending operations already own their seats; reserve the close's.
            try self.reserveReady(1);
            if (fd == listen_fd) {
                if (self.accept_ud) |ud| {
                    self.appendReserved(.{ .user_data = ud, .result = -1 });
                    self.accept_ud = null;
                }
                self.stopListening();
            } else if (self.conns.getPtr(fd)) |entry| {
                if (entry.pending.read_ud) |ud| self.appendReserved(.{ .user_data = ud, .result = -1 });
                if (entry.pending.write_ud) |ud| self.appendReserved(.{ .user_data = ud, .result = -1 });
                entry.pending = .{};
                self.closeFd(fd);
            }
            self.appendReserved(.{ .user_data = user_data, .result = 0 });
        }

        pub fn closeFd(self: *Self, fd: Fd) void {
            if (!Namespace.ownsFd(fd)) return self.platform.closeFd(fd);
            if (fd == listen_fd) return self.stopListening();
            const removed = self.conns.fetchRemove(fd) orelse return;
            std.debug.assert(removed.value.pending.read_ud == null and removed.value.pending.write_ud == null);
            removed.value.end.release(self.allocator);
        }

        pub fn recycleBorrowed(self: *Self, comp: completion.Completion) void {
            if (Namespace.ownsBorrowToken(comp.borrowed.token)) {
                self.buffer_pool.release(@intCast(Namespace.borrowTokenPayload(comp.borrowed.token)));
            } else {
                self.platform.recycleBorrowed(comp);
            }
        }

        pub fn poll(self: *Self, out: []completion.Completion, timeout_ms: i32) !usize {
            try self.sink.wake_failure.check();
            if (!self.wake_armed) {
                try self.platform.submitRecv(wake_user_data, self.sink.wake.read);
                self.wake_armed = true;
            }
            var platform_completions: [256]completion.Completion = undefined;
            const total = std.math.add(usize, self.ready_reserved, platform_completions.len) catch
                return error.OutOfMemory;
            try self.ready.ensureUnusedCapacity(self.allocator, total);
            const wait_ms: i32 = if (self.ready.len() > 0) 0 else timeout_ms;
            const count = try self.platform.poll(&platform_completions, wait_ms);
            for (platform_completions[0..count]) |comp| {
                if (comp.user_data != wake_user_data) {
                    self.ready.appendAssumeCapacity(comp);
                    continue;
                }
                if (comp.borrowed.active()) self.platform.recycleBorrowed(comp);
                self.wake_armed = false;
                if (!comp.recv_no_buffer and comp.result <= 0) return error.SignalReadFailed;
                self.sink.wake.drain() catch |err| {
                    self.sink.wake_failure.record(err);
                    return err;
                };
                self.harvest();
            }
            return self.ready.drain(out);
        }

        /// Settle the ends with news, one at a time so I/O runs outside the
        /// sink lock. A peer that signals again meanwhile requeues its end,
        /// so the pass is bounded by the queue it started with.
        fn harvest(self: *Self) void {
            const pass = self.sink.startPass();
            var budget = pass.ends;
            while (budget > 0) : (budget -= 1) {
                const end = self.sink.pop() orelse break;
                // tolerant: an end whose row is gone was closed by this owner.
                const fd = Namespace.fdFromId(end.row) catch continue;
                const entry = self.conns.getPtr(fd) orelse continue;
                entry.pending.readable_hint = true;
                entry.pending.writable_hint = true;
                if (entry.pending.read_ud != null) TryIo.completeRecv(self, entry);
                if (entry.pending.write_ud != null) TryIo.completeSend(self, entry);
            }
            if (pass.accept) self.takeAccept();
        }

        fn takeAccept(self: *Self) void {
            const ud = self.accept_ud orelse return;
            const listener = self.listener orelse return;
            const end = listener.take() orelse return;
            self.accept_ud = null;
            const fd = self.bindAccepted(end) catch |err| {
                end.release(self.allocator);
                self.appendReserved(.{ .user_data = ud, .result = -1, .failure = err });
                return;
            };
            self.appendReserved(.{ .user_data = ud, .result = 0, .accepted_fd = fd });
        }

        fn bindAccepted(self: *Self, end: *End) !Fd {
            const fd = try self.reserveFd();
            try self.conns.ensureUnusedCapacity(1);
            end.bind(self.sink, Namespace.fdId(fd));
            // Bytes or a close may have arrived before this end had a sink.
            self.conns.putAssumeCapacity(fd, .{ .end = end, .pending = .{
                .readable_hint = true,
                .writable_hint = true,
            } });
            return fd;
        }

        fn stopListening(self: *Self) void {
            const listener = self.listener orelse return;
            self.listener = null;
            // A listener exists only through an exchange.
            self.exchange.?.unlisten(listener);
        }

        fn reserveFd(self: *Self) !Fd {
            if (self.next_id == 0 or self.next_id > Namespace.max_fd_id) return error.OutOfFds;
            const id = self.next_id;
            self.next_id += 1;
            return Namespace.fdFromId(id);
        }

        fn reserveReady(self: *Self, count: usize) !void {
            const total = std.math.add(usize, self.ready_reserved, count) catch return error.OutOfMemory;
            try self.ready.ensureUnusedCapacity(self.allocator, total);
            self.ready_reserved = total;
        }

        fn releaseReady(self: *Self, count: usize) void {
            std.debug.assert(self.ready_reserved >= count);
            self.ready_reserved -= count;
        }

        fn appendReserved(self: *Self, item: completion.Completion) void {
            self.releaseReady(1);
            self.ready.appendAssumeCapacity(item);
        }
    };
}

/// Resolve `inproc` locators to an in-process dial. Every other transport
/// resolves through `InnerResolver` to a platform target.
pub fn DialResolver(comptime Backend: type, comptime InnerResolver: type) type {
    return struct {
        pub fn resolve(locator: model.PeerLocator) !Backend.ConnectTarget {
            if (std.mem.eql(u8, locator.transport, model.transport.inproc))
                return .{ .inproc = locator.designator };
            return .{ .platform = try InnerResolver.resolve(locator) };
        }
    };
}

/// `inproc` over `Inner`, the platform's own policy, as the transport policy
/// `net.completion_resident.Resident` takes. Every other symbol passes to
/// `Inner` against the wrapped platform backend.
pub fn ResidentPolicy(comptime Backend: type, comptime Inner: type) type {
    return struct {
        fn isInproc(transport: []const u8) bool {
            return std.mem.eql(u8, transport, model.transport.inproc);
        }

        pub fn resolve(locator: model.PeerLocator) !Backend.ConnectTarget {
            if (isInproc(locator.transport)) return .{ .inproc = locator.designator };
            return .{ .platform = try Inner.resolve(locator) };
        }

        pub fn listenTarget(backend: *const Backend, transport: []const u8, config: netlayer.ListenConfig) !Backend.ListenTarget {
            if (!isInproc(transport)) return .{ .platform = try Inner.listenTarget(&backend.platform, transport, config) };
            if (config.designator.len == 0) return error.InvalidAddress;
            return .{ .inproc = config.designator };
        }

        pub fn localLocator(
            backend: *Backend,
            fd: Backend.Fd,
            transport: []const u8,
            identity: ?crypto.PeerKey,
            allocator: std.mem.Allocator,
        ) !model.PeerLocator {
            return switch (try backend.listenerAddress(fd)) {
                .inproc => |designator| model.clonePeerLocator(allocator, .{
                    .transport = transport,
                    .designator = designator,
                    .hints = model.Hints.emptyFalse(),
                }),
                .platform => Inner.localLocator(&backend.platform, fd, transport, identity, allocator),
            };
        }

        /// Restoration state belongs to the adapter beneath.
        pub fn restorationState(backend: *Backend, fd: Backend.Fd, out: []u8) netlayer.ListenerRestorationOutcome {
            const address = backend.listenerAddress(fd) catch |err| return .{ .failed = .init(err) };
            return switch (address) {
                .inproc => .unsupported,
                .platform => if (comptime @hasDecl(Inner, "restorationState")) Inner.restorationState(&backend.platform, fd, out) else .unsupported,
            };
        }

        /// An in-process designator names exactly one listener, so a listener
        /// advertises only its own.
        pub fn canonicalizeLocator(
            backend: *Backend,
            fd: Backend.Fd,
            transport: []const u8,
            identity: ?crypto.PeerKey,
            allocator: std.mem.Allocator,
            candidate: model.PeerLocator,
        ) !model.PeerLocator {
            if (!isInproc(transport)) return Inner.canonicalizeLocator(&backend.platform, fd, transport, identity, allocator, candidate);
            model.validatePeerLocator(candidate) catch return error.InvalidAddress;
            const served = switch (try backend.listenerAddress(fd)) {
                .inproc => |designator| designator,
                .platform => return error.InvalidAddress,
            };
            if (!isInproc(candidate.transport) or !std.mem.eql(u8, candidate.designator, served)) return error.InvalidAddress;
            return model.clonePeerLocator(allocator, candidate);
        }
    };
}

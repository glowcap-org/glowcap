//! Foreign stream providers as a completion adapter (ADR-0193).
//!
//! Each provider connection becomes a synthetic handle served by the same
//! `HintedTryIo` machine the multiplexed sidecars use. A read or write the
//! provider refuses arms a one-shot `submitPoll` on the connection's
//! readiness descriptor, and its completion raises the hint and retries. Dial
//! and listen attempts wait the same way before their finish verb runs. The
//! adapter never reads, writes, or closes a provider descriptor: every armed
//! poll is canceled and retired before the provider releases its handle.
//!
//! A provider owns its connection's bytes, so a read copies them once into a
//! buffer from this backend's shared pool and lends that buffer to the loop.
//! A write lends the loop's borrowed bytes to `try_write` for the call only;
//! the provider copies what it accepts.
//! Every other target and handle passes through to `Platform` unchanged.

const std = @import("std");

const foundation = @import("foundation");

const model = @import("model");
const completion = @import("../../completion/loop.zig");
const netlayer = @import("../../netlayer.zig");
const provider_mod = @import("provider.zig");
const state = @import("state.zig");

pub const Provider = provider_mod.Provider;
pub const VTable = provider_mod.VTable;
pub const Handle = provider_mod.Handle;
pub const Started = provider_mod.Started;
pub const Finished = provider_mod.Finished;

/// The providers a backend dials and listens through. They borrow storage
/// that outlives the backend.
pub const Options = struct {
    providers: []const Provider,
};

pub fn CompletionBackend(comptime Platform: type) type {
    comptime {
        if (!@hasDecl(Platform, "submitPoll"))
            @compileError(@typeName(Platform) ++ " must provide `submitPoll` to host foreign providers");
    }
    return struct {
        const Self = @This();
        const Namespace = completion.AdapterNamespace(Platform);
        pub const Fd = Platform.Fd;
        pub const PlatformBackend = Platform;
        pub const adapter_depth = Namespace.depth;
        const State = state.Types(Platform, Namespace);
        pub const ListenerAddress = State.ListenerAddress;
        pub const ConnectTarget = State.ConnectTarget;
        pub const ListenTarget = State.ListenTarget;
        pub const listen_fd = State.listen_fd;
        pub const Op = State.Op;
        pub const Identity = State.Identity;
        const Phase = State.Phase;
        const Entry = State.Entry;
        pub const ListenerRow = State.ListenerRow;

        /// One connection's adapter row; its provider handle is the provider's
        /// own cost.
        pub const connection_state_bytes = @sizeOf(Entry);

        const TryIoOps = struct {
            pub const Entry = Self.Entry;
            pub const holds_admission_seat = true;

            pub fn tryRead(entry: *Self.Entry, buf: []u8) completion.TryRead {
                return entry.provider.vtable.try_read(entry.provider.ctx, entry.phase.open, buf);
            }

            pub fn tryWrite(entry: *Self.Entry, bytes: []const u8) completion.TryWrite {
                return entry.provider.vtable.try_write(entry.provider.ctx, entry.phase.open, bytes);
            }

            pub fn closeOnFailure(_: *Self.Entry) void {}

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
        const Listening = @import("listener.zig").Machine(Self);

        allocator: std.mem.Allocator,
        platform: Platform,
        providers: []const Provider,
        listener: ?ListenerRow = null,
        conns: std.AutoHashMap(Fd, Entry),
        ready: completion.ReadyQueue = .{},
        ready_reserved: usize = 0,
        next_id: u32 = 1,
        buffer_pool: completion.BufferPool,

        /// Adopt `platform`, which this backend deinitializes from here on.
        pub fn initWithPlatform(
            allocator: std.mem.Allocator,
            options: Options,
            platform: Platform,
            read_buffers: u16,
            read_buffer_bytes: u32,
        ) !Self {
            var owned_platform = platform;
            errdefer owned_platform.deinit();
            const buffer_pool = try completion.BufferPool.init(allocator, read_buffers, read_buffer_bytes);
            return .{
                .allocator = allocator,
                .platform = owned_platform,
                .providers = options.providers,
                .conns = std.AutoHashMap(Fd, Entry).init(allocator),
                .buffer_pool = buffer_pool,
            };
        }

        /// The owning Loop closed and drained every handle first.
        pub fn deinit(self: *Self) void {
            std.debug.assert(self.conns.count() == 0 and self.listener == null);
            self.conns.deinit();
            self.platform.deinit();
            self.ready.deinit(self.allocator);
            self.buffer_pool.deinit();
        }

        pub fn tcpBackendStatus(self: *const Self) @TypeOf(self.platform.tcpBackendStatus()) {
            return self.platform.tcpBackendStatus();
        }

        /// Adapter work that completes off the caller's thread reaches this
        /// backend through a platform operation, so the platform's descriptor
        /// reports it; work that completes synchronously waits in the ready
        /// queue for the caller's next `poll`.
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
            return switch (target) {
                .platform => |platform_target| self.platform.openListener(platform_target),
                .provider => |serve| Listening.open(self, serve),
            };
        }

        pub const listenerLocator = Listening.locator;
        pub const listenerCanonicalize = Listening.canonicalize;
        pub const listenerRestorationState = Listening.restorationState;
        pub const listenerPending = Listening.pending;
        pub const submitListenReady = Listening.submitReady;

        pub fn listenerAddress(self: *Self, fd: Fd) !ListenerAddress {
            if (fd == listen_fd) return .external;
            return .{ .platform = try self.platform.listenerAddress(fd) };
        }

        /// The structured failure a provider keeps for the connection on
        /// `fd`, claimed once; platform connections answer through the
        /// platform when it keeps any.
        pub fn takeConnFailure(self: *Self, fd: Fd) ?foundation.FailureChain {
            const entry = self.conns.getPtr(fd) orelse {
                if (comptime @hasDecl(Platform, "takeConnFailure")) return self.platform.takeConnFailure(fd);
                return null;
            };
            const take = entry.provider.vtable.conn_take_failure orelse return null;
            return switch (entry.phase) {
                .open => |conn| take(entry.provider.ctx, conn),
                .connecting, .failed => null,
            };
        }

        pub fn listenerPort(address: ListenerAddress) ?u16 {
            return switch (address) {
                .platform => |platform| Platform.listenerPort(platform),
                .external => null,
            };
        }

        pub fn startDial(self: *Self, user_data: u64, target: ConnectTarget) !Fd {
            const locator = switch (target) {
                .platform => |platform_target| return self.platform.startDial(user_data, platform_target),
                .external => |locator| locator,
            };
            const provider = try self.providerFor(locator.transport);
            try self.reserveReady(1);
            errdefer self.releaseReady(1);
            const fd = try self.reserveFd();
            try self.conns.ensureUnusedCapacity(1);
            switch (provider.vtable.start_connect(provider.ctx, locator)) {
                .ready => |handle| {
                    self.conns.putAssumeCapacity(fd, openEntry(provider, handle));
                    self.appendReserved(.{ .user_data = user_data, .result = 0 });
                },
                .pending => |handle| {
                    self.conns.putAssumeCapacity(fd, .{
                        .provider = provider,
                        .phase = .{ .connecting = handle.ptr },
                        .fd = handle.fd,
                        .connect_ud = user_data,
                    });
                    const entry = self.conns.getPtr(fd).?;
                    self.platform.submitPoll(Identity.userData(.start_poll, Namespace.fdId(fd)), handle.fd, .readable) catch |err| {
                        std.debug.assert(self.conns.remove(fd));
                        provider.vtable.cancel_connect(provider.ctx, handle.ptr);
                        return err;
                    };
                    entry.start_poll = true;
                },
                .failed => |err| return err,
            }
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

        /// A provider's peer proof belongs to its profile's sealed channel,
        /// which the Host runs above this adapter.
        pub fn verifiedChannelKey(self: *Self, fd: Fd) ?[32]u8 {
            if (Namespace.ownsFd(fd)) return null;
            return self.platform.verifiedChannelKey(fd);
        }

        pub fn submitAccept(self: *Self, user_data: u64, listen: Fd) !void {
            if (!Namespace.ownsFd(listen)) return self.platform.submitAccept(user_data, listen);
            if (listen != listen_fd) return error.ListenerClosed;
            return Listening.submitAccept(self, user_data);
        }

        pub fn submitRecv(self: *Self, user_data: u64, fd: Fd) !void {
            if (!Namespace.ownsFd(fd)) return self.platform.submitRecv(user_data, fd);
            try self.requireOpen(fd);
            try TryIo.submitRecv(self, user_data, fd);
            self.armPolls(fd);
        }

        pub fn submitSend(self: *Self, user_data: u64, fd: Fd, bytes: []const u8) !void {
            if (!Namespace.ownsFd(fd)) return self.platform.submitSend(user_data, fd, bytes);
            try self.requireOpen(fd);
            try TryIo.submitSend(self, user_data, fd, bytes);
            self.armPolls(fd);
        }

        /// The read's armed poll stays armed; its edge only raises the hint.
        pub fn submitCancel(self: *Self, cancel_user_data: u64, target_user_data: u64, fd: Fd) !void {
            if (!Namespace.ownsFd(fd))
                return self.platform.submitCancel(cancel_user_data, target_user_data, fd);
            return TryIo.submitCancel(self, cancel_user_data, target_user_data, fd);
        }

        pub fn shutdownFd(self: *Self, fd: Fd) void {
            if (!Namespace.ownsFd(fd)) self.platform.shutdownFd(fd);
        }

        /// Settle every seat, retire the row's armed polls, then release the
        /// provider handle and publish the close.
        pub fn submitClose(self: *Self, user_data: u64, fd: Fd) !void {
            if (!Namespace.ownsFd(fd)) return self.platform.submitClose(user_data, fd);
            if (fd == listen_fd) return Listening.close(self, user_data);
            const entry = self.conns.getPtr(fd) orelse {
                try self.reserveReady(1);
                self.appendReserved(.{ .user_data = user_data, .result = 0 });
                return;
            };
            if (entry.closing) return error.AlreadyClosing;
            // Pending operations already hold their seats; reserve the close's.
            try self.reserveReady(1);
            if (entry.connect_ud) |ud| self.appendReserved(.{ .user_data = ud, .result = -1 });
            if (entry.pending.read_ud) |ud| self.appendReserved(.{ .user_data = ud, .result = -1 });
            if (entry.pending.write_ud) |ud| self.appendReserved(.{ .user_data = ud, .result = -1 });
            entry.connect_ud = null;
            entry.pending = .{};
            entry.close_ud = user_data;
            self.beginClose(fd, entry);
        }

        /// Release a handle the loop no longer waits on.
        pub fn closeFd(self: *Self, fd: Fd) void {
            if (!Namespace.ownsFd(fd)) return self.platform.closeFd(fd);
            if (fd == listen_fd) return Listening.release(self);
            const entry = self.conns.getPtr(fd) orelse return;
            std.debug.assert(entry.connect_ud == null and entry.pending.read_ud == null and entry.pending.write_ud == null);
            if (!entry.closing) self.beginClose(fd, entry);
        }

        pub fn recycleBorrowed(self: *Self, comp: completion.Completion) void {
            if (Namespace.ownsBorrowToken(comp.borrowed.token)) {
                self.buffer_pool.release(@intCast(Namespace.borrowTokenPayload(comp.borrowed.token)));
            } else {
                self.platform.recycleBorrowed(comp);
            }
        }

        pub fn poll(self: *Self, out: []completion.Completion, timeout_ms: i32) !usize {
            var platform_completions: [256]completion.Completion = undefined;
            // Each internal completion publishes at most one record per seat
            // its row reserved; pass-through records need their own room.
            const room = std.math.add(usize, self.ready_reserved, platform_completions.len) catch
                return error.OutOfMemory;
            try self.ready.ensureUnusedCapacity(self.allocator, room);
            const wait_ms: i32 = if (self.ready.len() > 0) 0 else timeout_ms;
            const count = try self.platform.poll(&platform_completions, wait_ms);
            for (platform_completions[0..count]) |comp| {
                if (Identity.owns(comp.user_data)) self.dispatch(comp) else self.ready.appendAssumeCapacity(comp);
            }
            return self.ready.drain(out);
        }

        fn dispatch(self: *Self, comp: completion.Completion) void {
            const id = Identity.id(comp.user_data);
            const op = Identity.op(comp.user_data);
            if (id == 0) return Listening.dispatch(self, op, comp);
            const fd = Namespace.fdFromId(id) catch unreachable;
            const entry = self.conns.getPtr(fd) orelse unreachable;
            switch (op) {
                .cancel => entry.cancels -= 1,
                .read_poll => {
                    entry.read_poll = false;
                    if (!entry.closing) self.edge(entry, comp, .read);
                },
                .write_poll => {
                    entry.write_poll = false;
                    if (!entry.closing) self.edge(entry, comp, .write);
                },
                .start_poll => {
                    entry.start_poll = false;
                    if (!entry.closing) self.finishConnect(entry);
                },
            }
            if (entry.closing) return self.maybeFinish(fd, entry);
            self.armPolls(fd);
        }

        fn edge(self: *Self, entry: *Entry, comp: completion.Completion, direction: enum { read, write }) void {
            if (comp.result < 0) return TryIo.failOpenConnection(self, entry, comp.failure orelse error.ReadinessFailed);
            switch (direction) {
                .read => {
                    entry.pending.readable_hint = true;
                    TryIo.completeRecv(self, entry);
                },
                .write => {
                    entry.pending.writable_hint = true;
                    TryIo.completeSend(self, entry);
                },
            }
        }

        fn finishConnect(self: *Self, entry: *Entry) void {
            const ud = entry.connect_ud.?;
            entry.connect_ud = null;
            const attempt = entry.phase.connecting;
            switch (entry.provider.vtable.finish_connect(entry.provider.ctx, attempt)) {
                .ready => |handle| {
                    entry.* = openEntry(entry.provider, handle);
                    self.appendReserved(.{ .user_data = ud, .result = 0 });
                },
                .failed => |err| {
                    entry.phase = .failed;
                    self.appendReserved(.{ .user_data = ud, .result = -1, .failure = err });
                },
            }
        }

        /// Arm a poll for each direction with a parked seat and no hint.
        fn armPolls(self: *Self, fd: Fd) void {
            const entry = self.conns.getPtr(fd) orelse return;
            if (entry.closing or entry.phase != .open or entry.pending.terminal_failure != null) return;
            const id = Namespace.fdId(fd);
            if (entry.pending.read_ud != null and !entry.pending.readable_hint and !entry.read_poll) {
                self.platform.submitPoll(Identity.userData(.read_poll, id), entry.fd, .readable) catch |err|
                    return TryIo.failOpenConnection(self, entry, err);
                entry.read_poll = true;
            }
            if (entry.pending.write_ud != null and !entry.pending.writable_hint and !entry.write_poll) {
                self.platform.submitPoll(Identity.userData(.write_poll, id), entry.fd, .writable) catch |err|
                    return TryIo.failOpenConnection(self, entry, err);
                entry.write_poll = true;
            }
        }

        fn beginClose(self: *Self, fd: Fd, entry: *Entry) void {
            entry.closing = true;
            const id = Namespace.fdId(fd);
            inline for (.{ .{ "read_poll", Op.read_poll }, .{ "write_poll", Op.write_poll }, .{ "start_poll", Op.start_poll } }) |armed| {
                if (@field(entry, armed[0])) self.cancelPoll(&entry.cancels, Identity.userData(armed[1], id), entry.fd);
            }
            self.maybeFinish(fd, entry);
        }

        /// A refused cancel leaves the poll armed; its completion still
        /// retires the row once the descriptor turns ready.
        pub fn cancelPoll(self: *Self, cancels: *u2, target: u64, fd: i32) void {
            const id = Identity.id(target);
            // tolerant: the armed poll still completes on its own edge.
            self.platform.submitCancel(Identity.userData(.cancel, id), target, fd) catch return;
            cancels.* += 1;
        }

        fn maybeFinish(self: *Self, fd: Fd, entry: *Entry) void {
            if (!entry.quiet()) return;
            const provider = entry.provider;
            switch (entry.phase) {
                .open => |conn| provider.vtable.conn_close(provider.ctx, conn),
                .connecting => |attempt| provider.vtable.cancel_connect(provider.ctx, attempt),
                .failed => {},
            }
            const close_ud = entry.close_ud;
            std.debug.assert(self.conns.remove(fd));
            if (close_ud) |ud| self.appendReserved(.{ .user_data = ud, .result = 0 });
        }

        fn requireOpen(self: *Self, fd: Fd) !void {
            const entry = self.conns.getPtr(fd) orelse return error.ConnectionLost;
            if (entry.closing or entry.phase != .open) return error.ConnectionLost;
        }

        pub fn openEntry(provider: *const Provider, handle: provider_mod.Handle) Entry {
            return .{
                .provider = provider,
                .phase = .{ .open = handle.ptr },
                .fd = handle.fd,
                .pending = .{ .writable_hint = true },
            };
        }

        pub fn providerFor(self: *const Self, transport: []const u8) !*const Provider {
            for (self.providers) |*provider|
                if (std.mem.eql(u8, provider.transport, transport)) return provider;
            return error.UnknownTransport;
        }

        pub fn reserveFd(self: *Self) !Fd {
            if (self.next_id == 0 or self.next_id > Namespace.max_fd_id) return error.OutOfFds;
            const id = self.next_id;
            self.next_id += 1;
            return Namespace.fdFromId(id);
        }

        pub fn reserveReady(self: *Self, count: usize) !void {
            const total = std.math.add(usize, self.ready_reserved, count) catch return error.OutOfMemory;
            try self.ready.ensureUnusedCapacity(self.allocator, total);
            self.ready_reserved = total;
        }

        pub fn releaseReady(self: *Self, count: usize) void {
            std.debug.assert(self.ready_reserved >= count);
            self.ready_reserved -= count;
        }

        pub fn appendReserved(self: *Self, item: completion.Completion) void {
            self.releaseReady(1);
            self.ready.appendAssumeCapacity(item);
        }
    };
}

/// Resolve every transport `InnerResolver` does not know to a foreign
/// provider dial; the backend refuses a symbol no provider serves.
pub const ResidentPolicy = @import("resident_policy.zig").ResidentPolicy;
pub const PlatformRefused = @import("resident_policy.zig").PlatformRefused;

pub fn DialResolver(comptime Backend: type, comptime InnerResolver: type) type {
    return struct {
        pub fn resolve(locator: model.PeerLocator) !Backend.ConnectTarget {
            const inner = InnerResolver.resolve(locator) catch |err| {
                if (err == error.UnknownTransport) return .{ .external = locator };
                return err;
            };
            return .{ .platform = inner };
        }
    };
}

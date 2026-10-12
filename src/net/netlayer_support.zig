//! Reusable stream storage, listener shells, and locator helpers beneath the
//! netlayer contract.
//!
//! These mechanisms contain no transport policy: residents supply concrete
//! byte sources, contexts, and listener verbs, while `netlayer.zig` owns
//! dial/listen outcomes and the contract vtables these shells fill in.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const engine = @import("engine");
const connection = @import("connection.zig");
const failure_contract = @import("netlayer/failure.zig");
const netlayer = @import("netlayer.zig");
const stream_shim = @import("stream_shim.zig");

/// Caller-owned read/write buffers handed to a dial/accept. `read` sizes the
/// steady per-connection memory, not the largest admissible frame.
pub const Buffers = struct {
    read: []u8,
    write: []u8,
};

/// Borrowed provider-owned configuration for one dial or listener operation.
/// The selected provider validates the exact payload type and must copy any
/// value retained after the starting call returns.
pub const OperationOptions = struct {
    data: ?*const anyopaque = null,
    size: usize = 0,

    pub const inherit: OperationOptions = .{};

    pub fn decode(self: OperationOptions, comptime T: type) error{InvalidOptions}!?*const T {
        const data = self.data orelse {
            if (self.size != 0) return error.InvalidOptions;
            return null;
        };
        if (self.size != @sizeOf(T) or @intFromPtr(data) % @alignOf(T) != 0)
            return error.InvalidOptions;
        return @ptrCast(@alignCast(data));
    }

    pub fn requireInherited(self: OperationOptions) error{InvalidOptions}!void {
        if (self.data != null or self.size != 0) return error.InvalidOptions;
    }
};

/// Borrowed configuration for one listener bind.
pub const ListenConfig = struct {
    designator: []const u8,
    identity: ?foundation.crypto.PeerKey = null,
    options: OperationOptions = .inherit,
};

/// One pinned byte-source stream: a shim reader/writer pair plus the allocation
/// from which their concrete interfaces can be recovered by field offset.
pub fn PinnedStream(comptime Source: type, comptime Context: type) type {
    return struct {
        const Self = @This();
        const ShimT = stream_shim.Shim(Source);

        reader: ShimT.Reader,
        writer: ShimT.Writer,
        allocator: std.mem.Allocator,
        context: Context,

        /// Pin the two shim sources and the transport context on `allocator`.
        pub fn create(
            allocator: std.mem.Allocator,
            read_source: Source,
            write_source: Source,
            bufs: Buffers,
            context: Context,
        ) std.mem.Allocator.Error!*Self {
            const self = try allocator.create(Self);
            self.* = .{
                .reader = ShimT.Reader.init(read_source, bufs.read),
                .writer = ShimT.Writer.init(write_source, bufs.write),
                .allocator = allocator,
                .context = context,
            };
            return self;
        }

        pub fn intoConnection(self: *Self, io: std.Io, peer: *engine.Peer) connection.Connection {
            return connection.Connection.init(io, peer, &self.reader.interface, &self.writer.interface, .{
                .ctx = self,
                .close_fn = close,
                .socket_handle_fn = socketHandle,
                .take_failure_fn = takeFailure,
            });
        }

        /// Release the transport handle before freeing its pinned allocation.
        pub fn close(ctx: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.context.closeStream();
            self.allocator.destroy(self);
        }

        fn socketHandle(ctx: *anyopaque) ?std.Io.net.Socket.Handle {
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (comptime @hasDecl(Context, "socketHandle")) return self.context.socketHandle();
            return null;
        }

        fn takeFailure(ctx: *anyopaque) ?foundation.FailureChain {
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (comptime @hasDecl(Context, "takeFailure")) return self.context.takeFailure();
            return null;
        }
    };
}

/// One pinned raw socket connection: a `Raw` that already carries
/// `std.Io.net.Stream`'s own reader and writer, held at a stable address for
/// the `Connection`'s life.
///
/// This is the second pinned shell beside `PinnedStream`, and the two exist
/// because their sources differ in kind. `PinnedStream` builds a shim reader
/// and writer over a byte `Source`, for transports that expose only read and
/// write calls (an in-process pipe, the iroh sidecar). A raw socket connection
/// already owns a `std.Io.Reader` and `std.Io.Writer` over its buffers, so
/// wrapping it in a shim would put a second buffer and a copy between the
/// socket and the frame parser (ADR-0043, ADR-0055). `Raw` supplies `reader`
/// and `writer` fields with an `interface`, an `io` field, `close`, and
/// `readinessFd`. Neither raw socket type carries a failure chain, so the
/// handle publishes none.
///
/// `std.Io.Reader`'s vtable recovers its concrete reader from `&interface` by
/// field offset, so the pair needs an address that outlives the call that made
/// it. Allocated from the peer's allocator at connect or accept and freed by
/// the connection's transport handle on `deinit`: one small per-connection
/// allocation on the blocking path, the price of keeping `Connection`
/// transport-neutral.
pub fn PinnedRawStream(comptime Raw: type) type {
    return struct {
        const Self = @This();

        raw: Raw,
        allocator: std.mem.Allocator,

        /// Pin `raw` on `peer.allocator` and weld it to `peer`. On allocation
        /// failure `raw` is still the caller's to close.
        pub fn adopt(peer: *engine.Peer, raw: Raw) std.mem.Allocator.Error!connection.Connection {
            const self = try peer.allocator.create(Self);
            self.* = .{ .raw = raw, .allocator = peer.allocator };
            return connection.Connection.init(self.raw.io, peer, &self.raw.reader.interface, &self.raw.writer.interface, .{
                .ctx = self,
                .close_fn = close,
                .socket_handle_fn = socketHandle,
            });
        }

        fn close(ctx: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.raw.close();
            self.allocator.destroy(self);
        }

        fn socketHandle(ctx: *anyopaque) ?std.Io.net.Socket.Handle {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.raw.readinessFd();
        }
    };
}

/// One listener behind the contract `netlayer.Listener` vtable, written once
/// as typed verbs over `Impl.State`. The shell owns the `*anyopaque` recovery,
/// the scalar-to-outcome adaptation, and the vtable itself, so a resident never
/// writes a `@ptrCast` accessor stub. `Impl` declares:
///
/// - `State`: the type the vtable's `ctx` points at, usually heap-pinned.
/// - `metadata`: the `model.transport.Metadata` this listener hosts. Its symbol,
///   designator scheme, and sealed-channel flag fill the vtable.
/// - `accept(*State, *engine.Peer, Buffers) AcceptError!Connection`
/// - `waitAcceptable(*State, i32) AcceptError!bool`
/// - `localLocator(*State, std.mem.Allocator) ListenError!model.PeerLocator`
/// - `canonicalizeLocator(*State, std.mem.Allocator, model.PeerLocator) ListenError!model.PeerLocator`
/// - `close(*State) ?ListenerCloseFailure`, releasing whatever `State` owns,
///   its own storage included when the listener is heap-pinned. A borrowed
///   listener returns null and frees nothing.
/// - optional `readinessFd(*State) i32`, when accept has one pollable
///   descriptor.
/// - optional `restorationState(*State, []u8) RestorationStateError!usize`.
///
/// Each verb keeps its own error projection. The shell adds none.
pub fn ListenerShell(comptime Impl: type) type {
    return struct {
        pub const State = Impl.State;

        pub const vtable: netlayer.Listener.VTable = .{
            .transport_name = Impl.metadata.symbol,
            .designator_scheme = Impl.metadata.designator_scheme,
            .sealed_channel = Impl.metadata.sealed_channel,
            .accept = failure_contract.adaptAccept(accept),
            .wait_acceptable = failure_contract.adaptAcceptReadiness(waitAcceptable),
            .local_locator = failure_contract.adaptListenerLocator(localLocator),
            .canonicalize_locator = failure_contract.adaptListenerCanonicalize(canonicalizeLocator),
            .restoration_state = if (@hasDecl(Impl, "restorationState"))
                failure_contract.adaptRestorationState(restorationState)
            else
                null,
            .readiness_fd = if (@hasDecl(Impl, "readinessFd")) &readinessFd else null,
            .close = close,
        };

        pub fn of(ctx: *anyopaque) *State {
            return @ptrCast(@alignCast(ctx));
        }

        /// `state` as the contract listener.
        pub fn listener(state: *State) netlayer.Listener {
            return .{ .ctx = state, .vtable = &vtable };
        }

        fn accept(ctx: *anyopaque, peer: *engine.Peer, bufs: Buffers) failure_contract.AcceptError!connection.Connection {
            return Impl.accept(of(ctx), peer, bufs);
        }

        fn waitAcceptable(ctx: *anyopaque, timeout_ms: i32) failure_contract.AcceptError!bool {
            return Impl.waitAcceptable(of(ctx), timeout_ms);
        }

        fn localLocator(ctx: *anyopaque, allocator: std.mem.Allocator) failure_contract.ListenError!model.PeerLocator {
            return Impl.localLocator(of(ctx), allocator);
        }

        fn canonicalizeLocator(
            ctx: *anyopaque,
            allocator: std.mem.Allocator,
            candidate: model.PeerLocator,
        ) failure_contract.ListenError!model.PeerLocator {
            return Impl.canonicalizeLocator(of(ctx), allocator, candidate);
        }

        fn restorationState(ctx: *anyopaque, out: []u8) failure_contract.RestorationStateError!usize {
            return Impl.restorationState(of(ctx), out);
        }

        fn readinessFd(ctx: *anyopaque) i32 {
            return Impl.readinessFd(of(ctx));
        }

        fn close(ctx: *anyopaque) ?failure_contract.ListenerCloseFailure {
            return Impl.close(of(ctx));
        }
    };
}

pub const DesignatorScheme = model.transport.DesignatorScheme;
pub const hint_direct_addresses = model.transport.hint_direct_addresses;

/// The locator's direct-address string hint, or null when it is absent or has
/// a different value kind.
pub fn directAddrHint(hints: model.Hints) ?[]const u8 {
    for (hints.entries) |entry| {
        if (!std.mem.eql(u8, entry.name, hint_direct_addresses)) continue;
        switch (entry.value) {
            .string => |s| return s,
            else => return null,
        }
    }
    return null;
}

/// Complete-size query/copy: no partial restoration state is ever published.
pub fn writeListenerRestorationState(out: []u8, value: []const u8) usize {
    if (out.len >= value.len) @memcpy(out[0..value.len], value);
    return value.len;
}

/// Clone a validated locator only when its immutable transport identity matches
/// the listener that is canonicalizing it.
pub fn canonicalizeFixedLocator(
    allocator: std.mem.Allocator,
    locator: model.PeerLocator,
    expected_transport: []const u8,
    expected_designator: []const u8,
) (error{InvalidAddress} || std.mem.Allocator.Error)!model.PeerLocator {
    model.validatePeerLocator(locator) catch return error.InvalidAddress;
    if (!std.mem.eql(u8, locator.transport, expected_transport) or
        !std.mem.eql(u8, locator.designator, expected_designator))
        return error.InvalidAddress;
    return model.clonePeerLocator(allocator, locator);
}

/// Shared context recovery for a resident whose optional `std.Io` lives in an
/// `io` field.
pub fn ResidentContext(comptime R: type) type {
    return struct {
        pub inline fn of(ctx: *anyopaque) *R {
            return @ptrCast(@alignCast(ctx));
        }

        pub fn io(ctx: *anyopaque) ?std.Io {
            return of(ctx).io;
        }
    };
}

/// Linear transport-symbol lookup for the small resident set.
pub fn resolve(comptime T: type, items: []const T, transport: []const u8) ?T {
    for (items) |item| {
        if (std.mem.eql(u8, item.transportName(), transport)) return item;
    }
    return null;
}

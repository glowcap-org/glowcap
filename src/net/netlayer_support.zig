//! Reusable stream storage and locator helpers beneath the netlayer contract.
//!
//! These mechanisms contain no transport policy: residents supply concrete
//! byte sources and contexts, while `netlayer.zig` owns dial/listen outcomes and
//! lifecycle vtables.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const engine = @import("engine");
const connection = @import("connection.zig");
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

    pub fn borrow(comptime T: type, value: *const T) OperationOptions {
        return .{ .data = value, .size = @sizeOf(T) };
    }

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

/// Linear transport-symbol lookup for the deliberately small resident set.
pub fn resolve(comptime T: type, items: []const T, transport: []const u8) ?T {
    for (items) |item| {
        if (std.mem.eql(u8, item.transportName(), transport)) return item;
    }
    return null;
}

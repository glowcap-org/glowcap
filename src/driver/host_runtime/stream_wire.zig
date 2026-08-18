//! Ownership transaction between a stream netlayer and Host wire admission.
//!
//! The transaction owns both wire buffers and the produced connection until
//! HostRuntime commits them into its wire table. A refusal before that commit
//! closes the connection and frees both buffers exactly once.

const std = @import("std");

const model = @import("model");
const engine = @import("engine");
const net = @import("net");

pub const Parts = struct {
    conn: net.Connection,
    read: []u8,
    write: []u8,
};

pub const Buffers = struct {
    allocator: std.mem.Allocator,
    read: []u8,
    write: []u8,
    owned: bool = true,

    pub fn init(allocator: std.mem.Allocator, bytes: usize) std.mem.Allocator.Error!Buffers {
        const read = try allocator.alloc(u8, bytes);
        errdefer allocator.free(read);
        return .{
            .allocator = allocator,
            .read = read,
            .write = try allocator.alloc(u8, bytes),
        };
    }

    pub fn view(self: *const Buffers) net.netlayer.Buffers {
        return .{ .read = self.read, .write = self.write };
    }

    pub fn attach(self: *Buffers, conn: net.Connection) Prepared {
        std.debug.assert(self.owned);
        const buffers = self.*;
        self.owned = false;
        return .{ .conn = conn, .buffers = buffers };
    }

    pub fn deinit(self: *Buffers) void {
        if (!self.owned) return;
        self.allocator.free(self.read);
        self.allocator.free(self.write);
        self.owned = false;
    }
};

pub const Prepared = struct {
    conn: net.Connection,
    buffers: Buffers,
    owned: bool = true,

    pub fn connection(self: *Prepared) *net.Connection {
        std.debug.assert(self.owned);
        return &self.conn;
    }

    pub fn take(self: *Prepared) Parts {
        std.debug.assert(self.owned);
        self.owned = false;
        self.buffers.owned = false;
        return .{ .conn = self.conn, .read = self.buffers.read, .write = self.buffers.write };
    }

    pub fn deinit(self: *Prepared) void {
        if (!self.owned) return;
        self.conn.deinit();
        self.buffers.deinit();
        self.owned = false;
    }
};

pub const DialOutcome = union(enum) {
    prepared: Prepared,
    failed: net.netlayer.DialFailure,
};

pub fn dial(
    allocator: std.mem.Allocator,
    buffer_bytes: usize,
    layer: net.netlayer.Netlayer,
    peer: *engine.Peer,
    locator: model.PeerLocator,
    options: net.netlayer.OperationOptions,
) std.mem.Allocator.Error!DialOutcome {
    var buffers = try Buffers.init(allocator, buffer_bytes);
    defer buffers.deinit();
    return switch (layer.dialOutcome(peer, locator, buffers.view(), options)) {
        .connected => |conn| .{ .prepared = buffers.attach(conn) },
        .failed => |failure| .{ .failed = failure },
    };
}

pub const AcceptOutcome = union(enum) {
    prepared: Prepared,
    failed: net.netlayer.AcceptFailure,
};

pub fn accept(
    allocator: std.mem.Allocator,
    buffer_bytes: usize,
    listener: net.netlayer.Listener,
    peer: *engine.Peer,
) std.mem.Allocator.Error!AcceptOutcome {
    var buffers = try Buffers.init(allocator, buffer_bytes);
    defer buffers.deinit();
    return switch (listener.acceptOutcome(peer, buffers.view())) {
        .accepted => |conn| .{ .prepared = buffers.attach(conn) },
        .failed => |failure| .{ .failed = failure },
    };
}

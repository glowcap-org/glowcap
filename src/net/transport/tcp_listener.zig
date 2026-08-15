//! Profile-aware listener shared by native TCP residents and C projections.
//!
//! The raw runtime owns the socket. This layer owns the one rule for what a
//! listener advertises: address-designated TCP publishes its bound address as
//! the designator; key-designated TCP publishes the durable peer key there and
//! the bound address as its direct-addresses hint.

const std = @import("std");

const crypto = @import("foundation").crypto;
const model = @import("model");
const netlayer = @import("../netlayer.zig");
const addressing = @import("tcp_addressing.zig");
const runtime = @import("tcp_runtime.zig");

const IpAddress = std.Io.net.IpAddress;

pub const designator_buf_len = 64;

pub const Listener = struct {
    socket: runtime.Listener,
    profile: model.transport.Metadata,
    identity: ?crypto.PeerKey,

    pub fn bind(
        comptime transport: model.transport.Known,
        io: std.Io,
        address: IpAddress,
        identity: ?crypto.PeerKey,
    ) (IpAddress.ListenError || error{WakeChannelFailed})!Listener {
        comptime {
            const metadata = transport.metadata();
            if (metadata.dial_shape != .host_port or metadata.address_source == .none)
                @compileError("a TCP listener requires a host-port TCP profile");
        }
        const profile = comptime transport.metadata();
        switch (profile.designator_scheme) {
            .address => std.debug.assert(identity == null),
            .key => std.debug.assert(identity != null),
        }
        return .{
            .socket = try runtime.Listener.bind(io, address),
            .profile = profile,
            .identity = identity,
        };
    }

    pub fn localAddress(self: *const Listener) IpAddress {
        return self.socket.localAddress();
    }

    pub fn readinessFd(self: *const Listener) std.Io.net.Socket.Handle {
        return self.socket.readinessFd();
    }

    pub fn waitAcceptable(self: *Listener, timeout_ms: i32) runtime.WaitError!bool {
        return self.socket.waitAcceptable(timeout_ms);
    }

    pub fn acceptRaw(
        self: *Listener,
        read_buf: []u8,
        write_buf: []u8,
        options: runtime.StreamOptions,
    ) runtime.AcceptError!runtime.Connection {
        return self.socket.accept(read_buf, write_buf, options);
    }

    pub fn acceptStream(self: *Listener, options: runtime.StreamOptions) runtime.AcceptError!std.Io.net.Stream {
        return self.socket.acceptStream(options);
    }

    pub fn localLocator(self: *const Listener, allocator: std.mem.Allocator) netlayer.ListenError!model.PeerLocator {
        var address_storage: [designator_buf_len]u8 = undefined;
        const address = std.fmt.bufPrint(&address_storage, "{f}", .{self.localAddress()}) catch unreachable;
        var identity_storage: [crypto.PeerKey.designator_len]u8 = undefined;
        const designator: []const u8 = if (self.identity) |identity| blk: {
            identity_storage = identity.toDesignator();
            break :blk &identity_storage;
        } else address;
        var hint_storage: [1]model.HintEntry = undefined;
        const hints = if (self.profile.address_source == .direct_addresses_hint)
            model.Hints.forDirectAddresses(address, &hint_storage)
        else
            model.Hints.emptyFalse();
        return model.clonePeerLocator(allocator, .{
            .transport = self.profile.symbol,
            .designator = designator,
            .hints = hints,
        });
    }

    /// Admit a replacement publication through this TCP profile's locator
    /// grammar. Address-designated TCP may publish a different reachable
    /// address (for example after NAT discovery); key-designated profiles keep
    /// the listener's durable identity and require a dialable address hint.
    pub fn validateLocator(self: *const Listener, locator: model.PeerLocator) netlayer.ListenError!void {
        model.validatePeerLocator(locator) catch return error.InvalidAddress;
        if (!std.mem.eql(u8, locator.transport, self.profile.symbol)) return error.InvalidAddress;
        if (self.identity) |identity| {
            const expected = identity.toDesignator();
            if (!std.mem.eql(u8, locator.designator, &expected)) return error.InvalidAddress;
        }
        _ = addressing.resolveProfile(
            self.profile,
            locator.designator,
            netlayer.directAddrHint(locator.hints) orelse "",
        ) catch return error.InvalidAddress;
    }

    pub fn canonicalizeLocator(
        self: *const Listener,
        allocator: std.mem.Allocator,
        locator: model.PeerLocator,
    ) netlayer.ListenError!model.PeerLocator {
        try self.validateLocator(locator);
        return model.clonePeerLocator(allocator, locator);
    }

    pub fn shutdown(self: *Listener) void {
        self.socket.shutdown();
    }

    pub fn deinit(self: *Listener) void {
        self.socket.deinit();
    }
};

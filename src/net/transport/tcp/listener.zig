//! Profile-aware listener shared by Zig TCP residents and C projections.
//!
//! The raw runtime owns the socket. `advertisement.zig` owns what a listener
//! publishes.

const std = @import("std");

const crypto = @import("foundation").crypto;
const model = @import("model");
const netlayer = @import("../../netlayer.zig");
const advertisement = @import("advertisement.zig");
const runtime = @import("runtime.zig");

const IpAddress = std.Io.net.IpAddress;

pub const designator_buf_len = advertisement.designator_buf_len;

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
        return advertisement.locator(allocator, self.profile, self.localAddress(), self.identity);
    }

    pub fn validateLocator(self: *const Listener, locator: model.PeerLocator) netlayer.ListenError!void {
        return advertisement.validate(self.profile, self.identity, locator);
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

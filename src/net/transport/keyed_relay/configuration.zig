//! Owned relay route and registration configuration.

const std = @import("std");
const route = @import("route.zig");

const foundation = @import("foundation");

const PeerKey = foundation.crypto.PeerKey;
const RelayUrl = route.RelayUrl;

pub fn validateUrls(relay_url: []const u8, register_url: []const u8) !void {
    const relay = try RelayUrl.parse(relay_url);
    if (register_url.len == 0) return;
    const register = try RelayUrl.parse(register_url);
    if (!sameAuthority(relay, register)) return error.InvalidRelayUrl;
}

pub const Registration = union(enum) {
    dial_only,
    registered: struct {
        url_text: []const u8,
        public_key: ?PeerKey,
    },
};

pub const Config = struct {
    allocator: std.mem.Allocator,
    storage: []u8,
    relay_url_text: []const u8,
    relay_url: RelayUrl,
    registration: Registration,

    pub fn dialOnly(allocator: std.mem.Allocator, url: []const u8) !Config {
        const storage = try allocator.dupe(u8, url);
        errdefer allocator.free(storage);
        return .{
            .allocator = allocator,
            .storage = storage,
            .relay_url_text = storage,
            .relay_url = try RelayUrl.parse(storage),
            .registration = .dial_only,
        };
    }

    pub fn registered(
        allocator: std.mem.Allocator,
        relay_url: []const u8,
        register_url: []const u8,
        public_key: ?PeerKey,
    ) !Config {
        const total = std.math.add(usize, relay_url.len, register_url.len) catch
            return error.OutOfMemory;
        const storage = try allocator.alloc(u8, total);
        errdefer allocator.free(storage);
        @memcpy(storage[0..relay_url.len], relay_url);
        @memcpy(storage[relay_url.len..], register_url);
        const owned_relay = storage[0..relay_url.len];
        const owned_register = storage[relay_url.len..];
        const parsed_register = try RelayUrl.parse(owned_register);
        const parsed_relay = try RelayUrl.parse(owned_relay);
        if (!sameAuthority(parsed_relay, parsed_register)) return error.InvalidRelayUrl;
        return .{
            .allocator = allocator,
            .storage = storage,
            .relay_url_text = owned_relay,
            .relay_url = parsed_relay,
            .registration = .{ .registered = .{
                .url_text = owned_register,
                .public_key = public_key,
            } },
        };
    }

    pub fn deinit(self: *Config) void {
        self.allocator.free(self.storage);
        self.* = undefined;
    }

    pub fn same(self: Config, other: Config) bool {
        if (!std.mem.eql(u8, self.relay_url_text, other.relay_url_text)) return false;
        return switch (self.registration) {
            .dial_only => other.registration == .dial_only,
            .registered => |left| switch (other.registration) {
                .registered => |right| std.mem.eql(u8, left.url_text, right.url_text) and
                    std.meta.eql(left.public_key, right.public_key),
                else => false,
            },
        };
    }
};

const State = struct {
    refs: std.atomic.Value(usize) = .init(1),
    value: Config,
};

/// Immutable deployment configuration shared by the keyed and Noise profile
/// views. Listeners copy the route text they outlive; channels never retain it.
pub const Lease = struct {
    state: *State,

    pub fn dialOnly(allocator: std.mem.Allocator, url: []const u8) !Lease {
        const state = try allocator.create(State);
        errdefer allocator.destroy(state);
        state.* = .{ .value = try Config.dialOnly(allocator, url) };
        return .{ .state = state };
    }

    pub fn registered(
        allocator: std.mem.Allocator,
        relay_url: []const u8,
        register_url: []const u8,
        public_key: ?PeerKey,
    ) !Lease {
        const state = try allocator.create(State);
        errdefer allocator.destroy(state);
        state.* = .{ .value = try Config.registered(
            allocator,
            relay_url,
            register_url,
            public_key,
        ) };
        return .{ .state = state };
    }

    pub fn retain(self: Lease) Lease {
        _ = self.state.refs.fetchAdd(1, .monotonic);
        return .{ .state = self.state };
    }

    pub fn release(self: *Lease) void {
        const state = self.state;
        self.* = undefined;
        if (state.refs.fetchSub(1, .acq_rel) != 1) return;
        const allocator = state.value.allocator;
        state.value.deinit();
        allocator.destroy(state);
    }

    pub fn view(self: Lease) *const Config {
        return &self.state.value;
    }

    pub fn same(self: Lease, other: Lease) bool {
        return self.state.value.same(other.state.value);
    }
};

fn sameAuthority(left: RelayUrl, right: RelayUrl) bool {
    return left.scheme == right.scheme and left.port == right.port and
        std.ascii.eqlIgnoreCase(left.host, right.host);
}

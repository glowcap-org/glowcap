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

/// Borrowed deployment routes. The alias names the same relay registry as
/// `relay_url`, reachable through a different ingress. Only that exact route
/// is redirected. Unrelated peer hints retain their own destination.
pub const Options = struct {
    relay_url: []const u8,
    register_url: ?[]const u8 = null,
    public_key: ?PeerKey = null,
    relay_alias_url: ?[]const u8 = null,

    pub fn validate(self: Options) !void {
        if (self.register_url) |registration| {
            if (registration.len == 0) return error.InvalidRelayUrl;
        }
        try validateUrls(self.relay_url, self.register_url orelse "");
        if (self.relay_alias_url) |alias| _ = try RelayUrl.parse(alias);
    }
};

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
    relay_alias_url: ?RelayUrl,
    registration: Registration,

    pub fn dialOnly(allocator: std.mem.Allocator, url: []const u8) !Config {
        return init(allocator, .{ .relay_url = url });
    }

    pub fn registered(
        allocator: std.mem.Allocator,
        relay_url: []const u8,
        register_url: []const u8,
        public_key: ?PeerKey,
    ) !Config {
        return init(allocator, .{
            .relay_url = relay_url,
            .register_url = register_url,
            .public_key = public_key,
        });
    }

    /// One startup allocation owns every parsed URL view. Dial selection
    /// borrows it without copying configuration per connection. The shared
    /// lease keeps these bytes until both profiles and their listeners retire.
    pub fn init(allocator: std.mem.Allocator, options: Options) !Config {
        try options.validate();
        const relay_url = options.relay_url;
        const register_url = options.register_url orelse "";
        const alias_url = options.relay_alias_url orelse "";
        const routes_len = std.math.add(usize, relay_url.len, register_url.len) catch
            return error.OutOfMemory;
        const total = std.math.add(usize, routes_len, alias_url.len) catch
            return error.OutOfMemory;
        const storage = try allocator.alloc(u8, total);
        errdefer allocator.free(storage);
        @memcpy(storage[0..relay_url.len], relay_url);
        @memcpy(storage[relay_url.len..routes_len], register_url);
        @memcpy(storage[routes_len..], alias_url);
        const owned_relay = storage[0..relay_url.len];
        const owned_register = storage[relay_url.len..routes_len];
        const parsed_relay = try RelayUrl.parse(owned_relay);
        return .{
            .allocator = allocator,
            .storage = storage,
            .relay_url_text = owned_relay,
            .relay_url = parsed_relay,
            .relay_alias_url = if (options.relay_alias_url != null) try RelayUrl.parse(storage[routes_len..]) else null,
            .registration = if (options.register_url != null) .{ .registered = .{
                .url_text = owned_register,
                .public_key = options.public_key,
            } } else .dial_only,
        };
    }

    pub fn selectDialRoute(self: Config, hint: ?RelayUrl) RelayUrl {
        const target = hint orelse return self.relay_url;
        if (self.relay_alias_url) |alias| {
            if (sameRoute(target, alias)) return self.relay_url;
        }
        return target;
    }

    pub fn deinit(self: *Config) void {
        self.allocator.free(self.storage);
        self.* = undefined;
    }

    pub fn same(self: Config, other: Config) bool {
        if (!std.mem.eql(u8, self.relay_url_text, other.relay_url_text)) return false;
        if (self.relay_alias_url) |alias| {
            if (!sameRoute(alias, other.relay_alias_url orelse return false)) return false;
        } else if (other.relay_alias_url != null) return false;
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
/// views. Listeners copy the route text they outlive. Channels never retain it.
pub const Lease = struct {
    state: *State,

    pub fn init(allocator: std.mem.Allocator, options: Options) !Lease {
        const state = try allocator.create(State);
        errdefer allocator.destroy(state);
        state.* = .{ .value = try Config.init(allocator, options) };
        return .{ .state = state };
    }

    pub fn dialOnly(allocator: std.mem.Allocator, url: []const u8) !Lease {
        return init(allocator, .{ .relay_url = url });
    }

    pub fn registered(
        allocator: std.mem.Allocator,
        relay_url: []const u8,
        register_url: []const u8,
        public_key: ?PeerKey,
    ) !Lease {
        return init(allocator, .{
            .relay_url = relay_url,
            .register_url = register_url,
            .public_key = public_key,
        });
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

fn sameRoute(left: RelayUrl, right: RelayUrl) bool {
    const left_path = if (left.path.len == 0) "/" else left.path;
    const right_path = if (right.path.len == 0) "/" else right.path;
    return sameAuthority(left, right) and
        std.mem.eql(u8, left_path, right_path) and
        std.mem.eql(u8, left.query orelse "", right.query orelse "");
}

//! Shared constants and stdout emit for `pancake app rooms-peer`.
const std = @import("std");
const pancake = @import("pancake");
const iroh = @import("iroh");

pub const Io = std.Io;
pub const Allocator = std.mem.Allocator;
pub const model = pancake.ocapn.model;
pub const actors = pancake.actors;
pub const driver = pancake.driver;
pub const net = pancake.net;

pub const Host = driver.core.Host;
pub const HostSession = driver.core.HostSession;
pub const RoomsBackend = iroh.CompletionBackend(net.KeyedRelayBackend);
pub const RoomsDialResolver = iroh.CompositeDialResolver(net.KeyedRelayBackend, net.relay.DialResolver);
pub const RoomsLoop = net.completion.Loop(RoomsBackend, RoomsDialResolver);
pub const RoomsBridge = driver.Bridge(RoomsLoop);

pub const frame_cap: usize = 1 << 16;
/// One room leg plus direct iroh/keyed-relay legs, all admitted by one Loop.
pub const max_sessions: usize = 32;
/// One slot belongs exclusively to the room-control dial. Direct accepts and
/// handoff dials cannot consume it, so room recovery remains possible at the
/// ordinary-session ceiling.
pub const reserved_room_sessions: usize = 1;
/// One read per admitted session plus iroh's readiness and stopper channels.
pub const read_buffers: u16 = max_sessions + 2;
pub const completion_queue_entries: u16 = 256;
pub const timer_ms: u64 = 150;
pub const redial_cooldown_wakes: u32 = 13;
/// Join-window deadline in maintain wakes: about 15 s at `timer_ms` = 150.
/// A healthy join is roughly five round-trips (fetch directory, enter/open
/// fallback, subscribe), so this is order-of-magnitude headroom over it, and
/// two full abandon-and-redial recovery cycles still fit inside the
/// supervisor's 45 s start window.
pub const join_deadline_wakes: u32 = 100;
pub const dial_timeout_ms: u64 = 4000;
pub const file_cap = Io.Limit.limited(1 << 24);
pub const default_locator = "http://pancake-rooms:8000/locator";
pub const reply_placeholder = "YOUR REPLY HERE";
pub const replied_cap: usize = 1200;

/// Derive a dial-only keyed-relay rendezvous URL from an `http://host:port/…`
/// rooms locator bootstrap (`ws://host:port/relay`). Returns null for
/// `https://` (native keyed-relay speaks cleartext `ws://` only), non-http
/// locators, or a host:port the relay URL grammar refuses after DNS. `localhost`
/// maps to `127.0.0.1` because `RelayUrl` admits IP literals only. A DNS name
/// such as `pancake-rooms` is resolved once here so the native tier still only
/// dials an IP. The caller owns the returned string for the resident's life
/// (`RelayUrl` borrows it).
pub fn deriveRendezvousUrl(io: Io, gpa: Allocator, locator: []const u8) Allocator.Error!?[]u8 {
    const scheme = "http://";
    if (!std.mem.startsWith(u8, locator, scheme)) return null;
    const rest = locator[scheme.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const hostport = rest[0..slash];
    if (hostport.len == 0) return null;
    const colon = std.mem.lastIndexOfScalar(u8, hostport, ':') orelse return null;
    var host = hostport[0..colon];
    const port = hostport[colon + 1 ..];
    if (host.len == 0 or port.len == 0) return null;
    if (std.mem.eql(u8, host, "localhost")) host = "127.0.0.1";
    const url = try std.fmt.allocPrint(gpa, "ws://{s}:{s}/relay", .{ host, port });
    defer gpa.free(url);
    return admitRelayUrl(io, gpa, url);
}

/// Resolve rendezvous URL: `PANCAKE_RENDEZVOUS` when set, else derive from an
/// `http://…/locator` bootstrap. Owned string or null. An explicit env value
/// that cannot be admitted as a `RelayUrl` (after DNS) is `error.InvalidRendezvousUrl`.
pub fn resolveRendezvousUrl(io: Io, gpa: Allocator, environ_rendezvous: ?[]const u8, locator: []const u8) (Allocator.Error || error{InvalidRendezvousUrl})!?[]u8 {
    if (environ_rendezvous) |url| {
        return (try admitRelayUrl(io, gpa, url)) orelse error.InvalidRendezvousUrl;
    }
    return deriveRendezvousUrl(io, gpa, locator);
}

/// Admit a `ws://` relay URL. `RelayUrl.parse` takes IP literals only; a DNS
/// host is resolved to an address so the native keyed-relay dial still sees an
/// IP. The caller owns the returned string.
pub fn admitRelayUrl(io: Io, gpa: Allocator, url: []const u8) Allocator.Error!?[]u8 {
    if (net.relay.RelayUrl.parse(url)) |_| return try gpa.dupe(u8, url) else |_| {}
    const rewritten = (try resolveRelayUrlHost(io, gpa, url)) orelse return null;
    errdefer gpa.free(rewritten);
    _ = net.relay.RelayUrl.parse(rewritten) catch {
        gpa.free(rewritten);
        return null;
    };
    return rewritten;
}

fn resolveRelayUrlHost(io: Io, gpa: Allocator, url: []const u8) Allocator.Error!?[]u8 {
    const scheme = "ws://";
    if (!std.mem.startsWith(u8, url, scheme)) return null;
    const rest = url[scheme.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const authority = rest[0..slash];
    const path = rest[slash..];
    const split = model.uri.splitHostPort(authority) catch return null;
    const ip = (try lookupRelayHost(io, gpa, split.host, split.port)) orelse return null;
    defer gpa.free(ip);
    if (std.mem.indexOfScalar(u8, ip, ':') != null) {
        return try std.fmt.allocPrint(gpa, "ws://[{s}]:{d}{s}", .{ ip, split.port, path });
    }
    return try std.fmt.allocPrint(gpa, "ws://{s}:{d}{s}", .{ ip, split.port, path });
}

fn lookupRelayHost(io: Io, gpa: Allocator, host: []const u8, port: u16) Allocator.Error!?[]u8 {
    if (net.tcp.parseHostPort(host, port)) |_| return try gpa.dupe(u8, host) else |_| {}
    const name = Io.net.HostName.init(host) catch return null;
    var results: [16]Io.net.HostName.LookupResult = undefined;
    var queue = Io.Queue(Io.net.HostName.LookupResult).init(&results);
    name.lookup(io, &queue, .{ .port = port, .family = .ip4 }) catch return null;
    while (queue.getOneUncancelable(io)) |result| {
        switch (result) {
            .address => |addr| switch (addr) {
                .ip4 => |ip4| {
                    const b = ip4.bytes;
                    return try std.fmt.allocPrint(gpa, "{d}.{d}.{d}.{d}", .{ b[0], b[1], b[2], b[3] });
                },
                .ip6 => continue,
            },
            .canonical_name => continue,
        }
    } else |_| {}
    return null;
}

/// The longest nickname this peer will mint an inbox for, matching `MAX_NICK` in
/// `apps/rooms/lib/limits.ts`. The name arrives from the directory on a peer's
/// say-so, and it ends up inside a bootstrap swissnum this process keeps for
/// good, so the length is not theirs to choose without a ceiling.
pub const max_nick: usize = 32;

/// How many direct-message inboxes this peer will hold, matching
/// `MAX_DM_INBOXES` in `apps/rooms/lib/limits.ts`.
pub const max_dm_inboxes: usize = 256;

/// Resolve a CapTP dial target. An `http(s)://…/locator` bootstrap is fetched
/// and its first line taken as the `ocapn://` URI (the rooms web UI serves it);
/// an `ocapn://` URI or bare designator passes through. Returns an owned string.
pub fn resolveLocator(io: Io, gpa: Allocator, locator: []const u8) ![]u8 {
    const is_http = std.mem.startsWith(u8, locator, "http://") or std.mem.startsWith(u8, locator, "https://");
    if (!is_http) return gpa.dupe(u8, locator);

    var client = std.http.Client{ .allocator = gpa, .io = io };
    defer client.deinit();
    var body = std.Io.Writer.Allocating.init(gpa);
    defer body.deinit();
    const result = client.fetch(.{ .location = .{ .url = locator }, .response_writer = &body.writer }) catch {
        return error.BootstrapFailed;
    };
    if (result.status != .ok) return error.BootstrapFailed;
    const text = body.writer.buffered();
    var lines = std.mem.splitScalar(u8, text, '\n');
    const first = std.mem.trim(u8, lines.next() orelse "", " \t\r\n");
    if (first.len == 0) return error.BootstrapEmpty;
    return gpa.dupe(u8, first);
}

/// Agent-facing JSON and usage text go to stdout; diagnostics use `log` (stderr).
pub fn emitStdout(io: Io, bytes: []const u8) void {
    Io.File.stdout().writeStreamingAll(io, bytes) catch {};
}

pub fn emitStdoutFmt(io: Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [16384]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    emitStdout(io, msg);
}

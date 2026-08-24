//! The rooms wire profile: one authority for the profile spellings, and
//! rooms-peer minting kept to the directories that own it.

const std = @import("std");
const util = @import("../util.zig");

const appendViolation = util.appendViolation;
const expectFileContains = util.expectFileContains;

/// One rooms peer's spelling of the fleet's wire profile.
///
/// A room is a closed fleet of pancake peers, so it runs on pancake's own
/// profile rather than the interop floor. That profile is one fact, and five
/// languages each have to spell it: a peer that names only half of it, or
/// names last week's half, opens a session every other member refuses. The
/// failure is a live `CaptpVersionMismatch` in a step that has to bring five
/// runtimes up before it can report anything, so the spelling is checked here
/// instead.
const RoomsProfileSpelling = struct {
    path: []const u8,
    /// How this language writes the Cap'n Proto codec and the Syrup floor.
    capnp: []const u8,
    syrup: []const u8,
    /// How it writes the `pancake-next` version and the 1.0 floor.
    next: []const u8,
    v1_0: []const u8,
};

const rooms_profile_authority = "apps/rooms/lib/protocol.ts";

const rooms_profile_spellings = [_]RoomsProfileSpelling{
    .{
        .path = "apps/rooms/lib/profile.zig",
        .capnp = ".capnp",
        .syrup = ".syrup",
        .next = ".next",
        .v1_0 = ".v1_0",
    },
    .{
        .path = "apps/rooms/clients/python/room_client.py",
        .capnp = "\"capnp\"",
        .syrup = "\"syrup\"",
        .next = "\"next\"",
        .v1_0 = "\"v1_0\"",
    },
    .{
        .path = "apps/rooms/clients/racket/room-client.rkt",
        .capnp = "'capnp",
        .syrup = "'syrup",
        .next = "'next",
        .v1_0 = "'v1_0",
    },
    .{
        .path = "apps/rooms/clients/rust/room.rs",
        .capnp = "Codec::Capnp",
        .syrup = "Codec::Syrup",
        .next = "CaptpVersion::Next",
        .v1_0 = "CaptpVersion::V1_0",
    },
};

/// Every rooms peer offers the same CapTP version and codec.
///
/// `apps/rooms/lib/protocol.ts` decides; the four sibling spellings follow.
/// The check is parity rather than a pinned constant, so moving the fleet to a
/// different profile stays a one-line edit in the authority — it just cannot
/// be a one-line edit, because this fails until the others move with it.
pub fn checkRoomsWireProfile(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const authority = root.readFileAlloc(io, rooms_profile_authority, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read the rooms wire-profile authority with {s}", .{ rooms_profile_authority, @errorName(err) });
        return;
    };
    defer gpa.free(authority);

    const wants_capnp = std.mem.indexOf(u8, authority, "CODEC = \"capnp\"") != null;
    const wants_next = std.mem.indexOf(u8, authority, "CAPTP_VERSION = \"next\"") != null;
    if (!wants_capnp and std.mem.indexOf(u8, authority, "CODEC = \"syrup\"") == null) {
        try appendViolation(gpa, violations, "{s}: names no `CODEC` the sibling peers can follow; the fleet's codec is decided here", .{rooms_profile_authority});
        return;
    }
    if (!wants_next and std.mem.indexOf(u8, authority, "CAPTP_VERSION = \"v1_0\"") == null) {
        try appendViolation(gpa, violations, "{s}: names no `CAPTP_VERSION` the sibling peers can follow; the fleet's CapTP version is decided here", .{rooms_profile_authority});
        return;
    }

    for (rooms_profile_spellings) |peer| {
        const source = root.readFileAlloc(io, peer.path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for the rooms wire-profile check with {s}", .{ peer.path, @errorName(err) });
            continue;
        };
        defer gpa.free(source);
        // Raw source, not comment-stripped: these are language literals
        // (`Codec::Syrup`, `'syrup`, `.v1_0`), and prose that describes the
        // profile has no reason to spell one. Four languages' comment syntaxes
        // would need four strippers to buy nothing.
        const code = source;

        const want_codec = if (wants_capnp) peer.capnp else peer.syrup;
        const wrong_codec = if (wants_capnp) peer.syrup else peer.capnp;
        if (std.mem.indexOf(u8, code, want_codec) == null) {
            try appendViolation(gpa, violations, "{s}: does not name `{s}`, the codec {s} decides for every rooms peer; a peer on the other codec cannot open a session with the fleet", .{ peer.path, want_codec, rooms_profile_authority });
        }
        if (std.mem.indexOf(u8, code, wrong_codec) != null) {
            try appendViolation(gpa, violations, "{s}: still names `{s}` after {s} moved the fleet's codec; the two spellings have drifted apart", .{ peer.path, wrong_codec, rooms_profile_authority });
        }

        const want_version = if (wants_next) peer.next else peer.v1_0;
        const wrong_version = if (wants_next) peer.v1_0 else peer.next;
        if (std.mem.indexOf(u8, code, want_version) == null) {
            try appendViolation(gpa, violations, "{s}: does not name `{s}`, the CapTP version {s} decides for every rooms peer; the codec alone is half a profile and the handshake refuses on the other half", .{ peer.path, want_version, rooms_profile_authority });
        }
        if (std.mem.indexOf(u8, code, wrong_version) != null) {
            try appendViolation(gpa, violations, "{s}: still names `{s}` after {s} moved the fleet's CapTP version; the two spellings have drifted apart", .{ peer.path, wrong_version, rooms_profile_authority });
        }
    }
}

/// The directories under `apps/rooms` whose TypeScript mints peers.
const rooms_peer_dirs = [_][]const u8{
    "apps/rooms/demos",
    "apps/rooms/test",
    "apps/rooms/server",
    "apps/rooms/web",
    "apps/rooms/web/ui",
    "apps/rooms/lib",
};

/// Every rooms peer is minted through `lib/locator.ts`.
///
/// A peer comes into being by dialing or by being dialed, and both halves have
/// to wear the fleet's profile. `new Host()` and `listen(host, port)` each hand
/// back the v1.0 Syrup floor instead, and the session that peer opens is then
/// refused as a malformed frame — a message that points at the codec rather
/// than at the line that minted the host. That mistake was made four times in
/// one afternoon across demos, tests, and the server, which is what a
/// convention rather than a check buys. `roomsHost` and `roomsListen` are the
/// two front doors; a peer that genuinely wants the floor (proving pancake
/// meets an interop partner there) says so on the line with
/// `rooms-profile-exempt:` and a reason.
pub fn checkRoomsPeerMinting(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const authority = "apps/rooms/lib/locator.ts";
    for (rooms_peer_dirs) |dir_path| {
        var dir = root.openDir(io, dir_path, .{ .iterate = true }) catch |err| {
            try appendViolation(gpa, violations, "{s}: cannot be opened for the rooms locator-profile check ({s})", .{ dir_path, @errorName(err) });
            continue;
        };
        defer dir.close(io);
        var walker = dir.iterate();
        while (walker.next(io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".ts") and !std.mem.endsWith(u8, entry.name, ".tsx")) continue;
            const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir_path, entry.name });
            defer gpa.free(path);
            // The authority is where both front doors are built, so it is the
            // one file allowed to reach the raw constructors.
            if (std.mem.eql(u8, path, authority)) continue;
            const source = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: cannot be read for the rooms locator-profile check ({s})", .{ path, @errorName(err) });
                continue;
            };
            defer gpa.free(source);

            var line_no: usize = 0;
            var lines = std.mem.splitScalar(u8, source, '\n');
            while (lines.next()) |line| {
                line_no += 1;
                if (std.mem.indexOf(u8, line, "rooms-profile-exempt:") != null) continue;
                // `listenIroh(` / `listenKeyedTcp(` / `roomsListen(` do not
                // contain this token, so the match is the bare function alone.
                if (std.mem.indexOf(u8, line, "new Host(") != null) {
                    try appendViolation(gpa, violations, "{s}:{d}: mints a peer with `new Host(` — a default Host speaks the v1.0 Syrup floor and the room refuses its frames; mint it through `roomsHost` in {s}", .{ path, line_no, authority });
                }
                // A qualified `listen` belongs to something else — `Deno.listen`
                // opens a socket, and a socket has no CapTP profile to get
                // wrong. Only the bare call mints a pancake peer.
                const bare_listen = if (std.mem.indexOf(u8, line, "listen(")) |at|
                    at == 0 or line[at - 1] != '.'
                else
                    false;
                if (bare_listen and std.mem.indexOf(u8, line, "function listen(") == null) {
                    try appendViolation(gpa, violations, "{s}:{d}: accepts peers with the bare `listen(` — its default host speaks the v1.0 Syrup floor; accept through `roomsListen` in {s}", .{ path, line_no, authority });
                }
            }
        }
    }
}

/// Join input may absorb only the parser's typed grammar refusal.
///
/// A broad catch here reports archive, Wasm, and runtime failures as malformed
/// text, then asks the reader to retry an address that was valid. Both parser
/// fronts share one translation so widening either catch cannot create a
/// second error policy.
pub fn checkRoomsBootstrapParseFailures(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const path = "apps/rooms/web/ui/net/bootstrap.ts";
    const source = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: cannot be read for the bootstrap parse-failure check ({s})", .{ path, @errorName(err) });
        return;
    };
    defer gpa.free(source);

    const translation = "if (error instanceof PancakeError && error.code === INVALID_ARGUMENT) return null;\n\tthrow error;";
    if (std.mem.count(u8, source, translation) != 1) {
        try appendViolation(gpa, violations, "{s}: parser failures must have one typed INVALID_ARGUMENT-to-null translation that rethrows every other failure", .{path});
    }
    const use = "return invalidArgumentOrThrow(err);";
    if (std.mem.count(u8, source, use) != 2) {
        try appendViolation(gpa, violations, "{s}: directoryId and linkDirectory must both use the shared typed parse-failure translation", .{path});
    }
}

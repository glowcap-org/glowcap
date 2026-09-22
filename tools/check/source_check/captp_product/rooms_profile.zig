//! The Rooms wire profile: one core preference, binding projections, and peer
//! minting kept to the directories that own it.

const std = @import("std");
const util = @import("../util.zig");

const appendViolation = util.appendViolation;
const expectFileContains = util.expectFileContains;

/// Every rooms peer offers the same CapTP version and codec.
///
/// `model.Preference.native` decides the pair. The C ABI reflects it into
/// generated constants, every binding exposes a named profile, and Rooms code
/// selects that profile without naming either wire axis.
pub fn checkRoomsWireProfile(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    try expectFileContains(io, gpa, root, violations, "src/ocapn/model/negotiated.zig", &.{
        "pub const native: Preference",
        ".captp_version = .next",
        ".codec = .capnp",
    });
    try expectFileContains(io, gpa, root, violations, "src/c_abi/shared/profile.zig", &.{
        "GLOWCAP_INTEROP_CODEC: u32 = codecToC(model.Preference.baseline.codec)",
        "GLOWCAP_INTEROP_CAPTP_VERSION: u32 = captpVersionToC(model.Preference.baseline.captp_version)",
        "GLOWCAP_NATIVE_CODEC: u32 = codecToC(model.Preference.native.codec)",
        "GLOWCAP_NATIVE_CAPTP_VERSION: u32 = captpVersionToC(model.Preference.native.captp_version)",
    });
    try expectFileContains(io, gpa, root, violations, "apps/rooms/lib/profile.ts", &.{
        "? { profile: \"native\", features: \"full\" }",
        ": { profile: \"interop\", features: \"baseline\" }",
    });
    try expectFileContains(io, gpa, root, violations, "apps/rooms/lib/locator.ts", &.{
        "return new Host(seed, roomsHostOptions(posture));",
    });
    // The wire vocabulary itself is not held here by substring: the clients
    // read it from the tables `zig build gen-rooms-protocol` emits, and
    // `apps/rooms/test/protocol_gen_test.ts` holds those to `protocol.ts`.
    const profile_uses = [_]struct { path: []const u8, needle: []const u8 }{
        .{ .path = "apps/rooms/clients/python/room_client.py", .needle = "Host(profile=\"native\")" },
        .{ .path = "apps/rooms/clients/racket/room-client.rkt", .needle = "#:profile 'native" },
        .{ .path = "apps/rooms/clients/rust/room.rs", .needle = "HostOptions::with_profile(glowcap::HostProfile::Native)" },
        .{ .path = "apps/rooms/clients/zig/client.zig", .needle = "model.Preference.native" },
    };
    for (profile_uses) |use| try expectFileContains(io, gpa, root, violations, use.path, &.{use.needle});
}

/// The directories under `apps/rooms` whose TypeScript mints peers.
const rooms_peer_dirs = [_][]const u8{
    "apps/rooms/demos",
    "apps/rooms/test",
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
/// one afternoon across demos, tests, and the server. That is the price of
/// a convention rather than a check. `roomsHost` and `roomsListen` are the
/// two front doors; a peer that genuinely wants the floor (proving glowcap
/// meets an interop partner there) says so on the line with
/// `rooms-profile-exempt:` and a reason.
pub fn checkRoomsPeerMinting(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const authority = "apps/rooms/lib/locator.ts";
    const profile_authority = "apps/rooms/lib/profile.ts";
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
                // wrong. Only the bare call mints a glowcap peer.
                const bare_listen = if (std.mem.indexOf(u8, line, "listen(")) |at|
                    at == 0 or line[at - 1] != '.'
                else
                    false;
                if (bare_listen and std.mem.indexOf(u8, line, "function listen(") == null) {
                    try appendViolation(gpa, violations, "{s}:{d}: accepts peers with the bare `listen(` — its default host speaks the v1.0 Syrup floor; accept through `roomsListen` in {s}", .{ path, line_no, authority });
                }
                if (std.mem.indexOf(u8, line, "CAPTP_VERSION") != null or
                    std.mem.indexOf(u8, line, "export const CODEC") != null or
                    std.mem.indexOf(u8, line, "codec: CODEC") != null or
                    std.mem.indexOf(u8, line, "captpVersion: CAPTP_VERSION") != null or
                    (!std.mem.eql(u8, path, profile_authority) and
                        (std.mem.indexOf(u8, line, "codec: \"capnp\"") != null or
                            std.mem.indexOf(u8, line, "captpVersion: \"next\"") != null)))
                {
                    try appendViolation(gpa, violations, "{s}:{d}: restates a loose codec or CapTP version in Rooms application code; select the runtime's coherent profile through `roomsHostOptions`", .{ path, line_no });
                }
            }
        }
    }
}

/// Rust owns input refusal classification; presentation must not reinterpret
/// a Wasm/runtime failure as malformed text or initialize a TS Host to parse.
pub fn checkRoomsInputParseFailures(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const owner_path = "apps/rooms/web/ui/application.ts";
    const owner = root.readFileAlloc(io, owner_path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: cannot be read for the input parse-failure check ({s})", .{ owner_path, @errorName(err) });
        return;
    };
    defer gpa.free(owner);
    for ([_][]const u8{ ".directoryAuthority(", ".inspectDirectory(", ".inspectCapability(" }) |call| {
        if (std.mem.count(u8, owner, call) != 1) {
            try appendViolation(gpa, violations, "{s}: route views must call the shared Rust {s} export exactly once", .{ owner_path, call });
        }
    }
    for ([_][]const u8{ "catch (", "catch{", "catch {", ".catch(" }) |handler| {
        if (std.mem.indexOf(u8, owner, handler) != null) {
            try appendViolation(gpa, violations, "{s}: the application projection must propagate Rust/Wasm failures without a catch translation", .{owner_path});
            break;
        }
    }
    const consumers = [_][]const u8{
        "apps/rooms/web/ui/page_bootstrap.ts",
        "apps/rooms/web/ui/joining.ts",
        "apps/rooms/web/ui/session/attached_session.ts",
        "apps/rooms/web/ui/session/attached_command_powers.ts",
    };
    for (consumers) |path| {
        const source = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: cannot be read for the input parse-failure check ({s})", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(source);
        if (std.mem.indexOf(u8, source, "lib/locator.ts") != null or
            std.mem.indexOf(u8, source, "lib/routes.ts") != null)
        {
            try appendViolation(gpa, violations, "{s}: presentation route inspection must use the Rust application boundary without TS locator/runtime ownership", .{path});
        }
    }
}

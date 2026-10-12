//! CapTP vocabulary on the product surfaces: the transport table in every
//! doc that carries one, and the ADR-0079 product nouns.

const std = @import("std");
const util = @import("../util.zig");

const appendViolation = util.appendViolation;
const expectFileContains = util.expectFileContains;
const bans_transport = @import("../bans/transport.zig");

/// The transport-agnosticism phrase bans live in `source_check/bans.zig`
/// (`transport_vocabulary`). This keeps only the resident-count heuristic,
/// whose violation message names the fix (`keyed-tcp` in the enumeration)
/// rather than the matched needle. It shares the scanned path list with
/// those rows.
pub fn checkTransportVocabulary(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    for (bans_transport.transport_vocabulary_paths) |path| {
        const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for transport-vocabulary check with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);

        // Resident enumerations that still say "three" without keyed-tcp.
        if (std.mem.indexOf(u8, contents, "three residents") != null or
            std.mem.indexOf(u8, contents, "Three residents") != null or
            std.mem.indexOf(u8, contents, "All three residents") != null or
            std.mem.indexOf(u8, contents, "three real residents") != null or
            std.mem.indexOf(u8, contents, "Three ship today") != null or
            std.mem.indexOf(u8, contents, "walks all three") != null)
        {
            if (std.mem.indexOf(u8, contents, "keyed-tcp") == null) {
                try appendViolation(
                    gpa,
                    violations,
                    "{s}: netlayer resident count omits `keyed-tcp` — list `tcp`, `keyed-tcp`, `inproc`, and iroh",
                    .{path},
                );
            }
        }
    }
}

/// CapTP vocabulary (ADR-0079): public symbols and binding export maps the
/// compiler cannot compare across language boundaries.
pub fn checkCaptpVocabulary(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const driver_header = root.readFileAlloc(io, "include/glowcap_host.h", gpa, .limited(4 << 20)) catch |err| {
        try appendViolation(gpa, violations, "include/glowcap_host.h: cannot be read for the vocabulary check ({s})", .{@errorName(err)});
        return;
    };
    defer gpa.free(driver_header);
    for ([_][]const u8{ "GlowcapHostSession", "glowcap_host_session_" }) |needle| {
        if (std.mem.indexOf(u8, driver_header, needle) == null) {
            try appendViolation(gpa, violations, "include/glowcap_host.h: missing `{s}` — the byte-fed CapTP session family (ADR-0079)", .{needle});
        }
    }

    const positive = [_]struct { path: []const u8, needle: []const u8, what: []const u8 }{
        .{ .path = "src/driver/core/host.zig", .needle = "pub const HostSession", .what = "the byte-fed CapTP session Zig type (aligns with GlowcapHostSession)" },
        .{ .path = "src/ocapn/engine/node.zig", .needle = "pub const PeerHandle", .what = "the engine's Node-scoped registered-session handle" },
        .{ .path = "src/ocapn/engine/node.zig", .needle = "pub const registerPeer", .what = "the Node registers Peers" },
    };
    for (positive) |p| {
        const contents = root.readFileAlloc(io, p.path, gpa, .limited(4 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for CapTP vocabulary positive check with {s}", .{ p.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, p.needle) == null) {
            try appendViolation(gpa, violations, "{s}: missing `{s}` — {s} (ADR-0079)", .{ p.path, p.needle, p.what });
        }
    }
}

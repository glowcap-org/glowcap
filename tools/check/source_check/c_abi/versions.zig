//! The ABI version lockstep: one triple stated in `build.zig`, the generated
//! headers, and every binding mirror, plus the prerelease rule that an
//! unsupported provider contract stays at version 1.

const std = @import("std");
const util = @import("../util.zig");

const appendViolation = util.appendViolation;
const expectFileContains = util.expectFileContains;
const fileContains = util.fileContains;
const firstIntIn = util.firstIntIn;
const parseJsonFile = util.parseJsonFile;
const getField = util.getField;
const jsonStringEquals = util.jsonStringEquals;

/// The ABI version triple is stated four times: `abi_version` in `build.zig`,
/// `.version` in `build.zig.zon`, `GLOWCAP_VERSION_*` in `src/c_abi/ocapn/mod.zig`,
/// and the generated `#define GLOWCAP_VERSION_*` macros in `include/glowcap_ocapn.h`.
/// This parses all four and holds them in lockstep, so bumping one surface
/// without the others fails the gate instead of shipping a package whose zon
/// version disagrees with the soname it installs.
pub fn checkAbiVersionLockstep(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const Triple = struct { major: i64, minor: i64, patch: i64 };
    const sources = [_]struct {
        path: []const u8,
        keys: [3][]const u8,
        // The triple's declaration site, when the keys alone are ambiguous in
        // the file (build.zig has many `.major =` struct literals).
        anchor: ?[]const u8 = null,
    }{
        .{ .path = "build.zig", .keys = .{ ".major =", ".minor =", ".patch =" }, .anchor = "const abi_version" },
        .{ .path = "src/c_abi/ocapn/mod.zig", .keys = .{
            "GLOWCAP_VERSION_MAJOR: u32 =",
            "GLOWCAP_VERSION_MINOR: u32 =",
            "GLOWCAP_VERSION_PATCH: u32 =",
        } },
        .{ .path = "include/glowcap_ocapn.h", .keys = .{
            "#define GLOWCAP_VERSION_MAJOR",
            "#define GLOWCAP_VERSION_MINOR",
            "#define GLOWCAP_VERSION_PATCH",
        } },
    };

    var triples: [sources.len]?Triple = @splat(null);
    for (sources, 0..) |source, i| {
        const contents = root.readFileAlloc(io, source.path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for ABI version lockstep check with {s}", .{ source.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        const search_from = if (source.anchor) |anchor|
            (if (std.mem.indexOf(u8, contents, anchor)) |at| contents[at..] else contents)
        else
            contents;
        var parts: [3]i64 = undefined;
        var ok = true;
        for (source.keys, 0..) |key, k| {
            const at = std.mem.indexOf(u8, search_from, key) orelse {
                try appendViolation(gpa, violations, "{s}: ABI version component '{s}' not found", .{ source.path, key });
                ok = false;
                continue;
            };
            parts[k] = firstIntIn(search_from[at + key.len ..]) orelse {
                try appendViolation(gpa, violations, "{s}: ABI version component '{s}' has no integer value", .{ source.path, key });
                ok = false;
                continue;
            };
        }
        if (ok) triples[i] = .{ .major = parts[0], .minor = parts[1], .patch = parts[2] };
    }

    var zon_triple: ?Triple = null;
    const zon = root.readFileAlloc(io, "build.zig.zon", gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "build.zig.zon: failed to read for ABI version lockstep check with {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(zon);
    if (std.mem.indexOf(u8, zon, ".version = \"")) |at| {
        const rest = zon[at + ".version = \"".len ..];
        const end = std.mem.indexOfScalar(u8, rest, '"') orelse rest.len;
        var it = std.mem.splitScalar(u8, rest[0..end], '.');
        const major = firstIntIn(it.next() orelse "");
        const minor = firstIntIn(it.next() orelse "");
        const patch = firstIntIn(it.next() orelse "");
        if (major != null and minor != null and patch != null) {
            zon_triple = .{ .major = major.?, .minor = minor.?, .patch = patch.? };
        } else {
            try appendViolation(gpa, violations, "build.zig.zon: .version \"{s}\" is not a semantic version triple", .{rest[0..end]});
        }
    } else {
        try appendViolation(gpa, violations, "build.zig.zon: no .version field found for ABI version lockstep check", .{});
    }

    const anchor = triples[0] orelse return;
    for (sources[1..], triples[1..]) |source, maybe_triple| {
        const triple = maybe_triple orelse continue;
        if (!std.meta.eql(triple, anchor)) {
            try appendViolation(gpa, violations, "{s}: ABI version {d}.{d}.{d} drifts from build.zig abi_version {d}.{d}.{d}", .{
                source.path, triple.major, triple.minor, triple.patch, anchor.major, anchor.minor, anchor.patch,
            });
        }
    }
    if (zon_triple) |triple| {
        if (!std.meta.eql(triple, anchor)) {
            try appendViolation(gpa, violations, "build.zig.zon: .version {d}.{d}.{d} drifts from build.zig abi_version {d}.{d}.{d}", .{
                triple.major, triple.minor, triple.patch, anchor.major, anchor.minor, anchor.patch,
            });
        }
    }
}

/// Provider tables reserve version negotiation without pretending unsupported
/// prerelease layouts remain contracts. Every replacement stays at version 1;
/// this check is relaxed only when glowcap intentionally supports an older
/// released table beside a new one.
pub fn checkPrereleaseProviderAbiVersions(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const Source = struct {
        path: []const u8,
        keys: []const []const u8,
    };
    const sources = [_]Source{
        .{
            .path = "src/c_abi/shared/transport_provider.zig",
            .keys = &.{
                "GLOWCAP_TRANSPORT_PROVIDER_ABI_VERSION: u32 =",
                "GLOWCAP_TRANSPORT_PROFILE_ABI_VERSION: u32 =",
                "GLOWCAP_STREAM_TRANSPORT_ABI_VERSION: u32 =",
            },
        },
        .{
            .path = "src/c_abi/shared/locator.zig",
            .keys = &.{"GLOWCAP_LOCATOR_VIEW_ABI_VERSION: u32 ="},
        },
        .{
            .path = "src/c_abi/shared/multiplexed_transport.zig",
            .keys = &.{"GLOWCAP_MULTIPLEXED_TRANSPORT_ABI_VERSION: u32 ="},
        },
    };

    for (sources) |source| {
        const contents = root.readFileAlloc(io, source.path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for prerelease provider ABI check with {s}", .{ source.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        for (source.keys) |key| {
            const at = std.mem.indexOf(u8, contents, key) orelse {
                try appendViolation(gpa, violations, "{s}: provider ABI constant `{s}` is missing", .{ source.path, key });
                continue;
            };
            const version = firstIntIn(contents[at + key.len ..]) orelse {
                try appendViolation(gpa, violations, "{s}: provider ABI constant `{s}` has no version", .{ source.path, key });
                continue;
            };
            if (version != 1) {
                try appendViolation(gpa, violations, "{s}: prerelease provider ABI `{s}` is version {d}; unsupported replacement contracts stay at version 1", .{ source.path, key, version });
            }
        }
    }
}

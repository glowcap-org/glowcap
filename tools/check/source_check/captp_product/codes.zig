//! The host error-code map, held across the C header, the bindings, and the
//! docs that cite it.

const std = @import("std");
const util = @import("../util.zig");

const appendViolation = util.appendViolation;
const expectFileContains = util.expectFileContains;

/// Every member of `driver_core.HostError` is classified by name somewhere, so
/// none of them falls through to an internal failure accidentally.
///
/// There are two core tables that classify by name, and either will do.
/// `driver_core.HostFailure` names host-tier refusals, while
/// `engine.abort_projection.classify` names protocol failures. A member in
/// neither falls through both `else` arms to an internal category even when
/// what happened is caller misuse. The `else` arms keep both switches
/// exhaustive, so the compiler cannot catch that drift.
///
/// All three sources are read rather than assumed, so a rename that emptied one
/// fails here instead of passing on an empty set: the error set must have
/// members, and both switches must be found.
pub fn checkHostErrorCodeMap(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const declaring = "src/driver/core/host/errors.zig";
    const mapping = "src/driver/core/host/failure.zig";
    const projection = "src/ocapn/engine/abort_projection.zig";

    const host_source = root.readFileAlloc(io, declaring, gpa, .limited(4 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for the HostError code-map check with {s}", .{ declaring, @errorName(err) });
        return;
    };
    defer gpa.free(host_source);
    const map_source = root.readFileAlloc(io, mapping, gpa, .limited(4 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for the HostError code-map check with {s}", .{ mapping, @errorName(err) });
        return;
    };
    defer gpa.free(map_source);
    const projection_source = root.readFileAlloc(io, projection, gpa, .limited(4 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for the HostError code-map check with {s}", .{ projection, @errorName(err) });
        return;
    };
    defer gpa.free(projection_source);

    const set_open = "pub const HostError = error{";
    const set_start = std.mem.indexOf(u8, host_source, set_open) orelse {
        try appendViolation(gpa, violations, "{s}: `{s}` not found — update `checkHostErrorCodeMap` in tools/check/source_check/captp_product/codes.zig", .{ declaring, set_open });
        return;
    };
    const set_body_start = set_start + set_open.len;
    // The set ends at the first `};` in column zero after it, the spelling every
    // top-level declaration in this tree closes with.
    const set_end_rel = std.mem.indexOf(u8, host_source[set_body_start..], "\n};") orelse {
        try appendViolation(gpa, violations, "{s}: `HostError` has no closing brace line — update `checkHostErrorCodeMap` in tools/check/source_check/captp_product/codes.zig", .{declaring});
        return;
    };
    const set_body = host_source[set_body_start .. set_body_start + set_end_rel];

    const switch_open = "pub fn classify(cause: anyerror) Kind {";
    const switch_start = std.mem.indexOf(u8, map_source, switch_open) orelse {
        try appendViolation(gpa, violations, "{s}: `{s}` not found — update `checkHostErrorCodeMap` in tools/check/source_check/captp_product/codes.zig", .{ mapping, switch_open });
        return;
    };
    const switch_end_rel = std.mem.indexOf(u8, map_source[switch_start..], "\n}") orelse map_source.len - switch_start;
    const switch_body = map_source[switch_start .. switch_start + switch_end_rel];

    const classify_open = "pub fn classify(";
    const classify_start = std.mem.indexOf(u8, projection_source, classify_open) orelse {
        try appendViolation(gpa, violations, "{s}: `{s}` not found — update `checkHostErrorCodeMap` in tools/check/source_check/captp_product/codes.zig", .{ projection, classify_open });
        return;
    };
    const classify_end_rel = std.mem.indexOf(u8, projection_source[classify_start..], "\n}") orelse projection_source.len - classify_start;
    const classify_body = projection_source[classify_start .. classify_start + classify_end_rel];

    var members: usize = 0;
    var lines = std.mem.splitScalar(u8, set_body, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        // Members are the bare `Name,` lines; doc comments and blank lines are
        // everything else in there.
        if (line.len < 2 or !std.mem.endsWith(u8, line, ",")) continue;
        if (std.mem.startsWith(u8, line, "//")) continue;
        const name = line[0 .. line.len - 1];
        if (name.len == 0 or !std.ascii.isUpper(name[0])) continue;
        var identifier = true;
        for (name) |c| {
            if (!std.ascii.isAlphanumeric(c)) identifier = false;
        }
        if (!identifier) continue;
        members += 1;

        var needle_buf: [128]u8 = undefined;
        const needle = std.fmt.bufPrint(&needle_buf, "error.{s},", .{name}) catch {
            try appendViolation(gpa, violations, "exit-code member `{s}` overflows the needle buffer; grow it", .{name});
            continue;
        };
        var alt_buf: [128]u8 = undefined;
        const alt = std.fmt.bufPrint(&alt_buf, "error.{s} ", .{name}) catch {
            try appendViolation(gpa, violations, "exit-code member `{s}` overflows the needle buffer; grow it", .{name});
            continue;
        };
        if (std.mem.indexOf(u8, switch_body, needle) != null) continue;
        if (std.mem.indexOf(u8, switch_body, alt) != null) continue;
        if (std.mem.indexOf(u8, classify_body, needle) != null) continue;
        if (std.mem.indexOf(u8, classify_body, alt) != null) continue;
        try appendViolation(
            gpa,
            violations,
            "{s}: `HostError.{s}` is named neither in the Host failure classifier in {s} nor in the abort classifier in {s}, so it falls through both to an internal failure. Give it the category its siblings have.",
            .{ declaring, name, mapping, projection },
        );
    }
    if (members == 0) {
        try appendViolation(
            gpa,
            violations,
            "{s}: the HostError code-map check parsed no members, so it is holding nothing — update `checkHostErrorCodeMap` in tools/check/source_check/captp_product/codes.zig",
            .{declaring},
        );
    }
}

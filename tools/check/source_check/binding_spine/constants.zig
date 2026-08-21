//! Hand-kept binding constant mirrors, held numerically to the generated
//! headers so a desynced discriminant fails the gate instead of a live
//! conversation.

const std = @import("std");
const util = @import("../util.zig");

const appendViolation = util.appendViolation;
const expectFileContains = util.expectFileContains;
const fileContains = util.fileContains;
const containsAsSymbol = util.containsAsSymbol;
const firstIntIn = util.firstIntIn;
const extractBraceBlock = util.extractBraceBlock;

const ConstantsFile = struct {
    path: []const u8,
    /// Racket states constants as `(define NAME INT)`; the other three as a
    /// `NAME … = … INT` assignment per line.
    racket: bool = false,
};

const binding_constants_files = [_]ConstantsFile{
    .{ .path = "bindings/rust/src/abi_constants.rs" },
    .{ .path = "bindings/python/pancake/_constants.py" },
    .{ .path = "bindings/ts/runtime/internal/constants.ts" },
    .{ .path = "bindings/racket/private/constants.rkt", .racket = true },
    // The per-binding iroh FFI mirrors of the `PANCAKE_IROH_*` transport
    // constants, held against include/pancake_net_transport_iroh.h.
    .{ .path = "bindings/rust/src/sys/iroh.rs" },
    .{ .path = "bindings/python/pancake/_ffi_iroh.py" },
    .{ .path = "bindings/racket/private/ffi-iroh.rkt", .racket = true },
};

const generated_binding_constant_files = [_][]const u8{
    "python/pancake/_constants_gen.py",
    "racket/private/constants-gen.rkt",
    "rust/src/abi_constants_gen.rs",
    "ts/abi/constants.ts",
};

pub fn isGeneratedBindingConstantFile(path: []const u8) bool {
    for (generated_binding_constant_files) |generated| {
        if (std.mem.eql(u8, path, generated)) return true;
    }
    return false;
}

/// Every per-binding ABI constant mirror restates discriminants and return codes
/// from the generated headers by hand. The headers themselves cannot drift (the
/// parity tests reflect them from the Zig c_abi source), but the mirror files
/// can. This parses each mirror's numeric values and asserts they match the
/// matching `#define PANCAKE_…` value, so a hand-edit that desyncs a constant
/// fails the gate instead of waiting for a live conversation to touch it.
///
/// The header values come from every generated header, not just the ocapn
/// base, so the driver archive's `PANCAKE_HOST_*` and the iroh archive's
/// `PANCAKE_IROH_*` mirrors are held too. The mirror
/// files span both the ocapn constant files and the per-binding iroh FFI files
/// (`binding_constants_files`), and `lookupHeaderConst` tolerates the `PANCAKE_`
/// or leading-`_` prefix a private FFI mirror spells its names with.
pub fn checkBindingConstants(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const headers = [_][]const u8{
        "include/pancake_ocapn.h",
        "include/pancake_host.h",
        "include/pancake_net_transport_tcp.h",
        "include/pancake_net_transport_inproc.h",
        "include/pancake_net_transport_iroh.h",
    };
    // The header buffers back the `header_vals` key slices, so keep them alive
    // for the whole check.
    var header_buffers: std.ArrayList([]u8) = .empty;
    defer {
        for (header_buffers.items) |buf| gpa.free(buf);
        header_buffers.deinit(gpa);
    }

    // Map every header's `#define PANCAKE_<NAME> <int>` value, keyed by the name
    // after the `PANCAKE_` prefix. Mirrors drop `ERR_` from `WOULD_BLOCK`, so
    // each `ERR_<X>` also registers a bare `<X>` alias.
    var header_vals = std.StringHashMap(i64).init(gpa);
    defer header_vals.deinit();
    for (headers) |header_path| {
        const header = root.readFileAlloc(io, header_path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for constant-mirror check with {s}", .{ header_path, @errorName(err) });
            continue;
        };
        try header_buffers.append(gpa, header);
        var rest = header;
        const needle = "#define PANCAKE_";
        while (std.mem.indexOf(u8, rest, needle)) |start| {
            const after = rest[start + needle.len ..];
            const line_end = std.mem.indexOfScalar(u8, after, '\n') orelse after.len;
            const line = after[0..line_end];
            rest = after[line_end..];

            const name_end = std.mem.indexOfAny(u8, line, " \t") orelse continue;
            const name = line[0..name_end];
            const value = firstIntIn(line[name_end..]) orelse continue;
            try header_vals.put(name, value);
            if (std.mem.startsWith(u8, name, "ERR_")) try header_vals.put(name["ERR_".len..], value);
        }
    }

    var norm_buf: [128]u8 = undefined;
    for (binding_constants_files) |file| {
        const contents = root.readFileAlloc(io, file.path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for constant-mirror check with {s}", .{ file.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);

        if (file.racket) {
            var rest = contents;
            while (std.mem.indexOf(u8, rest, "(define ")) |start| {
                const after = rest[start + "(define ".len ..];
                rest = after;
                const name_end = std.mem.indexOfAny(u8, after, " \t") orelse continue;
                const raw_name = after[0..name_end];
                const value = firstIntIn(after[name_end..]) orelse continue;
                try compareConstant(gpa, violations, file.path, &header_vals, raw_name, value, &norm_buf);
            }
        } else {
            var lines = std.mem.splitScalar(u8, contents, '\n');
            while (lines.next()) |raw_line| {
                const trimmed = std.mem.trim(u8, raw_line, " \t");
                if (std.mem.startsWith(u8, trimmed, "//") or std.mem.startsWith(u8, trimmed, "#")) continue;
                const eq = std.mem.indexOfScalar(u8, raw_line, '=') orelse continue;
                var lhs = raw_line[0..eq];
                if (std.mem.indexOfScalar(u8, lhs, ':')) |colon| lhs = lhs[0..colon];
                const lhs_trimmed = std.mem.trim(u8, lhs, " \t");
                const name_start = if (std.mem.lastIndexOfAny(u8, lhs_trimmed, " \t")) |sp| sp + 1 else 0;
                const raw_name = lhs_trimmed[name_start..];
                if (raw_name.len == 0) continue;
                // The value is the first integer up to a `;` or `//` comment.
                var rhs = raw_line[eq + 1 ..];
                if (std.mem.indexOfScalar(u8, rhs, ';')) |semi| rhs = rhs[0..semi];
                if (std.mem.indexOf(u8, rhs, "//")) |c| rhs = rhs[0..c];
                const value = firstIntIn(rhs) orelse continue;
                try compareConstant(gpa, violations, file.path, &header_vals, raw_name, value, &norm_buf);
            }
        }
    }
}

/// Keep the public resource-knob table aligned with the executable default.
/// HostRuntime derives its frame cap from driver_core.Host, whose default is
/// the session limit mirrored as PANCAKE_DEFAULT_FRAME_CAP.
pub fn checkArchitectureConstantClaims(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    try expectFileContains(io, gpa, root, violations, "src/driver/host_runtime/contract.zig", &.{
        "const default_frame_cap = (driver_core.Host.Options{}).limits.max_frame_bytes;",
    });
    try expectFileContains(io, gpa, root, violations, "docs/architecture.md", &.{
        "| `driver.HostRuntime.Options.frame_cap` | Protocol admission for sessions the owning face creates. | 1 MiB |",
    });
}

fn compareConstant(
    gpa: std.mem.Allocator,
    violations: *std.ArrayList([]const u8),
    path: []const u8,
    header_vals: *std.StringHashMap(i64),
    raw_name: []const u8,
    value: i64,
    norm_buf: *[128]u8,
) !void {
    if (raw_name.len > norm_buf.len) return;
    var name = norm_buf[0..raw_name.len];
    for (raw_name, 0..) |c, i| name[i] = if (c == '-') '_' else std.ascii.toUpper(c);
    const expected = lookupHeaderConst(header_vals, name) orelse return; // no header counterpart (e.g. struct sizes)
    if (expected != value) {
        try appendViolation(gpa, violations, "{s}: constant {s} = {d} drifts from header PANCAKE_… = {d}", .{ path, raw_name, value, expected });
    }
}

/// Look up a mirror constant's expected header value, tolerating the two prefix
/// conventions a private FFI mirror uses: an iroh Rust mirror spells the full
/// `PANCAKE_IROH_EV_*`, a Python one spells `_IROH_EV_*`, while the header keys
/// are stripped of `PANCAKE_`. The direct hit is tried first; a prefix strip
/// only ever turns a would-be silent skip into a match, never an existing match
/// into a miss.
fn lookupHeaderConst(header_vals: *std.StringHashMap(i64), name: []const u8) ?i64 {
    if (header_vals.get(name)) |v| return v;
    if (std.mem.startsWith(u8, name, "PANCAKE_")) {
        if (header_vals.get(name["PANCAKE_".len..])) |v| return v;
    }
    if (std.mem.startsWith(u8, name, "_")) {
        if (header_vals.get(name[1..])) |v| return v;
    }
    return null;
}

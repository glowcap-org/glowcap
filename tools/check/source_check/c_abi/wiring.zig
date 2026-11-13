//! Host wiring lockstep: the host-action arm table, the host-pump import
//! allowlist, and the rule that no ADR number rides in a runtime string.

const std = @import("std");
const json_files = @import("../json_files.zig");
const source_tree = @import("../source_tree.zig");
const text_match = @import("../text_match.zig");
const violation_log = @import("../violation_log.zig");

const appendViolation = violation_log.appendViolation;
const expectFileContains = text_match.expectFileContains;
const fileContains = text_match.fileContains;
const firstIntIn = text_match.firstIntIn;
const parseJsonFile = json_files.parseJsonFile;
const getField = json_files.getField;
const jsonStringEquals = json_files.jsonStringEquals;

/// HostAction / C embedder_pump arm parity: a new action kind must fail the
/// build rather than silently drop from either switch spine. Node actions have
/// their independent product lockstep check in `captp_product/node_actions.zig`.
pub fn checkHostActionArmLockstep(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const header_path = "include/glowcap_host.h";
    const header = root.readFileAlloc(io, header_path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for HostAction arm lockstep with {s}", .{ header_path, @errorName(err) });
        return;
    };
    defer gpa.free(header);

    var action_names: std.ArrayList([]const u8) = .empty;
    defer action_names.deinit(gpa);
    try text_match.namesAfterPrefix(gpa, header, "#define GLOWCAP_HOST_ACTION_", &action_names);
    if (action_names.items.len == 0) {
        try appendViolation(gpa, violations, "{s}: no GLOWCAP_HOST_ACTION_* for HostAction arm lockstep", .{header_path});
        return;
    }

    const zig_action = root.readFileAlloc(io, "src/driver/core/host/action.zig", gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "src/driver/core/host/action.zig: failed to read for HostAction arm lockstep with {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(zig_action);
    // Zig HostAction tags (snake) must match header constants (SCREAMING).
    const zig_tags = [_][]const u8{ "dial", "cancel_dial", "flush", "close", "need_gift_id", "settled", "failed", "resume_work" };
    if (action_names.items.len != zig_tags.len) {
        try appendViolation(gpa, violations, "HostAction arm lockstep: header has {d} GLOWCAP_HOST_ACTION_* but Zig HostAction expects {d} tags", .{ action_names.items.len, zig_tags.len });
    }
    for (zig_tags) |tag| {
        if (std.mem.find(u8, zig_action, tag) == null) {
            try appendViolation(gpa, violations, "src/driver/core/host/action.zig: missing HostAction tag `{s}`", .{tag});
        }
    }

    const embedder = root.readFileAlloc(io, "src/c_abi/host/embedder_pump.zig", gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "src/c_abi/host/embedder_pump.zig: failed to read for HostAction arm lockstep with {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(embedder);
    for (action_names.items) |name| {
        var token_buf: [96]u8 = undefined;
        const token = std.mem.print(&token_buf, "GLOWCAP_HOST_ACTION_{s}", .{name}) catch {
            try appendViolation(gpa, violations, "HostAction arm lockstep: action name `{s}` too long", .{name});
            continue;
        };
        if (std.mem.find(u8, embedder, token) == null) {
            // SETTLE and FAIL share the complete arm in embedder_pump.
            if (std.mem.eql(u8, name, "SETTLE") or std.mem.eql(u8, name, "FAIL")) {
                if (std.mem.find(u8, embedder, "GLOWCAP_HOST_ACTION_SETTLE") != null and
                    std.mem.find(u8, embedder, "GLOWCAP_HOST_ACTION_FAIL") != null) continue;
            }
            try appendViolation(gpa, violations, "src/c_abi/host/embedder_pump.zig: missing drain arm for `{s}`", .{token});
        }
    }
}

/// `host/pump.zig` is Host-private pump mechanics: only the Host core's own
/// responsibility files may import it. Cross-file `pub fn` stays for Zig module
/// visibility. This gate is what keeps the boundary from rotting into a second
/// public API.
pub fn checkHostPumpImportGate(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    // The Host core is the `src/driver/core/` directory: `host.zig` and the
    // siblings split out of it, each still implementing `Host` verbs behind
    // decl aliases. The pump is private to that directory as a whole, the
    // list stopped naming files when every slice of the split was adding one.
    const host_core_dir = "src/driver/core/";
    const needle = "@import(\"host/pump.zig\")";
    const Sink = struct {
        gpa: std.mem.Allocator,
        violations: *std.ArrayList([]const u8),

        fn visit(self: @This(), path: []const u8, contents: []u8) std.mem.Allocator.Error!void {
            if (std.mem.startsWith(u8, path, host_core_dir)) return;
            if (std.mem.find(u8, contents, needle) != null) {
                try appendViolation(self.gpa, self.violations, "{s}: imports host/pump.zig — only the Host core's own files may (Host private pump)", .{path});
            }
        }
    };
    try source_tree.visitSourceFiles(io, gpa, root, violations, "host_pump import", "src", &source_tree.isZigPath, Sink{ .gpa = gpa, .violations = violations }, Sink.visit);
}

/// ADR names belong in docs and comments, never in strings that can reach a
/// panic message, CapTP abort text, log line, or other runtime surface.
pub fn checkNoAdrInRuntimeStrings(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const roots = [_][]const u8{ "src", "interop", "test/driver/transports", "test/support/transport" };
    for (roots) |rel| {
        var dir = root.openDir(io, rel, .{ .iterate = true }) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to open for ADR-runtime-string check with {s}", .{ rel, @errorName(err) });
            continue;
        };
        defer dir.close(io);
        var walker = try dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
            const path = try gpa.print("{s}/{s}", .{ rel, entry.path });
            defer gpa.free(path);
            const contents = root.readFileAlloc(io, path, gpa, .limited(4 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: failed to read for ADR-runtime-string check with {s}", .{ path, @errorName(err) });
                continue;
            };
            defer gpa.free(contents);
            var line_no: usize = 1;
            var lines = std.mem.splitScalar(u8, contents, '\n');
            while (lines.next()) |line| : (line_no += 1) {
                if (zigLineHasAdrInStringLiteral(line)) {
                    try appendViolation(gpa, violations, "{s}:{d}: ADR citation in a string literal — keep ADR names in comments/docs, not panic/abort/log text", .{ path, line_no });
                }
            }
        }
    }
}

fn srcHasCallOutsideDef(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
    call_needle: []const u8,
    def_path: []const u8,
) !bool {
    var dir = try root.openDir(io, "src", .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const path = try gpa.print("src/{s}", .{entry.path});
        defer gpa.free(path);
        if (std.mem.eql(u8, path, def_path)) continue;
        const contents = root.readFileAlloc(io, path, gpa, .limited(4 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: cannot be read for the C-ABI wiring check ({s})", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trimStart(u8, line, " \t");
            if (std.mem.startsWith(u8, trimmed, "//")) continue;
            if (std.mem.find(u8, line, call_needle) != null) return true;
        }
    }
    return false;
}

/// True when a double-quoted Zig string literal on `line` contains `ADR-`.
/// Line comments (`//`) outside strings are ignored. Multiline strings and
/// character literals are out of scope (ADR citations do not live there).
fn zigLineHasAdrInStringLiteral(line: []const u8) bool {
    var i: usize = 0;
    var in_string = false;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (!in_string) {
            if (c == '/' and i + 1 < line.len and line[i + 1] == '/') return false;
            if (c == '"') {
                in_string = true;
            }
            continue;
        }
        if (c == '\\') {
            i += 1; // skip escaped byte
            continue;
        }
        if (c == '"') {
            in_string = false;
            continue;
        }
        if (c == 'A' and i + 4 <= line.len and std.mem.eql(u8, line[i..][0..4], "ADR-")) {
            return true;
        }
    }
    return false;
}

test "zigLineHasAdrInStringLiteral ignores comments and flags string literals" {
    try std.testing.expect(!zigLineHasAdrInStringLiteral("// (ADR-0030) comment only"));
    try std.testing.expect(!zigLineHasAdrInStringLiteral("const x = 1; // (ADR-0001)"));
    try std.testing.expect(zigLineHasAdrInStringLiteral("@panic(\"needs store (ADR-0030)\");"));
    try std.testing.expect(zigLineHasAdrInStringLiteral(".message = \"cap (ADR-0008)\","));
    try std.testing.expect(!zigLineHasAdrInStringLiteral(".message = \"cap exceeded\","));
}

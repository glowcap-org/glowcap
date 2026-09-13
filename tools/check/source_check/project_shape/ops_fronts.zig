//! The direction between the build graph and an operations front (ADR-0150):
//! a front calls `zig build` for the toolchain half and never runs a build
//! tool itself, and the build graph never names a deployment directory. A
//! step that needed the front would be a build that depends on a machine; a
//! front that ran `cargo` or `deno` would be a second copy of the build.

const std = @import("std");
const util = @import("../util.zig");

const appendViolation = util.appendViolation;

/// Every operations front the tree ships: one per public deployable.
const ops_fronts = [_][]const u8{
    "apps/rooms/web/deploy/ops",
};

/// The path segment every deployable's directory carries. The build graph
/// may name a deployable's artifacts (`zig-out/rooms-web`) but never the
/// directory an operator runs from.
const deployment_segment = "/deploy/";

/// Programs the build graph owns. A front may invoke none of them directly;
/// `zig` is allowed only as `zig build`.
const build_tools = [_][]const u8{ "cargo", "deno", "wasm-bindgen", "npm", "npx", "raco", "uv" };

pub fn checkOpsFrontsCallZigOnly(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const graph = try util.readBuildStepSources(io, gpa, root);
    defer gpa.free(graph);
    if (std.mem.indexOf(u8, graph, deployment_segment) != null) {
        try appendViolation(gpa, violations, "build.zig or tools/build/**: the build graph names a `{s}` directory; an operations front calls `zig build`, never the reverse (ADR-0150)", .{deployment_segment});
    }
    for (ops_fronts) |path| {
        const body = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read the operations front with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(body);
        try checkFrontBody(gpa, violations, path, body);
    }
}

fn checkFrontBody(
    gpa: std.mem.Allocator,
    violations: *std.ArrayList([]const u8),
    path: []const u8,
    body: []const u8,
) !void {
    // A program is run when it is the first word of a command, so each line
    // is cut at the shell's command separators and only the head of each
    // piece is judged. Naming a tool anywhere else (`need zig`, a case label,
    // a message) is a presence probe or prose, not an invocation.
    var lines = std.mem.splitScalar(u8, body, '\n');
    var line_no: usize = 0;
    while (lines.next()) |raw| {
        line_no += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var pieces = std.mem.tokenizeAny(u8, line, ";&|()`");
        while (pieces.next()) |piece| {
            var words = std.mem.tokenizeAny(u8, piece, " \t\"'");
            var head = words.next() orelse continue;
            // Skip what precedes the program on its own command line.
            while (std.mem.indexOfScalar(u8, head, '=') != null or
                std.mem.eql(u8, head, "env") or std.mem.eql(u8, head, "exec") or
                std.mem.eql(u8, head, "timeout") or std.mem.eql(u8, head, "nice"))
            {
                head = words.next() orelse break;
            }
            if (std.mem.eql(u8, head, "zig")) {
                const verb = words.next() orelse continue;
                if (!std.mem.eql(u8, verb, "build")) {
                    try appendViolation(gpa, violations, "{s}:{d}: an operations front runs `zig` only as `zig build`, never the compiler itself (ADR-0150)", .{ path, line_no });
                }
                continue;
            }
            for (build_tools) |tool| {
                if (std.mem.eql(u8, head, tool)) {
                    try appendViolation(gpa, violations, "{s}:{d}: an operations front runs `{s}`; that is the build graph's, reach it through `zig build` (ADR-0150)", .{ path, line_no, tool });
                }
            }
        }
    }
}

test "a front that reaches for a build tool or the compiler is refused" {
    const gpa = std.testing.allocator;
    var violations: std.ArrayList([]const u8) = .empty;
    defer {
        for (violations.items) |v| gpa.free(v);
        violations.deinit(gpa);
    }
    try checkFrontBody(gpa, &violations, "ops",
        \\# cargo build is fine to mention in a comment
        \\(cd "$repo_root" && zig build rooms-deploy-prep)
        \\need zig; for tool in zig docker; do have "$tool"; done
        \\zig) fail "zig is not here; run this inside the devcontainer" ;;
        \\docker compose up -d || fail "read: deno task test"
        \\cargo build --release
        \\GLOWCAP_ROOMS_STATE=/tmp/x env zig fmt .
        \\deno task test && zig build check
    );
    try std.testing.expectEqual(@as(usize, 3), violations.items.len);
    try std.testing.expect(std.mem.indexOf(u8, violations.items[0], "ops:6:") != null);
    try std.testing.expect(std.mem.indexOf(u8, violations.items[1], "ops:7:") != null);
    try std.testing.expect(std.mem.indexOf(u8, violations.items[2], "ops:8:") != null);
}

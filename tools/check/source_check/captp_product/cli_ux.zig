//! CLI product shape: the driver-root shadow and the single JSON escaper.

const std = @import("std");
const text_match = @import("../text_match.zig");
const violation_log = @import("../violation_log.zig");
const skills = @import("skills.zig");

const appendViolation = violation_log.appendViolation;
const expectFileContains = text_match.expectFileContains;

test "collectCaptpRegistryNames takes Command rows only" {
    const gpa = std.testing.allocator;
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(gpa);
    const src =
        \\pub const commands = [_]Command{
        \\    .{
        \\        .name = "listen",
        \\        .help = "Bind",
        \\        .positionals = &[_]Positional{.{ .name = "locator", .help = "uri" }},
        \\    },
        \\    .{
        \\        .name = "dial",
        \\        .help = "Dial",
        \\    },
        \\};
    ;
    try skills.collectCaptpRegistryNames(gpa, src, &names);
    try std.testing.expectEqual(@as(usize, 2), names.items.len);
    try std.testing.expectEqualStrings("listen", names.items[0]);
    try std.testing.expectEqualStrings("dial", names.items[1]);
}

test "captpVerbTableIsPartial catches incomplete inventory tables" {
    const names = [_][]const u8{ "listen", "dial", "probe", "call" };
    try std.testing.expect(skills.captpVerbTableIsPartial(
        "| Verb | Role |\n| --- | --- |\n| `listen` | host |\n| `dial` | dial |\n| `probe` | poke |\n",
        &names,
    ));
    try std.testing.expect(!skills.captpVerbTableIsPartial(
        "| Verb | Role |\n| --- | --- |\n| `listen` | host |\n| `dial` | dial |\n| `probe` | poke |\n| `call` | act |\n",
        &names,
    ));
    try std.testing.expect(!skills.captpVerbTableIsPartial(
        "| Front | Shape |\n| --- | --- |\n| argv | `call` / `tell` / `fetch` / `probe` |\n",
        &names,
    ));
    try std.testing.expect(!skills.captpVerbTableIsPartial("defer to `glowcap help`", &names));
}

/// A `pub const X` in the driver root must not name something other than
/// `driver_core.X` when the core also declares `X`.
///
/// Every other re-export in that root (`Served`, `Error`, `Settled`,
/// `Identity`, `Capability`) forwards the core's type, so a reader learns the
/// rule "driver.X is driver_core.X" and then meets one that is not. The
/// owning face was `driver.Host` shadowing `driver_core.Host` until the
/// ownership-vocabulary pass renamed it `HostRuntime`. Nothing but this check
/// stops the next one.
/// Textual: the two roots are separate modules, so a reflection
/// check would have to import both into the scaffolding build.
pub fn checkDriverRootShadow(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const driver_src = root.readFileAlloc(io, "src/driver/mod.zig", gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "src/driver/mod.zig: failed to read for the shadow check with {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(driver_src);
    const core_src = root.readFileAlloc(io, "src/driver/core/mod.zig", gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "src/driver/core/mod.zig: failed to read for the shadow check with {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(core_src);

    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, driver_src, '\n');
    while (lines.next()) |line| {
        line_no += 1;
        const decl = "pub const ";
        if (!std.mem.startsWith(u8, std.mem.trimStart(u8, line, " \t"), decl)) continue;
        const after = std.mem.trimStart(u8, line, " \t")[decl.len..];
        const eq = std.mem.indexOfScalar(u8, after, '=') orelse continue;
        const name = std.mem.trim(u8, after[0..eq], " \t");
        if (name.len == 0) continue;
        const value = std.mem.trim(u8, after[eq + 1 ..], " \t;");
        // Does the core declare this name too?
        var core_decl_buf: [128]u8 = undefined;
        const core_decl = std.fmt.bufPrint(&core_decl_buf, "pub const {s} =", .{name}) catch {
            try appendViolation(gpa, violations, "src/driver/mod.zig:{d}: `pub const {s}` overflows the forwarding check's needle buffer; grow it", .{ line_no, name });
            continue;
        };
        if (std.mem.indexOf(u8, core_src, core_decl) == null) continue;
        // It does. The driver root's value must forward it.
        var want_buf: [160]u8 = undefined;
        const want = std.fmt.bufPrint(&want_buf, "driver_core.{s}", .{name}) catch {
            try appendViolation(gpa, violations, "src/driver/mod.zig:{d}: `pub const {s}` overflows the forwarding check's needle buffer; grow it", .{ line_no, name });
            continue;
        };
        if (std.mem.eql(u8, value, want)) continue;
        try appendViolation(gpa, violations, "src/driver/mod.zig:{d}: `pub const {s}` shadows `driver_core.{s}` with `{s}`; every other re-export in this root forwards the core's type, so a name that does not must not reuse the core's spelling (ADR-0011 names the owning face `HostRuntime` for this reason)", .{ line_no, name, name, value });
    }
}

/// Hold the CLI to one JSON string escaper.
///
/// There were two, written a minute apart by two changes that each thought they
/// were the only one. When the first was taught to handle bytes that are not
/// text, the second kept writing unparseable JSON, and the second was the one
/// recording what room members send, which is the least trusted input the CLI
/// has. A duplicate escaper does not announce itself: both compile, both look
/// right, and they disagree only on input nobody tests by hand.
pub fn checkSingleJsonEscaper(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const definition = "fn writeJsonString(";
    var found: std.ArrayList([]const u8) = .empty;
    defer {
        for (found.items) |path| gpa.free(path);
        found.deinit(gpa);
    }

    var dir = root.openDir(io, "cli", .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "cli/: cannot open it to check the JSON escaper ({s})", .{@errorName(err)});
        return;
    };
    defer dir.close(io);

    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        const source = dir.readFileAlloc(io, entry.path, gpa, .limited(4 << 20)) catch |err| {
            try appendViolation(gpa, violations, "cli/{s}: cannot be read for the CLI UX check ({s})", .{ entry.path, @errorName(err) });
            continue;
        };
        defer gpa.free(source);
        if (std.mem.indexOf(u8, source, definition) == null) continue;
        try found.append(gpa, try gpa.dupe(u8, entry.path));
    }

    if (found.items.len > 1) {
        for (found.items) |path| {
            try appendViolation(gpa, violations, "cli/{s}: defines `writeJsonString`, and so does another file under cli/. Keep one and alias it, so a fix to escaping reaches every caller.", .{path});
        }
    }
}

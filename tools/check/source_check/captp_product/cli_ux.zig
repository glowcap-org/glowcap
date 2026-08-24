//! CLI product honesty: the lab REPL's UX claims, the driver-root shadow,
//! and the single JSON escaper.

const std = @import("std");
const util = @import("../util.zig");
const skills = @import("skills.zig");
const deadlines = @import("deadlines.zig");

const appendViolation = util.appendViolation;
const expectFileContains = util.expectFileContains;

/// CapTP lab chrome/docs must match live keys: listen is argv-only; F1 (not
/// prompt `?`) opens the help modal; no stub search theater; no product-taste
/// names in `cli/repl` module headers.
pub fn checkCaptpLabUxHonesty(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const forbidden = [_]struct { path: []const u8, needle: []const u8, why: []const u8 }{
        .{ .path = "cli/repl/panes.zig", .needle = "dial or listen", .why = "empty-session chrome must invite dial only (listen is argv-only)" },
        .{ .path = "cli/repl/panes.zig", .needle = "F1 / ?", .why = "help modal must not claim prompt ? opens it (F1 does; ? is tip at prompt)" },
        .{ .path = "docs/cli.md", .needle = "dial` / `listen` inside", .why = "lab starts with dial inside; listen stays argv-only" },
        .{ .path = ".agents/skills/pancake-cli/SKILL.md", .needle = "dial/listen inside", .why = "skill session table: dial inside; listen argv-only" },
        .{ .path = "cli/mcp/mod.zig", .needle = "\"version\":\"0.1.0\"", .why = "MCP serverInfo.version must come from build_options, not a hard-coded literal" },
        .{ .path = "cli/mcp/mod.zig", .needle = "Content-Length", .why = "MCP stdio is NDJSON per the MCP transport spec; LSP Content-Length framing breaks Cursor/Claude" },
        .{ .path = "cli/registry.zig", .needle = "if (std.mem.eql(u8, cmd.name, \"listen\")) continue", .why = "use leafVisible; no ad-hoc listen skip lists" },
        .{ .path = "cli/cmd/tree.zig", .needle = "held; not yet on the wire", .why = "rooms-peer --dm ships via directory introduce; help must not claim held" },
        .{ .path = "cli/app/rooms_peer/peer.zig", .needle = "remaining milestone", .why = "DM introduce/tell shipped; do not reintroduce a silent skip" },
        .{ .path = "cli/app/rooms_peer/verbs.zig", .needle = "not-implemented", .why = "reply --dm writes outbox; not a not-implemented stub" },
    };
    for (forbidden) |row| {
        const contents = root.readFileAlloc(io, row.path, gpa, .limited(4 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for CapTP lab UX check with {s}", .{ row.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, row.needle) != null) {
            try appendViolation(gpa, violations, "{s}: forbidden needle `{s}` — {s}", .{ row.path, row.needle, row.why });
        }
    }
    try expectFileContains(io, gpa, root, violations, "cli/repl/panes.zig", &.{
        "F1       this help",
        "dial an ocapn:// locator",
    });
    try expectFileContains(io, gpa, root, violations, "cli/registry.zig", &.{
        "leafVisible",
        "flagVisibleMcp",
        "argv_only",
        "mcp_hide",
    });
    try expectFileContains(io, gpa, root, violations, "cli/app/rooms_peer/peer.zig", &.{"registerWithDirectory"});
    try expectFileContains(io, gpa, root, violations, "cli/app/rooms_peer/outbox.zig", &.{"startIntroduce(state, parsed.peer);"});
    try expectFileContains(io, gpa, root, violations, "cli/app/rooms_peer/wire.zig", &.{"offerInboxFor"});
}

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
    try std.testing.expect(!skills.captpVerbTableIsPartial("defer to `pancake help`", &names));
}

test "mentionsVerbInCode matches bare, call, and receiver-method phrasings" {
    // Bare token, as the README and vision write it.
    try std.testing.expect(skills.mentionsVerbInCode("the `connect` verb dials", "connect"));
    // As a call with arguments, as bindings/README's table writes it.
    try std.testing.expect(skills.mentionsVerbInCode("| `listen(host, port)` | accept |", "listen"));
    // As a method on a receiver, the other bindings/README phrasing.
    try std.testing.expect(skills.mentionsVerbInCode("call `conn.tell(ref, verb, args)`", "tell"));
    try std.testing.expect(skills.mentionsVerbInCode("`conn.serve()` runs the loop", "serve"));
    // Absent: prose mention outside code is not enough, and a different verb
    // inside code does not satisfy the missing one.
    try std.testing.expect(!skills.mentionsVerbInCode("you can tell it to stop", "tell"));
    try std.testing.expect(!skills.mentionsVerbInCode("only `conn.close()` here", "serve"));
}

/// Hold the CLI to one JSON string escaper.
///
/// There were two, written a minute apart by two changes that each thought they
/// were the only one. When the first was taught to handle bytes that are not
/// text, the second kept writing unparseable JSON — and the second was the one
/// recording what room members send, which is the least trusted input the CLI
/// has. A duplicate escaper does not announce itself: both compile, both look
/// right, and they disagree only on input nobody tests by hand.
/// A `pub const X` in the driver root must not name something other than
/// `driver_core.X` when the core also declares `X`.
///
/// Every other re-export in that root (`Served`, `Error`, `Settled`,
/// `Identity`, `Capability`) forwards the core's type, so a reader learns the
/// rule "driver.X is driver_core.X" and then meets one that is not. The
/// owning face was `driver.Host` shadowing `driver_core.Host` until the
/// ownership-vocabulary pass renamed it `HostRuntime`; nothing but this check
/// stops the next one.
/// Textual on purpose: the two roots are separate modules, so a reflection
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
        try appendViolation(gpa, violations, "src/driver/mod.zig:{d}: `pub const {s}` shadows `driver_core.{s}` with `{s}`; every other re-export in this root forwards the core's type, so a name that does not must not reuse the core's spelling (ADR-0113 names the owning face `HostRuntime` for this reason)", .{ line_no, name, name, value });
    }
}

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

test "initializedPositive accepts only a bounded budget that closes its own initializer" {
    // Literal budgets and the shared defaults are both bounded.
    try std.testing.expect(deadlines.initializedPositive("", ".{ .handshake = .{ .ms = 10_000 } }", "handshake"));
    try std.testing.expect(deadlines.initializedPositive("", ".{\n    .settle = .{ .ms = 5000 },\n}", "settle"));
    try std.testing.expect(deadlines.initializedPositive("", ".{ .handshake = driver.default_handshake_budget }", "handshake"));
    try std.testing.expect(deadlines.initializedPositive("", ".{ .settle = pancake.driver.default_settle_budget }", "settle"));

    // The unbounded spelling, and the expired zero, however spelled.
    try std.testing.expect(!deadlines.initializedPositive("", ".{ .handshake = .unbounded }", "handshake"));
    try std.testing.expect(!deadlines.initializedPositive("", ".{ .handshake = .{ .ms = 0 } }", "handshake"));
    try std.testing.expect(!deadlines.initializedPositive("", ".{ .handshake = .{ .ms = 0_000 } }", "handshake"));
    try std.testing.expect(!deadlines.initializedPositive("", ".{}", "handshake"));

    // A positive-looking first token that is not the value. Reading the digits
    // and stopping is how a check convinces itself an unbounded wait is bounded.
    try std.testing.expect(!deadlines.initializedPositive("", ".{ .handshake = .{ .ms = 10_000 - 10_000 } }", "handshake"));
    try std.testing.expect(!deadlines.initializedPositive("", ".{ .handshake = .{ .ms = 10 * factor } }", "handshake"));

    // A different field whose name merely ends in this one.
    try std.testing.expect(!deadlines.initializedPositive("", ".{ .my_handshake = .{ .ms = 10_000 } }", "handshake"));
    try std.testing.expect(!deadlines.initializedPositive("", ".{ .handshake_hint = .{ .ms = 10_000 } }", "handshake"));
}

test "buffer-explicit session options require both bounded waits" {
    const file =
        "const handshake_budget = driver.default_handshake_budget;\n" ++
        "const settle_budget = driver.default_settle_budget;";
    const bounded = "a, b, .{ .handshake = handshake_budget, .settle = settle_budget }";
    try std.testing.expect(deadlines.initializedPositive(file, bounded, "handshake"));
    try std.testing.expect(deadlines.initializedPositive(file, bounded, "settle"));
    const unbounded = "a, b, .{ .handshake = .unbounded, .settle = .{ .ms = 10 } }";
    try std.testing.expect(!deadlines.initializedPositive(file, unbounded, "handshake"));
}

test "callArguments fails closed on an unbalanced call" {
    // The opener is at index 8; the call never closes. Returning the rest of
    // the file here is how a budget belonging to some later call comes to
    // satisfy this one.
    const src = "x = open(a, b\n.handshake = .{ .ms = 5 },\n";
    try std.testing.expectEqual(@as(usize, 0), deadlines.callArguments(src, 9).len);
    const closed = "x = open(a, .handshake = .{ .ms = 5 })";
    try std.testing.expect(deadlines.callArguments(closed, 9).len > 0);
}

test "blankComments erases comments without mistaking a locator for one" {
    var src = "a // gone\n.handshake = .{ .ms = 1 },".*;
    deadlines.blankComments(&src);
    try std.testing.expect(std.mem.indexOf(u8, &src, "gone") == null);
    try std.testing.expect(deadlines.initializedPositive(&src, &src, "handshake"));

    // The `//` inside a string is not a comment: treating it as one would blank
    // the rest of the argument list, and the budget in it would read as absent.
    var uri = "\"tcp://host\", .{ .handshake = .{ .ms = 9 } }".*;
    deadlines.blankComments(&uri);
    try std.testing.expect(deadlines.initializedPositive(&uri, &uri, "handshake"));

    // And a budget that only appears in a comment is not a budget.
    var commented = "// .handshake = .{ .ms = 9 }\n.{}".*;
    deadlines.blankComments(&commented);
    try std.testing.expect(!deadlines.initializedPositive(&commented, &commented, "handshake"));
}

//! CapTP waits are bounded: `.unbounded` stays out of cli/ and examples,
//! deadline fields are positive, and the listen stop wake is wired.

const std = @import("std");
const util = @import("../util.zig");

const appendViolation = util.appendViolation;
const expectFileContains = util.expectFileContains;

/// Product CLI CapTP waits must be finite (ADR-0030). An `.unbounded` budget
/// parks forever on a silent peer, the hang that wedged `cli-test` and left
/// zombie test binaries back when unbounded was a silent default.
pub fn checkCliCaptpDeadlines(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    try expectFileContains(io, gpa, root, violations, "cli/ocapn/session_opts.zig", &.{
        "pub fn sessionOpts()",
        "default_handshake_timeout_ms",
        "default_settle_timeout_ms",
        "unhandled_failure",
    });
    try expectFileContains(io, gpa, root, violations, "cli/ocapn/mod.zig", &.{
        "default_handshake_timeout_ms",
        "default_settle_timeout_ms",
        "HandshakeTimedOut",
        "sessionOpts()",
    });
    try expectFileContains(io, gpa, root, violations, "test/cli/session_cases.zig", &.{
        "sessionOpts()",
        "HandshakeTimedOut",
        ".handshake = .{ .ms = 200 }",
    });
    try expectFileContains(io, gpa, root, violations, "test/cli/captp_cases.zig", &.{
        "cmdListen",
        "cmdCall",
        "publish",
        "greeter",
        "requestStop while accepting",
        "requestStop while serving",
    });
    try expectFileContains(io, gpa, root, violations, "test/cli/all.zig", &.{
        "captp_cases.zig",
    });

    var dir = root.openDir(io, "cli", .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "cli/: failed to open for CapTP-deadline check with {s}", .{@errorName(err)});
        return;
    };
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const path = try std.fmt.allocPrint(gpa, "cli/{s}", .{entry.path});
        defer gpa.free(path);
        const contents = root.readFileAlloc(io, path, gpa, .limited(4 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for CapTP-deadline check with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        var line_no: usize = 1;
        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |line| : (line_no += 1) {
            const trimmed = std.mem.trimStart(u8, line, " \t");
            if (std.mem.startsWith(u8, trimmed, "//")) continue;
            // `SessionOptions` has no default budget, so the compiler already
            // refuses an omitted one everywhere. What it cannot refuse is the
            // budget that says forever out loud, which is right for an
            // in-process pair and wrong on a product path and in an example a
            // reader copies.
            if (std.mem.indexOf(u8, line, ".handshake = .unbounded") != null or
                std.mem.indexOf(u8, line, ".settle = .unbounded") != null)
            {
                try appendViolation(gpa, violations, "{s}:{d}: an unbounded CapTP budget parks forever on a silent peer; name a finite `.{{ .ms = N }}` (cli/ has `sessionOpts()`)", .{ path, line_no });
            }
        }
    }
}

/// A teaching surface must not demonstrate the unbounded wait.
///
/// The compiler refuses an omitted budget (`SessionOptions` has no default),
/// and a `.ms` of zero or less times out immediately, so the one spelling left
/// that waits forever is `.unbounded`. `cli/` is already refused it above,
/// because there it is a hang. In an example it is worse than a hang: a reader
/// copies it.
///
/// This asserts the positive, every call that opens a session names a budget
/// ,  rather than matching the shape of a bad one. A first attempt looked for
/// `, .{})` on the call's own line and so was blind to every real call in the
/// tree, all of which wrap their arguments across lines.
///
/// Blank out every comment, keeping the source's byte offsets so reported line
/// numbers still point at the right place. Zig has no block comments, so this
/// is `//` to end of line, skipping the ones inside a string literal, a locator
/// like `"tcp://host"` is not the start of a comment, and a naive scan that
/// thinks it is truncates the argument list it was meant to read.
pub fn blankComments(src: []u8) void {
    var i: usize = 0;
    while (i < src.len) {
        switch (src[i]) {
            '"' => {
                i += 1;
                while (i < src.len and src[i] != '"') : (i += 1) {
                    if (src[i] == '\\') i += 1;
                }
                i += 1;
            },
            '\'' => {
                i += 1;
                while (i < src.len and src[i] != '\'') : (i += 1) {
                    if (src[i] == '\\') i += 1;
                }
                i += 1;
            },
            '/' => {
                if (i + 1 < src.len and src[i + 1] == '/') {
                    while (i < src.len and src[i] != '\n') : (i += 1) src[i] = ' ';
                } else i += 1;
            },
            else => i += 1,
        }
    }
}

/// Whether the value expression at the start of `value` is a bounded budget: a
/// positive integer, a `.{ .ms = <positive> }` budget literal, a named
/// constant resolving to either, or the driver's shared default budget.
///
/// The whole expression is read, not just its first token. "starts with a
/// nonzero digit" accepts `10_000 - 10_000` and `10_000 * 0`, which are the
/// zero this refuses wearing a disguise, so the digits must run all the way to
/// the delimiter that ends the expression. An identifier is resolved once
/// against the file's own top-level constants: a named, documented budget is
/// the form an example *should* teach, and a check that only accepted literals
/// would push every example toward a magic number. `.unbounded` has no arm
/// here: it is the value this check exists to refuse.
pub fn valuePositive(file: []const u8, value_expr: []const u8, allow_name: bool) bool {
    // What may legally follow the value: the end of an argument, of a struct
    // initializer, of a call, or of a declaration.
    const ends = struct {
        fn at(text: []const u8) bool {
            const rest = std.mem.trimStart(u8, text, " \t\r\n");
            return rest.len == 0 or rest[0] == ',' or rest[0] == '}' or rest[0] == ')' or rest[0] == ';';
        }
    }.at;
    const value = std.mem.trimStart(u8, value_expr, " \t\r\n");
    var digits: usize = 0;
    var nonzero = false;
    while (digits < value.len) : (digits += 1) {
        const ch = value[digits];
        if (ch == '_') continue;
        if (!std.ascii.isDigit(ch)) break;
        if (ch != '0') nonzero = true;
    }
    if (digits > 0) {
        if (!nonzero) return false;
        return ends(value[digits..]);
    }

    // The `driver.Budget` literal the buffer-explicit constructors take:
    // `.{ .ms = N }`, bounded exactly when N is.
    if (std.mem.startsWith(u8, value, ".{")) {
        const inner = value[2..];
        const ms = std.mem.indexOf(u8, inner, ".ms") orelse return false;
        const after_ms = std.mem.trimStart(u8, inner[ms + ".ms".len ..], " \t\r\n");
        if (after_ms.len == 0 or after_ms[0] != '=') return false;
        return valuePositive(file, after_ms[1..], allow_name);
    }

    for ([_][]const u8{
        "driver.default_handshake_budget",
        "driver.default_settle_budget",
        "glowcap.driver.default_handshake_budget",
        "glowcap.driver.default_settle_budget",
    }) |shared| {
        if (std.mem.startsWith(u8, value, shared) and ends(value[shared.len..])) return true;
    }

    if (!allow_name) return false;

    // An identifier, resolved against `const <name> ... = <literal>;`. One hop
    // only, except for the shared driver defaults handled above: wider
    // evaluation is more than this text check should infer.
    var name_len: usize = 0;
    while (name_len < value.len and (std.ascii.isAlphanumeric(value[name_len]) or value[name_len] == '_')) name_len += 1;
    if (name_len == 0) return false;
    if (!ends(value[name_len..])) return false;
    const name = value[0..name_len];

    var probe: usize = 0;
    while (std.mem.indexOfPos(u8, file, probe, "const ")) |c| {
        probe = c + "const ".len;
        if (!std.mem.startsWith(u8, file[probe..], name)) continue;
        const after = file[probe + name.len ..];
        if (after.len == 0 or std.ascii.isAlphanumeric(after[0]) or after[0] == '_') continue;
        const eq = std.mem.indexOfScalar(u8, after, '=') orelse continue;
        // Only across the declaration's own type annotation, never past a
        // newline into some later statement.
        if (std.mem.indexOfScalar(u8, after[0..eq], '\n') != null) continue;
        if (valuePositive(file, after[eq + 1 ..], false)) return true;
    }
    return false;
}

/// Whether `args` initializes `field` to a positive value.
///
/// The match must be a field initializer of exactly this name: a field whose
/// name merely ends in the one being looked for is a different field, and
/// accepting it is how a check reports coverage it does not have.
pub fn initializedPositive(file: []const u8, args: []const u8, field: []const u8) bool {
    var probe: usize = 0;
    while (std.mem.indexOfPos(u8, args, probe, field)) |f| {
        probe = f + field.len;
        // `.handshake`, not `my_handshake` and not a longer name this one is
        // a prefix of.
        if (f == 0 or args[f - 1] != '.') continue;
        if (probe < args.len and (std.ascii.isAlphanumeric(args[probe]) or args[probe] == '_')) continue;
        const after_name = std.mem.trimStart(u8, args[probe..], " \t\r\n");
        if (after_name.len == 0 or after_name[0] != '=') continue;
        if (valuePositive(file, after_name[1..], true)) return true;
    }
    return false;
}

pub fn checkExampleCaptpDeadlines(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    var dir = root.openDir(io, "examples/zig", .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "examples/zig: failed to open for CapTP-deadline check with {s}", .{@errorName(err)});
        return;
    };
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const path = try std.fmt.allocPrint(gpa, "examples/zig/{s}", .{entry.path});
        defer gpa.free(path);
        const contents = root.readFileAlloc(io, path, gpa, .limited(4 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for CapTP-deadline check with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        blankComments(contents);
        // The compiler refuses an omitted budget everywhere, so what is
        // left to hold here is the one that says forever out loud. An example
        // is copied, so it must not be the place a reader learns that spelling.
        {
            var line_no: usize = 1;
            var lines = std.mem.splitScalar(u8, contents, '\n');
            while (lines.next()) |line| : (line_no += 1) {
                if (std.mem.indexOf(u8, line, ".handshake = .unbounded") != null or
                    std.mem.indexOf(u8, line, ".settle = .unbounded") != null)
                {
                    try appendViolation(gpa, violations, "{s}:{d}: an unbounded CapTP budget waits forever on a silent peer, and a reader copies this line; name a finite `.{{ .ms = N }}`", .{ path, line_no });
                }
            }
        }
    }
}

/// Ctrl+C on `ocapn listen` must poll `waitAcceptable` rather than close the
/// listen FD from another thread (Zig Threaded Io panics on that BADF).
pub fn checkCliListenStopWake(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    try expectFileContains(io, gpa, root, violations, "cli/operability/signals.zig", &.{
        "accept-after-close",
        "must not close a listen FD",
        "pub const poll_ms",
    });
    try expectFileContains(io, gpa, root, violations, "cli/ocapn/listen_foreground.zig", &.{
        "waitAcceptable",
        "serveUntilStop",
        "signals.poll_ms",
    });
    try expectFileContains(io, gpa, root, violations, "cli/ocapn/listen_background.zig", &.{
        "waitAcceptable",
        "serveUntilStop",
        "signals.poll_ms",
    });
    try expectFileContains(io, gpa, root, violations, "src/net/netlayer.zig", &.{
        "waitAcceptable",
    });
    try expectFileContains(io, gpa, root, violations, "test/cli/captp_cases.zig", &.{
        "requestStop while accepting",
        "requestStop while serving",
    });
}

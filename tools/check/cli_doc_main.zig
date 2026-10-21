//! Validate documentation examples against the product's command registry.
const std = @import("std");
const cli = @import("cli");
const corpus = @import("source_check/docs/corpus.zig");
const util = @import("source_check/util.zig");
const Command = cli.cmd_types.Command;
const Flag = cli.cmd_types.Flag;

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    var root = try std.Io.Dir.cwd().openDir(init.io, std.mem.span(init.minimal.args.vector[1]), .{ .iterate = true });
    defer root.close(init.io);
    var violations: std.ArrayList([]const u8) = .empty;
    for (try corpus.load(init.io, gpa, root, &violations, gpa)) |entry| try checkText(gpa, &violations, entry.path, entry.text);
    for (violations.items) |message| std.debug.print("{s}\n", .{message});
    if (violations.items.len != 0) std.process.exit(1);
}

fn checkText(gpa: std.mem.Allocator, violations: *std.ArrayList([]const u8), path: []const u8, text: []const u8) !void {
    var shell = false;
    var fenced = false;
    var command: std.ArrayList(u8) = .empty;
    defer command.deinit(gpa);
    var lines = std.mem.splitScalar(u8, text, '\n');
    var number: usize = 0;
    while (lines.next()) |line| {
        number += 1;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "```") or std.mem.startsWith(u8, trimmed, "~~~")) {
            fenced = !fenced;
            shell = false;
            for ([_][]const u8{ "sh", "bash", "shell", "console", "zsh" }) |lang| {
                if (fenced and std.mem.eql(u8, trimmed[3..], lang)) shell = true;
            }
            continue;
        }
        if (!shell or std.mem.startsWith(u8, trimmed, "#")) continue;
        const continued = std.mem.endsWith(u8, trimmed, "\\");
        try command.appendSlice(gpa, if (continued) trimmed[0 .. trimmed.len - 1] else trimmed);
        if (continued) {
            try command.append(gpa, ' ');
            continue;
        }
        defer command.clearRetainingCapacity();
        try checkShell(gpa, violations, path, number, command.items);
    }
}

fn checkShell(gpa: std.mem.Allocator, violations: *std.ArrayList([]const u8), path: []const u8, number: usize, text: []const u8) !void {
    var start: usize = 0;
    var at: usize = 0;
    var quote: ?u8 = null;
    while (at < text.len) : (at += 1) {
        const c = text[at];
        if (c == '\\' and quote != '\'') {
            at += @intFromBool(at + 1 < text.len);
            continue;
        }
        if (quote != '\'' and c == '$' and at + 1 < text.len and text[at + 1] == '(') {
            var end = at + 2;
            var depth: usize = 1;
            while (end < text.len and depth > 0) : (end += 1) {
                if (text[end] == '(') depth += 1;
                if (text[end] == ')') depth -= 1;
            }
            if (depth == 0) {
                try checkShell(gpa, violations, path, number, text[at + 2 .. end - 1]);
                at = end - 1;
                continue;
            }
        }
        if (quote) |q| {
            if (c == q) quote = null;
            continue;
        }
        if (c == '\'' or c == '"') {
            quote = c;
            continue;
        }
        if (c == '#' and (at == 0 or std.ascii.isWhitespace(text[at - 1]))) {
            try checkInvocation(gpa, violations, path, number, text[start..at]);
            return;
        }
        if (c == '|' or c == ';' or c == '&') {
            try checkInvocation(gpa, violations, path, number, text[start..at]);
            start = at + 1;
        }
    }
    try checkInvocation(gpa, violations, path, number, text[start..]);
}
fn checkInvocation(gpa: std.mem.Allocator, violations: *std.ArrayList([]const u8), path: []const u8, number: usize, text: []const u8) !void {
    const args = try words(gpa, text);
    defer {
        for (args) |arg| gpa.free(arg);
        gpa.free(args);
    }
    var at: usize = 0;
    while (at < args.len) : (at += 1) {
        const arg = args[at];
        if (std.mem.eql(u8, arg, "$") or std.mem.eql(u8, arg, "exec") or std.mem.eql(u8, arg, "env") or assignment(arg)) continue;
        if (std.mem.eql(u8, arg, "docker") and at + 2 < args.len and std.mem.eql(u8, args[at + 1], "exec")) {
            at += 2;
            while (at < args.len and std.mem.startsWith(u8, args[at], "-")) : (at += 1) {
                if (std.mem.eql(u8, args[at], "-e") or std.mem.eql(u8, args[at], "-u") or std.mem.eql(u8, args[at], "-w")) at += 1;
            }
            continue; // the loop advances past the container name
        }
        if (std.mem.eql(u8, std.fs.path.basename(arg), "glowcap")) {
            if (problem(args[at + 1 ..])) |why| try util.appendViolation(gpa, violations, "{s}:{d}: glowcap example {s}", .{ path, number, why });
        }
        break;
    }
}
fn assignment(arg: []const u8) bool {
    const equal = std.mem.indexOfScalar(u8, arg, '=') orelse return false;
    if (equal == 0 or (!std.ascii.isAlphabetic(arg[0]) and arg[0] != '_')) return false;
    for (arg[0..equal]) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    return true;
}

fn words(gpa: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var word: std.ArrayList(u8) = .empty;
    defer word.deinit(gpa);
    var quote: ?u8 = null;
    var active = false;
    var i: usize = 0;
    while (i <= text.len) : (i += 1) {
        const c: u8 = if (i == text.len) ' ' else text[i];
        if (quote) |q| {
            if (c == q) {
                quote = null;
                continue;
            }
        } else {
            if ((c == '#' and !active) or c == '|' or c == ';' or c == '&' or (c == '>' and !active)) {
                if (active) try out.append(gpa, try gpa.dupe(u8, word.items));
                break;
            }
            if (c == '"' or c == '\'') {
                quote = c;
                active = true;
                continue;
            }
            if (std.ascii.isWhitespace(c)) {
                if (active) {
                    try out.append(gpa, try gpa.dupe(u8, word.items));
                    word.clearRetainingCapacity();
                    active = false;
                }
                continue;
            }
        }
        if (c == '\\' and quote != '\'' and i + 1 < text.len) {
            i += 1;
            try word.append(gpa, text[i]);
        } else try word.append(gpa, c);
        active = true;
    }
    return out.toOwnedSlice(gpa);
}

fn problem(args: []const []const u8) ?[]const u8 {
    var node: *const Command = &cli.tree.root;
    var path: [16]*const Command = undefined;
    var depth: usize = 1;
    path[0] = node;
    var seen: [128][]const u8 = undefined;
    var seen_count: usize = 0;
    var positional_count: usize = 0;
    var help = false;
    var flags_done = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) {
            flags_done = true;
            continue;
        }
        if (!flags_done and (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h"))) {
            help = true;
            continue;
        }
        if (!flags_done and std.mem.startsWith(u8, arg, "-")) {
            const eq = std.mem.indexOfScalar(u8, arg, '=') orelse arg.len;
            const flag = lookup(path[0..depth], arg[0..eq]) orelse return "uses an unknown flag";
            if (seen_count == seen.len) return "has too many flags";
            seen[seen_count] = flag.long;
            seen_count += 1;
            if (flag.kind == .string_flag and eq == arg.len) {
                i += 1;
                if (i == args.len) return "omits a flag value";
            }
            continue;
        }
        if (!node.isLeaf()) {
            node = node.findChild(arg) orelse return "does not resolve to a command";
            if (depth == path.len) return "exceeds command depth";
            path[depth] = node;
            depth += 1;
        } else positional_count += 1;
    }
    if (help) return null;
    if (!node.isLeaf() or node.run == null) return "must name a leaf command";
    for (node.flags) |flag| {
        // Required flags are declared by the command catalog's help metadata.
        if (std.mem.indexOf(u8, flag.help, "(required)") == null) continue;
        var found = false;
        for (seen[0..seen_count]) |name| {
            if (std.mem.eql(u8, name, flag.long)) found = true;
        }
        if (!found) return "omits a required flag declared by the command table";
    }
    var required: usize = 0;
    for (node.positionals) |pos| {
        if (pos.required) required += 1;
    }
    if (positional_count < required) return "omits a required positional argument";
    return null;
}
fn lookup(path: []const *const Command, spelling: []const u8) ?Flag {
    var inherited: [48]Flag = undefined;
    var count: usize = 0;
    cli.cmd_types.collectPersistent(path, &inherited, &count);
    for ([_][]const Flag{ path[path.len - 1].flags, inherited[0..count] }) |flags| {
        for (flags) |flag| {
            if (std.mem.startsWith(u8, spelling, "--") and std.mem.eql(u8, spelling[2..], flag.long)) return flag;
            if (spelling.len == 2 and flag.short != null and spelling[1] == flag.short.?) return flag;
        }
    }
    return null;
}

test "shell words stop at a pipeline but preserve quoted arguments" {
    const gpa = std.testing.allocator;
    const args = try words(gpa, "ocapn call '$LOC' greeter greet 'a | b' | python3 -c code");
    defer {
        for (args) |arg| gpa.free(arg);
        gpa.free(args);
    }
    try std.testing.expectEqual(@as(usize, 6), args.len);
    try std.testing.expectEqualStrings("a | b", args[5]);
}

test "examples resolve real leaves and required flags without executing" {
    try std.testing.expect(problem(&.{ "apps", "rooms", "session" }) != null);
    try std.testing.expect(problem(&.{ "apps", "rooms", "session", "start" }) != null);
    try std.testing.expect(problem(&.{ "apps", "rooms", "session", "start", "--dir=./workspace" }) == null);
    try std.testing.expect(problem(&.{ "apps", "rooms", "session", "--help" }) == null);
    try std.testing.expect(problem(&.{ "ocapn", "missing" }) != null);
    try std.testing.expect(problem(&.{ "--json", "ocapn", "call", "$LOC", "greeter", "greet", "world" }) == null);
}

test "every shell invocation is checked across assignments wrappers and pipelines" {
    const gpa = std.testing.allocator;
    var violations: std.ArrayList([]const u8) = .empty;
    defer {
        for (violations.items) |v| gpa.free(v);
        violations.deinit(gpa);
    }
    try checkText(gpa, &violations, "x.md", "```sh\nFOO=x glowcap invalid\nprintf x | glowcap invalid\nglowcap help; glowcap invalid\nenv FOO=x glowcap invalid\ndocker exec box /bin/glowcap invalid\n```\n");
    try std.testing.expectEqual(@as(usize, 5), violations.items.len);
    try checkText(gpa, &violations, "x.md", "```sh\nglowcap apps rooms session start --dir <member-dir>\necho 'glowcap invalid'\nglowcap help | cat -n\n```\n");
    try std.testing.expectEqual(@as(usize, 5), violations.items.len);
}

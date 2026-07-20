//! The CLI's built-in demo actors for `--publish` / `ocapn publish`.
//!
//! Names match the Zig examples (`greeter`) and the identity-echo helper
//! (`echo`). The say-verbs draw their speech balloons here so the CapTP seam
//! file next door stays about dial, session options, and exit codes.
const std = @import("std");
const pancake = @import("pancake");

const model = pancake.ocapn.model;
const actors = pancake.actors;

/// One row per demo verb: dispatch below and REPL Tab completion share this
/// table, so a new verb lands in both in the same change. Say-verbs carry
/// their balloon figure; the null-figure rows have bespoke arms in `handle`.
pub const DemoVerb = struct {
    name: []const u8,
    blurb: []const u8,
    figure: ?[]const u8 = null,
};

pub const demo_verbs = [_]DemoVerb{
    .{ .name = "greet", .blurb = "Greeter greet verb" },
    .{ .name = "cowsay", .blurb = "Greeter cowsay verb", .figure = cow_figure },
    .{ .name = "pancakesay", .blurb = "Greeter pancakesay verb", .figure = pancake_figure },
    .{ .name = "goblinsay", .blurb = "Greeter goblinsay verb", .figure = goblin_figure },
    .{ .name = "echo", .blurb = "Echo verb" },
};

const Greeter = struct {
    pub fn handle(self: *Greeter, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = self;
        if (msg.args.len != 1 or msg.args[0] != .string) return error.BadInvocation;
        const who = msg.args[0].string;
        if (std.mem.eql(u8, msg.verb, "greet")) {
            return .{ .string = try std.fmt.allocPrint(turn.arena, "Hello, {s}", .{who}) };
        }
        for (demo_verbs) |v| {
            const figure = v.figure orelse continue;
            if (std.mem.eql(u8, msg.verb, v.name)) {
                return .{ .string = try formatSay(turn.arena, who, figure) };
            }
        }
        return error.NoSuchMethod;
    }
};

/// Classic one-line cowsay balloon (CLI demo only — not a system cowsay).
const cow_figure =
    \\
    \\        \   ^__^
    \\         \  (oo)\_______
    \\            (__)\       )\/\
    \\                ||----w |
    \\                ||     ||
;

/// Stack-of-pancakes speech balloon (CLI demo — the product's own joke).
/// Middle cake wears a little face.
const pancake_figure =
    \\
    \\       \
    \\        \    .------.
    \\         \  (_|___|__)
    \\            (_|^_^|__)
    \\            (_____|__)
    \\             ~~syrup~~
;

/// Friendly goblin speech balloon (CLI demo doodle — not Spritely's mascot art).
/// Trailing spaces after `\` keep Zig from treating `\` as a line continue.
const goblin_figure =
    \\
    \\       \
    \\        \      ,^,
    \\         \   ( o.o )
    \\             \  =  /
    \\            /|     |\ 
    \\             U     U
;

fn formatSay(arena: std.mem.Allocator, msg: []const u8, figure: []const u8) ![]const u8 {
    const w = msg.len;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(arena);
    try out.append(arena, ' ');
    try out.appendNTimes(arena, '_', w + 2);
    try out.append(arena, '\n');
    try out.print(arena, "< {s} >\n", .{msg});
    try out.append(arena, ' ');
    try out.appendNTimes(arena, '-', w + 2);
    try out.appendSlice(arena, figure);
    return try out.toOwnedSlice(arena);
}

const Echo = struct {
    pub fn handle(self: *Echo, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = self;
        _ = turn;
        if (!std.mem.eql(u8, msg.verb, "echo")) return error.NoSuchMethod;
        if (msg.args.len != 1) return error.BadInvocation;
        return msg.args[0];
    }
};

/// The publishable built-in names, in `publishBuiltin`'s dispatch order. Tab
/// completion consumes this list; the dispatch below stays an if-chain because
/// each name binds a distinct actor type.
pub const names = [_][]const u8{ "greeter", "echo" };

/// Publish a named built-in on `session` (`greeter` or `echo`).
pub fn publishBuiltin(session: anytype, name: []const u8) !void {
    if (std.mem.eql(u8, name, "greeter")) {
        _ = try session.publish(name, Greeter, .{});
    } else if (std.mem.eql(u8, name, "echo")) {
        _ = try session.publish(name, Echo, .{});
    } else {
        return error.UnknownBuiltin;
    }
}

//! Rooms application commands use the product parser, help, and completion.
//! The Rust Rooms executable handles the parsed request through its shared
//! application. No Rooms wire or workspace state is owned by this adapter.
const std = @import("std");
const Ctx = @import("../../ctx.zig").Ctx;
const Parsed = @import("../../cmd/types.zig").Parsed;
const log = @import("../../operability/log.zig");
pub const commands = @import("session_commands.zig").commands;
pub const team_commands = @import("session_commands.zig").team_commands;

pub fn envelope(gpa: std.mem.Allocator, verb: []const u8, parsed: *const Parsed) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();
    var named: std.json.ObjectMap = .empty;
    var flags = parsed.flags.iterator();
    while (flags.next()) |flag| {
        const key = flag.key_ptr.*;
        if (std.mem.eql(u8, key, "dir")) continue;
        var values = std.array_list.Managed(std.json.Value).init(alloc);
        if (parsed.repeated.get(key)) |repeated| {
            for (repeated.items) |value| try values.append(.{ .string = value });
        } else {
            try values.append(.{ .string = switch (flag.value_ptr.*) {
                .string_flag => |value| value,
                .bool_flag => |value| if (value) "true" else "false",
            } });
        }
        try named.put(alloc, key, .{ .array = values });
    }
    return std.json.Stringify.valueAlloc(gpa, .{
        .verb = verb,
        .state = parsed.flagString("dir") orelse return error.Usage,
        .named = std.json.Value{ .object = named },
        .arguments = parsed.positionals,
    }, .{});
}

pub fn run(comptime verb: []const u8) *const fn (*Ctx, *Parsed) anyerror!u8 {
    return struct {
        fn execute(ctx: *Ctx, parsed: *Parsed) anyerror!u8 {
            if (parsed.flagString("dir") == null) {
                log.err(ctx.io, "--dir is required; reuse the same private workspace on every Rooms command", .{});
                return error.Usage;
            }
            const body = try envelope(ctx.gpa, verb, parsed);
            defer ctx.gpa.free(body);
            return @import("../../operability/installation.zig").replace(ctx, "rooms-session", &.{ "control", body });
        }
    }.execute;
}

//! The Host's values project as borrowed views (ADR-0246): every data arm
//! reads where the value lies, a container is a lazy sequence, and a
//! capability has no projection, which the scan the Host runs before
//! lending a tree makes unreachable.

const std = @import("std");
const builtin = @import("builtin");
const glowcap = @import("glowcap");

const core = glowcap.driver.core;
const model = glowcap.ocapn.model;
const value_views = core.value_views;
const Value = core.Value;

test "values project as views by arm, containers lazily" {
    const numbers = [_]Value{ .{ .integer = 4 }, .{ .integer = -5 } };
    const entries = [_]Value.StructEntry{
        .{ .key = "k", .value = .{ .string = "v" } },
        .{ .key = "n", .value = .{ .list = &numbers } },
    };
    const tagged_items = [_]Value{.{ .keyword = "kw" }};
    const values = [_]Value{
        .{ .bytes = "raw" },
        .{ .@"struct" = &entries },
        .{ .tagged = .{ .tag = "t", .value = &tagged_items } },
        .{ .set = &numbers },
        .{ .@"error" = .{ .message = "oops" } },
        .{ .boolean = true },
    };
    const args = value_views.args(&values);
    try std.testing.expectEqual(@as(usize, 6), try args.len());
    try std.testing.expectEqualStrings("raw", (try args.at(0)).bytes);
    const record = (try args.at(1)).@"struct";
    try std.testing.expectEqual(@as(usize, 2), try record.len());
    var entry_it = record.iterator();
    const first = (try entry_it.next()).?;
    try std.testing.expectEqualStrings("k", first.key);
    try std.testing.expectEqualStrings("v", first.value.string);
    const second = (try entry_it.next()).?;
    try std.testing.expectEqual(@as(i64, -5), (try second.value.list.at(1)).integer);
    try std.testing.expect((try entry_it.next()) == null);
    const tagged = (try args.at(2)).tagged;
    try std.testing.expectEqualStrings("t", tagged.tag);
    try std.testing.expectEqualStrings("kw", (try tagged.value.at(0)).keyword);
    try std.testing.expectEqual(@as(usize, 2), try (try args.at(3)).set.len());
    try std.testing.expectEqualStrings("oops", (try args.at(4)).@"error".message);
    try std.testing.expect((try args.at(5)).boolean);
    try std.testing.expectError(error.MalformedView, args.at(6));

    // The tail of a sequence is the same backing, further in.
    const rest = try args.from(4);
    try std.testing.expectEqual(@as(usize, 2), try rest.len());
    try std.testing.expect((try rest.at(1)).boolean);
    var it = args.iterator();
    var walked: usize = 0;
    while (try it.next()) |_| walked += 1;
    try std.testing.expectEqual(@as(usize, 6), walked);
}

test "a capability does not project and the scan finds one at any depth" {
    // The scan reads the identity only, so an empty registry stands in.
    const Registry = std.meta.Child(@FieldType(core.Capability, "registry"));
    const registry: Registry = .init(null);
    const capability: core.Capability = .{ .registry = &registry, .id = @fromBackingInt(@intCast(1)) };
    const inner = [_]Value{ .{ .integer = 1 }, .{ .capability = capability } };
    const entries = [_]Value.StructEntry{.{ .key = "c", .value = .{ .list = &inner } }};
    const deep = [_]Value{ .{ .string = "s" }, .{ .@"struct" = &entries } };
    try std.testing.expect(value_views.carriesCapability(&deep));
    try std.testing.expect(!value_views.carriesCapability(&inner[0..1].*));
    try std.testing.expectError(error.MalformedView, value_views.argument(&inner[1]));
    const args = value_views.args(&inner);
    try std.testing.expectError(error.MalformedView, args.at(1));
}

test "a slice of integers projects as a run, a list of integer values does not" {
    const words = [_]i64{ 7, -8, 9 };
    const one = [_]Value{.{ .integer = 7 }};
    const values = [_]Value{ .{ .integers = &words }, .{ .list = &one } };
    try std.testing.expect(!value_views.carriesCapability(&values));
    const args = value_views.args(&values);
    const run = (try args.at(0)).list;
    try std.testing.expectEqual(@as(usize, 3), try run.len());
    try std.testing.expectEqual(@as(i64, -8), (try run.at(1)).integer);
    if (builtin.cpu.arch.endian() == .little) try std.testing.expectEqualSlices(i64, &words, run.typedRun().?);
    try std.testing.expect((try args.at(1)).list.typedRun() == null);
}

test "Host copy measurement and capability visits give integer runs list depth" {
    const Visitor = struct {
        fn visit(_: void, _: core.Capability) !void {
            return error.UnexpectedCapability;
        }
    };
    const scalar = [_]Value{.{ .integer = 7 }};
    const leaves = [_]Value{
        .{ .integers = &.{7} }, .{ .list = &scalar },
        .{ .integers = &.{} },  .{ .list = &.{} },
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for (leaves, 0..) |leaf, shape| {
        for ([_]usize{ 63, 64 }) |depth| {
            var backing: [65][1]Value = undefined;
            backing[depth][0] = leaf;
            var level = depth;
            while (level != 0) {
                level -= 1;
                backing[level][0] = .{ .list = &backing[level + 1] };
            }
            const root = backing[0][0];
            if (depth == 64 and shape < 2) {
                try std.testing.expectError(error.ValueTooDeep, core.copyValue(Value, arena.allocator(), root));
                try std.testing.expectError(error.ValueTooDeep, core.copyValue(model.Argument, arena.allocator(), root));
                try std.testing.expectError(error.ValueTooDeep, core.valueCopyBytes(&.{root}));
                try std.testing.expectError(error.ValueTooDeep, root.forEachCapability({}, Visitor.visit));
            } else {
                _ = try core.copyValue(Value, arena.allocator(), root);
                _ = try core.copyValue(model.Argument, arena.allocator(), root);
                _ = try core.valueCopyBytes(&.{root});
                try root.forEachCapability({}, Visitor.visit);
            }
        }
    }
}

test "served Host reply lends containers without turn storage and near reply keeps lowering" {
    const allocator = std.testing.allocator;
    var host = @import("../support/core_host.zig").init(allocator, @splat(0x6a), .withFrameCap(4096));
    defer host.deinit();
    const session = try @import("../support/host_pair.zig").publishAndOpenAccepted(&host, "tcp", "127.0.0.1:8080", "");
    var vat = glowcap.actors.Vat.init(allocator);
    defer vat.deinit();
    var empty: [0]u8 = .{};
    var arena = std.heap.FixedBufferAllocator.init(&empty);
    var turn = glowcap.actors.Turn{
        .vat = &vat,
        .port = &session.served.port,
        .self_ref = .{ .local = 0 },
        .ingress = .local,
        .arena = arena.allocator(),
        .origin = .{ .served = null },
    };
    const Handler = struct {
        pub fn handle(_: *@This(), _: *core.HostTurn, _: []const u8, _: core.Args) !Value {
            return .{ .@"struct" = &.{.{ .key = "value", .value = .{ .integer = 42 } }} };
        }
    };
    var adapter: core.Hosting(Handler) = .{ .inner = .{} };
    const reply = try adapter.handle(&turn, .{ .verb = "get", .reference_slots = 0 });
    try std.testing.expectEqual(@as(i64, 42), (try reply.viewed.@"struct".at(0)).value.integer);
    turn.origin = .local;
    try std.testing.expectError(error.OutOfMemory, adapter.handle(&turn, .{ .verb = "get", .reference_slots = 0 }));
}

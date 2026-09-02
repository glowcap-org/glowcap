const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const session = glowcap.ocapn.session;
const inspect = session.inspect;

test "session inspect walks export and import rows" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();

    try s.registerExport(.from(3));
    try s.registerImport(.from(7));
    try std.testing.expectEqual(@as(usize, 1), inspect.exportCount(&s));
    try std.testing.expectEqual(@as(usize, 1), inspect.importCount(&s));

    const ExportCtx = struct {
        n: usize = 0,
        pos: u64 = 0,
        fn visit(c: *@This(), v: session.ExportView) void {
            c.n += 1;
            c.pos = v.position.int();
        }
    };
    var ex = ExportCtx{};
    inspect.forEachExport(&s, &ex, ExportCtx.visit);
    try std.testing.expectEqual(@as(usize, 1), ex.n);
    try std.testing.expectEqual(@as(u64, 3), ex.pos);

    const ImportCtx = struct {
        n: usize = 0,
        pos: u64 = 0,
        fn visit(c: *@This(), v: session.ImportView) void {
            c.n += 1;
            c.pos = v.position.int();
        }
    };
    var im = ImportCtx{};
    inspect.forEachImport(&s, &im, ImportCtx.visit);
    try std.testing.expectEqual(@as(usize, 1), im.n);
    try std.testing.expectEqual(@as(u64, 7), im.pos);
}

test "session inspect walks outbound answers from a sent deliver" {
    const allocator = std.testing.allocator;
    var s = session.Session.init(allocator);
    defer s.deinit();
    try s.registerImport(.from(7));

    try s.recordSend(.{
        .deliver = .{
            .target = .{ .far = .{ .import_position = .from(7) } },
            .args = &.{.{ .bytes = "hello" }},
            .answer = .from(42),
        },
    });
    try std.testing.expectEqual(@as(usize, 1), inspect.outboundAnswerCount(&s));
    try std.testing.expectEqual(@as(usize, 0), inspect.inboundAnswerCount(&s));

    const Ctx = struct {
        n: usize = 0,
        pos: u64 = 0,
        fn visit(c: *@This(), v: session.AnswerRowView) void {
            c.n += 1;
            c.pos = switch (v.position) {
                .wire => |wire| wire.int(),
                .virtual => |virtual| virtual.int(),
            };
        }
    };
    var out = Ctx{};
    inspect.forEachOutboundAnswer(&s, &out, Ctx.visit);
    try std.testing.expectEqual(@as(usize, 1), out.n);
    try std.testing.expectEqual(@as(u64, 42), out.pos);

    var inbound = Ctx{};
    inspect.forEachInboundAnswer(&s, &inbound, Ctx.visit);
    try std.testing.expectEqual(@as(usize, 0), inbound.n);
}

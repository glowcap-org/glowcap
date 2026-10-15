//! Parsed integer runs preserve session nesting limits on both slab paths.

const std = @import("std");
const glowcap = @import("glowcap");
const model = glowcap.ocapn.model;
const session = glowcap.ocapn.session;
const syrup = glowcap.ocapn.codec.syrup;

test "a decoded integer run obeys the same session depth bound as lazy integers" {
    const samples = "0+1+2+3+4+5+6+7+8+9+10+11+";
    const accepted = "<10'op:deliver<11'desc:export7+>[[" ++ samples ++ "]]ff>";
    const refused = "<10'op:deliver<11'desc:export7+>[[[" ++ samples ++ "]]]ff>";
    for ([_]usize{ 0, 16 }) |capacity| {
        for ([_][]const u8{ accepted, refused }, 0..) |bytes, i| {
            var views: [16]model.view.Argument = undefined;
            var slab = model.view.ValueSlab.init(std.mem.sliceAsBytes(views[0..capacity]));
            const body = try syrup.decodeBodyInto(.v1_0, .{ .bytes = bytes, .shape = .byte }, &slab);
            var s = session.Session.initWith(std.testing.allocator, .{ .limits = .{ .max_nesting_depth = 1 } });
            defer s.deinit();
            try s.registerExport(.from(7));
            if (i == 0) {
                if (capacity != 0) try std.testing.expect((try body.deliver.args.at(0)).list.wordRun() != null);
                try s.recordRecvView(body);
            } else {
                try std.testing.expectError(error.NestingTooDeep, s.recordRecvView(body));
            }
        }
    }
}

//! Parsed integer runs preserve the session's nesting ceiling on both slab paths.

const std = @import("std");
const glowcap = @import("glowcap");
const model = glowcap.ocapn.model;
const session = glowcap.ocapn.session;
const syrup = glowcap.ocapn.codec.syrup;

/// A deliver whose argument is `depth` lists nested around one run of
/// integers, so the run's own list sits at `depth`: one bracket opens the
/// argument list and `depth + 1` open the lists inside it.
fn deliverBytes(buffer: []u8, depth: usize) []const u8 {
    const head = "<10'op:deliver<11'desc:export7+>";
    const samples = "0+1+2+3+4+5+6+7+8+9+10+11+";
    const tail = "ff>";
    const brackets = depth + 2;
    var len: usize = 0;
    @memcpy(buffer[len..][0..head.len], head);
    len += head.len;
    @memset(buffer[len..][0..brackets], '[');
    len += brackets;
    @memcpy(buffer[len..][0..samples.len], samples);
    len += samples.len;
    @memset(buffer[len..][0..brackets], ']');
    len += brackets;
    @memcpy(buffer[len..][0..tail.len], tail);
    len += tail.len;
    return buffer[0..len];
}

test "a decoded integer run obeys the same session depth bound as lazy integers" {
    var buffer: [512]u8 = undefined;
    // The run's list is a container, so it may sit one level short of the
    // ceiling and its items sit at the ceiling.
    for ([_]usize{ model.max_value_depth - 1, model.max_value_depth, model.max_value_depth + 1 }) |depth| {
        const bytes = deliverBytes(&buffer, depth);
        for ([_]usize{ 0, 128 }) |capacity| {
            var views: [128]model.view.Argument = undefined;
            var slab = model.view.ValueSlab.init(std.mem.sliceAsBytes(views[0..capacity]));
            var body: model.view.Body = undefined;
            try syrup.decodeBodyInto(.v1_0, .{ .bytes = bytes, .shape = .byte }, &slab, &body);
            // The run sits in the innermost list. The parsed slab holds it as a
            // word run, and the lazy path walks its integers one at a time.
            var innermost = try body.deliver.args.at(0);
            for (0..depth) |_| innermost = try innermost.list.at(0);
            try std.testing.expectEqual(capacity != 0, innermost.list.wordRun() != null);
            var s = session.Session.init(std.testing.allocator);
            defer s.deinit();
            try s.registerExport(.from(7));
            if (depth < model.max_value_depth) {
                try s.recordRecvView(body);
            } else {
                try std.testing.expectError(error.NestingTooDeep, s.recordRecvView(body));
            }
        }
    }
}

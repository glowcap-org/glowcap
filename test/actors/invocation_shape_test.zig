//! CapTP's op:deliver argument list is authoritative. These authored lists
//! test actor projection and forwarding independently of its message builder.
const std = @import("std");
const glowcap = @import("glowcap");
const model = glowcap.ocapn.model;
const actors = glowcap.actors;
const engine = glowcap.ocapn.engine;
const a = std.testing.allocator;

const Case = struct { verb: ?[]const u8, args: []const model.Argument, wire: []const model.Argument };
const cases = [_]Case{
    .{ .verb = null, .args = &.{}, .wire = &.{} },
    .{ .verb = "", .args = &.{}, .wire = &.{.{ .symbol = "" }} },
    .{ .verb = "call", .args = &.{}, .wire = &.{.{ .symbol = "call" }} },
    .{ .verb = null, .args = &.{.{ .integer = 37 }}, .wire = &.{.{ .integer = 37 }} },
    .{ .verb = "", .args = &.{.{ .integer = 37 }}, .wire = &.{ .{ .symbol = "" }, .{ .integer = 37 } } },
    .{ .verb = "call", .args = &.{.{ .integer = 37 }}, .wire = &.{ .{ .symbol = "call" }, .{ .integer = 37 } } },
};

fn expectArgs(expected: []const model.Argument, actual: model.view.Args) !void {
    try std.testing.expectEqual(expected.len, try actual.len());
    for (expected, 0..) |value, i| {
        const got = try actual.at(i);
        try std.testing.expectEqualStrings(@tagName(value), @tagName(got));
        switch (value) {
            .symbol => |symbol| try std.testing.expectEqualStrings(symbol, got.symbol),
            .integer => |integer| try std.testing.expectEqual(integer, got.integer),
            else => unreachable,
        }
    }
}

fn paired(syrup: bool) !engine.pairing.Pair {
    return if (syrup) engine.pairing.pairedV1_0Syrup(a) else engine.pairing.paired(a);
}

fn shuttle(pair: *engine.pairing.Pair) !void {
    try std.testing.expectEqual(engine.pairing.ShuttleOutcome.quiescent, try engine.pairing.shuttleUntilQuiescent(&pair.p1, &pair.p2));
}

test "actor invocation builders preserve authored lists in both codecs and both representations" {
    for ([_]bool{ false, true }) |syrup| {
        var pair = try paired(syrup);
        defer pair.deinit();
        try pair.p1.importObject(5);
        try pair.p2.exportObject(5);
        var vat = actors.Vat.init(a);
        defer vat.deinit();
        var port = actors.Port.init(a, &pair.p1);
        defer port.deinit(&vat);
        for (cases) |case| {
            for ([_]bool{ false, true }) |freight| {
                const remote: actors.Ref = .{ .far = model.FarRef.object(5) };
                if (freight) {
                    try port.tellDelivery(&vat, remote, .{ .verb = case.verb, .args = .fromOwnedSlice(case.args), .reference_slots = 0 });
                } else {
                    try port.tell(&vat, remote, .{ .verb = case.verb, .args = case.args });
                }
                try shuttle(&pair);
                var event = pair.p2.pollEvent() orelse return error.MissingDelivery;
                defer event.deinit();
                try expectArgs(case.wire, event.view().deliver.args);
            }
        }
    }
}

const Forwarder = struct {
    target: actors.Ref,
    pub fn handle(self: *Forwarder, turn: *actors.Turn, msg: actors.Delivery) !model.Argument {
        return turn.forward(self.target, msg);
    }
};

test "actor forwarding round-trips authored positional lists in both codecs" {
    for ([_]bool{ false, true }) |syrup| {
        var pair = try paired(syrup);
        defer pair.deinit();
        try pair.p1.importObject(5);
        try pair.p2.exportObject(5);
        try pair.p2.importObject(6);
        try pair.p1.exportObject(6);
        var vat = actors.Vat.init(a);
        defer vat.deinit();
        var port = actors.Port.init(a, &pair.p2);
        defer port.deinit(&vat);
        const proxy = try vat.spawn(Forwarder, .{ .target = .{ .far = model.FarRef.object(6) } });
        try port.bindExport(&vat, proxy, 5);
        for (cases) |case| {
            try pair.p1.sendBorrowed(.{ .deliver = .{ .target = .{ .far = model.FarRef.object(5) }, .args = case.wire } });
            try shuttle(&pair);
            var incoming = pair.p2.pollEvent() orelse return error.MissingDelivery;
            defer incoming.deinit();
            _ = try port.serve(&vat, &incoming);
            try shuttle(&pair);
            var forwarded = pair.p1.pollEvent() orelse return error.MissingForward;
            defer forwarded.deinit();
            try expectArgs(case.wire, forwarded.view().deliver.args);
        }
    }
}

const Probe = struct {
    expected: *const Case,
    pub fn handle(self: *Probe, _: *actors.Turn, msg: actors.Delivery) !model.Argument {
        try std.testing.expectEqual(self.expected.verb != null, msg.verb != null);
        if (self.expected.verb) |method| try std.testing.expectEqualStrings(method, msg.verb.?);
        try expectArgs(self.expected.args, msg.args);
        return .{ .void = {} };
    }
};

test "local invocation preserves selector presence through near calls and queue copies" {
    var vat = actors.Vat.init(a);
    defer vat.deinit();
    for (&cases) |*case| {
        const probe = try vat.spawn(Probe, .{ .expected = case });
        const message: actors.Message = .{ .verb = case.verb, .args = case.args };
        _ = try vat.near(probe, message);
        try vat.tell(probe, message);
        try vat.drive();
    }
}

test "attenuation grants an empty selector without granting direct invocation" {
    var vat = actors.Vat.init(a);
    defer vat.deinit();
    const target = try vat.spawn(Probe, .{ .expected = &cases[1] });
    const proxy = try actors.ocap.attenuate(&vat, target, &.{""});
    _ = try vat.near(proxy, .{ .verb = "" });
    try std.testing.expectError(actors.ocap.Error.Attenuated, vat.near(proxy, .{}));
    try std.testing.expectError(actors.ocap.Error.Attenuated, vat.near(proxy, .{ .verb = "call" }));
}

test "direct raw argument list reconstructs a leading symbol after actor splitting" {
    for ([_][]const u8{ "", "call" }) |symbol| {
        const authored = [_]model.Argument{ .{ .symbol = symbol }, .{ .integer = 37 } };
        const wire_delivery = try actors.Delivery.fromArgs(.fromOwnedSlice(&authored));
        try std.testing.expectEqualStrings(symbol, wire_delivery.verb.?);
        try std.testing.expectEqual(@as(usize, 1), try wire_delivery.args.len());
        // A direct receiver takes the whole list, including the peeled symbol.
        // This scalar fixture reconstructs borrowed data, not a server adapter.
        const reconstructed = [_]model.Argument{
            .{ .symbol = wire_delivery.verb.? },
            .{ .integer = (try wire_delivery.arg(0)).integer },
        };
        try expectArgs(&authored, .fromOwnedSlice(&reconstructed));
        const near_delivery = (actors.Message{ .verb = null, .args = &authored }).delivery();
        try std.testing.expect(near_delivery.verb == null);
        try expectArgs(&authored, near_delivery.args);
    }
}

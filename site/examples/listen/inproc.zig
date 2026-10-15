const std = @import("std");
const glowcap = @import("glowcap");

pub fn example(io: std.Io, allocator: std.mem.Allocator) !void {
    var exchange = glowcap.net.inproc_completion.Exchange.init(allocator);
    defer exchange.deinit();
    const server = try glowcap.driver.listen(
        allocator,
        io,
        .{ .symbols = &.{.inproc}, .inproc = &exchange },
        glowcap.ocapn.model.transport.inproc,
        .{ .designator = "greeter" },
        .ephemeral,
        .{ .handshake = .{ .ms = 10_000 }, .settle = .{ .ms = 10_000 } },
    );
    defer server.deinit();

    try serve(server);
}

// From here, the CapTP workflow is transport-independent.
const Greeter = struct {
    pub fn handle(_: *Greeter, ht: *glowcap.driver.HostTurn, verb: []const u8, args: glowcap.driver.Args) !glowcap.driver.Value {
        if (!std.mem.eql(u8, verb, "greet")) return error.NoSuchMethod;
        if ((try args.len()) != 1) return error.BadInvocation;
        return .{ .string = try std.fmt.allocPrint(ht.turn.arena, "Hello, {s}", .{try args.string(0)}) };
    }
};

fn serve(server: *glowcap.driver.Server) !void {
    try server.publish("greeter", Greeter, .{});
    while (true) {
        var session = try server.accept();
        defer session.deinit();
        try session.serve();
    }
}

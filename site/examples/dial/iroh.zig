const std = @import("std");
const glowcap = @import("glowcap");
const iroh = @import("iroh");

pub fn example(io: std.Io, allocator: std.mem.Allocator) !void {
    // Discovery resolves a bare iroh node ID without an address hint.
    var iroh_resident = try iroh.Resident.init(io, null, .{ .reachability = .discovery });
    defer iroh_resident.deinit() catch |err| std.log.err("iroh teardown failed: {s}", .{@errorName(err)});
    const netlayers = [_]glowcap.net.netlayer.Netlayer{iroh_resident.netlayer()};
    const node_id = "<64 lowercase hex characters from the server>";
    const partner = iroh.locator(node_id);

    // From here, the CapTP workflow is transport-independent.
    const session = try glowcap.driver.connect(
        allocator,
        &netlayers,
        partner,
        .ephemeral,
        .{ .handshake = .{ .ms = 10_000 }, .settle = .{ .ms = 10_000 } },
    );
    defer session.deinit();

    const greeter = try session.fetch("greeter"); // a capability this peer published
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const settled = try session.call(greeter, "greet", &.{.{ .string = "world" }}, arena.allocator());
    switch (settled) {
        .fulfilled => |value| std.debug.print("{s}\n", .{value.string}),
        .broken => |reason| std.debug.print("the greeter refused: {s}\n", .{reason}),
    }
}
